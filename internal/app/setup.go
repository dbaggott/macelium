package app

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/dbaggott/macelium/internal/run"
	"github.com/dbaggott/macelium/internal/term"
)

// setup finds the state repo and sets this Mac up from it, or, when there
// is none, captures this Mac into a new one, scans it for secrets and pushes
// it once the operator says to, then sets this Mac up from it. Each step is
// skipped when what it leaves is already there, so running it again goes on
// from where it stopped.
//
// Its prompts read the terminal, and fail at end-of-file, even after a
// partly typed reply, so a run whose terminal has gone away stops at a
// question and takes no at an offer, rather than guess.

const signInNeeds = "needs a personal access token or a registered SSH key, since account passwords are refused over HTTPS; git asks for what it needs"

// The exit status gitleaks is told to give when it finds a secret, apart
// from the 1 it gives when it fails.
const gitleaksFoundStatus = 3

var (
	gitURLRe   = regexp.MustCompile(`^(https|ssh)://([^/@]+@)?([^/@:]+)(:[0-9]+)?/(.*)$`)
	scpURLRe   = regexp.MustCompile(`^([^/@:]+@)?([^/@:]+):(.*)$`)
	ownerRepo  = regexp.MustCompile(`^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$`)
	usernameRe = regexp.MustCompile(`^[A-Za-z0-9-]+$`)
)

// parseGitURL takes a git URL: https://, ssh:// or scp form,
// [user@]host:path, and returns its host, and its path without its leading
// /, trailing / or .git. A user name or a port is no part of either.
func parseGitURL(u string) (host, path string, ok bool) {
	if m := gitURLRe.FindStringSubmatch(u); m != nil {
		host, path = m[3], m[5]
	} else if m := scpURLRe.FindStringSubmatch(u); m != nil && !strings.Contains(u, "://") {
		host, path = m[2], m[3]
	} else {
		return "", "", false
	}
	path = strings.TrimPrefix(path, "/")
	path = strings.TrimSuffix(path, "/")
	path = strings.TrimSuffix(path, ".git")
	return host, path, path != "" && !strings.ContainsAny(path, " \t\n\r\v\f")
}

// stateRepo is the state repo setup works with: its host, whether that is
// GitHub, its path there, which GitHub's names compare in any case, the URL
// to clone, and how to name it.
type stateRepo struct {
	host     string
	github   bool
	repoPath string
	url      string
	name     string
}

// parseStateRepo takes <owner>/<repo>, meaning GitHub, or a git URL.
func parseStateRepo(arg string) (stateRepo, bool) {
	var r stateRepo
	if ownerRepo.MatchString(arg) {
		r.host, r.repoPath = "github.com", strings.TrimSuffix(arg, ".git")
		r.url = "https://github.com/" + r.repoPath
	} else if host, path, ok := parseGitURL(arg); ok {
		r.host, r.repoPath, r.url = host, path, arg
	} else {
		return r, false
	}
	r.name = r.url
	if strings.EqualFold(r.host, "github.com") {
		r.github, r.name = true, r.repoPath
		return r, ownerRepo.MatchString(r.repoPath)
	}
	return r, true
}

// NamesStateRepo reports whether setup takes arg as its state repo.
func NamesStateRepo(arg string) bool {
	_, ok := parseStateRepo(arg)
	return ok
}

// names reports whether a git remote URL names the state repo: on GitHub,
// in any case; elsewhere, the same host and path exactly.
func (r stateRepo) names(remote string) bool {
	host, path, ok := parseGitURL(remote)
	if !ok {
		return false
	}
	if r.github {
		return strings.EqualFold(host, "github.com") && strings.EqualFold(path, r.repoPath)
	}
	return host == r.host && path == r.repoPath
}

// setup is the state the setup flow shares.
type setup struct {
	*Session
	stateRepo
	path, pathState    string
	login              string
	signedIn, toldSign bool
	wentOn             bool
	found              string
	public             bool
	secretsFound       bool
}

// dirname returns the directory part of a path, as dirname(1) does.
func dirname(p string) string {
	trimmed := strings.TrimRight(p, "/")
	if trimmed == "" {
		return "/"
	}
	return filepath.Dir(trimmed)
}

// defaultPath returns where the state repo goes when no path is given: in
// the first of the directories people keep code in that this Mac has, else
// the home directory.
func (u *setup) defaultPath() string {
	base := u.repoPath[strings.LastIndex(u.repoPath, "/")+1:]
	for _, dir := range []string{"Developer", "git", "src", "code", "Projects"} {
		if isDir(filepath.Join(u.home, dir)) {
			return u.home + "/" + dir + "/" + base
		}
	}
	return u.home + "/" + base
}

// readPathState sets pathState to what the path holds: empty, when it is
// missing or an empty directory; named, a repo whose remote names the state
// repo; unpushed, a repo with macelium.conf and no remote, as init leaves
// it; else other. A repo counts only at its top level.
func (u *setup) readPathState() {
	u.pathState = "other"
	if !exists(u.path) || emptyDir(u.path) {
		u.pathState = "empty"
		return
	}
	if !isDir(u.path) {
		return
	}
	top, status := run.Output("git", "-C", u.path, "rev-parse", "--show-toplevel")
	abs, err := filepath.Abs(u.path)
	if err == nil {
		abs, err = filepath.EvalSymlinks(abs)
	}
	if status != 0 || err != nil || top != abs {
		return
	}
	remote, _ := run.Output("git", "-C", u.path, "config", "--get", "remote.origin.url")
	if remote != "" {
		if u.names(remote) {
			u.pathState = "named"
		}
	} else if isFile(filepath.Join(u.path, "macelium.conf")) {
		u.pathState = "unpushed"
	}
}

// ask asks a question with its default, which may be empty, and returns
// the reply, or the default when the reply is empty. At end-of-file, it
// says the run stopped. Unlike askValue, it never takes the default at
// end-of-file, and an empty default allows an empty reply.
func (u *setup) ask(question, def string) (string, bool) {
	hint := ""
	if def != "" {
		hint = " [" + def + "]"
	}
	answer, ok := term.Prompt(question + hint + ": ")
	if !ok {
		term.WriteTTY("\n")
		u.printStopped("no answer")
		return "", false
	}
	if answer == "" {
		answer = def
	}
	return answer, true
}

// choose asks a question with two choices, and the number of the default
// one or "", until the reply is 1 or 2, or empty with a default.
func (u *setup) choose(question, def, one, two string) (string, bool) {
	term.WriteTTY(fmt.Sprintf("%s\n  1) %s\n  2) %s\n", question, one, two))
	for {
		answer, ok := u.ask("Choose 1 or 2", def)
		if !ok {
			return "", false
		}
		if answer == "1" || answer == "2" {
			return answer, true
		}
	}
}

// askYes asks a yes-or-no question, as confirm does. At end-of-file, it
// says the run stopped.
func (u *setup) askYes(question string, def bool) (yes, ok bool) {
	switch u.confirm(question, def) {
	case 0:
		return true, true
	case 1:
		return false, true
	}
	term.WriteTTY("\n")
	u.printStopped("no answer")
	return false, false
}

// askPath sets path to the answer to where the state repo goes,
// defaultPath offered, with a leading ~ expanded and a relative path made
// absolute. A directory to hold it that is missing is created on a yes,
// and a no asks again.
func (u *setup) askPath(question string) bool {
	for {
		answer, ok := u.ask(question, u.defaultPath())
		if !ok {
			return false
		}
		path := answer
		if path == "~" || strings.HasPrefix(path, "~/") {
			path = u.home + path[1:]
		}
		if !strings.HasPrefix(path, "/") {
			wd, _ := os.Getwd()
			path = wd + "/" + path
		}
		u.path = path
		parent := dirname(path)
		if isDir(parent) {
			return true
		}
		yes, ok := u.askYes("The path "+parent+" does not exist, should I create it?", true)
		if !ok {
			return false
		}
		if !yes {
			continue
		}
		if os.MkdirAll(parent, 0o755) == nil {
			return true
		}
		u.printError("could not create " + parent)
	}
}

// tellSignIn prints the line saying how a host other than GitHub signs in,
// once a run.
func (u *setup) tellSignIn(host string) {
	if u.toldSign {
		return
	}
	u.heading(host + " sign-in: " + signInNeeds)
	u.toldSign = true
}

func ghSignedIn() bool {
	_, status := run.Capture(nil, "gh", "auth", "status", "--hostname", "github.com")
	return status == 0
}

// readLogin sets login to the account gh is signed in to GitHub as, failing
// when it is signed in to none.
func (u *setup) readLogin() bool {
	login, status := run.Output("gh", "api", "user", "--jq", ".login")
	u.login = login
	return status == 0 && login != ""
}

// ghAuthLogin runs gh's browser sign-in to GitHub, which adds the account
// to any gh is already signed in to and makes it the active one.
func (u *setup) ghAuthLogin() bool {
	cmd := exec.Command("gh", "auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web")
	if tty, err := os.Open("/dev/tty"); err == nil {
		defer tty.Close()
		cmd.Stdin = tty
	}
	cmd.Stdout, cmd.Stderr = u.Out, u.Err
	if cmd.Run() != nil {
		u.printError("gh auth login failed")
		return false
	}
	return true
}

// signInToGitHub signs in to GitHub with gh, unless it is, has git use it,
// and says who it is signed in as, once a run.
func (u *setup) signInToGitHub() bool {
	if u.signedIn {
		return true
	}
	if !ghSignedIn() {
		u.heading("Signing in to GitHub")
		if !u.ghAuthLogin() {
			return false
		}
	}
	if u.interactive("gh", "auth", "setup-git", "--hostname", "github.com") != 0 {
		u.printError("gh auth setup-git failed")
		return false
	}
	if !u.readLogin() {
		u.printError("gh api user did not say who is signed in")
		return false
	}
	u.heading("Signed in to GitHub as " + u.login)
	u.signedIn = true
	return true
}

// lsRemoteAnonymously reads a GitHub repo's refs with no credential
// helper, so a gh signed in before this run can't make a private repo read
// as public.
func lsRemoteAnonymously(repoPath string) (string, bool) {
	cmd := exec.Command("git", "-c", "credential.helper=", "ls-remote", "https://github.com/"+repoPath)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	out, err := cmd.Output()
	return string(out), err == nil
}

// findRepo finds the state repo, setting found to refs, empty (a repo with
// no refs) or missing, and public when git reads it without a sign-in. On
// GitHub it reads anonymously, then, unless anonymous, signs in and asks
// gh; elsewhere it reads with git, and a repo git can't read stops the run.
func (u *setup) findRepo(anonymous bool) bool {
	u.found, u.public = "missing", false
	if u.github {
		// Once this run has signed in, gh decides.
		if !u.signedIn {
			if refs, ok := lsRemoteAnonymously(u.repoPath); ok {
				u.public, u.found = true, "refs"
				if refs == "" {
					u.found = "empty"
				}
				return true
			}
		}
		if anonymous {
			return true
		}
		if !u.signInToGitHub() {
			u.printStopped("looking for " + u.name + " needs a GitHub sign-in")
			return false
		}
		// Only gh's not-found error means there is no repo; any other, such
		// as a network failure, stops rather than offer to create one.
		view, status := run.Capture(nil, "gh", "repo", "view", u.repoPath, "--json", "isEmpty,visibility", "--jq", `"\(.isEmpty) \(.visibility)"`)
		if status != 0 {
			if strings.Contains(view, "Could not resolve to a Repository") {
				return true
			}
			fmt.Fprintln(u.Err, view)
			u.printStopped("gh repo view " + u.repoPath + " failed")
			return false
		}
		u.found = "refs"
		if strings.HasPrefix(view, "true") {
			u.found = "empty"
		}
		u.public = strings.HasSuffix(view, "PUBLIC")
		return true
	}
	u.tellSignIn(u.host)
	refs, status := runStdout("git", "ls-remote", u.url)
	if status != 0 {
		u.printStopped("git can't read " + u.url + ". " + u.host + " sign-in: " + signInNeeds)
		return false
	}
	u.found = "refs"
	if refs == "" {
		u.found = "empty"
	}
	return true
}

// cloneAndBootstrap clones the state repo to the path, unless it already
// holds the clone, and bootstraps it, then offers the GitHub sign-in when
// offerSignIn is set.
func (u *setup) cloneAndBootstrap(offerSignIn, cloned bool) int {
	if cloned {
		u.heading("Clone: " + u.path + " is already a clone of " + u.name)
	} else {
		u.heading("Cloning " + u.name + " to " + u.path)
		if os.MkdirAll(dirname(u.path), 0o755) != nil || u.interactive("git", "clone", u.url, u.path) != 0 {
			u.printStopped("git clone " + u.url + " failed")
			return 1
		}
	}

	u.heading("macelium bootstrap " + u.path)
	if status := bootstrapCheckout(u.Session, u.path); status != 0 {
		return status
	}

	// The repo read without a sign-in, so pushing to it still needs one. The
	// Mac is set up by now, so end-of-file is a no, and a failed sign-in is
	// reported, not a failure.
	if offerSignIn && !ghSignedIn() {
		if u.confirm("Sign in to GitHub with gh, so you can push changes from this machine?", true) == 0 {
			if !u.signInToGitHub() {
				u.heading("GitHub sign-in: failed; run gh auth login and gh auth setup-git to push from this machine")
			}
		} else {
			u.heading("GitHub sign-in: skipped; run gh auth login and gh auth setup-git to push from this machine")
		}
	}
	return 0
}

// cloneAskedPath is the guided form's clone: it offers the clone at the
// default path when there is one, unless askFirst, else asks the path, then
// clones and bootstraps, offering the sign-in after when GitHub read the
// repo without one.
func (u *setup) cloneAskedPath(askFirst bool) int {
	if !askFirst {
		u.path = u.defaultPath()
		u.readPathState()
		if u.pathState == "named" {
			yes, ok := u.askYes("It is already cloned at "+u.path+". Set up this Mac from that clone?", true)
			if !ok {
				return 1
			}
			if yes {
				return u.cloneAndBootstrap(u.public, true)
			}
		}
	}
	if !u.askPath("Where do you want to clone the state repo?") {
		return 1
	}
	u.readPathState()
	switch u.pathState {
	case "empty":
		return u.cloneAndBootstrap(u.public, false)
	case "named":
		return u.cloneAndBootstrap(u.public, true)
	}
	u.printError(u.path + " holds something other than a clone of " + u.name + ": run macelium setup again and answer another path")
	return 1
}

// scanForSecrets scans the files at the path, which are what the commit
// before the push takes, for secrets with gitleaks, and says what it found,
// showing any secret redacted. It fails when gitleaks fails.
func (u *setup) scanForSecrets() bool {
	u.secretsFound = false
	u.heading("Scanning " + u.path + " for secrets (gitleaks)")
	var output string
	var status int
	u.withSpinner("Scanning "+u.path+" for secrets", func() {
		output, status = run.Capture(nil, "gitleaks", "dir", u.path, "--no-banner", "--redact", "--verbose", "--log-level", "warn",
			"--exit-code", fmt.Sprint(gitleaksFoundStatus))
	})
	switch status {
	case 0:
		u.println("No secrets detected in " + u.path + ".")
	case gitleaksFoundStatus:
		u.secretsFound = true
		u.printf("%s\n\n", output)
		fmt.Fprintln(u.Err, "Warning: gitleaks found what look like secrets in "+u.path+", shown above redacted. Pushing sends them to "+u.name+", and from there to every Mac set up from it. Remove each from its file, or move it to ~/.zshrc.local or ~/.gitconfig.local, which stay on this Mac. Nothing is committed until you say to push.")
	default:
		fmt.Fprintln(u.Err, output)
		u.printStopped("gitleaks failed scanning " + u.path + ", so nothing was pushed")
		return false
	}
	return true
}

// reviewBeforePush shows the path, and asks whether to push it, no by
// default when the scan found secrets. On a no, it says how to go on.
func (u *setup) reviewBeforePush() (yes, ok bool) {
	u.printf("\nThe new state repo is at %s.\n", u.path)
	yes, ok = u.askYes("Push "+u.path+" to "+u.name+" now? (You can inspect the files in another terminal first)", !u.secretsFound)
	if !ok || yes {
		return
	}
	u.println("Nothing was committed or pushed. Change the files in " + u.path + " as you need to.")
	u.println("Run macelium setup again (or install.sh) to go on: it finds " + u.path + " already captured, and scans it and asks again before it commits and pushes.")
	return
}

// captureAuthor returns the name and email the state repo at the path
// gives every machine, in its chezmoi data, which author its commit. It
// asks for either it lacks.
func (u *setup) captureAuthor() (name, email string, ok bool) {
	// A config file that does not exist keeps this Mac's chezmoi config
	// out.
	data, _ := run.Output("chezmoi", "data", "--source", u.path, "--config", u.path+"/.git/no-chezmoi-config.toml", "--format", "json")
	var values map[string]any
	_ = json.Unmarshal([]byte(data), &values)
	str := func(k string) string {
		switch v := values[k].(type) {
		case string:
			return v
		case nil, bool:
			return ""
		default:
			return fmt.Sprint(v)
		}
	}
	name, email = str("name"), str("email")
	if name == "" || email == "" {
		u.println("The state repo's chezmoi data names no author for its commit.")
	}
	for name == "" {
		def, _ := run.Output("git", "config", "--global", "--includes", "user.name")
		if name, ok = u.ask("Name", def); !ok {
			return
		}
	}
	for email == "" {
		def, _ := run.Output("git", "config", "--global", "--includes", "user.email")
		if email, ok = u.ask("Email", def); !ok {
			return
		}
	}
	return name, email, true
}

// commitStateRepo commits what the path holds, which the scan and the
// review saw.
func (u *setup) commitStateRepo() bool {
	u.heading("Committing " + u.path)
	name, email, ok := u.captureAuthor()
	if !ok || !u.commitCapture(u.path, name, email) {
		u.printStopped("committing " + u.path + " failed, so nothing was pushed")
		return false
	}
	return true
}

// pushStateRepo pushes the state repo's branch to its remote, setting its
// upstream.
func (u *setup) pushStateRepo() bool {
	u.heading("Pushing " + u.path + " to " + u.name)
	if u.interactive("git", "-C", u.path, "push", "-u", "origin", "HEAD") != 0 {
		u.printStopped("git push to " + u.name + " failed")
		return false
	}
	return true
}

// ghRepoCreate creates the state repo on GitHub from the path, pushing it,
// with visibility --private or --public.
func (u *setup) ghRepoCreate(visibility string) bool {
	u.heading("gh repo create " + u.repoPath + " " + visibility + " --source " + u.path + " --push")
	return u.interactive("gh", "repo", "create", u.repoPath, visibility, "--source", u.path, "--push") == 0
}

// createOnGitHub creates the state repo on GitHub from the path and pushes
// it. A private repo GitHub refuses is offered as a public one, no by
// default.
func (u *setup) createOnGitHub() bool {
	visibility := "--private"
	if u.public {
		visibility = "--public"
	}
	if u.ghRepoCreate(visibility) {
		return true
	}
	if _, status := run.Capture(nil, "gh", "repo", "view", u.repoPath); status == 0 {
		u.printStopped("gh created " + u.repoPath + " but did not push to it; run macelium setup again to push")
		return false
	}
	if visibility == "--private" &&
		u.confirm("GitHub did not create a private repo, for the reason above. Create a public one, which anyone can read, everything captured in it included?", false) == 0 &&
		u.ghRepoCreate("--public") {
		return true
	}
	u.printStopped("gh repo create " + u.repoPath + " failed")
	return false
}

// createStateRepo, for a GitHub repo to create (create) or a repo with no
// refs, asks the path, captures this Mac there with init, scans it for
// secrets, pushes it once the operator says to, and bootstraps it, each step
// skipped when the path shows it done.
func (u *setup) createStateRepo(create bool) int {
	if u.github && !u.signInToGitHub() {
		u.printStopped("pushing to " + u.name + " needs a GitHub sign-in")
		return 1
	}
	if !u.askPath("Where do you want to keep the new state repo?") {
		return 1
	}
	u.readPathState()
	// A clone of the empty repo has nothing to push, and init refuses it.
	if u.pathState == "named" {
		if _, status := run.Capture(nil, "git", "-C", u.path, "rev-parse", "-q", "--verify", "HEAD"); status != 0 {
			u.pathState = "other"
		}
	}
	if u.pathState == "other" {
		u.printError(u.path + " holds something other than a new state repo for " + u.name + ": run macelium setup again and answer another path")
		return 1
	}
	if create && u.pathState == "named" {
		u.printStopped(u.path + "'s remote names " + u.name + ", which GitHub does not have: run git -C " + u.path + " remote remove origin, then macelium setup again, to create it")
		return 1
	}
	if create {
		choice, ok := u.choose("Who can read the new repo?", "1", "only you (private)", "anyone (public), including everything init captures")
		if !ok {
			return 1
		}
		u.public = choice != "1"
	}

	if u.pathState == "empty" {
		u.println()
		u.println("Macelium will now record your computer's current setup, this includes: your")
		u.println("Homebrew applications and, if you choose, your git, shell and mise settings.")
		u.println("You'll be asked a few questions about what to include. Nothing is installed or")
		u.println("changed on your computer during this step.")
		flag := ""
		if u.public {
			flag = "--public "
		}
		u.heading("macelium init " + flag + u.path)
		if _, _, ok := captureMac(u.Session, u.public, u.path); !ok {
			u.printStopped("macelium init failed")
			return 1
		}
	} else {
		u.heading("macelium init: " + u.path + " already holds the new state repo")
	}

	if !u.scanForSecrets() {
		return 1
	}
	yes, ok := u.reviewBeforePush()
	if !ok {
		return 1
	}
	if !yes {
		return 0
	}
	if !u.commitStateRepo() {
		return 1
	}

	if create {
		if !u.createOnGitHub() {
			return 1
		}
	} else {
		if u.pathState != "named" && u.interactive("git", "-C", u.path, "remote", "add", "origin", u.url) != 0 {
			u.printStopped("git remote add origin " + u.url + " failed")
			return 1
		}
		if !u.pushStateRepo() {
			return 1
		}
	}

	u.heading("macelium bootstrap " + u.path)
	return bootstrapCheckout(u.Session, u.path)
}

// goOnFromFound goes on from what findRepo found. then is what to do with a
// repo found missing: "new" creates it, and anything else stops; "ask"
// asks the path of a repo to clone first.
func (u *setup) goOnFromFound(then string) int {
	switch u.found {
	case "refs":
		return u.cloneAskedPath(then == "ask")
	case "empty":
		return u.createStateRepo(false)
	}
	if then == "new" {
		return u.createStateRepo(true)
	}
	u.printStopped("found no repo " + u.name + " to read")
	return 1
}

// askRepo asks for the state repo until a reply names one, saying invalid
// of a reply that names none, then finds it and goes on from what it found.
func (u *setup) askRepo(question, invalid string) int {
	if question == "" {
		question = "Your state repo, as <owner>/<repo> on GitHub or a git URL"
	}
	if invalid == "" {
		invalid = "that is neither <owner>/<repo> nor a git URL"
	}
	for {
		answer, ok := u.ask(question, "")
		if !ok {
			return 1
		}
		if r, ok := parseStateRepo(answer); ok {
			u.stateRepo = r
			break
		}
		u.printError(invalid)
	}
	if !u.findRepo(false) {
		return 1
	}
	return u.goOnFromFound("")
}

// guided, with no argument, asks where the state repo is, finds it, and
// clones it, or creates it when there is none.
func (u *setup) guided() int {
	term.WriteTTY("\n\nWelcome to Macelium!  You will now be guided through the setup.\n\n")
	choice, ok := u.choose("What source control provider do you use?", "1", "GitHub", "another git provider")
	if !ok {
		return 1
	}
	if choice == "2" {
		u.tellSignIn("Git host")
		return u.askRepo("The state repo's git URL", "that is not a git URL")
	}

	if ghSignedIn() && u.readLogin() {
		if !u.confirmSignedIn() {
			return 1
		}
	} else {
		if status := u.askUsername(); status != 0 || u.wentOn {
			return status
		}
	}

	u.stateRepo, _ = parseStateRepo(u.login + "/macelium-state")
	if !u.findRepo(false) {
		return 1
	}
	switch u.found {
	case "refs":
		u.println("Found " + u.url + ".")
	case "empty":
		u.println("Found " + u.url + ", with nothing in it yet.")
	default:
		choice, ok := u.choose("No macelium-state repo found for "+u.login+". Are you setting this up for the first time, or is your repo named something else?", "",
			"first time: capture this Mac into a new "+u.login+"/macelium-state", "something else: give its name or URL")
		if !ok {
			return 1
		}
		if choice == "1" {
			return u.goOnFromFound("new")
		}
		return u.askRepo("", "")
	}
	return u.goOnFromFound("")
}

// confirmSignedIn, with gh signed in already, says as whom, and asks
// whether to go on as that account or sign in to another, then signs in.
func (u *setup) confirmSignedIn() bool {
	u.println("gh is signed in to GitHub as " + u.login + ".")
	choice, ok := u.choose("Continue as "+u.login+"?", "1", "yes", "no, sign in to another account")
	if !ok {
		return false
	}
	if choice == "2" {
		u.heading("Signing in to GitHub")
		if !u.ghAuthLogin() {
			return false
		}
	}
	return u.signInToGitHub()
}

// askUsername, with gh signed out, asks the GitHub username. With none, it
// has the user create an account first; with one, it looks for its
// macelium-state without signing in, and on finding it, goes on from
// there, setting wentOn. Otherwise it signs in, and when the account is not
// the one named, asks whether to sign in as it or go on.
func (u *setup) askUsername() int {
	var user string
	for {
		answer, ok := u.ask("GitHub username (empty if you do not have an account yet)", "")
		if !ok {
			return 1
		}
		user = answer
		if user == "" || usernameRe.MatchString(user) {
			break
		}
		u.printError("that is not a GitHub username")
	}
	if user == "" {
		u.println("You'll need a GitHub account. Opening https://github.com/signup in your browser.")
		_ = exec.Command("open", "https://github.com/signup").Run()
		if _, ok := u.ask("Create the account there, then come back and press Enter to sign in", ""); !ok {
			return 1
		}
	} else {
		u.stateRepo, _ = parseStateRepo(user + "/macelium-state")
		u.findRepo(true)
		if u.found != "missing" {
			u.wentOn = true
			return u.foundWithoutSignIn()
		}
		u.println("No public " + user + "/macelium-state found; signing in to look for a private one.")
	}
	if !u.signInToGitHub() {
		u.printStopped("finding your state repo needs a GitHub sign-in")
		return 1
	}
	if user == "" || strings.EqualFold(u.login, user) {
		return 0
	}
	choice, ok := u.choose("gh is signed in as "+u.login+", not "+user+".", "1", "sign in as "+user, "continue as "+u.login)
	if !ok {
		return 1
	}
	if choice != "1" {
		return 0
	}
	u.heading("Signing in to GitHub as " + user)
	u.println("    (" + u.login + " stays signed in too; gh auth switch moves between them)")
	if !u.ghAuthLogin() {
		return 1
	}
	u.signedIn = false
	if !u.signInToGitHub() {
		return 1
	}
	if !strings.EqualFold(u.login, user) {
		u.printStopped("signed in as " + u.login + ", not " + user)
		return 1
	}
	return 0
}

// foundWithoutSignIn takes the state repo findRepo found without a
// sign-in: it confirms it, or offers the clone of it at the default path,
// then goes on from it, or asks for another repo.
func (u *setup) foundWithoutSignIn() int {
	question := "Set up this Mac from it?"
	if u.found == "refs" {
		u.println("Found " + u.url + ".")
		u.path = u.defaultPath()
		u.readPathState()
		if u.pathState == "named" {
			return u.cloneAskedPath(false)
		}
	} else {
		u.println("Found " + u.url + ", with nothing in it yet.")
		question = "Capture this Mac into it?"
	}
	yes, ok := u.askYes(question, true)
	if !ok {
		return 1
	}
	if yes {
		return u.goOnFromFound("ask")
	}
	return u.askRepo("", "")
}

// Setup takes the state repo, as <owner>/<repo> on GitHub or a git URL, and
// the path, or neither, for the guided form. The repo is one
// NamesStateRepo takes.
func (s *Session) Setup(args []string) int {
	u := &setup{Session: s}
	if len(args) > 0 {
		u.stateRepo, _ = parseStateRepo(args[0])
	}
	if !s.requireTerminal() {
		return 1
	}
	// The formula depends on gitleaks. Only a new state repo is scanned, but
	// setup checks first, so it never stops partway for want of it.
	if !run.Lookable("gitleaks") {
		s.printError("needs gitleaks to scan a new state repo for secrets: brew install gitleaks")
		return 1
	}
	if !s.refuseForeignChezmoi() {
		return 1
	}
	if len(args) == 0 {
		return u.guided()
	}

	u.path = u.defaultPath()
	if len(args) > 1 {
		u.path = args[1]
	}
	s.heading("Path: " + u.path)
	// The path is checked before the network, so a wrong one changes
	// nothing. Empty, or missing, it is cloned to; a clone of the state repo
	// is used as it is.
	u.readPathState()
	cloned := false
	switch u.pathState {
	case "empty":
	case "named":
		cloned = true
	default:
		s.printError(u.path + " holds something other than a clone of " + u.name + ": name another path, as the second argument")
		return 1
	}

	// A GitHub repo is probed over HTTPS, whatever form names it, since that
	// is what an anonymous read and gh's sign-in both use.
	offerSignIn := false
	if !u.github {
		if !cloned {
			u.tellSignIn(u.host)
		}
	} else if lsRemote(u.repoPath) {
		s.heading("GitHub sign-in: not needed, git can read " + u.name)
		offerSignIn = true
	} else if !u.signInToGitHub() {
		s.printStopped("git can't read " + u.name + " without a GitHub sign-in")
		return 1
	}
	return u.cloneAndBootstrap(offerSignIn, cloned)
}

// lsRemote reports whether git reads a GitHub repo, with no prompt for a
// credential.
func lsRemote(repoPath string) bool {
	cmd := exec.Command("git", "ls-remote", "https://github.com/"+repoPath)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	return cmd.Run() == nil
}

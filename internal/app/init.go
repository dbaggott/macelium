package app

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"

	"github.com/dbaggott/macelium/internal/run"
	"github.com/dbaggott/macelium/internal/settings"
	"github.com/dbaggott/macelium/internal/term"
)

// The line a captured ~/.zshrc ends with, and the section a captured
// ~/.gitconfig ends with, so that each machine's own differences load last.
const (
	zshrcLocalLine        = "[[ -r ~/.zshrc.local ]] && source ~/.zshrc.local"
	gitconfigLocalSection = "[include]\n\tpath = ~/.gitconfig.local"
)

var (
	tokenRe       = regexp.MustCompile(`(^|[^[:alnum:]_])(ghp_|github_pat_|sk-|AKIA|xox)|://[^/@[:space:]]+:[^/@[:space:]]+@`)
	secretExport  = regexp.MustCompile(`^[[:space:]]*export[[:space:]]+[[:alnum:]_]*(TOKEN|SECRET|KEY|PASSWORD)[[:alnum:]_]*=`)
	extraHeader   = regexp.MustCompile(`(?i)^[[:space:]]*extraheader[[:space:]]*=`)
	sectionHeader = regexp.MustCompile(`^[[:space:]]*\[`)
	userHeader    = regexp.MustCompile(`^[[:space:]]*\[user\][[:space:]]*$`)
	nameKey       = regexp.MustCompile(`^[[:space:]]*name[[:space:]]*=`)
	emailKey      = regexp.MustCompile(`^[[:space:]]*email[[:space:]]*=`)
)

// askValue asks on the terminal, again while the reply and the default are
// both empty, and returns the reply, or the default for an empty one.
// End-of-file on an empty reply gives the default, and fails when there is
// none; after a partly typed reply, it fails.
func askValue(question, def string) (string, bool) {
	if def != "" {
		question += " [" + def + "]"
	}
	for {
		answer, ok := term.Prompt(question + ": ")
		if !ok {
			term.WriteTTY("\n")
			if answer != "" || def == "" {
				return "", false
			}
			answer = def
		}
		if answer == "" {
			answer = def
		}
		if answer != "" {
			return answer, true
		}
	}
}

// initBrewfile returns this Mac's formulae, casks and taps as a Brewfile,
// with macelium's own line in place of the one brew bundle dump writes, or
// last when it writes none.
func initBrewfile() (string, bool) {
	own := `brew "` + SelfFormula + `", trusted: true, restart_service: :always`
	dump, status := runStdout("brew", "bundle", "dump", "--formula", "--cask", "--tap", "--file=-")
	if status != 0 {
		return "", false
	}
	var lines []string
	found := false
	if dump != "" {
		for _, line := range strings.Split(dump, "\n") {
			if strings.HasPrefix(line, `brew "`+SelfFormula+`"`) {
				line, found = own, true
			}
			lines = append(lines, line)
		}
	}
	if !found {
		lines = append(lines, own)
	}
	return strings.Join(lines, "\n"), true
}

// runStdout runs a command whose errors go to the terminal, and returns its
// output without trailing newlines and its exit status.
func runStdout(name string, args ...string) (string, int) {
	cmd := exec.Command(name, args...)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	return strings.TrimRight(string(out), "\n"), run.Status(err)
}

// secretLines returns the numbers of the lines of a zshrc or a gitconfig
// that look like secrets: in either, a value starting with a known token
// prefix, or a URL with credentials; in a zshrc, an export of a name that
// holds TOKEN, SECRET, KEY or PASSWORD; in a gitconfig, an extraHeader.
func secretLines(gitconfig bool, content string) []int {
	var numbers []int
	for i, line := range strings.Split(content, "\n") {
		if tokenRe.MatchString(line) || (!gitconfig && secretExport.MatchString(line)) || (gitconfig && extraHeader.MatchString(line)) {
			numbers = append(numbers, i+1)
		}
	}
	sort.Ints(numbers)
	return numbers
}

// splitLines returns the content without the lines numbered, or those lines
// alone. In a gitconfig, a moved line comes with its section's header, and
// a moved header takes its whole section with it.
func splitLines(kept bool, numbers []int, gitconfig bool, content string) string {
	move := map[int]bool{}
	for _, n := range numbers {
		move[n] = true
	}
	var out []string
	header, shown, whole := "", false, false
	for i, line := range strings.Split(content, "\n") {
		n := i + 1
		isHeader := gitconfig && sectionHeader.MatchString(line)
		if isHeader {
			header, shown, whole = line, false, move[n]
		}
		moving := move[n] || (gitconfig && whole)
		if kept {
			if !moving {
				out = append(out, line)
			}
			continue
		}
		if !moving {
			continue
		}
		if gitconfig && !isHeader && header != "" && !shown {
			out = append(out, header)
		}
		out = append(out, line)
		shown = true
	}
	return strings.TrimRight(strings.Join(out, "\n"), "\n")
}

// gitconfigTemplate returns a gitconfig as a chezmoi template: its [user]
// name and email read the state repo's values, any {{ in it stays literal,
// and it ends with the section that includes ~/.gitconfig.local, unless it
// already does.
func gitconfigTemplate(content string) string {
	var out []string
	user := false
	for _, line := range strings.Split(content, "\n") {
		line = strings.ReplaceAll(line, "{{", `{{ "{{" }}`)
		lower := strings.ToLower(line)
		switch {
		case sectionHeader.MatchString(line):
			user = userHeader.MatchString(lower)
			out = append(out, line)
		case user && nameKey.MatchString(lower):
			out = append(out, line[:len(nameKey.FindString(lower))]+" {{ .name }}")
		case user && emailKey.MatchString(lower):
			out = append(out, line[:len(emailKey.FindString(lower))]+" {{ .email }}")
		default:
			out = append(out, line)
		}
	}
	template := strings.TrimRight(strings.Join(out, "\n"), "\n")
	var nonBlank []string
	for _, l := range strings.Split(template, "\n") {
		if strings.TrimSpace(l) != "" {
			nonBlank = append(nonBlank, l)
		}
	}
	if len(nonBlank) >= 2 && strings.Join(nonBlank[len(nonBlank)-2:], "\n") == gitconfigLocalSection {
		return template
	}
	return template + "\n\n" + gitconfigLocalSection
}

// readTrimmed returns a file's content without its trailing newlines.
func readTrimmed(path string) string {
	data, _ := os.ReadFile(path)
	return strings.TrimRight(string(data), "\n")
}

// offerCapture shows a file under the home directory, and asks whether to
// capture it, saying anything more there is to say.
func (s *Session) offerCapture(rel string, public bool, more string) bool {
	where := "and will be published if the repo is public"
	if public {
		where = "and will be published with it, since the repo is public"
	}
	s.heading("~/" + rel)
	data, _ := os.ReadFile(filepath.Join(s.home, rel))
	_, _ = s.Out.Write(data)
	s.printf("\n~/%s goes into the state repo, %s.\n", rel, where)
	if more != "" {
		s.println(more)
	}
	return s.confirm("Capture ~/"+rel+"?", true) == 0
}

// offerMove lists the lines of a file under the home directory that look
// like secrets, and offers to move them to its .local file. It returns the
// file as it goes into the state repo, and the lines moved.
func (s *Session) offerMove(gitconfig bool, rel, local string) (kept, moved string) {
	kept = readTrimmed(filepath.Join(s.home, rel))
	numbers := secretLines(gitconfig, kept)
	if len(numbers) == 0 {
		return kept, ""
	}
	lines := splitLines(false, numbers, gitconfig, kept)
	s.println("These lines look like secrets:")
	s.println("  " + strings.ReplaceAll(lines, "\n", "\n  "))
	if s.confirm("Move them to ~/"+local+", kept on this Mac only and out of the state repo?", true) == 0 {
		return splitLines(true, numbers, gitconfig, kept), lines
	}
	return kept, ""
}

// appendLocal appends lines to a .local file, leaving it mode 0600, since
// they look like secrets.
func appendLocal(path, lines string) bool {
	if lines == "" {
		return true
	}
	old := syscall.Umask(0o077)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	syscall.Umask(old)
	if err != nil {
		return false
	}
	_, err = f.WriteString(lines + "\n")
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err == nil && os.Chmod(path, 0o600) == nil
}

// Init captures this Mac into a new state repo at path, then says what to
// do next.
func (s *Session) Init(public bool, path string) int {
	name, email, ok := captureMac(s, public, path)
	if !ok {
		return 1
	}
	if !s.commitCapture(path, name, email) {
		s.printError("committing " + path + " failed: remove it and run macelium init again")
		return 1
	}
	s.printf("\nState repo: %s, with one commit and no remote.\n", path)
	s.println("Next, push it to a new repo, then run macelium bootstrap " + path + ".")
	return 0
}

// commitCapture commits everything in a repo captureMac wrote, authored by
// name and email, amending the commit there is when there is one, so a repo
// not yet pushed always has one commit.
func (s *Session) commitCapture(path, name, email string) bool {
	args := []string{"-C", path, "-c", "user.name=" + name, "-c", "user.email=" + email, "-c", "commit.gpgsign=false",
		"commit", "-q", "--no-verify"}
	if _, status := run.Capture(nil, "git", "-C", path, "rev-parse", "-q", "--verify", "HEAD"); status == 0 {
		args = append(args, "--amend")
	}
	args = append(args, "-m", "Capture this Mac with macelium init")
	return s.interactive("git", "-C", path, "add", "-A") == 0 && s.interactive("git", args...) == 0
}

// defaultAuthor returns the name and email to offer: git's, or else the
// GitHub account's gh is signed in to.
func defaultAuthor() (name, email string) {
	name, _ = run.Output("git", "config", "--global", "--includes", "user.name")
	email, _ = run.Output("git", "config", "--global", "--includes", "user.email")
	if (name != "" && email != "") || !run.Lookable("gh") {
		return
	}
	if _, status := run.Capture(nil, "gh", "auth", "status"); status != 0 {
		return
	}
	out, status := run.Output("gh", "api", "user")
	if status != 0 {
		return
	}
	var user struct {
		Name  *string `json:"name"`
		ID    any     `json:"id"`
		Login *string `json:"login"`
	}
	if json.Unmarshal([]byte(out), &user) != nil {
		return
	}
	if name == "" && user.Name != nil {
		name = *user.Name
	}
	if email == "" && user.ID != nil && user.Login != nil {
		email = fmt.Sprintf("%v+%s@users.noreply.github.com", jsonNumber(user.ID), *user.Login)
	}
	return
}

func jsonNumber(v any) string {
	if f, ok := v.(float64); ok {
		return fmt.Sprintf("%.0f", f)
	}
	return fmt.Sprint(v)
}

// capture captures this Mac into a new state repo at path, a git repo with
// nothing committed and no remote, and returns the name and email it asked
// for.
func (s *Session) capture(public bool, path string) (string, string, bool) {
	if !s.refuseForeignChezmoi() {
		return "", "", false
	}
	if (exists(path) && !isDir(path)) || (isDir(path) && !emptyDir(path)) {
		s.printError(path + " exists and is not empty: name a new or empty directory")
		return "", "", false
	}

	defaultName, defaultEmail := defaultAuthor()
	s.println("Your name and email go into the state repo, for every machine's git config, and author its first commit.")
	name, ok := askValue("Name", defaultName)
	var email string
	if ok {
		email, ok = askValue("Email", defaultEmail)
	}
	if !ok {
		s.printError("no answer, so nothing was written")
		return "", "", false
	}

	s.heading("brew bundle dump --formula --cask --tap")
	brewfile, ok := initBrewfile()
	if !ok {
		s.printError("brew bundle dump failed, so nothing was written")
		return "", "", false
	}

	var gitconfig, zshrc, mise, gitconfigMoved, zshrcMoved string
	if isFile(filepath.Join(s.home, ".gitconfig")) && s.offerCapture(".gitconfig", public, "") {
		var kept string
		kept, gitconfigMoved = s.offerMove(true, ".gitconfig", ".gitconfig.local")
		gitconfig = gitconfigTemplate(kept)
	}
	if isFile(filepath.Join(s.home, ".zshrc")) && s.offerCapture(".zshrc", public,
		"Secrets are better kept in a password manager or the Keychain, read by the command that needs them.") {
		zshrc, zshrcMoved = s.offerMove(false, ".zshrc", ".zshrc.local")
		lastLine := ""
		for _, l := range strings.Split(zshrc, "\n") {
			if strings.TrimSpace(l) != "" {
				lastLine = l
			}
		}
		if lastLine != zshrcLocalLine {
			zshrc += "\n" + zshrcLocalLine
		}
	}
	if isFile(filepath.Join(s.home, ".config/mise/config.toml")) && s.offerCapture(".config/mise/config.toml", public, "") {
		mise = readTrimmed(filepath.Join(s.home, ".config/mise/config.toml"))
	}

	home := filepath.Join(path, "home")
	files := []struct{ path, content string }{
		{filepath.Join(path, "macelium.conf"), fmt.Sprintf("# The manifest: https://github.com/dbaggott/macelium#configuration-reference\ncontract %d\n", KnownContract)},
		{filepath.Join(path, ".chezmoiroot"), "home\n"},
		{filepath.Join(path, "Brewfile"), brewfile + "\n"},
		{filepath.Join(path, "macos.sh"), "# The macOS settings every machine has, a declaration a line:\n# https://github.com/dbaggott/macelium#configuration-reference\n"},
		{filepath.Join(home, ".chezmoi.toml.tmpl"), "{{- /* macelium finds the state repo through chezmoi source-path, so the\n       config names this checkout as chezmoi's source. */ -}}\nsourceDir = {{ .chezmoi.workingTree | quote }}\n"},
		{filepath.Join(home, ".chezmoidata.toml"), "# Values every machine shares, which templates read as {{ .name }} and\n# {{ .email }}. One machine's differences go in ~/.gitconfig.local and\n# ~/.zshrc.local, never here.\nname = " + settings.Quote(name) + "\nemail = " + settings.Quote(email) + "\n"},
	}
	if gitconfig != "" {
		files = append(files, struct{ path, content string }{filepath.Join(home, "dot_gitconfig.tmpl"), gitconfig + "\n"})
	}
	if zshrc != "" {
		files = append(files, struct{ path, content string }{filepath.Join(home, "dot_zshrc"), zshrc + "\n"})
	}
	if mise != "" {
		files = append(files, struct{ path, content string }{filepath.Join(home, "dot_config/mise/config.toml"), mise + "\n"})
	}
	written := os.MkdirAll(home, 0o755) == nil
	for _, f := range files {
		if !written {
			break
		}
		written = os.MkdirAll(filepath.Dir(f.path), 0o755) == nil && os.WriteFile(f.path, []byte(f.content), 0o644) == nil
	}
	if !written || s.interactive("git", "init", "-q", "-b", "main", path) != 0 {
		s.printError("writing " + path + " failed: remove it and run macelium init again")
		return "", "", false
	}
	if !appendLocal(filepath.Join(s.home, ".gitconfig.local"), gitconfigMoved) || !appendLocal(filepath.Join(s.home, ".zshrc.local"), zshrcMoved) {
		s.printError("moving the secrets to the .local files failed; they stay in ~/.gitconfig and ~/.zshrc, and out of the state repo")
		return "", "", false
	}
	if gitconfigMoved != "" {
		s.println("Moved lines that look like secrets to ~/.gitconfig.local.")
	}
	if zshrcMoved != "" {
		s.println("Moved lines that look like secrets to ~/.zshrc.local.")
	}
	return name, email, true
}

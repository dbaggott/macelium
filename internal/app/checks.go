package app

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/dbaggott/macelium/internal/run"
	"github.com/dbaggott/macelium/internal/settings"
	"github.com/dbaggott/macelium/internal/term"
)

// The agent's run on wake can start before the network is back, so
// --notify retries the fetch; a plan or apply run by hand fetches once.
const notifyFetchAttempts = 3

var fetchRetry = 30 * time.Second

var (
	chezmoiStatusLine = regexp.MustCompile(`^[ ADMR]{2} `)
	unmetEntry        = regexp.MustCompile(`(?m)^→ .* needs to be `)
	unlistedEntry     = regexp.MustCompile(`(?m)^Would (uninstall|untap)`)
	bundleEntry       = regexp.MustCompile(`^(?:→ )?(.*) needs to be .*`)
)

// checkChezmoi takes whether to diff the targets chezmoi status lists.
func (s *Session) checkChezmoi(wantDiff bool) {
	out, status := run.Capture(nil, "chezmoi", "status")
	if status != 0 {
		s.chezmoi.fail(run.Failure("chezmoi status", out, status))
		return
	}
	// Status lines are two state columns and a path. Of the warnings, only
	// the config template's means the machine differs from the repo: its
	// config file was rendered from an older template.
	var items []string
	for _, line := range strings.Split(out, "\n") {
		if chezmoiStatusLine.MatchString(line) {
			items = append(items, line)
		}
		if strings.HasPrefix(line, "warning: config file template has changed") {
			s.chezmoiConfigStale = true
		}
	}
	s.chezmoi.items = strings.Join(items, "\n")
	if len(items) == 0 && !s.chezmoiConfigStale {
		s.chezmoi.result = "clean"
		return
	}
	s.chezmoi.result = "drift"
	if wantDiff && len(items) > 0 {
		color := "false"
		if f := s.outFile(); f != nil && term.IsTerminal(f) {
			color = "true"
		}
		out, status := run.Capture(nil, "chezmoi", "diff", "--no-pager", "--color="+color)
		if status != 0 {
			s.chezmoi.fail(run.Failure("chezmoi diff", out, status))
		} else {
			s.chezmoiDiff = out
		}
	}
}

// brewfiles returns the state repo's Brewfile and then the machine's local
// one, when it has one.
func (s *Session) brewfiles() string {
	data, _ := os.ReadFile(s.stateBrewfile)
	// A Brewfile without a final newline would otherwise join the next one.
	all := string(data) + "\n"
	if isFile(s.localBrewfile()) {
		local, _ := os.ReadFile(s.localBrewfile())
		all += string(local)
	}
	return all
}

func (s *Session) brewBundle(args ...string) (string, int) {
	return run.Capture(strings.NewReader(s.brewfiles()), "brew", append([]string{"bundle"}, args...)...)
}

// unlistedEntries takes brew bundle cleanup's output and returns each entry
// under its "Would uninstall" and "Would untap" headings as "<kind> <name>".
// Any other line starting "Would " opens a list that is not of entries, such
// as the cache files `brew cleanup` would remove.
func unlistedEntries(out string) string {
	var entries []string
	kind := ""
	for _, line := range strings.Split(out, "\n") {
		switch {
		case line == "Would uninstall casks:":
			kind = "cask"
		case line == "Would uninstall formulae:":
			kind = "formula"
		case line == "Would untap:":
			kind = "tap"
		case strings.HasPrefix(line, "Would uninstall ") && strings.HasSuffix(line, ":"):
			kind = strings.TrimSuffix(strings.TrimPrefix(line, "Would uninstall "), ":")
		case strings.HasPrefix(line, "Would ") || strings.HasPrefix(line, "Run `brew bundle cleanup"):
			kind = ""
		case kind != "" && strings.TrimSpace(line) != "":
			entries = append(entries, kind+" "+line)
		}
	}
	return strings.Join(entries, "\n")
}

// checkBrew lists what Homebrew has that neither Brewfile lists. Without
// --force, brew bundle cleanup lists what it would remove and exits 1 only
// when that includes something to uninstall or untap. Its list of cache
// files `brew cleanup` would remove leaves the exit status 0, so the status
// is the signal. The Brewfiles arrive on stdin, so stdin is never a terminal
// and cleanup cannot ask to go ahead. --formula --cask --tap keeps it to what
// Homebrew installs, leaving out the package managers it also covers by
// default (npm, uv, cargo, go, VS Code extensions).
func (s *Session) checkBrew() {
	if !exists(s.stateBrewfile) {
		s.brew.result = "skipped"
		return
	}
	out, status := s.brewBundle("cleanup", "--formula", "--cask", "--tap", "--file=-")
	switch {
	case status == 0:
		s.brew.result = "clean"
	case status == 1 && unlistedEntry.MatchString(out):
		s.brew.result, s.brew.items = "drift", unlistedEntries(out)
	default:
		s.brew.fail(run.Failure("brew bundle cleanup", out, status))
	}
}

// checkMissing lists what either Brewfile lists that the machine lacks. brew
// bundle check exits 1 both for an entry the machine does not meet and for
// a Brewfile it cannot read, so the output tells them apart: --verbose
// prints a line per unmet entry, whatever it lacks (not installed, not
// tapped, not linked, a service not started). Without --no-upgrade an
// installed package with a newer release counts as unmet. check has no
// filter by entry type, so it covers every kind of entry a Brewfile holds.
func (s *Session) checkMissing() {
	if !exists(s.stateBrewfile) {
		s.missing.result = "skipped"
		return
	}
	out, status := s.brewBundle("check", "--no-upgrade", "--verbose", "--file=-")
	switch {
	case status == 0:
		s.missing.result = "clean"
	case status == 1 && unmetEntry.MatchString(out):
		var items []string
		for _, line := range strings.Split(out, "\n") {
			if rest, ok := strings.CutPrefix(line, "→ "); ok {
				items = append(items, rest)
			}
		}
		s.missing.result, s.missing.items = "drift", strings.Join(items, "\n")
	default:
		s.missing.fail(run.Failure("brew bundle check --no-upgrade", out, status))
	}
}

// bundleEntries returns the entries in brew bundle check's messages: the
// text before " needs to be ", which is the same with and without
// --no-upgrade.
func bundleEntries(out string) map[string]bool {
	entries := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		if m := bundleEntry.FindStringSubmatch(line); m != nil {
			entries[m[1]] = true
		}
	}
	return entries
}

// checkOutdated lists the upgrades brew bundle would make. Without
// --no-upgrade, brew bundle check also reports an installed entry with a
// newer release, so an entry it reports that checkMissing did not is one
// brew bundle would upgrade. With HOMEBREW_BUNDLE_NO_UPGRADE set, check
// reads it as --no-upgrade and finds none, as brew bundle then upgrades none.
func (s *Session) checkOutdated() {
	switch s.missing.result {
	case "error":
		s.outdated.fail("needs check 'missing', which failed")
		return
	case "skipped":
		s.outdated.result = "skipped"
		return
	}
	out, status := s.brewBundle("check", "--verbose", "--file=-")
	if status == 1 && unmetEntry.MatchString(out) {
		missing := bundleEntries(s.missing.items)
		var items []string
		for entry := range bundleEntries(out) {
			if !missing[entry] {
				items = append(items, entry)
			}
		}
		sort.Strings(items)
		s.outdated.items = strings.Join(items, "\n")
	} else if status != 0 {
		s.outdated.fail(run.Failure("brew bundle check", out, status))
		return
	}
	s.outdated.result = "clean"
	if s.outdated.items != "" {
		s.outdated.result = "drift"
	}
}

// updateHomebrew runs brew update, returning the warning a failed one
// gives: upgrades are only shown, so the Homebrew checks then read the
// metadata the last update left.
func updateHomebrew() string {
	out, status := run.Capture(nil, "brew", "update", "--quiet")
	if status == 0 {
		return ""
	}
	lines := strings.Split(out, "\n")
	return "brew update failed, so the Homebrew sections are as of its last update: " + lines[len(lines)-1]
}

// fetchCheckout fetches the checkout, making up to attempts attempts. It
// fails, with the behind check's error set, when every attempt does.
func (s *Session) fetchCheckout(attempts int) bool {
	for attempt := 1; ; attempt++ {
		// With no remote named, fetch takes the one the branch's upstream is
		// on.
		out, status := run.Capture(nil, "git", "-C", s.repo, "fetch", "--quiet")
		if status == 0 {
			return true
		}
		if attempt >= attempts {
			s.behind.fail(run.Failure("git fetch", out, status))
			return false
		}
		time.Sleep(fetchRetry)
	}
}

func (s *Session) checkBehind() {
	out, status := run.Capture(nil, "git", "-C", s.repo, "rev-parse", "--abbrev-ref", "@{upstream}")
	if status != 0 {
		s.behind.fail(run.Failure("git rev-parse --abbrev-ref @{upstream}", out, status))
		return
	}
	s.upstream = out
	out, status = run.Capture(nil, "git", "-C", s.repo, "log", "--oneline", "HEAD..@{upstream}")
	switch {
	case status != 0:
		s.behind.fail(run.Failure("git log HEAD..@{upstream}", out, status))
	case out != "":
		s.behind.result, s.behind.items = "drift", out
	default:
		s.behind.result, s.behind.items = "clean", ""
	}
}

// checkMise lists the runtimes the mise global config pins that are not
// installed. mise also loads the config files in the current directory and
// its parents, so it runs from the home directory to keep a project's own
// pins out. It exits 0 whether or not a version is missing, and marks each
// one it lists.
func (s *Session) checkMise() {
	out, status := run.Capture(nil, "mise", "-C", s.home, "ls", "--missing")
	if status != 0 {
		s.mise.fail(run.Failure("mise ls --missing", out, status))
		return
	}
	var items []string
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "(missing)") {
			items = append(items, line)
		}
	}
	if len(items) > 0 {
		s.mise.result, s.mise.items = "drift", strings.Join(items, "\n")
	} else {
		s.mise.result = "clean"
	}
}

// probeSandboxes sets each sandboxed app's state, and macosNotes to why the
// settings of those that were not compared were not, a line each. The
// container is visible without Full Disk Access, and listing its
// preferences is what fails, while defaults export prints an empty domain
// either way.
func (s *Session) probeSandboxes() {
	var notes []string
	for i := range s.list.Sandboxes {
		sb := &s.list.Sandboxes[i]
		container := filepath.Join(s.home, "Library/Containers", sb.Domain)
		switch {
		case !isDir(container):
			sb.State = "absent"
			notes = append(notes, fmt.Sprintf("%s has not run yet, so its settings wait: open %s once, then run `macelium settings`", sb.App, sb.App))
		case func() bool {
			_, err := os.ReadDir(filepath.Join(container, "Data/Library/Preferences"))
			return err == nil
		}():
			sb.State = "readable"
		default:
			sb.State = "unreadable"
			notes = append(notes, sb.App+"'s settings were not checked: reading them needs Full Disk Access for the terminal (System Settings → Privacy & Security → Full Disk Access)")
		}
	}
	s.macosNotes = strings.Join(notes, "\n")
}

// exportDomain returns a domain's preferences as defaults exports them, or
// why it could not.
func exportDomain(currentHost bool, domain string) (settings.Domain, string) {
	var args []string
	if currentHost {
		args = append(args, "-currentHost")
	}
	args = append(args, "export", domain, "-")
	cmd := exec.Command("defaults", args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	status := run.Status(cmd.Run())
	if status != 0 {
		return nil, run.Failure("defaults "+strings.Join(args[:len(args)-1], " "), strings.TrimRight(stderr.String(), "\n"), status)
	}
	d, err := settings.ParseDomain(stdout.Bytes())
	if err != nil {
		return nil, fmt.Sprintf("defaults %s printed no plist: %v", strings.Join(args[:len(args)-1], " "), err)
	}
	return d, ""
}

// checkMacos compares the settings the list declares with the machine's.
// Each comparison exports afresh: apply's runs after chezmoi apply, whose
// scripts may have written the keys.
func (s *Session) checkMacos() {
	s.macos = check{}
	s.differing, s.macosNotes = nil, ""
	list := s.settingsFile
	if list == "" {
		if s.repo == "" {
			s.macos.fail(s.repoDetail)
			return
		}
		list = s.stateSettings
		if !exists(list) {
			s.macos.result = "skipped"
			return
		}
	}
	l, detail := settings.Load(list)
	if l == nil {
		s.macos.fail(detail)
		return
	}
	s.list = l
	s.probeSandboxes()
	type key struct {
		host   bool
		domain string
	}
	exports := map[key]settings.Domain{}
	var items []string
	for i, setting := range l.Settings {
		if sb := l.SandboxOf(setting.Domain); sb >= 0 && l.Sandboxes[sb].State != "readable" {
			continue
		}
		k := key{setting.CurrentHost, setting.Domain}
		d, ok := exports[k]
		if !ok {
			var why string
			if d, why = exportDomain(setting.CurrentHost, setting.Domain); d == nil {
				s.macos.fail(why)
				s.differing = nil
				return
			}
			exports[k] = d
		}
		current, same := setting.Compare(d)
		if same {
			continue
		}
		s.differing = append(s.differing, i)
		items = append(items, fmt.Sprintf("%s: %s → %s", setting.Name(), current, setting.Declared()))
	}
	s.macos.items = strings.Join(items, "\n")
	s.macos.result = "clean"
	if len(s.differing) > 0 {
		s.macos.result = "drift"
	}
}

// The apps hooks: each <apps>/<app>/after-apply runs with bash after the
// other steps, and runs again whenever a hook, an app's watches list, or a
// path one of those lists changes. A watches list holds a git pathspec a
// line, relative to the state repo's root. The files hashed are those git
// lists as tracked or untracked and not ignored, and that still exist. The
// state directory keeps the hash from the last run in which every hook
// succeeded.

func (s *Session) hooksHashFile() string {
	return filepath.Join(s.stateDir(), "apps-hooks.sha256")
}

// appsHooks returns each hook's path.
func (s *Session) appsHooks() []string {
	matches, _ := filepath.Glob(filepath.Join(s.stateApps, "*", "after-apply"))
	var hooks []string
	for _, m := range matches {
		if isFile(m) {
			hooks = append(hooks, m)
		}
	}
	return hooks
}

func hookApp(hook string) string {
	return filepath.Base(filepath.Dir(hook))
}

// appsHooksHash returns the combined hash of the hooks, the watches lists
// and the files they name, or why git could not list them. The hash is
// sha256 over shasum -a 256's lines for the files, so a machine keeps the
// hash the shell version of macelium recorded.
func (s *Session) appsHooksHash() (string, bool) {
	rel := strings.TrimPrefix(s.stateApps, s.repo+"/")
	specs := []string{rel + "/*/after-apply", rel + "/*/watches"}
	watches, _ := filepath.Glob(filepath.Join(s.stateApps, "*", "watches"))
	for _, w := range watches {
		if !isFile(w) {
			continue
		}
		data, _ := os.ReadFile(w)
		for _, line := range strings.Split(string(data), "\n") {
			if line = strings.TrimSpace(line); line != "" {
				specs = append(specs, line)
			}
		}
	}
	cmd := exec.Command("git", append([]string{"-C", s.repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"}, specs...)...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if status := run.Status(cmd.Run()); status != 0 {
		return run.Failure("git ls-files", strings.TrimRight(stdout.String()+stderr.String(), "\n"), status), false
	}
	// Each line pairs a path with its content's hash, so a rename changes
	// the combined hash too.
	var lines bytes.Buffer
	for _, path := range strings.Split(stdout.String(), "\x00") {
		if path == "" || !isFile(filepath.Join(s.repo, path)) {
			continue
		}
		data, err := os.ReadFile(filepath.Join(s.repo, path))
		if err != nil {
			return err.Error(), false
		}
		sum := sha256.Sum256(data)
		lines.WriteString(shasumLine(hex.EncodeToString(sum[:]), path))
	}
	sum := sha256.Sum256(lines.Bytes())
	return hex.EncodeToString(sum[:]), true
}

// shasumLine returns the line shasum prints for a file: its hash, two
// spaces and its path, the line led by a backslash and the path's
// backslashes and newlines escaped when it has either.
func shasumLine(hash, path string) string {
	if strings.ContainsAny(path, "\\\n") {
		path = strings.NewReplacer(`\`, `\\`, "\n", `\n`).Replace(path)
		return `\` + hash + "  " + path + "\n"
	}
	return hash + "  " + path + "\n"
}

func (s *Session) checkHooks() {
	s.hooks = check{}
	if !isDir(s.stateApps) {
		s.hooks.result = "skipped"
		return
	}
	hooks := s.appsHooks()
	if len(hooks) == 0 {
		s.hooks.result = "clean"
		return
	}
	hash, ok := s.appsHooksHash()
	if !ok {
		s.hooks.fail("could not hash the apps hooks: " + hash)
		return
	}
	if recorded, err := os.ReadFile(s.hooksHashFile()); err == nil && strings.TrimRight(string(recorded), "\n") == hash {
		s.hooks.result = "clean"
		return
	}
	names := make([]string, len(hooks))
	for i, h := range hooks {
		names[i] = hookApp(h)
	}
	why := "a hook, or a file one watches, changed since they last ran"
	if !exists(s.hooksHashFile()) {
		why = "not run on this machine yet"
	}
	s.hooks.result, s.hooks.items = "drift", fmt.Sprintf("run %s (%s)", strings.Join(names, ", "), why)
}

// runAppsHooks runs every hook, and records the hash when all succeed. One
// that fails stops none after it.
func (s *Session) runAppsHooks() bool {
	hash, ok := s.appsHooksHash()
	if !ok {
		fmt.Fprintf(s.Err, "could not hash the apps hooks: %s\n", hash)
		return false
	}
	var failed []string
	for _, hook := range s.appsHooks() {
		app := hookApp(hook)
		s.println(app)
		cmd := exec.Command("bash", hook)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, s.Out, s.Err
		if cmd.Run() != nil {
			failed = append(failed, app)
		}
	}
	if len(failed) > 0 {
		fmt.Fprintf(s.Err, "after-apply failed for %s\n", strings.Join(failed, ", "))
		return false
	}
	err := os.MkdirAll(s.stateDir(), 0o755)
	if err == nil {
		err = os.WriteFile(s.hooksHashFile(), []byte(hash+"\n"), 0o644)
	}
	if err != nil {
		fmt.Fprintln(s.Err, err)
		return false
	}
	return true
}

// checkMachine runs every check but the behind one, which plan and apply
// each run in their own order. Full also diffs the files chezmoi lists,
// updates Homebrew and looks for upgrades. The checks run at once, but for
// Homebrew's, which follow its update in turn.
func (s *Session) checkMachine(full bool) {
	var wg sync.WaitGroup
	var updateWarning string
	wg.Go(func() { s.checkChezmoi(full) })
	wg.Go(s.checkMise)
	wg.Go(s.checkMacos)
	if s.repo != "" {
		wg.Go(func() {
			if full && exists(s.stateBrewfile) {
				updateWarning = updateHomebrew()
			}
			s.checkBrew()
			s.checkMissing()
			if full {
				s.checkOutdated()
			}
		})
		wg.Go(s.checkHooks)
	} else {
		s.hooks.fail(s.repoDetail)
		s.brew.fail(s.repoDetail)
		s.missing.fail(s.repoDetail)
		if full {
			s.outdated.fail(s.repoDetail)
		}
	}
	wg.Wait()
	s.warn(updateWarning)
}

// fetchAndCheckBehind takes how many fetch attempts to make.
func (s *Session) fetchAndCheckBehind(attempts int) {
	if s.repo == "" {
		s.behind.fail(s.repoDetail)
	} else if s.fetchCheckout(attempts) {
		s.checkBehind()
	}
}

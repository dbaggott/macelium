package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"

	"github.com/dbaggott/macelium/internal/run"
	"github.com/dbaggott/macelium/internal/settings"
	"github.com/dbaggott/macelium/internal/term"
)

// Listing it needs Full Disk Access: it holds the system's privacy database.
const fullDiskAccessProbe = "/Library/Application Support/com.apple.TCC"

var caskName = regexp.MustCompile(`^[[:alnum:]@._/+-]+$`)

func (s *Session) bootstrapLog() string {
	return filepath.Join(s.home, "Library/Logs/macelium-bootstrap.log")
}

// terminalApp returns the name of the app running this process, from the
// bundle identifier macOS puts in its environment.
func terminalApp() string {
	if id := os.Getenv("__CFBundleIdentifier"); id != "" {
		out, _ := run.Output("mdfind", "kMDItemCFBundleIdentifier == '"+id+"'")
		if path := strings.SplitN(out, "\n", 2)[0]; path != "" {
			return strings.TrimSuffix(filepath.Base(path), ".app")
		}
	}
	return "your terminal app"
}

// appsToAdopt returns the path of each app brew bundle would adopt: one in
// /Applications that a cask either Brewfile lists would install, while
// Homebrew has not installed that cask. It returns why when the casks cannot
// be read.
func (s *Session) appsToAdopt() ([]string, string) {
	cmd := exec.Command("brew", "bundle", "list", "--cask", "--file=-")
	cmd.Stdin = strings.NewReader(s.brewfiles())
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, failureOf("brew bundle list --cask", stderr.String(), err)
	}
	var casks []string
	for _, line := range strings.Split(string(out), "\n") {
		if caskName.MatchString(line) {
			casks = append(casks, line)
		}
	}
	if len(casks) == 0 {
		return nil, ""
	}
	cmd = exec.Command("brew", append([]string{"info", "--cask", "--json=v2"}, casks...)...)
	stderr.Reset()
	cmd.Stderr = &stderr
	info, err := cmd.Output()
	if err != nil {
		return nil, failureOf("brew info --cask --json=v2", stderr.String(), err)
	}
	var parsed struct {
		Casks []struct {
			Installed *string          `json:"installed"`
			Artifacts []map[string]any `json:"artifacts"`
		} `json:"casks"`
	}
	if err := json.Unmarshal(info, &parsed); err != nil {
		return nil, "brew info printed no JSON: " + err.Error()
	}
	var apps []string
	for _, c := range parsed.Casks {
		if c.Installed != nil {
			continue
		}
		for _, artifact := range c.Artifacts {
			app, ok := artifact["app"].([]any)
			if !ok || len(app) == 0 {
				continue
			}
			// An app artifact is its source path, then options whose target,
			// when given, is the name it is installed under.
			name, _ := app[0].(string)
			for _, opt := range app[1:] {
				if m, ok := opt.(map[string]any); ok {
					if target, ok := m["target"].(string); ok {
						name = target
						break
					}
				}
			}
			name = name[strings.LastIndex(name, "/")+1:]
			if isDir("/Applications/" + name) {
				apps = append(apps, "/Applications/"+name)
			}
		}
	}
	return apps, ""
}

// failureOf describes a command that failed, from its errors, or from how
// it failed when it printed none.
func failureOf(command, stderr string, err error) string {
	if stderr = strings.TrimRight(stderr, "\n"); stderr != "" {
		return stderr
	}
	return run.Failure(command, err.Error(), run.Status(err))
}

// mayChangeApp fails when macOS's App Management protection refuses this
// process a change inside the app's bundle. A refusal by ownership is left
// to the sudo that brew runs.
func (s *Session) mayChangeApp(app string, problem func(string)) bool {
	probe := filepath.Join(app, "Contents", ".macelium-bootstrap-probe")
	if err := os.Mkdir(probe, 0o755); err != nil {
		return !errors.Is(err, syscall.EPERM)
	}
	if os.Remove(probe) != nil {
		problem("Could not remove " + probe + ", made to check App Management: remove it by hand.")
	}
	return true
}

// checkPreflight changes nothing. It returns what needs fixing before the
// bootstrap can run, each problem and its fix a paragraph.
func (s *Session) checkPreflight() string {
	var problems []string
	problem := func(p string) { problems = append(problems, p+"\n") }
	terminal := terminalApp()
	if !run.Lookable("chezmoi") {
		problem("chezmoi is not installed: `brew install chezmoi`.")
	}
	if exists(s.stateBrewfile) {
		if apps, why := s.appsToAdopt(); why != "" {
			problem("Could not list the apps Homebrew would take over, to check that it may:\n" + why)
		} else {
			blocked := ""
			for _, app := range apps {
				if !s.mayChangeApp(app, problem) {
					blocked += "  " + strings.TrimSuffix(filepath.Base(app), ".app") + "\n"
				}
			}
			if blocked != "" {
				problem("These apps are pre-installed and Homebrew needs to take over installation:\n\n" + blocked +
					"\nYou can resolve this in one of two ways:\n\n" +
					"  1. uninstall them by deleting them from /Applications (your user data will be preserved and Homebrew will install fresh copies)\n" +
					"  2. grant " + terminal + " \"App Management\" permission (via " + appManagementSettings + "), and keep it: `macelium apply` needs it to upgrade apps too")
			}
		}
	}
	if exists(s.stateSettings) {
		l, why := settings.Load(s.stateSettings)
		if l == nil {
			problem(why)
		} else {
			s.list = l
			var sandboxed []string
			for _, sb := range l.Sandboxes {
				sandboxed = append(sandboxed, sb.App)
			}
			if _, err := os.ReadDir(fullDiskAccessProbe); len(sandboxed) > 0 && err != nil {
				problem("The settings list has settings for " + strings.Join(sandboxed, ", ") + ", which macOS sandboxes, so reading and writing them needs Full Disk Access:\n\n" +
					"  grant " + terminal + " \"Full Disk Access\" permission (via System Settings → Privacy & Security → Full Disk Access)")
			}
		}
	}
	return strings.Join(problems, "\n")
}

// checkFileVault says so, at once and among the warnings at the end, when
// FileVault is off. It says nothing when fdesetup fails or prints anything
// else.
func (s *Session) checkFileVault() {
	out, status := run.Output("fdesetup", "status")
	// Its first line only, as it may print more after it.
	if status != 0 || strings.SplitN(out, "\n", 2)[0] != "FileVault is Off." {
		return
	}
	fmt.Fprintf(s.Err, "\n%s\n%s\n%s\n",
		"FYI: Your macOS FileVault is off. Enabling it is generally considered a security",
		"best practice. If you want it, enable it through System Settings. Macelium will",
		"work either way, and you can enable it after this process completes.")
	s.warn("FileVault is off: enable it through System Settings → Privacy & Security → FileVault if you want it.")
}

// startSudo asks for the password once for macelium's own steps, and keeps
// sudo's credentials fresh until the bootstrap ends, returning what stops
// the keeping. Homebrew discards them the first time a brew process needs
// sudo, so a cask that runs sudo asks again.
func (s *Session) startSudo() (func(), bool) {
	s.enableTouchIDSudo()
	s.println()
	s.println("Macelium will now configure your computer according to your specifications. This")
	s.println("includes installing your Homebrew-managed applications and, depending on what you")
	s.println("are installing, this may take a long time. You'll be prompted to enter your")
	s.println("password one or more times as part of installation.")
	s.println()
	if s.interactive("sudo", "-v") != 0 {
		return nil, false
	}
	// The keeper is off the terminal, since under use_pty, sudo's default,
	// sudo relays the terminal's input to the command it runs, away from
	// the step reading it. It is outside this process's tree, where a logged
	// step's display would take its sudo for one asking for a password.
	keeper := fmt.Sprintf(`while kill -0 %d 2>/dev/null; do sudo -n -v; sleep 50; done </dev/null >/dev/null 2>&1 & echo $!`, os.Getpid())
	out, status := run.Output("sh", "-c", keeper)
	pid, err := strconv.Atoi(out)
	if status != 0 || err != nil {
		return func() {}, true
	}
	kill := func() {
		if p, err := os.FindProcess(pid); err == nil {
			_ = p.Kill()
		}
	}
	// An interrupt ends bootstrap with the keeper stopped, as a return does.
	interrupted := make(chan os.Signal, 1)
	signal.Notify(interrupted, os.Interrupt, syscall.SIGTERM)
	done := make(chan struct{})
	go func() {
		select {
		case sig := <-interrupted:
			kill()
			os.Exit(128 + int(sig.(syscall.Signal)))
		case <-done:
		}
	}()
	return func() {
		signal.Stop(interrupted)
		close(done)
		kill()
	}, true
}

// printInitNotes prints the state repo's notes on chezmoi init's questions,
// before chezmoi asks them on a machine that has no chezmoi config yet.
func (s *Session) printInitNotes() {
	if s.stateInitNotes == "" || !isFile(s.stateInitNotes) || s.chezmoiConfigFile() != "" {
		return
	}
	data, _ := os.ReadFile(s.stateInitNotes)
	s.printf("%s", data)
}

// explainChangedFiles explains the question chezmoi asks about each file
// edited since chezmoi last wrote it, before it asks: the first status
// column says so.
func (s *Session) explainChangedFiles() {
	out, _ := run.Output("chezmoi", "status", "--source", s.repo, "--exclude", "scripts")
	var changed []string
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "M") && len(line) > 3 {
			changed = append(changed, "  "+line[3:])
		}
	}
	if len(changed) == 0 {
		return
	}
	s.println("These files were edited here since chezmoi last wrote them, so it asks about each:")
	s.println(strings.Join(changed, "\n"))
	s.println("Answer diff to see what the repo would change, overwrite to take the repo's version,")
	s.println("or skip to keep the edit, which macelium plan then reports until it is resolved.")
}

// remaining returns the manual steps, those the machine shows undone first.
func (s *Session) remaining() []string {
	// The shell that ran the bootstrap started before chezmoi wrote its
	// config.
	steps := []string{"Run `exec zsh -l`, so this shell reads its new config."}
	if exists(s.stateSettings) {
		if l, _ := settings.Load(s.stateSettings); l != nil {
			s.list = l
			s.probeSandboxes()
			if s.macosNotes != "" {
				for _, note := range strings.Split(s.macosNotes, "\n") {
					steps = append(steps, note+".")
				}
			}
		}
	}
	steps = append(steps, "Open each newly installed app once, granting the permissions it asks for.")
	files, _ := filepath.Glob(filepath.Join(s.stateApps, "*", "manual-steps"))
	for _, f := range files {
		if !isFile(f) {
			continue
		}
		data, _ := os.ReadFile(f)
		for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
			if strings.TrimSpace(line) != "" {
				steps = append(steps, line)
			}
		}
	}
	return append(steps, "Enter license keys, and set login items.")
}

// settingsStep writes the settings as a step of its own, with its warnings
// and why it stopped in the step's output.
func settingsStep(s *Session) bool {
	if !s.writeSettings(false) {
		s.printWarnings()
		fmt.Fprintf(s.Err, "stopped: %s\n", s.macos.detail)
		return false
	}
	s.printWarnings()
	return true
}

// findBrew puts Homebrew on PATH when it is installed but not there, as a
// new Mac's shell has it before its config does. It fails when there is no
// Homebrew.
func findBrew() bool {
	if run.Lookable("brew") {
		return true
	}
	for _, prefix := range []string{"/opt/homebrew", "/usr/local"} {
		if info, err := os.Stat(prefix + "/bin/brew"); err == nil && info.Mode()&0o111 != 0 {
			os.Setenv("HOMEBREW_PREFIX", prefix)
			os.Setenv("HOMEBREW_CELLAR", prefix+"/Cellar")
			repository := prefix
			if prefix == "/usr/local" {
				repository = prefix + "/Homebrew"
			}
			os.Setenv("HOMEBREW_REPOSITORY", repository)
			os.Setenv("PATH", prefix+"/bin:"+prefix+"/sbin:"+os.Getenv("PATH"))
			return true
		}
	}
	return false
}

// Bootstrap sets up this Mac from the checkout, or from the one chezmoi's
// config names when checkout is "".
func (s *Session) Bootstrap(checkout string) int {
	if !s.requireTerminal() {
		return 1
	}
	term.Banner(s.Out, s.Version)
	if !findBrew() {
		s.printError("Homebrew is not installed: see https://brew.sh")
		return 1
	}
	rerun := "macelium bootstrap"
	dir := ""
	if checkout != "" {
		abs, err := filepath.Abs(checkout)
		if err == nil {
			abs, err = filepath.EvalSymlinks(abs)
		}
		if err != nil || !isDir(abs) {
			s.printError("no directory " + checkout)
			return 1
		}
		dir = abs
	}
	if !s.refuseForeignChezmoi() {
		return 1
	}
	if dir != "" {
		s.useCheckout(dir)
		rerun += " " + shellQuote(dir)
	} else {
		s.findCheckout()
	}
	if s.repo == "" {
		s.printError(s.repoDetail)
		return 1
	}

	s.println("Checking what the bootstrap needs from macOS...")
	if problems := s.checkPreflight(); problems != "" {
		fmt.Fprintf(s.Err, "\n%s", problems)
		return 1
	}
	s.checkFileVault()

	stopKeeper, ok := s.startSudo()
	if !ok {
		s.printStopped("sudo failed")
		return 1
	}
	defer stopKeeper()
	s.useStepLog(s.bootstrapLog())

	s.printInitNotes()
	if !s.runTerminalStep("chezmoi init", "chezmoi", "init", "--source", s.repo) {
		s.printStopped("chezmoi init failed")
		return 1
	}
	// Each script and step is its own, so one that fails stops none after
	// it, and chezmoi records each script that succeeds as run.
	s.explainChangedFiles()
	s.runTerminalStep("Files", "chezmoi", "apply", "--source", s.repo, "--exclude", "scripts")
	scripts, _ := run.Output("chezmoi", "managed", "--source", s.repo, "--include", "scripts")
	for _, script := range strings.Split(scripts, "\n") {
		if script == "" {
			continue
		}
		s.runLoggedStep(script, command("chezmoi", "apply", "--source", s.repo, filepath.Join(s.home, script)))
	}
	s.runInstallSteps(false)
	if exists(s.stateSettings) {
		s.runLoggedStep("macOS settings", step{fn: settingsStep, label: "settings_step"})
	}
	// Hooks that ran on an earlier bootstrap are skipped, as a finished step.
	s.checkHooks()
	switch s.hooks.result {
	case "drift":
		s.runLoggedStep("Apps hooks", step{fn: (*Session).runAppsHooks, label: "run_apps_hooks"})
	case "error":
		s.recordStep("Apps hooks", "failed")
		s.heading("Apps hooks")
		s.println(s.hooks.detail)
	}

	s.heading("Differences from the state repo (macelium plan)")
	// plan compares the machine with the checkout chezmoi's config names, so
	// after applying another, such as a worktree, it would list their
	// difference.
	// The plan is a run of its own: its warnings print within it, and the
	// bootstrap's own at the end.
	plan := NewSession(s.Sub, s.Version)
	plan.Out, plan.Err = s.Out, s.Err
	plan.findCheckout()
	if plan.repo != s.repo {
		s.printf("Skipped: this bootstrap ran from %s, and macelium plan only checks %s.\n", s.repo, plan.repo)
	} else {
		plan.unlistedNote = "They were on this Mac before the bootstrap: the state repo doesn't list them."
		plan.Plan(false)
	}

	s.println("\nSteps:")
	failed := 0
	for _, r := range s.stepResults {
		s.printf("  %-7s %s\n", r.result, r.name)
		if r.result == "failed" {
			failed++
		}
	}
	s.println("\nManual steps:")
	for _, line := range s.remaining() {
		s.println("  - " + line)
	}
	s.printWarnings()
	s.println()
	if failed > 0 {
		s.printf("Bootstrap finished with %d failed: fix what is shown above, or in %s, and run `%s` again; finished steps are skipped.\n", failed, s.bootstrapLog(), rerun)
		return 1
	}
	s.printOutcome("Bootstrap complete")
	return 0
}

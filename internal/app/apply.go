package app

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/dbaggott/macelium/internal/run"
)

// Apple's /etc/pam.d/sudo_local.template carries this line commented out;
// /etc/pam.d/sudo includes sudo_local, which survives system updates.
const pamTIDLine = "auth       sufficient     pam_tid.so"

const activateSettings = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

var (
	pamTID     = regexp.MustCompile(`(?m)^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so`)
	enrolledRe = regexp.MustCompile(`[1-9][0-9]* biometric template`)
)

func (s *Session) applyLog() string {
	return filepath.Join(s.home, "Library/Logs/macelium-apply.log")
}

// interactive runs a command on the terminal, which its prompts need, and
// returns its exit status.
func (s *Session) interactive(name string, args ...string) int {
	cmd := exec.Command(name, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, s.Out, s.Err
	err := cmd.Run()
	if errors.Is(err, exec.ErrNotFound) {
		fmt.Fprintf(s.Err, "%s: command not found\n", name)
	}
	return run.Status(err)
}

// enableTouchIDSudo offers to turn on Touch ID for sudo, when the list
// declares touch_id_sudo, the Mac has a finger enrolled and sudo does not
// take it already.
func (s *Session) enableTouchIDSudo() {
	if s.list == nil || !s.list.TouchID || s.touchIDDeclined {
		return
	}
	current, _ := os.ReadFile(s.sudoLocal)
	if pamTID.Match(current) {
		return
	}
	// A Mac without Touch ID, or with no finger enrolled, has nothing to
	// offer.
	enrolled, _ := run.Output("bioutil", "-c")
	if !enrolledRe.MatchString(enrolled) {
		return
	}
	// chezmoi apply can run with no terminal; that counts as declining.
	if !s.hasTerminal() {
		s.warn("no terminal, so Touch ID for sudo was skipped: run `macelium settings` in a terminal to be asked again")
		return
	}
	if s.confirm("Enable Touch ID for sudo in "+s.sudoLocal+"? This uses sudo.", false) != 0 {
		s.touchIDDeclined = true
		s.warn("Touch ID for sudo was skipped: run `macelium settings` to be asked again")
		return
	}
	// An existing file's last line may lack its newline; the line goes on
	// one of its own.
	line := pamTIDLine + "\n"
	if len(current) > 0 && current[len(current)-1] != '\n' {
		line = "\n" + line
	}
	cmd := exec.Command("sudo", "tee", "-a", s.sudoLocal)
	cmd.Stdin = strings.NewReader(line)
	cmd.Stderr = s.Err
	if cmd.Run() != nil {
		s.warn("could not write " + s.sudoLocal + ", so Touch ID for sudo was skipped")
	}
}

func (s *Session) writeSetting(i int) bool {
	return s.interactive("defaults", s.list.Settings[i].WriteArgs()...) == 0
}

func running(app string) bool {
	return exec.Command("pgrep", "-xq", app).Run() == nil
}

// writeSandboxed writes those of a sandboxed app's settings that differ,
// leaving the app alone when none does. A failed write warns, and the rest
// still run.
func (s *Session) writeSandboxed(sb int) {
	box := s.list.Sandboxes[sb]
	var keys []int
	for _, i := range s.differing {
		if s.list.Settings[i].Domain == box.Domain {
			keys = append(keys, i)
		}
	}
	if len(keys) == 0 {
		return
	}
	wasRunning := running(box.App)
	if wasRunning {
		_ = exec.Command("killall", box.App).Run()
		for range 50 {
			if !running(box.App) {
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	failed := false
	for _, i := range keys {
		if !s.writeSetting(i) {
			s.warn("could not write " + s.list.Settings[i].Name() + ", skipped it")
			failed = true
		}
	}
	if failed {
		s.warn("to write " + box.App + "'s settings, give the terminal Full Disk Access (System Settings → Privacy & Security → Full Disk Access), quit and reopen it, then run `macelium settings`")
	}
	if wasRunning {
		_ = exec.Command("open", "-ga", box.App).Run()
	}
}

// writeSettings compares the settings again, writes those that differ, then
// restarts the apps that read them. A failed write stops it, but for a
// sandboxed app's, which warns. alwaysTouchID offers Touch ID for sudo on a
// run that has no key to write too. It fails with the macos check's detail
// set to why.
func (s *Session) writeSettings(alwaysTouchID bool) bool {
	s.checkMacos()
	if s.macos.result == "error" {
		s.macos.detail = "could not read the macOS settings: " + s.macos.detail
		return false
	}
	if s.macosNotes != "" {
		s.warn(s.macosNotes)
	}
	s.settingsWritten = false
	if len(s.differing) == 0 {
		if alwaysTouchID {
			s.enableTouchIDSudo()
		}
		return true
	}
	s.settingsWritten = true
	s.println("Writing:")
	s.println(indent(s.macos.items))
	var apps []string
	hotkeys := false
	failed := ""
	for _, i := range s.differing {
		setting := s.list.Settings[i]
		if s.list.SandboxOf(setting.Domain) >= 0 {
			continue
		}
		if !s.writeSetting(i) {
			failed = setting.Name()
			break
		}
		if setting.Type == "hotkey" {
			hotkeys = true
		}
		apps = append(apps, s.list.RestartsFor(setting.Domain)...)
	}
	if failed == "" {
		for sb := range s.list.Sandboxes {
			s.writeSandboxed(sb)
		}
	}
	// The keys written before a failed write still take effect.
	// activateSettings, a private tool, applies the keyboard shortcut
	// changes without a logout.
	if hotkeys && s.interactive(activateSettings, "-u") != 0 {
		s.warn("could not activate the keyboard shortcuts: log out and in to apply them")
	}
	// One that is not running is skipped.
	var restarted []string
	seen := map[string]bool{}
	for _, app := range apps {
		if seen[app] {
			continue
		}
		seen[app] = true
		if exec.Command("killall", app).Run() == nil {
			restarted = append(restarted, app)
		}
	}
	if len(restarted) > 0 {
		s.println("Restarted: " + strings.Join(restarted, " "))
	}
	if failed != "" {
		s.macos.detail = "could not write " + failed
		return false
	}
	s.enableTouchIDSudo()
	return true
}

// Settings writes the macOS settings that differ from the list, the state
// repo's unless file names another, without asking.
func (s *Session) Settings(file string) int {
	s.settingsFile = file
	if file == "" {
		s.findCheckout()
	}
	if !s.writeSettings(true) {
		s.printStopped(s.macos.detail)
		return 1
	}
	s.printWarnings()
	switch {
	case s.macos.result == "skipped":
		s.printOutcome("No settings list in the state repo")
	case s.settingsWritten:
		s.printOutcome("macOS settings applied")
	default:
		s.printOutcome("No macOS settings differ")
	}
	return 0
}

// upgradeSelf upgrades macelium, then replaces this process with the
// upgraded command's apply, which plans and asks again, so what gets
// applied is what the version applying it showed. It returns, having
// changed nothing else, only when the upgrade fails. MACELIUM_UPGRADED_FROM
// stops the new apply doing the same again.
func (s *Session) upgradeSelf() {
	s.heading("brew upgrade macelium")
	if s.interactive("brew", "upgrade", "macelium") != 0 {
		s.println("No changes made.")
		return
	}
	// This process's path can name the old keg, which the upgrade replaced.
	prefix, status := run.Output("brew", "--prefix")
	upgraded := filepath.Join(prefix, "bin", "macelium")
	if info, err := os.Stat(upgraded); status != 0 || err != nil || info.Mode()&0o111 == 0 {
		s.printStopped("macelium was upgraded, but not found under brew --prefix to run")
		return
	}
	os.Setenv("MACELIUM_UPGRADED_FROM", s.Version)
	err := syscall.Exec(upgraded, []string{upgraded, "apply"}, os.Environ())
	s.printStopped("could not run the upgraded macelium: " + err.Error())
}

// Apply prints the plan, asks, then brings this Mac in line with the state
// repo.
func (s *Session) Apply() int {
	if !s.requireTerminal() {
		return 1
	}
	upgradedFrom := os.Getenv("MACELIUM_UPGRADED_FROM")
	if upgradedFrom != "" {
		s.printf("\nmacelium was upgraded from %s to %s, and plans again.\n\n", upgradedFrom, s.Version)
	}
	s.findCheckout()
	if s.manifestFailed {
		s.printError(s.repoDetail)
		return 1
	}
	s.withSpinner("Fetching the state repo", func() { s.fetchAndCheckBehind(1) })
	if s.behind.result == "drift" {
		s.printf("Your local macelium state is behind %s by %s:\n", s.upstream, commitsPhrase(countLines(s.behind.items)))
		s.println(indent(s.behind.items))
		if s.confirm("Pull them first?", true) == 0 {
			if s.interactive("git", "-C", s.repo, "pull", "--ff-only") != 0 {
				return 1
			}
			// The pulled commits may change the manifest.
			s.useCheckout(s.repo)
			if s.manifestFailed {
				s.printError(s.repoDetail)
				return 1
			}
			s.checkBehind()
		}
	}
	s.withSpinner("Comparing this machine with the state repo", func() { s.checkMachine(true) })
	s.printPlan()
	if s.failedChecks() != "" {
		s.println("No changes made.")
		return 1
	}
	change, upgrades := s.itemsToChange(), countLines(s.outdated.items)
	if change+upgrades == 0 {
		return 0
	}
	var scope []string
	if change > 0 {
		scope = append(scope, fmt.Sprintf("%d to change", change))
	}
	if upgrades > 0 {
		scope = append(scope, fmt.Sprintf("%d to upgrade", upgrades))
	}
	s.println()
	if s.confirm("Apply the "+strings.Join(scope, " and ")+"?", false) != 0 {
		s.println("No changes made.")
		return 0
	}
	if upgradedFrom == "" {
		for _, item := range strings.Split(s.outdated.items, "\n") {
			if item == "Formula "+SelfFormula {
				s.upgradeSelf()
				return 1
			}
		}
	}
	// Without an upgrade in the plan, no step upgrades, a state repo's
	// chezmoi script that runs brew bundle included.
	if upgrades == 0 {
		os.Setenv("HOMEBREW_BUNDLE_NO_UPGRADE", "1")
	}
	if !s.runTerminalStep("chezmoi apply", "chezmoi", "apply", "--force") {
		s.printStopped("chezmoi apply failed")
		return 1
	}
	s.useStepLog(s.applyLog())
	if failed := s.runInstallSteps(true); failed != "" {
		s.printStopped(failed + " failed")
		return 1
	}
	if s.macos.items != "" {
		s.heading("macOS settings")
		if !s.writeSettings(false) {
			s.printStopped(s.macos.detail)
			return 1
		}
		if !s.settingsWritten {
			s.println("No macOS settings differ any more.")
		}
	}
	if s.hooks.items != "" {
		s.heading("Apps hooks")
		if !s.runAppsHooks() {
			s.printStopped("an apps hook failed")
			return 1
		}
	}
	s.printWarnings()
	s.println()
	s.printOutcome("Apply complete")
	return 0
}

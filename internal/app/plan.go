package app

import (
	"fmt"
	"strings"
	"sync"

	"github.com/dbaggott/macelium/internal/run"
)

type namedCheck struct {
	name string
	*check
}

// checkTable returns each check that ran, in the order plan prints them.
func (s *Session) checkTable() []namedCheck {
	table := []namedCheck{
		{"chezmoi", &s.chezmoi}, {"brew", &s.brew}, {"missing", &s.missing}, {"behind", &s.behind},
		{"mise", &s.mise}, {"macos", &s.macos}, {"hooks", &s.hooks},
	}
	if s.outdated.result != "" {
		table = append(table, namedCheck{"outdated", &s.outdated})
	}
	return table
}

func (s *Session) failedChecks() string {
	var failed []string
	for _, c := range s.checkTable() {
		if c.result == "error" {
			failed = append(failed, c.name)
		}
	}
	return strings.Join(failed, ", ")
}

func commitsPhrase(n int) string {
	if n == 1 {
		return "1 commit"
	}
	return fmt.Sprintf("%d commits", n)
}

func (s *Session) itemsToChange() int {
	return countLines(s.chezmoi.items) + countLines(s.missing.items) + countLines(s.mise.items) + countLines(s.macos.items) + countLines(s.hooks.items)
}

func (s *Session) itemsUndecided() int {
	n := countLines(s.brew.items)
	if s.chezmoiConfigStale {
		n++
	}
	return n
}

// planStatus is 0 when nothing differs, 2 when anything does, 1 when a check
// failed, whatever the others found. The outdated check only shows
// upgrades, so its drift does not count.
func (s *Session) planStatus() int {
	drift := false
	for _, c := range s.checkTable() {
		if c.result == "error" {
			return 1
		}
		if c.result == "drift" && c.name != "outdated" {
			drift = true
		}
	}
	if drift {
		return 2
	}
	return 0
}

// printSection prints a heading and the section's items, and nothing when
// it has none.
func (s *Session) printSection(heading, items string) {
	if items == "" {
		return
	}
	s.printf("\n%s\n%s\n", heading, indent(items))
}

// printKeepRemove prints an unlisted entry with the commands that keep or
// remove it: its heading, the command that removes it, and the Brewfile
// lines that keep it.
func (s *Session) printKeepRemove(heading, remove string, lines []string) {
	quoted := ""
	for _, l := range lines {
		quoted += " '" + l + "'"
	}
	s.printf("\n  %s\n", heading)
	s.printf("    keep, this machine:   %s\n", "mkdir -p ~/.config/macelium && printf '%s\\n'"+quoted+" >> ~/.config/macelium/Brewfile.local")
	s.printf("    keep, every machine:  add to the repo's Brewfile, through a PR:\n")
	for _, l := range lines {
		s.printf("                            %s\n", l)
	}
	s.printf("    remove:               %s\n", remove)
}

// printUnlisted prints each unlisted entry, "<kind> <name>" a line, with the
// commands that keep or remove it. A tap comes after the packages from it:
// brew untap refuses while one is installed, and listing one keeps the tap,
// so the tap's own fate follows theirs.
func (s *Session) printUnlisted(entries string) {
	if entries == "" {
		return
	}
	s.printf("\n%s\n", "Homebrew: installed but not listed — keep or remove each")
	if s.unlistedNote != "" {
		s.printf("  %s\n", s.unlistedNote)
	}
	type entry struct{ kind, name string }
	var list []entry
	taps := map[string]bool{}
	for _, line := range strings.Split(entries, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		e := entry{fields[0], strings.Join(fields[1:], " ")}
		list = append(list, e)
		if e.kind == "tap" {
			taps[e.name] = true
		}
	}
	for _, e := range list {
		if e.kind == "tap" {
			continue
		}
		var lines []string
		tap := ""
		if strings.Count(e.name, "/") >= 2 {
			tap = e.name[:strings.LastIndex(e.name, "/")]
		}
		if tap != "" && taps[tap] {
			lines = append(lines, `tap "`+tap+`"`)
		}
		var line, remove string
		switch e.kind {
		case "formula":
			// A formula from a third-party tap needs trusting before brew
			// loads it.
			line, remove = `brew "`+e.name+`"`, "brew uninstall "+e.name
			if tap != "" {
				line += ", trusted: true"
			}
		case "cask":
			line, remove = `cask "`+e.name+`"`, "brew uninstall --cask "+e.name
		default:
			s.printf("\n  %s %s\n", e.kind, e.name)
			continue
		}
		s.printKeepRemove(e.kind+" "+e.name, remove, append(lines, line))
	}
	for _, e := range list {
		if e.kind != "tap" {
			continue
		}
		var from []string
		for _, other := range list {
			if strings.HasPrefix(other.name, e.name+"/") {
				from = append(from, other.name)
			}
		}
		if len(from) > 0 {
			s.printf("\n  tap %s\n", e.name)
			s.printf("    kept along with any formula or cask from it that you keep\n")
			s.printf("    remove:               brew untap %s, after removing %s\n", e.name, strings.Join(from, ", "))
		} else {
			s.printKeepRemove("tap "+e.name, "brew untap "+e.name, []string{`tap "` + e.name + `"`})
		}
	}
}

func (s *Session) printPlan() {
	files := s.chezmoi.items
	if s.chezmoiConfigStale {
		if files != "" {
			files += "\n"
		}
		files += "chezmoi's config is from an older config template (undecided: `chezmoi init` regenerates it)"
	}
	s.printSection("Repo: commits the checkout lacks", s.behind.items)
	s.printSection("Files", files)
	if s.chezmoiDiff != "" {
		s.printf("\n%s\n", s.chezmoiDiff)
	}
	s.printSection("Homebrew: listed but not installed", s.missing.items)
	s.printUnlisted(s.brew.items)
	s.printSection("Runtimes", s.mise.items)
	s.printSection("macOS settings", s.macos.items)
	s.printSection("Apps hooks", s.hooks.items)
	s.printSection("Homebrew: upgrades available", s.outdated.items)

	for _, c := range s.checkTable() {
		if c.result != "error" {
			continue
		}
		lines := strings.Split(c.detail, "\n")
		fmt.Fprintf(s.Err, "\nCheck '%s' failed: %s\n", c.name, lines[0])
		if len(lines) > 1 {
			fmt.Fprintln(s.Err, indent(strings.Join(lines[1:], "\n")))
		}
	}
	// A warning counts toward nothing.
	s.warn(s.macosNotes)
	if isFile(s.localBrewfile()) && !exists(s.stateBrewfile) {
		s.warn("macelium reads ~/.config/macelium/Brewfile.local only with the state repo's Brewfile, and " + s.stateBrewfile + " does not exist: its packages are not checked or installed")
	}
	s.printWarnings()

	change, undecided := s.itemsToChange(), s.itemsUndecided()
	upgrade, commits := countLines(s.outdated.items), countLines(s.behind.items)
	failed := s.failedChecks()
	s.println()
	if change+upgrade+undecided+commits == 0 && failed == "" {
		s.println("No changes. This machine matches the state repo.")
		return
	}
	line := "Plan"
	if failed != "" {
		line = "Partial plan (error)"
	}
	line += fmt.Sprintf(": %d to change, %d to upgrade, %d undecided.", change, upgrade, undecided)
	if commits > 0 {
		line += fmt.Sprintf(" Behind %s by %s.", s.upstream, commitsPhrase(commits))
	}
	s.println(line)
}

// notify posts a macOS notification, returning why it failed, on one line
// for the run's log line.
func notify(title, message string) (string, bool) {
	out, status := run.Capture(nil, "osascript",
		"-e", "on run argv",
		"-e", "display notification (item 2 of argv) with title (item 1 of argv)",
		"-e", "end run",
		title, message)
	if status == 0 {
		return "", true
	}
	return detailLine(run.Failure("osascript", out, status)), false
}

// printLogLine prints plan --notify's one line for a run whose exit status
// is status, after posting the notification when it is not 0.
func (s *Session) printLogLine(status int) {
	notified, notifyDetail := "no", ""
	if status != 0 {
		message := "Run `macelium plan`."
		if failed := s.failedChecks(); failed != "" {
			message += " Failed checks: " + failed + "."
		}
		var ok bool
		if notifyDetail, ok = notify("Macelium drift", message); ok {
			notified = "yes"
		} else {
			notified = "failed"
		}
	}
	line := timestamp()
	errors := ""
	for _, c := range s.checkTable() {
		line += " " + c.name + "=" + c.result
		if c.detail != "" {
			errors += " " + c.name + "_error=" + shellQuote(detailLine(c.detail))
		}
	}
	line += " notified=" + notified + errors
	if notifyDetail != "" {
		line += " notify_error=" + shellQuote(notifyDetail)
	}
	s.println(line)
}

// printRefusalLogLine posts the notification that the manifest was refused,
// and prints plan --notify's line for a run that checked nothing.
func (s *Session) printRefusalLogLine(why string) {
	notified := "yes"
	notifyDetail, ok := notify("Macelium drift", "The state repo's macelium.conf was refused. Run `macelium plan`.")
	if !ok {
		notified = "failed"
	}
	line := timestamp() + " manifest=error notified=" + notified + " manifest_error=" + shellQuote(detailLine(why))
	if notifyDetail != "" {
		line += " notify_error=" + shellQuote(notifyDetail)
	}
	s.println(line)
}

// shellQuote quotes s as /bin/bash's printf %q does in the C locale that
// launchd runs the service in, so the log line reads as it always has.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	for i := 0; i < len(s); i++ {
		if c := s[i]; c < 0x20 || c >= 0x7f {
			return ansiQuote(s)
		}
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case ' ', '\t', '\'', '"', '\\', '|', '&', ';', '(', ')', '<', '>', '!', '{', '}', '*', '[', '?', ']', '^', '$', '`', ',':
			b.WriteByte('\\')
		case '#':
			if i == 0 {
				b.WriteByte('\\')
			}
		}
		b.WriteByte(c)
	}
	return b.String()
}

// ansiEscapes are the escapes $'...' quoting writes for a byte, beside the
// octal it writes for any other that is not printable ASCII.
var ansiEscapes = map[byte]string{
	0x1b: `\E`, '\a': `\a`, '\b': `\b`, '\f': `\f`, '\n': `\n`, '\r': `\r`, '\t': `\t`, '\v': `\v`,
	'\'': `\'`, '\\': `\\`,
}

// ansiQuote quotes s as $'...', for a string that is not all printable
// ASCII.
func ansiQuote(s string) string {
	var b strings.Builder
	b.WriteString("$'")
	for i := 0; i < len(s); i++ {
		c := s[i]
		if e, ok := ansiEscapes[c]; ok {
			b.WriteString(e)
		} else if c < 0x20 || c >= 0x7f {
			fmt.Fprintf(&b, `\%03o`, c)
		} else {
			b.WriteByte(c)
		}
	}
	b.WriteString("'")
	return b.String()
}

// Plan compares this machine with the state repo, prints the difference, or
// with notify one log line, and returns plan's exit status.
func (s *Session) Plan(notifyMode bool) int {
	s.findCheckout()
	if s.manifestFailed {
		if notifyMode {
			s.printRefusalLogLine(s.repoDetail)
		} else {
			s.printError(s.repoDetail)
		}
		return 1
	}
	if notifyMode {
		// No one is watching, so the fetch, which may wait out its retries,
		// runs beside the checks.
		var wg sync.WaitGroup
		wg.Go(func() { s.fetchAndCheckBehind(notifyFetchAttempts) })
		s.checkMachine(false)
		wg.Wait()
		status := s.planStatus()
		s.printLogLine(status)
		return status
	}
	s.withSpinner("Fetching the state repo", func() { s.fetchAndCheckBehind(1) })
	s.withSpinner("Comparing this machine with the state repo", func() { s.checkMachine(true) })
	s.printPlan()
	return s.planStatus()
}

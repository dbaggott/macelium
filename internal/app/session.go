// Package app is macelium's commands: plan, apply, settings, bootstrap,
// init and setup, over a state repo and this Mac.
package app

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dbaggott/macelium/internal/settings"
	"github.com/dbaggott/macelium/internal/term"
)

// SelfFormula is how brew bundle check names macelium in a state repo's
// Brewfile.
const SelfFormula = "dbaggott/tap/macelium"

// KnownContract is the manifest contract this macelium reads.
const KnownContract = 1

// check is one check's result: clean, drift, error, or skipped when the
// state repo lacks the part it checks; on error, why: a line naming what
// failed, then whatever the failing command printed; and on drift, what
// differs, one item per line.
type check struct {
	result, detail, items string
}

func (c *check) fail(detail string) { c.result, c.detail = "error", detail }

// Session is one run of a command: where it writes, the state repo it
// found, what its checks found, and the warnings it gives at its end.
type Session struct {
	// The command being run, which its messages name.
	Sub     string
	Version string
	Out     io.Writer
	Err     io.Writer

	home string

	// warnings needs the operator's attention but stops nothing, a line
	// each, which each command prints at its end.
	warnings []string

	// The checkout, once its manifest loads, or why it was not found; and
	// whether the manifest refused, which stops plan and apply before any
	// check.
	repo, repoDetail string
	manifestFailed   bool
	// The parts of the state repo the manifest names, each an absolute path
	// that may not exist. A missing one skips its part.
	stateBrewfile, stateSettings, stateApps, stateInitNotes string
	upstream                                                string

	chezmoi, brew, missing, behind, mise, macos, hooks check
	// Run only for the full plan, and never drift for plan's exit status.
	outdated check
	// Whether chezmoi's config was rendered from an older config template,
	// and the diff of the targets chezmoi status lists.
	chezmoiConfigStale bool
	chezmoiDiff        string

	// The settings list as check_macos last read it, the indexes of the
	// settings that differ, and the notes on sandboxed apps whose settings
	// were not compared.
	list         *settings.List
	differing    []int
	macosNotes   string
	settingsFile string
	// Whether write_settings had a key to write.
	settingsWritten bool
	// Set when the operator declines Touch ID for sudo, so a run offers it
	// once.
	touchIDDeclined bool

	// Said under the heading of the packages installed but not listed, when
	// set: bootstrap says where they came from.
	unlistedNote string

	// The log a logged step's output goes to, and each step and how it
	// ended.
	stepLog     string
	stepResults []stepResult
	// How long a logged step's status waits between updates.
	tick time.Duration

	// confirm asks a yes-or-no question on the terminal, which hasTerminal
	// says there is; sudoLocal is the PAM file Touch ID for sudo goes in.
	// Tests replace them.
	confirm     func(question string, def bool) int
	hasTerminal func() bool
	sudoLocal   string
}

type stepResult struct{ name, result string }

// NewSession returns a session for the command sub, writing to stdout and
// stderr.
func NewSession(sub, version string) *Session {
	return &Session{
		Sub: sub, Version: version, Out: os.Stdout, Err: os.Stderr,
		home: os.Getenv("HOME"), tick: 5 * time.Second,
		confirm: term.Confirm, hasTerminal: term.Usable, sudoLocal: "/etc/pam.d/sudo_local",
	}
}

// child returns a copy of the session writing to w, as a subshell would
// run: what it sets stays its own.
func (s *Session) child(w io.Writer) *Session {
	c := *s
	c.Out, c.Err = w, w
	c.warnings = append([]string(nil), s.warnings...)
	c.stepResults = append([]stepResult(nil), s.stepResults...)
	return &c
}

func (s *Session) localBrewfile() string {
	return filepath.Join(s.home, ".config/macelium/Brewfile.local")
}

func (s *Session) stateDir() string {
	return filepath.Join(s.home, ".local/state/macelium")
}

func (s *Session) printf(format string, a ...any) { fmt.Fprintf(s.Out, format, a...) }
func (s *Session) println(a ...any)               { fmt.Fprintln(s.Out, a...) }

// warn takes warnings, a line each. One already given, such as apply's
// settings step repeating the plan's, is given once.
func (s *Session) warn(lines string) {
	for _, line := range strings.Split(lines, "\n") {
		if line == "" {
			continue
		}
		dup := false
		for _, w := range s.warnings {
			if w == line {
				dup = true
				break
			}
		}
		if !dup {
			s.warnings = append(s.warnings, line)
		}
	}
}

// printWarnings prints each warning, after a blank line, to stderr.
func (s *Session) printWarnings() {
	if len(s.warnings) == 0 {
		return
	}
	fmt.Fprintln(s.Err)
	for _, w := range s.warnings {
		fmt.Fprintf(s.Err, "Warning: %s\n", w)
	}
}

// printOutcome prints how a command ended with the warnings' count, as its
// last line.
func (s *Session) printOutcome(outcome string) {
	switch n := len(s.warnings); n {
	case 0:
		s.printf("%s.\n", outcome)
	case 1:
		s.printf("%s, with 1 warning.\n", outcome)
	default:
		s.printf("%s, with %d warnings.\n", outcome, n)
	}
}

// heading prints a step's or a section's name as a heading.
func (s *Session) heading(name string) {
	s.printf("\n==> %s\n", name)
}

// printError prints a message to stderr, naming the command.
func (s *Session) printError(msg string) {
	name := "macelium"
	if s.Sub != "" {
		name += " " + s.Sub
	}
	fmt.Fprintf(s.Err, "%s: %s\n", name, msg)
}

// printStopped prints why the command stopped, after the warnings, as its
// last line.
func (s *Session) printStopped(why string) {
	s.printWarnings()
	fmt.Fprint(s.Err, "\n")
	s.printError("stopped: " + why)
}

// requireTerminal fails, having said why, unless stdin and stdout are a
// terminal.
func (s *Session) requireTerminal() bool {
	if term.IsTerminal(os.Stdin) && term.IsTerminal(os.Stdout) {
		return true
	}
	s.printError("needs a terminal for its prompts")
	return false
}

// outFile returns the file the session writes to, when it writes to one,
// for what draws on a terminal.
func (s *Session) outFile() *os.File {
	if f, ok := s.Out.(*os.File); ok {
		return f
	}
	return nil
}

func (s *Session) withSpinner(label string, fn func()) {
	if f := s.outFile(); f != nil {
		term.WithSpinner(f, label, fn)
		return
	}
	fn()
}

// detailLine returns a detail on one line, for the log: its first line,
// then its last when it has more.
func detailLine(detail string) string {
	lines := strings.Split(detail, "\n")
	first, last := lines[0], lines[len(lines)-1]
	if first == last {
		return first
	}
	return first + " " + last
}

// countLines counts the lines of a list, a line an item.
func countLines(s string) int {
	if s == "" {
		return 0
	}
	return strings.Count(s, "\n") + 1
}

// indent indents each line of s two spaces.
func indent(s string) string {
	lines := strings.Split(s, "\n")
	for i := range lines {
		lines[i] = "  " + lines[i]
	}
	return strings.Join(lines, "\n")
}

func timestamp() string {
	return time.Now().Format("2006-01-02T15:04:05-0700")
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// emptyDir reports whether path is a directory holding nothing.
func emptyDir(path string) bool {
	entries, err := os.ReadDir(path)
	return err == nil && len(entries) == 0
}

// quotedString returns s double-quoted, its backslashes and double quotes
// escaped: a JSON string, or a TOML basic string.
func quotedString(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"`
}

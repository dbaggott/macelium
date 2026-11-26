package app

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/dbaggott/macelium/internal/run"
	"github.com/dbaggott/macelium/internal/term"
)

// The output lines of a logged step the terminal shows: Homebrew's
// progress.
var shownLine = regexp.MustCompile(`^(Tapping|Installing|Upgrading) |has failed!$`)

// step is a logged step's command: a program and its arguments, or a
// function run in a copy of the session writing to the step's output, with
// the name its log gives it.
type step struct {
	argv  []string
	fn    func(*Session) bool
	label string
}

func command(argv ...string) step { return step{argv: argv} }

func (st step) String() string {
	if st.fn != nil {
		return st.label
	}
	return strings.Join(st.argv, " ")
}

func (s *Session) recordStep(name, result string) {
	s.stepResults = append(s.stepResults, stepResult{name, result})
}

// useStepLog takes the log for the logged steps that follow.
func (s *Session) useStepLog(log string) {
	s.stepLog = log
	_ = os.MkdirAll(filepath.Dir(log), 0o755)
}

// runTerminalStep runs a step's command on the terminal, which its prompts
// need, and records the step.
func (s *Session) runTerminalStep(name string, argv ...string) bool {
	s.heading(name)
	if s.interactive(argv[0], argv[1:]...) == 0 {
		s.recordStep(name, "ok")
		return true
	}
	s.recordStep(name, "failed")
	return false
}

// runLoggedStep runs a step with its output in the log, showing only
// Homebrew's progress lines and the step's status (term.StepView), records
// the step, and returns its exit status.
func (s *Session) runLoggedStep(name string, st step) int {
	s.heading(fmt.Sprintf("%s (output in %s)", name, s.stepLog))
	log, err := os.OpenFile(s.stepLog, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log = nil
	}
	if log != nil {
		defer log.Close()
		fmt.Fprintf(log, "\n==> %s %s\n", timestamp(), st)
	}
	onTTY := false
	if f := s.outFile(); f != nil && term.IsTerminal(f) {
		onTTY = true
	}
	cache := ""
	if len(st.argv) > 0 && st.argv[0] == "brew" {
		cache, _ = run.Output("brew", "--cache")
	}

	r, w, err := os.Pipe()
	if err != nil {
		s.recordStep(name, "failed")
		s.printf("Failed: %v\n", err)
		return 1
	}
	status := make(chan int, 1)
	if st.fn != nil {
		child := s.child(w)
		go func() {
			ok := st.fn(child)
			w.Close()
			if ok {
				status <- 0
			} else {
				status <- 1
			}
		}()
	} else {
		cmd := exec.Command(st.argv[0], st.argv[1:]...)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, w, w
		err := cmd.Start()
		w.Close()
		if err != nil {
			code := 1
			if errors.Is(err, exec.ErrNotFound) {
				code = 127
			}
			fmt.Fprintf(io.MultiWriter(logOrDiscard(log), s.Out), "%s: %v\n", st.argv[0], err)
			r.Close()
			s.recordStep(name, "failed")
			s.printf("Failed, exit status %d:\n", code)
			return code
		}
		go func() { status <- run.Status(cmd.Wait()) }()
	}

	var output bytes.Buffer
	lines := make(chan string)
	go func() {
		defer close(lines)
		reader := bufio.NewReader(r)
		for {
			line, err := reader.ReadString('\n')
			if line != "" {
				output.WriteString(line)
				if log != nil {
					_, _ = log.WriteString(line)
				}
				text := strings.TrimSuffix(line, "\n")
				if shownLine.MatchString(text) {
					lines <- text
				}
			}
			if err != nil {
				return
			}
		}
	}()
	view := &term.StepView{
		Name: name, OnTTY: onTTY, Downloads: term.NewDownloads(cache), Tick: s.tick,
		Out: s.Out, Root: os.Getpid(), ProcessTree: term.ProcessTree,
	}
	view.Run(lines)
	r.Close()
	code := <-status
	if code == 0 {
		s.recordStep(name, "ok")
		return 0
	}
	s.recordStep(name, "failed")
	s.printf("Failed, exit status %d:\n", code)
	// brew's errors start "Error:"; without any, the end of the output says
	// why.
	all := strings.Split(strings.TrimSuffix(output.String(), "\n"), "\n")
	var errorLines []string
	for _, l := range all {
		if strings.HasPrefix(l, "Error: ") {
			errorLines = append(errorLines, l)
		}
	}
	if len(errorLines) == 0 {
		errorLines = all[max(0, len(all)-5):]
		if len(errorLines) == 1 && errorLines[0] == "" {
			errorLines = nil
		}
	}
	for _, l := range errorLines {
		s.println(l)
	}
	if len(st.argv) > 0 && st.argv[0] == "brew" {
		for _, hint := range brewFailureHints(all, terminalApp()) {
			s.println("")
			s.println(hint)
		}
	}
	return code
}

// A cask upgrade copies the installed app back into the Caskroom, then
// deletes it from /Applications; when the delete fails the copy stays, and
// each later upgrade refuses to overwrite it.
var leftoverAppCopy = regexp.MustCompile(`It seems there is already an App at '([^']*/Caskroom/[^']*)'`)

var appChangeRefused = regexp.MustCompile(`/Applications/.*(Operation not permitted|Permission denied)|(Operation not permitted|Permission denied).*/Applications/`)

// brewFailureHints returns what to do about each failure in a brew step's
// output it recognises. Unless the terminal has App Management, macOS
// refuses any process, root included, a change to another developer's app.
func brewFailureHints(output []string, terminal string) []string {
	refused, leftover := false, ""
	for _, l := range output {
		if m := leftoverAppCopy.FindStringSubmatch(l); m != nil && leftover == "" {
			leftover = m[1]
		}
		refused = refused || appChangeRefused.MatchString(l)
	}
	var hints []string
	if refused {
		hints = append(hints, "macOS refused a change to an app in /Applications: give "+terminal+
			" App Management (System Settings → Privacy & Security → App Management), quit and reopen it, then try again.")
	}
	if leftover != "" {
		hints = append(hints, "An earlier upgrade stopped partway and left a copy of the app at "+leftover+
			": remove it (`rm -rf "+shellQuote(leftover)+"`), then try again. If the upgrade fails again, its new error says why.")
	}
	return hints
}

func logOrDiscard(f *os.File) io.Writer {
	if f == nil {
		return io.Discard
	}
	return f
}

// runInstallSteps runs brew bundle over each Brewfile, then mise install,
// each a logged step of its own. A step that fails stops those after it
// when stop is set. It returns the name of the step that stopped them, or
// of the last that failed.
func (s *Session) runInstallSteps(stop bool) string {
	type install struct {
		name string
		st   step
	}
	var steps []install
	if exists(s.stateBrewfile) {
		steps = append(steps, install{"brew bundle, the state repo's Brewfile", command("brew", "bundle", "--file="+s.stateBrewfile)})
		if isFile(s.localBrewfile()) {
			steps = append(steps, install{"brew bundle, this machine's Brewfile.local", command("brew", "bundle", "--file="+s.localBrewfile())})
		}
	}
	steps = append(steps, install{"mise install", command("mise", "-C", s.home, "install")})
	failed := ""
	for _, i := range steps {
		if s.runLoggedStep(i.name, i.st) == 0 {
			continue
		}
		failed = i.name
		if stop {
			return failed
		}
	}
	return failed
}

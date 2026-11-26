//go:build harness

package app

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/dbaggott/macelium/internal/term"
)

// The test build's stand-ins for what setup runs, with
// MACELIUM_HARNESS_STUB_SETUP set: each records its call, and whether stdin
// is a terminal, in $STUB_LOG; bootstrap exits $STUB_MACELIUM_STATUS, and
// the capture writes a repo with macelium.conf and nothing committed, as the
// real one does.
func init() {
	if os.Getenv("MACELIUM_HARNESS_STUB_SETUP") == "" {
		return
	}
	bootstrapCheckout = func(s *Session, checkout string) int {
		stubLog("macelium bootstrap " + checkout)
		var status int
		// Unset, it is 0.
		_, _ = fmt.Sscan(os.Getenv("STUB_MACELIUM_STATUS"), &status)
		return status
	}
	captureMac = func(s *Session, public bool, path string) (string, string, bool) {
		flag := ""
		if public {
			flag = "--public "
		}
		stubLog("macelium init " + flag + path)
		ok := os.MkdirAll(path, 0o755) == nil &&
			os.WriteFile(filepath.Join(path, "macelium.conf"), []byte("contract 1\n"), 0o644) == nil &&
			exec.Command("git", "init", "-q", "-b", "main", path).Run() == nil
		return "", "", ok
	}
}

func stubLog(line string) {
	tty := "no"
	if term.IsTerminal(os.Stdin) {
		tty = "yes"
	}
	f, err := os.OpenFile(os.Getenv("STUB_LOG"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s tty=%s\n", line, tty)
}

// HarnessLoggedStep runs argv as a logged step named name, with its log at
// log and a tick of tick, and returns its exit status and how it recorded
// the step, as "<name>\t<result>".
func HarnessLoggedStep(name, log string, tick time.Duration, argv []string) (int, string) {
	s := NewSession("", "")
	s.tick = tick
	s.useStepLog(log)
	status := s.runLoggedStep(name, command(argv...))
	var results []string
	for _, r := range s.stepResults {
		results = append(results, r.name+"\t"+r.result)
	}
	return status, strings.Join(results, "\n")
}

// Package run runs the commands macelium drives.
package run

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"syscall"
)

// Capture runs a command with stdin, or nothing when stdin is nil, and
// returns its output and errors together, without trailing newlines, and its
// exit status.
func Capture(stdin io.Reader, name string, args ...string) (string, int) {
	cmd := exec.Command(name, args...)
	cmd.Stdin = stdin
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	if errors.Is(err, exec.ErrNotFound) {
		return name + ": command not found", 127
	}
	return strings.TrimRight(out.String(), "\n"), Status(err)
}

// Output runs a command with nothing on stdin, and returns its output
// without trailing newlines, its errors left out, and its exit status.
func Output(name string, args ...string) (string, int) {
	cmd := exec.Command(name, args...)
	out, err := cmd.Output()
	if errors.Is(err, exec.ErrNotFound) {
		return "", 127
	}
	return strings.TrimRight(string(out), "\n"), Status(err)
}

// Status returns the exit status a command's error stands for: 0 for none,
// 128 plus the signal for one killed by a signal, and 127 for one that could
// not start.
func Status(err error) int {
	if err == nil {
		return 0
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if ws, ok := exit.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return exit.ExitCode()
	}
	return 127
}

// Failure describes a command that failed: its name, its exit status, then
// whatever it printed.
func Failure(command, out string, status int) string {
	s := fmt.Sprintf("`%s` exited %d", command, status)
	if out != "" {
		s += ":\n" + out
	}
	return s
}

// Lookable reports whether the command is on PATH.
func Lookable(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

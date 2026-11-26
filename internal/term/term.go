// Package term is macelium's terminal: whether a stream is one, its size,
// the prompts read from /dev/tty, and the spinner.
package term

import (
	"fmt"
	"io"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	xterm "golang.org/x/term"
)

// IsTerminal reports whether f is a terminal.
func IsTerminal(f *os.File) bool {
	return xterm.IsTerminal(int(f.Fd()))
}

// Size returns the terminal's rows and columns, each 24 and 80 when there
// is no terminal to ask.
func Size() (rows, cols int) {
	rows, cols = 24, 80
	tty, err := os.Open("/dev/tty")
	if err != nil {
		return
	}
	defer tty.Close()
	c, r, err := xterm.GetSize(int(tty.Fd()))
	if err != nil {
		return
	}
	if r > 0 {
		rows = r
	}
	if c > 0 {
		cols = c
	}
	return
}

// Usable reports whether /dev/tty can be opened, which it cannot for a
// process with no controlling terminal.
func Usable() bool {
	tty, err := os.Open("/dev/tty")
	if err != nil {
		return false
	}
	tty.Close()
	return true
}

// Prompt writes the question to /dev/tty, then reads a reply from it.
func Prompt(question string) (string, bool) {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return "", false
	}
	defer tty.Close()
	fmt.Fprint(tty, question)
	return ReadLine(tty)
}

// WriteTTY writes s to /dev/tty, ignoring a terminal there is none of.
func WriteTTY(s string) {
	tty, err := os.OpenFile("/dev/tty", os.O_WRONLY, 0)
	if err != nil {
		return
	}
	defer tty.Close()
	fmt.Fprint(tty, s)
}

// ReadLine reads one line a byte at a time, as the shell's read does, so it
// takes nothing past the line's end from a terminal that a command run
// after it reads. It returns the line with its surrounding blanks trimmed,
// and false at end-of-file, with whatever was typed before it.
func ReadLine(r io.Reader) (string, bool) {
	var line []byte
	b := make([]byte, 1)
	for {
		n, err := r.Read(b)
		if n == 1 {
			if b[0] == '\n' {
				return strings.Trim(string(line), " \t"), true
			}
			line = append(line, b[0])
			continue
		}
		if err != nil {
			return strings.Trim(string(line), " \t"), false
		}
	}
}

// Confirm asks a yes-or-no question on the terminal, an empty reply giving
// def. Only y or yes, in any case, is a yes. It returns 0 for yes, 1 for no,
// and 2 at end-of-file, which is also a no.
func Confirm(question string, def bool) int {
	hint := "[y/N]"
	if def {
		hint = "[Y/n]"
	}
	answer, ok := Prompt(question + " " + hint + " ")
	if !ok {
		return 2
	}
	switch strings.ToLower(answer) {
	case "":
		if def {
			return 0
		}
		return 1
	case "y", "yes":
		return 0
	}
	return 1
}

// Spinner is the frames that take the place of a status's leading "...",
// at the same width: two mushrooms side by side, each growing and falling
// onto the other's spot, where its spore sprouts the next, so it runs in a
// loop that pauses only while each stands.
var Spinner = []string{"n  ", "T  ", "T  ", "/  ", "_. ", "., ", " o ", " n ", " T ", " T ", " \\ ", "._ ", ",. ", "o  "}

// FrameTime is the time between the spinner's frames.
const FrameTime = 150 * time.Millisecond

// Cut returns s cut to at most n characters.
func Cut(s string, n int) string {
	if n <= 0 {
		return ""
	}
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n])
}

// Frame draws a spinner frame over the one at the start of the cursor's
// line, saving and restoring the cursor, so that a prompt written after the
// status stays whole with the cursor after it.
func Frame(w io.Writer, i int) {
	fmt.Fprintf(w, "\0337\r  %s\0338", Spinner[i%len(Spinner)])
}

// WithSpinner runs fn while, when out is a terminal, the spinner turns
// beside label on the cursor's line, cut to the terminal's width, then
// clears the line.
func WithSpinner(out *os.File, label string, fn func()) {
	if !IsTerminal(out) {
		fn()
		return
	}
	_, cols := Size()
	fmt.Fprintf(out, "\r%s", Cut("  "+Spinner[0]+" "+label, cols-1))
	stop := make(chan struct{})
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		t := time.NewTicker(FrameTime)
		defer t.Stop()
		for i := 1; ; i++ {
			select {
			case <-stop:
				return
			case <-t.C:
				Frame(out, i)
			}
		}
	}()
	fn()
	close(stop)
	<-stopped
	fmt.Fprint(out, "\r\033[K")
}

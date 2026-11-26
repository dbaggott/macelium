package term

import (
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// SudoPrompt is the prompt sudo shows for a password on macOS.
const SudoPrompt = "Password:"

const waitingHint = "  ... waiting for input above (likely a password): type it and press Return"

// Downloads follows the downloads in progress in Homebrew's cache across a
// logged step's ticks: each one's size, and the tick it last grew at.
type Downloads struct {
	cache string
	seen  map[string]download
}

type download struct {
	size float64
	grew int
}

// NewDownloads follows the downloads in cache, or none when cache is empty.
func NewDownloads(cache string) *Downloads {
	return &Downloads{cache: cache, seen: map[string]download{}}
}

var downloadName = regexp.MustCompile(`^[0-9a-f]+--`)

// Status returns a logged step's status at tick n, the first being 0, of
// tick seconds each: its name and time so far, then the download that grew
// most of those that grew in the last three ticks, or else the one that grew
// last, as stalled. A download that has not grown since the step began, such
// as one an interrupted run left for resuming, is not shown.
func (d *Downloads) Status(name string, seconds, n, tick int) string {
	type file struct {
		path string
		size float64
	}
	var files []file
	if d.cache != "" {
		paths, _ := filepath.Glob(filepath.Join(d.cache, "downloads", "*.incomplete"))
		sort.Strings(paths)
		for _, p := range paths {
			// A download that finishes between the glob and the stat is gone.
			if info, err := os.Stat(p); err == nil {
				files = append(files, file{p, float64(info.Size())})
			}
		}
	}
	next := map[string]download{}
	var shown, stalled string
	var shownGrowth, shownSize, stalledSize float64
	stalledLast, growing := 0, 0
	for _, f := range files {
		var growth float64
		var last int
		if was, ok := d.seen[f.path]; ok {
			growth = f.size - was.size
			last = was.grew
			if growth > 0 {
				last = n
			}
		} else if n > 0 {
			growth, last = f.size, n
		} else {
			growth, last = 0, -1
		}
		next[f.path] = download{f.size, last}
		if last < 0 {
			continue
		}
		if n-last < 3 {
			growing++
			if shown == "" || growth > shownGrowth {
				shown, shownGrowth, shownSize = f.path, growth, f.size
			}
		} else if stalled == "" || last > stalledLast {
			stalled, stalledLast, stalledSize = f.path, last, f.size
		}
	}
	d.seen = next
	status := fmt.Sprintf("  ... %s, %s", name, duration(seconds))
	if shown != "" {
		status += fmt.Sprintf(": downloading %s, %s, %s/s", downloadOf(shown), size(shownSize), size(shownGrowth/float64(tick)))
		if growing > 1 {
			status += fmt.Sprintf(" (+%d more)", growing-1)
		}
	} else if stalled != "" {
		status += fmt.Sprintf(": %s stalled at %s, no growth for %s", downloadOf(stalled), size(stalledSize), duration((n-stalledLast)*tick))
	}
	return status
}

// downloadOf returns the name of a download Homebrew keeps in progress as
// <sha256>--<name>.incomplete.
func downloadOf(path string) string {
	name := downloadName.ReplaceAllString(filepath.Base(path), "")
	return strings.TrimSuffix(name, ".incomplete")
}

func size(bytes float64) string {
	switch {
	case bytes < 1024:
		return fmt.Sprintf("%d B", int64(bytes))
	case bytes < 1048576:
		return fmt.Sprintf("%d KB", int64(math.Trunc(bytes/1024)))
	case bytes < 1073741824:
		return fmt.Sprintf("%d MB", int64(math.Trunc(bytes/1048576)))
	}
	return fmt.Sprintf("%.1f GB", bytes/1073741824)
}

func duration(s int) string {
	if s < 60 {
		return fmt.Sprintf("%d s", s)
	}
	return fmt.Sprintf("%d min", s/60)
}

// ProcessTree returns every process as `ps -A -o pid=,ppid=,comm=` lists
// them.
func ProcessTree() string {
	out, _ := exec.Command("ps", "-A", "-o", "pid=,ppid=,comm=").Output()
	return string(out)
}

// PromptingSudo takes a process list, as ProcessTree gives it, and a pid,
// and returns the pid of a sudo below that pid with no child process, which
// is a sudo waiting for a password: one running a command waits for it as
// its child. It returns "" when there is none.
func PromptingSudo(ps string, root int) string {
	parent := map[int]int{}
	children := map[int]int{}
	var sudos []int
	for _, line := range strings.Split(ps, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		ppid, err2 := strconv.Atoi(fields[1])
		if err1 != nil || err2 != nil {
			continue
		}
		parent[pid] = ppid
		children[ppid]++
		comm := strings.Join(fields[2:], " ")
		if filepath.Base(comm) == "sudo" {
			sudos = append(sudos, pid)
		}
	}
	for _, pid := range sudos {
		if children[pid] > 0 {
			continue
		}
		// The depth bounds a cycle that reused pids could make in the list.
		p, ok := parent[pid]
		for depth := 0; ok && depth < 100; depth++ {
			if p == root {
				return strconv.Itoa(pid)
			}
			p, ok = parent[p]
		}
	}
	return ""
}

// StepView draws a logged step's status while its command runs. On a
// terminal the status is one line redrawn in place, led by the spinner;
// elsewhere it is a line each minute. It is the only writer to Out while it
// runs.
//
// sudo writes its prompt with no newline, at the end of the status line, so
// while a sudo below this process asks, nothing clears a line: each write
// starts on a new one, and no status is drawn.
type StepView struct {
	Name      string
	OnTTY     bool
	Downloads *Downloads
	Tick      time.Duration
	Out       io.Writer
	// The process whose sudo children count as asking, and how the
	// processes are listed.
	Root        int
	ProcessTree func() string

	statusLine string
	columns    int
	n, frame   int
	frozen     bool
	drawn      bool
	start      time.Time
	minutes    int
	waiting    string
	previous   string
	hinted     string
}

// Run draws the step until lines, its filtered output, is closed, printing
// each line it gets.
func (v *StepView) Run(lines <-chan string) {
	v.columns = 80
	v.start = time.Now()
	tick := time.NewTicker(v.Tick)
	defer tick.Stop()
	var frames <-chan time.Time
	if v.OnTTY {
		t := time.NewTicker(FrameTime)
		defer t.Stop()
		frames = t.C
	}
	v.doTick()
	for {
		select {
		case <-tick.C:
			v.n++
			v.doTick()
		case <-frames:
			v.doFrame()
		case line, ok := <-lines:
			if !ok {
				v.clear()
				return
			}
			v.clear()
			fmt.Fprintln(v.Out, line)
			if v.OnTTY && v.waiting == "" {
				v.draw()
			}
		}
	}
}

func (v *StepView) sudo() string {
	return PromptingSudo(v.ProcessTree(), v.Root)
}

// draw prints the status at the cursor, the spinner's frame in place of its
// "...", cut short of the terminal's width by room for sudo's prompt, since
// \033[K clears only the cursor's row and the frames redraw its start.
func (v *StepView) draw() {
	fmt.Fprint(v.Out, Cut("  "+Spinner[v.frame%len(Spinner)]+v.statusLine[5:], v.columns-len(SudoPrompt)-1))
	v.drawn, v.frozen = true, false
}

// doFrame draws the spinner's next frame over the drawn status's. Once a
// sudo has asked, the frames stop until the status is drawn again, since the
// cursor may have left its row.
func (v *StepView) doFrame() {
	if !v.drawn || v.frozen {
		return
	}
	if v.sudo() != "" {
		v.frozen = true
		return
	}
	v.frame++
	Frame(v.Out, v.frame)
}

// doTick updates the status and draws it, unless a sudo is asking, which it
// points at once the same sudo has asked for a tick.
func (v *StepView) doTick() {
	seconds := int(time.Since(v.start).Seconds())
	tickSeconds := max(int(v.Tick/time.Second), 1)
	v.statusLine = v.Downloads.Status(v.Name, seconds, v.n, tickSeconds)
	v.waiting = v.sudo()
	switch {
	case v.waiting != "":
		// The status stays drawn: a sudo that goes without a Return reaching
		// the terminal, such as one answered by Touch ID, leaves it on the
		// line.
		if v.waiting == v.previous && v.waiting != v.hinted {
			if v.OnTTY {
				fmt.Fprint(v.Out, "\n")
			}
			fmt.Fprintln(v.Out, waitingHint)
			v.hinted = v.waiting
			v.drawn = false
		}
	case v.OnTTY:
		_, v.columns = Size()
		fmt.Fprint(v.Out, "\r\033[K")
		v.draw()
	case seconds/60 > v.minutes:
		v.minutes = seconds / 60
		fmt.Fprintln(v.Out, v.statusLine)
	}
	v.previous = v.waiting
}

// clear leaves the cursor, on a terminal, at the start of a line holding no
// status, clearing the status line unless a sudo may have written its
// prompt on the cursor's line.
func (v *StepView) clear() {
	if !v.OnTTY {
		return
	}
	if v.drawn || v.waiting != "" {
		v.waiting = v.sudo()
	}
	if v.waiting != "" {
		fmt.Fprint(v.Out, "\n")
	} else if v.drawn {
		fmt.Fprint(v.Out, "\r\033[K")
	}
	v.drawn = false
}

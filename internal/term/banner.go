package term

import (
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// The banner's mushrooms, each stage its rows, top first, of one odd width
// with the stem on the middle column. A space is transparent, '|' is stem,
// 'o' a spot, and anything else cap.
var bannerStages = [][]string{
	{","},
	{"o", "|"},
	{" .-. ", "(___)", " | | "},
	{"  .-~-.  ", "(_______)", "   | |   ", "   | |   "},
	{"    .-~~~~~-.    ", "  .'  o      '.  ", " /         o   \\ ", "(_______________)", "       | |       ", "       | |       "},
}

// The name the banner's mycelium spells as it spreads.
const bannerSignature = "dnbg"

const (
	bannerWidth  = 64
	bannerRows   = 12
	bannerGround = 6
)

type banner struct {
	w          io.Writer
	grid, kind [bannerRows][]byte
	drawn      bool
	styles     map[byte]string
	reset      string
}

// Banner plays the banner on the terminal: a spore drifts down onto a
// ground line, mycelium spreads from it below the line, spelling the
// signature into a thread, then mushrooms fruit above it, and macelium's
// name and version follow, and a blank line. It is 64 columns by 15 rows,
// in color unless NO_COLOR is set, and a smaller terminal gets none. Each
// frame redraws the last by moving up over it.
func Banner(w io.Writer, version string) {
	rows, cols := Size()
	if rows < bannerRows+3 || cols < bannerWidth {
		return
	}
	b := &banner{w: w, styles: map[byte]string{}}
	if os.Getenv("NO_COLOR") == "" {
		b.styles = map[byte]string{
			'g': "\033[38;5;94m", 'h': "\033[38;5;180m", 't': "\033[1;38;5;230m", 's': "\033[38;5;223m",
			'c': "\033[38;5;167m", 'd': "\033[1;38;5;231m", 'w': "\033[1;38;5;223m",
		}
		b.reset = "\033[0m"
	}
	for r := range bannerRows {
		b.grid[r] = []byte(strings.Repeat(" ", bannerWidth))
		b.kind[r] = []byte(strings.Repeat(" ", bannerWidth))
	}
	b.grid[bannerGround] = []byte(strings.Repeat("_", bannerWidth))
	b.kind[bannerGround] = []byte(strings.Repeat("g", bannerWidth))

	// The cursor is hidden while it plays, and shown again however it ends.
	fmt.Fprint(w, "\033[?25l")
	interrupted := make(chan os.Signal, 1)
	signal.Notify(interrupted, os.Interrupt, syscall.SIGTERM)
	done := make(chan struct{})
	go func() {
		select {
		case <-interrupted:
			fmt.Fprint(w, "\033[?25h\n")
			os.Exit(130)
		case <-done:
		}
	}()
	defer func() {
		signal.Stop(interrupted)
		close(done)
		fmt.Fprint(w, "\033[?25h")
	}()
	b.play()
	fmt.Fprintf(w, "\n%24s%s%s%s  %s%s%s\n\n", "", b.styles['w'], "m a c e l i u m", b.reset, b.styles['h'], version, b.reset)
}

func random(n int) int { return rand.IntN(n) }

func (b *banner) play() {
	ground := bannerGround
	// The spore drifts down near the middle, lands in the ground line, and
	// sinks just below it.
	c := bannerWidth/2 - 6 + random(13)
	for r := 0; r < ground; r++ {
		b.put(r, c, '*', 'h')
		b.frame(140 * time.Millisecond)
		b.put(r, c, ' ', ' ')
		if r != ground-1 {
			c += random(3) - 1
		}
	}
	b.put(ground, c, '*', 'h')
	b.frame(300 * time.Millisecond)
	b.put(ground, c, '_', 'g')
	b.put(ground+1, c, '*', 'h')
	b.frame(300 * time.Millisecond)

	// Two tips grow from the spore, one each way, and branch. Each tip holds
	// its heading up, level or down for a while, and a branch veers off its
	// parent's and grows slower than the two leaders, so threads trace paths
	// through the soil. The spread ends when both leaders reach the edges.
	tipR := []int{ground + 1, ground + 1}
	tipC := []int{c, c}
	tipD := []int{-1, 1}
	tipV := []int{random(2), random(2)}
	letters := bannerSignature
	letterAt := c + 3
	for step := 0; step < 3*bannerWidth; step++ {
		n := len(tipR)
		for i := 0; i < n; i++ {
			r, c, d := tipR[i], tipC[i], tipD[i]
			if d == 0 {
				continue
			}
			chance := 5
			if i < 2 {
				chance = 8
			}
			if random(10) >= chance {
				continue
			}
			if b.kind[r][c] == 't' {
				b.put(r, c, b.grid[r][c], 'h')
			}
			if random(6) == 0 {
				tipV[i] = random(3) - 1
			}
			dr := tipV[i]
			if random(2) == 0 {
				dr = 0
			}
			nr, nc := r+dr, c+d
			if dr != 0 && random(4) == 0 {
				nc = c
			}
			if nr <= ground || nr >= bannerRows {
				tipV[i] = -dr
				dr, nr, nc = 0, r, c+d
			}
			if nc < 0 || nc >= bannerWidth || (i > 1 && random(25) == 0) {
				tipD[i] = 0
				continue
			}
			var ch byte
			switch {
			case nc == c:
				ch = '|'
			case dr < 0:
				ch = '\''
			case dr > 0:
				ch = ','
			default:
				switch random(4) {
				case 0:
					ch = '~'
				case 1:
					ch = '.'
				default:
					ch = '-'
				}
			}
			// The right leader spells the signature into its thread as it
			// grows, a letter every few columns, and no thread draws over one.
			if i == 1 && dr == 0 && len(letters) > 0 && nc >= letterAt {
				ch = letters[0]
				letters = letters[1:]
				letterAt = nc + 2 + random(3)
			}
			if !strings.ContainsRune(bannerSignature, rune(b.grid[nr][nc])) {
				b.put(nr, nc, ch, 't')
			}
			tipR[i], tipC[i] = nr, nc
			if len(tipR) < 20 && random(6) == 0 {
				tipR = append(tipR, nr)
				tipC = append(tipC, nc)
				tipD = append(tipD, d)
				if tipV[i] == 0 {
					tipV = append(tipV, random(2)*2-1)
				} else {
					tipV = append(tipV, -tipV[i])
				}
			}
		}
		if tipD[0] == 0 && tipD[1] == 0 {
			break
		}
		b.frame(15 * time.Millisecond)
	}
	for r := ground + 1; r < bannerRows; r++ {
		for c := range b.kind[r] {
			if b.kind[r][c] == 't' {
				b.kind[r][c] = 'h'
			}
		}
	}

	// Each mushroom's column, the last stage it reaches, and the tick it
	// starts on, with a thread up to it from the mycelium.
	siteCol := []int{11, 28, 43, 53}
	siteMax := []int{4, 2, 3, 1}
	siteDelay := []int{0, 3, 1, 5}
	for _, c := range siteCol {
		for r := ground + 1; r < bannerRows; r++ {
			if b.kind[r][c] == 'h' {
				break
			}
			b.put(r, c, '|', 'h')
		}
	}
	b.frame(80 * time.Millisecond)
	for tick := 0; tick < 10; tick++ {
		for r := 0; r < ground; r++ {
			b.grid[r] = []byte(strings.Repeat(" ", bannerWidth))
			b.kind[r] = []byte(strings.Repeat(" ", bannerWidth))
		}
		for i, col := range siteCol {
			s := tick - siteDelay[i]
			if s < 0 {
				continue
			}
			s = min(s, siteMax[i])
			b.mushroom(col, bannerStages[s])
		}
		b.frame(110 * time.Millisecond)
	}
}

// put sets the cell at a row and column, when it is on the grid, to a
// character and its class.
func (b *banner) put(r, c int, ch, k byte) {
	if r < 0 || r >= bannerRows || c < 0 || c >= bannerWidth {
		return
	}
	b.grid[r][c] = ch
	b.kind[r][c] = k
}

// mushroom draws a stage standing on the ground line, its stem on col.
func (b *banner) mushroom(col int, stage []string) {
	top := bannerGround - len(stage)
	left := col - len(stage[0])/2
	for i, row := range stage {
		for j := 0; j < len(row); j++ {
			ch := row[j]
			var k byte
			switch ch {
			case ' ':
				continue
			case '|':
				k = 's'
			case 'o':
				k = 'd'
			default:
				k = 'c'
			}
			b.put(top+i, left+j, ch, k)
		}
	}
}

// frame draws the grid over the last frame, each class in its color, then
// waits.
func (b *banner) frame(wait time.Duration) {
	var out strings.Builder
	if b.drawn {
		fmt.Fprintf(&out, "\033[%dA", bannerRows)
	}
	for r := range bannerRows {
		out.WriteString("\r")
		var prev byte
		for c := range bannerWidth {
			k := b.kind[r][c]
			if k != prev {
				if s, ok := b.styles[k]; ok {
					out.WriteString(s)
				} else {
					out.WriteString(b.reset)
				}
				prev = k
			}
			out.WriteByte(b.grid[r][c])
		}
		out.WriteString(b.reset + "\033[K\n")
	}
	fmt.Fprint(b.w, out.String())
	b.drawn = true
	time.Sleep(wait)
}

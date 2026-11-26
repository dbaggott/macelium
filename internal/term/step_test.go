package term

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// downloads is a Homebrew cache with its downloads directory, and grows
// a download in it.
type downloads struct {
	t     *testing.T
	cache string
	d     *Downloads
}

func newDownloads(t *testing.T) *downloads {
	cache := t.TempDir()
	if err := os.MkdirAll(filepath.Join(cache, "downloads"), 0o755); err != nil {
		t.Fatal(err)
	}
	return &downloads{t, cache, NewDownloads(cache)}
}

func (d *downloads) grow(name string, bytes int) {
	f, err := os.OpenFile(filepath.Join(d.cache, "downloads", sha+"--"+name+".incomplete"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		d.t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.Write(make([]byte, bytes)); err != nil {
		d.t.Fatal(err)
	}
}

// at returns brew bundle's status at tick n, of five seconds each.
func (d *downloads) at(n int) string {
	return d.d.Status("brew bundle", n*5, n, 5)
}

func TestStatusShowsTheGrowingDownloadWithItsRate(t *testing.T) {
	d := newDownloads(t)
	d.grow("Name.dmg", 10240)
	d.grow("Stale.dmg", 4096)
	d.at(0)
	d.grow("Name.dmg", 2097152)
	if got, want := d.at(1), "  ... brew bundle, 5 s: downloading Name.dmg, 2 MB, 409 KB/s"; got != want {
		t.Errorf("status %q, want %q", got, want)
	}
}

func TestStatusShowsAStoppedDownloadAsStalled(t *testing.T) {
	d := newDownloads(t)
	d.at(0)
	d.grow("Name.dmg", 2097152)
	d.at(1)
	d.at(2)
	if got := d.at(3); !strings.Contains(got, "downloading Name.dmg") {
		t.Errorf("status before three ticks: %q", got)
	}
	if got, want := d.at(4), "  ... brew bundle, 20 s: Name.dmg stalled at 2 MB, no growth for 15 s"; got != want {
		t.Errorf("status %q, want %q", got, want)
	}
}

func TestStatusCountsTheOtherGrowingDownloads(t *testing.T) {
	d := newDownloads(t)
	d.at(0)
	d.grow("Big.dmg", 2097152)
	d.grow("Small.dmg", 1024)
	d.grow("Other.pkg", 1024)
	if got := d.at(1); !strings.HasSuffix(got, "downloading Big.dmg, 2 MB, 409 KB/s (+2 more)") {
		t.Errorf("status %q", got)
	}
}

func TestStatusWithoutDownloadsShowsTheStepAndTime(t *testing.T) {
	d := newDownloads(t)
	d.grow("Stale.dmg", 4096)
	d.at(0)
	if got, want := d.at(13), "  ... brew bundle, 1 min"; got != want {
		t.Errorf("status %q, want %q", got, want)
	}
}

func TestStatusWithNoCacheShowsTheStep(t *testing.T) {
	if got, want := NewDownloads("").Status("mise install", 3, 0, 5), "  ... mise install, 3 s"; got != want {
		t.Errorf("status %q, want %q", got, want)
	}
}

const ps = `    1     0 /sbin/launchd
  500     1 /bin/zsh
  600   500 /bin/bash
  601   600 /usr/bin/sudo
  602   600 /usr/bin/sudo
  603   602 /usr/sbin/installer
  700     1 /usr/bin/sudo`

func TestPromptingSudoFindsAChildlessSudoBelowTheRoot(t *testing.T) {
	if got := PromptingSudo(ps, 500); got != "601" {
		t.Errorf("got %q, want 601", got)
	}
}

func TestPromptingSudoIgnoresASudoWithAChildOrOutsideTheRoot(t *testing.T) {
	var lines []string
	for _, l := range strings.Split(ps, "\n") {
		if !strings.Contains(l, " 601 ") {
			lines = append(lines, l)
		}
	}
	if got := PromptingSudo(strings.Join(lines, "\n"), 500); got != "" {
		t.Errorf("found %s, a sudo running a command, or one outside the tree", got)
	}
}

func TestEverySpinnerFrameIsAsWideAsTheStatusItReplaces(t *testing.T) {
	for _, f := range Spinner {
		if len(f) != 3 {
			t.Errorf("frame [%s] is %d columns wide", f, len(f))
		}
	}
}

func TestReadLineStopsAtTheLineAndTrimsBlanks(t *testing.T) {
	r := strings.NewReader("  yes \nnext\n")
	if got, ok := ReadLine(r); got != "yes" || !ok {
		t.Errorf("got %q %v", got, ok)
	}
	if got, ok := ReadLine(r); got != "next" || !ok {
		t.Errorf("the second line: got %q %v", got, ok)
	}
}

func TestReadLineAtEndOfFileGivesWhatWasTyped(t *testing.T) {
	if got, ok := ReadLine(strings.NewReader("part")); got != "part" || ok {
		t.Errorf("got %q %v, want part false", got, ok)
	}
	if got, ok := ReadLine(strings.NewReader("")); got != "" || ok {
		t.Errorf("got %q %v, want empty false", got, ok)
	}
}

func TestCutCountsCharactersNotBytes(t *testing.T) {
	if got := Cut("→ abc", 3); got != "→ a" {
		t.Errorf("got %q", got)
	}
	if got := Cut("abc", 0); got != "" {
		t.Errorf("got %q", got)
	}
}

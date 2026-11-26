package declare

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func read(t *testing.T, content string) (*File, []string, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "list.sh")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	f, errs, err := Read(path, []string{"setting", "flag"})
	if err != nil {
		t.Fatal(err)
	}
	return f, errs, path
}

func TestReadTakesWordsAsTheShellSplitsThem(t *testing.T) {
	t.Setenv("HOME", "/Users/me")
	f, errs, _ := read(t, `# a comment
setting a 'b c' "d e" f\ g # trailing comment

setting ~/x ~ h~ \
  continued
flag
`)
	if len(errs) > 0 || len(f.Stray) > 0 {
		t.Fatalf("errs %v, stray %v", errs, f.Stray)
	}
	want := []Declaration{
		{"setting", []string{"a", "b c", "d e", "f g"}, 2},
		{"setting", []string{"/Users/me/x", "/Users/me", "h~", "continued"}, 4},
		{"flag", nil, 6},
	}
	if !reflect.DeepEqual(f.Declarations, want) {
		t.Errorf("got %#v", f.Declarations)
	}
}

func TestReadListsEachLineThatIsNoDeclaration(t *testing.T) {
	f, _, path := read(t, "setting a\ndefaults write x y\n  setting indented\nsetting b \\\n  continued\n")
	want := []string{path + ":2: defaults write x y", path + ":3:   setting indented"}
	if !reflect.DeepEqual(f.Stray, want) {
		t.Errorf("got %q, want %q", f.Stray, want)
	}
}

func TestReadListsAnotherCommandOnADeclarationsLine(t *testing.T) {
	for _, line := range []string{"setting a b; rm -rf x", "setting a | cat", "setting a && rm x"} {
		f, _, path := read(t, line+"\n")
		if want := []string{path + ":1: " + line}; !reflect.DeepEqual(f.Stray, want) {
			t.Errorf("got %q, want %q", f.Stray, want)
		}
	}
}

func TestReadRefusesWhatWouldRunOrReadSomething(t *testing.T) {
	for _, line := range []string{
		`setting $HOME`, `setting "$HOME"`, `setting $(date)`, "setting `date`",
		`setting a > out`, `setting $'x'`, `setting $((1+1))`,
	} {
		f, errs, path := read(t, line+"\n")
		if len(f.Declarations) != 0 || len(errs) != 1 || !strings.HasPrefix(errs[0], path+":1: setting: takes only plain words") {
			t.Errorf("%s: declarations %v, errs %q", line, f.Declarations, errs)
		}
	}
}

func TestReadFailsOnWhatIsNotShellWords(t *testing.T) {
	path := filepath.Join(t.TempDir(), "list.sh")
	if err := os.WriteFile(path, []byte("setting 'unclosed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := Read(path, []string{"setting"}); err == nil {
		t.Error("read an unclosed quote")
	}
}

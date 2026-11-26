package app

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbaggott/macelium/internal/settings"
)

// touchIDSession is a session whose settings list declares touch_id_sudo,
// on a Mac with a finger enrolled, a sandbox PAM file and a sudo that runs
// its command, recording each question it asks.
func touchIDSession(t *testing.T, declared bool) (*Session, *[]string) {
	t.Helper()
	bin := t.TempDir()
	for name, script := range map[string]string{
		"bioutil": "#!/bin/sh\necho 'User: 1 biometric template'\n",
		"sudo":    "#!/bin/sh\nexec \"$@\"\n",
	} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	var asked []string
	var out bytes.Buffer
	s := NewSession("settings", "test")
	s.Out, s.Err = &out, &out
	s.sudoLocal = filepath.Join(t.TempDir(), "sudo_local")
	s.hasTerminal = func() bool { return true }
	s.confirm = func(q string, _ bool) int { asked = append(asked, q); return 1 }
	s.list = &settings.List{TouchID: declared}
	return s, &asked
}

func TestTouchIDIsOfferedOnlyWhenDeclared(t *testing.T) {
	s, asked := touchIDSession(t, false)
	s.enableTouchIDSudo()
	if len(*asked) != 0 {
		t.Errorf("offered with no touch_id_sudo: %q", *asked)
	}
	s, asked = touchIDSession(t, true)
	s.enableTouchIDSudo()
	if len(*asked) != 1 || !strings.HasPrefix((*asked)[0], "Enable Touch ID for sudo in "+s.sudoLocal) {
		t.Errorf("asked %q", *asked)
	}
}

// Bootstrap offers before its logged settings step, which runs in a copy of
// the session.
func TestTouchIDDeclinedOnceIsNotOfferedAgain(t *testing.T) {
	s, asked := touchIDSession(t, true)
	s.enableTouchIDSudo()
	s.child(&bytes.Buffer{}).enableTouchIDSudo()
	if len(*asked) != 1 {
		t.Errorf("asked %d times, want once", len(*asked))
	}
	if len(s.warnings) != 1 || !strings.Contains(s.warnings[0], "Touch ID for sudo was skipped") {
		t.Errorf("warnings %q", s.warnings)
	}
}

func TestTouchIDAcceptedAppendsTheLineOnItsOwn(t *testing.T) {
	s, _ := touchIDSession(t, true)
	if err := os.WriteFile(s.sudoLocal, []byte("# no final newline"), 0o644); err != nil {
		t.Fatal(err)
	}
	s.confirm = func(string, bool) int { return 0 }
	s.enableTouchIDSudo()
	got, _ := os.ReadFile(s.sudoLocal)
	if want := "# no final newline\n" + pamTIDLine + "\n"; string(got) != want {
		t.Errorf("sudo_local %q, want %q", got, want)
	}
	asked := false
	s.confirm = func(string, bool) int { asked = true; return 0 }
	s.enableTouchIDSudo()
	if asked {
		t.Error("offered again once sudo takes Touch ID")
	}
}

func TestShellQuoteIsBashsPrintfQ(t *testing.T) {
	for _, s := range []string{
		"", "plain", "two words", "`git fetch` exited 128: fatal: it's gone", "a=b,c:d", "~home", "#hash", "x~y#z",
		"tab\there", "line\nbreak", `back\slash "quoted" $var *glob? [x] {y} (z) <a> |&; !^`, "ünïcode",
		"Homebrew → upgrades — it's\\ \x1b\a\v\x7f",
	} {
		cmd := exec.Command("/bin/bash", "-c", `printf %q "$1"`, "_", s)
		cmd.Env = append(os.Environ(), "LC_ALL=C")
		want, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		if got := shellQuote(s); got != string(want) {
			t.Errorf("shellQuote(%q) = %s, bash gives %s", s, got, want)
		}
	}
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com"}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// The hash a machine keeps must be the one the shell version of macelium
// recorded, or every machine reruns its hooks on upgrading.
func TestAppsHooksHashIsTheShellVersions(t *testing.T) {
	repo := t.TempDir()
	repo, _ = filepath.EvalSymlinks(repo)
	files := map[string]string{
		"apps/one/after-apply": "echo one\n",
		"apps/one/watches":     "config/one\n  spaced/path  \n",
		"apps/two/after-apply": "echo two\n",
		"config/one/a":         "first\n",
		"config/one/b c":       "second\n",
		"spaced/path":          "x",
		"unwatched":            "y",
	}
	for path, content := range files {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(repo, path)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(repo, path), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	git(t, repo, "init", "-q")
	git(t, repo, "add", "apps", "config/one/a")
	git(t, repo, "commit", "-q", "-m", "state")
	s := NewSession("plan", "test")
	s.repo, s.stateApps = repo, repo+"/apps"
	got, ok := s.appsHooksHash()
	if !ok {
		t.Fatal(got)
	}
	// What the shell version ran, on the same files.
	listed, err := exec.Command("git", "-C", repo, "-c", "core.quotePath=false", "ls-files", "--cached", "--others", "--exclude-standard", "--",
		"apps/*/after-apply", "apps/*/watches", "config/one", "spaced/path").Output()
	if err != nil {
		t.Fatal(err)
	}
	// The shell version hashed each listed path, a line each.
	paths := strings.Split(strings.TrimRight(string(listed), "\n"), "\n")
	script := `cd "$1" && shift && shasum -a 256 -- "$@" | shasum -a 256 | cut -d ' ' -f 1`
	want, err := exec.Command("/bin/bash", append([]string{"-c", script, "_", repo}, paths...)...).Output()
	if err != nil {
		t.Fatal(err)
	}
	if got != strings.TrimSpace(string(want)) {
		t.Errorf("hash %s, the shell version's %s", got, want)
	}
}

func TestParseStateRepoTakesOwnerRepoOrAGitURL(t *testing.T) {
	for _, c := range []struct {
		arg                     string
		ok, github              bool
		host, repoPath, url, nm string
	}{
		{"me/state", true, true, "github.com", "me/state", "https://github.com/me/state", "me/state"},
		{"me/state.git", true, true, "github.com", "me/state", "https://github.com/me/state", "me/state"},
		{"git@github.com:Me/State.git", true, true, "github.com", "Me/State", "git@github.com:Me/State.git", "Me/State"},
		{"https://git.example.org/me/state.git", true, false, "git.example.org", "me/state", "https://git.example.org/me/state.git", "https://git.example.org/me/state.git"},
		{"ssh://git@git.example.org:2222/me/state", true, false, "git.example.org", "me/state", "ssh://git@git.example.org:2222/me/state", "ssh://git@git.example.org:2222/me/state"},
		{"state", false, false, "", "", "", ""},
		{"https://github.com/me/state/extra", false, true, "", "", "", ""},
		{"ftp://git.example.org/me/state", false, false, "", "", "", ""},
	} {
		r, ok := parseStateRepo(c.arg)
		if ok != c.ok {
			t.Errorf("%s: ok %v", c.arg, ok)
			continue
		}
		if ok && (r.github != c.github || r.host != c.host || r.repoPath != c.repoPath || r.url != c.url || r.name != c.nm) {
			t.Errorf("%s: got %+v", c.arg, r)
		}
	}
	r, _ := parseStateRepo("me/state")
	if !r.names("git@github.com:ME/STATE.git") || r.names("https://github.com/me/other") {
		t.Error("names compares GitHub's paths in any case, and only them")
	}
}

func TestUnlistedEntriesTakesOnlyWhatCleanupWouldRemove(t *testing.T) {
	out := "Would uninstall formulae:\nhello\nme/tap/tool\nWould uninstall casks:\nfirefox\nWould untap:\nme/tap\nWould uninstall vscode extensions:\nx.y\nWould `brew cleanup`:\n/cache/file\nRun `brew bundle cleanup --force` to make these changes."
	want := "formula hello\nformula me/tap/tool\ncask firefox\ntap me/tap\nvscode extensions x.y"
	if got := unlistedEntries(out); got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestBrewFailureHintsNameAppManagementAndTheLeftoverCopy(t *testing.T) {
	cases := []struct {
		name   string
		output []string
		want   []string
	}{
		{"an unrelated failure", []string{"Upgrading wget", "Error: wget: Download failed"}, nil},
		{"a refused delete", []string{
			"chown: /Applications/Shottr.app/Contents: Operation not permitted",
			"Error: shottr: Permission denied @ apply2files - /Applications/Shottr.app/Contents/CodeResources",
		}, []string{"App Management"}},
		{"a leftover copy", []string{
			"Error: shottr: It seems there is already an App at '/opt/homebrew/Caskroom/shottr/1.10.0/Shottr.app'.",
		}, []string{"mv /opt/homebrew/Caskroom/shottr/1.10.0/Shottr.app ~/.Trash/"}},
		{"two leftover copies, one twice", []string{
			"Error: shottr: It seems there is already an App at '/opt/homebrew/Caskroom/shottr/1.10.0/Shottr.app'.",
			"Error: tom: It seems there is already an App at '/opt/homebrew/Caskroom/tom/1.0/Tom's App.app'.",
			"Error: shottr: It seems there is already an App at '/opt/homebrew/Caskroom/shottr/1.10.0/Shottr.app'.",
		}, []string{"Shottr.app ~/.Trash/", `Tom\'s\ App.app ~/.Trash/`}},
		{"a permission failure outside /Applications", []string{
			"Error: Permission denied @ rb_sysopen - /opt/homebrew/var/x",
			"xattr: /System/Applications/Mail.app: Operation not permitted",
			"chown: /Users/me/Applications/x.app: Operation not permitted",
		}, nil},
	}
	for _, c := range cases {
		got := brewFailureHints(c.output, func() string { return "Ghostty" })
		if len(got) != len(c.want) {
			t.Errorf("%s: hints %q, want %d", c.name, got, len(c.want))
			continue
		}
		for i, w := range c.want {
			if !strings.Contains(got[i], w) {
				t.Errorf("%s: hint %q lacks %q", c.name, got[i], w)
			}
		}
	}
}

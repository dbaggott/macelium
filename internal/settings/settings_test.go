package settings

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const export = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>on</key><true/>
<key>count</key><integer>-3</integer>
<key>ratio</key><real>1.5</real>
<key>name</key><string>hello</string>
<key>colors</key><array><string>red</string><string>green</string></array>
<key>mixed</key><array><string>a</string><integer>1</integer></array>
<key>nested</key><dict><key>k</key><integer>1</integer><key>s</key><string>a/b</string></dict>
<key>when</key><date>2020-01-01T00:00:00Z</date>
<key>a.b</key><string>dotted</string>
<key>AppleSymbolicHotKeys</key><dict>
  <key>64</key><dict><key>enabled</key><false/></dict>
  <key>65</key><dict><key>enabled</key><true/></dict>
</dict>
</dict></plist>`

func domain(t *testing.T) Domain {
	t.Helper()
	d, err := ParseDomain([]byte(export))
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func TestCompareGivesTheCurrentValueAsThePlanShowsIt(t *testing.T) {
	d := domain(t)
	for _, c := range []struct {
		setting Setting
		current string
		same    bool
	}{
		{Setting{Key: "on", Type: "bool", Values: []string{"true"}}, "true", true},
		{Setting{Key: "on", Type: "bool", Values: []string{"false"}}, "true", false},
		{Setting{Key: "count", Type: "int", Values: []string{"-3"}}, "-3", true},
		{Setting{Key: "ratio", Type: "float", Values: []string{"1.50"}}, "1.500000", true},
		{Setting{Key: "ratio", Type: "float", Values: []string{"1.25"}}, "1.500000", false},
		{Setting{Key: "name", Type: "string", Values: []string{"hello"}}, "hello", true},
		{Setting{Key: "a.b", Type: "string", Values: []string{"dotted"}}, "dotted", true},
		{Setting{Key: "colors", Type: "array", Values: []string{"red", "green"}}, `["red","green"]`, true},
		{Setting{Key: "colors", Type: "array", Values: []string{"green", "red"}}, `["red","green"]`, false},
		{Setting{Key: "colors", Type: "unordered-array", Values: []string{"green", "red"}}, `["red","green"]`, true},
		{Setting{Key: "mixed", Type: "array", Values: []string{"a", "1"}}, `["a",1]`, false},
		{Setting{Key: "missing", Type: "string", Values: []string{"x"}}, "(not set)", false},
		{Setting{Key: "count", Type: "string", Values: []string{"-3"}}, "-3 (integer)", false},
		{Setting{Key: "nested", Type: "string", Values: []string{"x"}}, `{"k":1,"s":"a\/b"} (dictionary)`, false},
		{Setting{Key: "when", Type: "string", Values: []string{"x"}}, "2020-01-01T00:00:00Z (date)", false},
		{Setting{Key: "AppleSymbolicHotKeys", Type: "hotkey", Values: []string{"64", "0", "49", "1048576"}}, "false", true},
		{Setting{Key: "AppleSymbolicHotKeys", Type: "hotkey", Values: []string{"65", "0", "49", "1048576"}}, "true", false},
		{Setting{Key: "AppleSymbolicHotKeys", Type: "hotkey", Values: []string{"66", "0", "49", "1048576"}}, "(not set)", false},
	} {
		current, same := c.setting.Compare(d)
		if current != c.current || same != c.same {
			t.Errorf("%s %s %v: got %q %v, want %q %v", c.setting.Key, c.setting.Type, c.setting.Values, current, same, c.current, c.same)
		}
	}
}

func TestNameAndDeclaredAreAsThePlanShowsThem(t *testing.T) {
	hotkey := Setting{Domain: "com.apple.symbolichotkeys", Key: "AppleSymbolicHotKeys", Type: "hotkey", Values: []string{"64", "0", "49", "1048576"}}
	if got := hotkey.Name(); got != "com.apple.symbolichotkeys AppleSymbolicHotKeys.64.enabled" {
		t.Errorf("name %q", got)
	}
	array := Setting{CurrentHost: true, Domain: "d", Key: "k", Type: "array", Values: []string{`a"b`, `c\d`}}
	if got := array.Name(); got != "d k (current host)" {
		t.Errorf("name %q", got)
	}
	if got := array.Declared(); got != `["a\"b","c\\d"]` {
		t.Errorf("declared %q", got)
	}
}

func TestWriteArgsAreDefaultsWrites(t *testing.T) {
	for _, c := range []struct {
		setting Setting
		want    []string
	}{
		{Setting{Domain: "d", Key: "k", Type: "bool", Values: []string{"true"}}, []string{"write", "d", "k", "-bool", "true"}},
		{Setting{CurrentHost: true, Domain: "d", Key: "k", Type: "float", Values: []string{"0.5"}}, []string{"-currentHost", "write", "d", "k", "-float", "0.5"}},
		{Setting{Domain: "d", Key: "k", Type: "unordered-array", Values: []string{"<a&b>", `"`}}, []string{"write", "d", "k", "-array", "<string>&lt;a&amp;b&gt;</string>", `<string>"</string>`}},
	} {
		if got := c.setting.WriteArgs(); !reflect.DeepEqual(got, c.want) {
			t.Errorf("got %q, want %q", got, c.want)
		}
	}
	hotkey := Setting{Domain: "com.apple.symbolichotkeys", Key: "AppleSymbolicHotKeys", Type: "hotkey", Values: []string{"64", "0", "49", "1048576"}}.WriteArgs()
	if hotkey[3] != "-dict-add" || hotkey[4] != "64" || !strings.Contains(hotkey[5], "<integer>1048576</integer>") || !strings.Contains(hotkey[5], "<key>enabled</key><false/>") {
		t.Errorf("hotkey args %q", hotkey)
	}
}

func load(t *testing.T, content string) (*List, string, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "macos.sh")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	l, why := Load(path)
	return l, why, path
}

func TestLoadReadsEachDeclaration(t *testing.T) {
	l, why, _ := load(t, `setting -g AppleShowAllExtensions bool true
setting --current-host com.apple.x k unordered-array a b
disabled_hotkey 64 65535 49 1048576
restart_on_change com.apple.dock Dock
sandboxed_app com.apple.Safari Safari
touch_id_sudo
`)
	if l == nil {
		t.Fatal(why)
	}
	if l.Settings[0].Domain != "NSGlobalDomain" || !l.Settings[1].CurrentHost || l.Settings[2].Type != "hotkey" || !l.TouchID {
		t.Errorf("list %+v", l)
	}
	if got := l.RestartsFor("com.apple.dock"); !reflect.DeepEqual(got, []string{"Dock"}) {
		t.Errorf("restarts %q", got)
	}
	if got := l.RestartsFor("other"); !reflect.DeepEqual(got, FallbackRestarts) {
		t.Errorf("fallback %q", got)
	}
	if l.SandboxOf("com.apple.Safari") != 0 || l.SandboxOf("x") != -1 {
		t.Error("sandbox lookup")
	}
}

func TestLoadNamesEachDeclarationItGetsWrong(t *testing.T) {
	_, why, path := load(t, `setting d k int x
setting d k colour red
setting d k
disabled_hotkey 64 a 49 1
touch_id_sudo yes
`)
	want := "the settings list declares something wrongly:\n" +
		path + ":1: setting k: not one int value: x\n" +
		path + ":2: setting k: unknown type 'colour'\n" +
		path + ":3: setting takes a domain, a key, a type and a value\n" +
		path + ":4: disabled_hotkey 64: 'a' is not a number\n" +
		path + ":5: touch_id_sudo takes no arguments"
	if why != want {
		t.Errorf("got:\n%s\nwant:\n%s", why, want)
	}
}

func TestLoadNamesAListItCannotRead(t *testing.T) {
	if _, why := Load(filepath.Join(t.TempDir(), "missing.sh")); !strings.HasPrefix(why, "cannot read the settings list ") {
		t.Errorf("got %q", why)
	}
	if _, why := Load("-h"); why != "cannot read the settings list ./-h" {
		t.Errorf("got %q", why)
	}
}

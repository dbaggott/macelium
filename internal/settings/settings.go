// Package settings reads the settings list, compares its settings with a
// domain's preferences as defaults exports them, and gives the defaults
// arguments that write each.
//
// The list is a declaration file (package declare) of these:
//
//	setting [--current-host] <domain> <key> <type> <value>...
//	  <domain> is a defaults domain, or -g for the global one. <type> is
//	  bool, int, float, string, array or unordered-array; an array's values
//	  are its string elements, and an unordered one compares as a set.
//	disabled_hotkey <id> <character> <key code> <modifiers>
//	  A com.apple.symbolichotkeys entry turned off. Only its enabled flag is
//	  compared; a write writes the whole entry, keeping the key combination
//	  macOS stores with it so the shortcut reads the same if turned back on.
//	restart_on_change <domain> <app>
//	  The app to restart after a write to the domain. A write to a domain
//	  with no app declared restarts every app in FallbackRestarts.
//	sandboxed_app <domain> <app>
//	  The domain is that sandboxed app's, kept in
//	  ~/Library/Containers/<domain>. Its keys are compared only when the
//	  container's preferences can be read, which needs Full Disk Access; the
//	  app is quit for the writes, so it can't save its own values over them,
//	  and reopened if it was running.
//	touch_id_sudo
//	  Offer to turn on Touch ID for sudo, when the Mac has a finger enrolled
//	  and sudo does not take it already.
package settings

import (
	"encoding/base64"
	"fmt"
	"math"
	"os"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"howett.net/plist"

	"github.com/dbaggott/macelium/internal/declare"
)

// FallbackRestarts is what a write to a domain no restart_on_change names
// restarts.
var FallbackRestarts = []string{"Dock", "Finder", "SystemUIServer", "ControlCenter"}

var declarations = []string{"setting", "disabled_hotkey", "restart_on_change", "sandboxed_app", "touch_id_sudo"}

// Setting is one setting the list declares. A disabled hotkey is a setting
// of type hotkey, whose values are its id, character, key code and
// modifiers.
type Setting struct {
	CurrentHost bool
	Domain, Key string
	Type        string
	Values      []string
}

// Restart is a restart_on_change.
type Restart struct{ Domain, App string }

// Sandbox is a sandboxed_app, and its container's state: readable, absent
// when the app has not run yet, or unreadable.
type Sandbox struct {
	Domain, App string
	State       string
}

// List is the settings list read.
type List struct {
	Settings  []Setting
	Restarts  []Restart
	Sandboxes []Sandbox
	TouchID   bool
}

var (
	intRe      = regexp.MustCompile(`^-?[0-9]+$`)
	floatRe    = regexp.MustCompile(`^-?[0-9]+(\.[0-9]+)?$`)
	unsignedRe = regexp.MustCompile(`^[0-9]+$`)
)

// Load reads the list at path. It returns why, as the plan says it, when
// the list cannot be read or declares something wrongly.
func Load(path string) (*List, string) {
	// A path with no slash is shown as the shell's source would take it.
	if !strings.Contains(path, "/") {
		path = "./" + path
	}
	if r, err := os.Open(path); err != nil {
		return nil, "cannot read the settings list " + path
	} else {
		r.Close()
	}
	f, errs, err := declare.Read(path, declarations)
	if err != nil {
		return nil, "the settings list does not parse: " + err.Error()
	}
	if len(f.Stray) > 0 {
		return nil, "the settings list holds more than declarations and comments:\n" + strings.Join(f.Stray, "\n")
	}
	l := &List{}
	for _, d := range f.Declarations {
		if msg := l.declare(d.Name, d.Args); msg != "" {
			errs = append(errs, fmt.Sprintf("%s:%d: %s", path, d.Line, msg))
		}
	}
	if len(errs) > 0 {
		return nil, "the settings list declares something wrongly:\n" + strings.Join(errs, "\n")
	}
	return l, ""
}

// declare records a declaration, or returns what it gets wrong.
func (l *List) declare(name string, args []string) string {
	switch name {
	case "setting":
		host := false
		if len(args) > 0 && args[0] == "--current-host" {
			host, args = true, args[1:]
		}
		if len(args) < 4 {
			return "setting takes a domain, a key, a type and a value"
		}
		domain, key, typ, values := args[0], args[1], args[2], args[3:]
		valid := true
		switch typ {
		case "bool":
			valid = len(values) == 1 && (values[0] == "true" || values[0] == "false")
		case "int":
			valid = len(values) == 1 && intRe.MatchString(values[0])
		case "float":
			valid = len(values) == 1 && floatRe.MatchString(values[0])
		case "string":
			valid = len(values) == 1
		case "array", "unordered-array":
		default:
			return fmt.Sprintf("setting %s: unknown type '%s'", key, typ)
		}
		if !valid {
			return fmt.Sprintf("setting %s: not one %s value: %s", key, typ, strings.Join(values, " "))
		}
		if domain == "-g" {
			domain = "NSGlobalDomain"
		}
		l.Settings = append(l.Settings, Setting{host, domain, key, typ, values})
	case "disabled_hotkey":
		if len(args) != 4 {
			return "disabled_hotkey takes an id, a character, a key code and modifiers"
		}
		for _, a := range args {
			if !unsignedRe.MatchString(a) {
				return fmt.Sprintf("disabled_hotkey %s: '%s' is not a number", args[0], a)
			}
		}
		l.Settings = append(l.Settings, Setting{false, "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "hotkey", args})
	case "restart_on_change":
		if len(args) != 2 {
			return "restart_on_change takes a domain and an app"
		}
		l.Restarts = append(l.Restarts, Restart{args[0], args[1]})
	case "sandboxed_app":
		if len(args) != 2 {
			return "sandboxed_app takes a domain and an app"
		}
		l.Sandboxes = append(l.Sandboxes, Sandbox{Domain: args[0], App: args[1]})
	case "touch_id_sudo":
		if len(args) != 0 {
			return "touch_id_sudo takes no arguments"
		}
		l.TouchID = true
	}
	return ""
}

// SandboxOf returns the index of the sandboxed app a domain belongs to, or
// -1.
func (l *List) SandboxOf(domain string) int {
	for i, s := range l.Sandboxes {
		if s.Domain == domain {
			return i
		}
	}
	return -1
}

// RestartsFor returns the apps to restart after a write to domain.
func (l *List) RestartsFor(domain string) []string {
	var apps []string
	for _, r := range l.Restarts {
		if r.Domain == domain {
			apps = append(apps, r.App)
		}
	}
	if len(apps) == 0 {
		return FallbackRestarts
	}
	return apps
}

// Name returns the setting's key, as the plan names it.
func (s Setting) Name() string {
	name := s.Domain + " " + s.Key
	if s.Type == "hotkey" {
		name += "." + s.Values[0] + ".enabled"
	}
	if s.CurrentHost {
		name += " (current host)"
	}
	return name
}

// Declared returns the value the list declares, in the form Compare gives
// the current one.
func (s Setting) Declared() string {
	switch s.Type {
	case "hotkey":
		return "false"
	case "array", "unordered-array":
		quoted := make([]string, len(s.Values))
		for i, v := range s.Values {
			quoted[i] = quotedString(v)
		}
		return "[" + strings.Join(quoted, ",") + "]"
	}
	return s.Values[0]
}

func quotedString(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"`
}

// Domain is a domain's preferences, as defaults exports them.
type Domain map[string]any

// ParseDomain parses a plist defaults export printed.
func ParseDomain(data []byte) (Domain, error) {
	var d map[string]any
	if _, err := plist.Unmarshal(data, &d); err != nil {
		return nil, err
	}
	return d, nil
}

// lookup returns the value at a key path of the domain.
func (d Domain) lookup(path []string) (any, bool) {
	var v any = map[string]any(d)
	for _, k := range path {
		m, ok := v.(map[string]any)
		if !ok {
			return nil, false
		}
		if v, ok = m[k]; !ok {
			return nil, false
		}
	}
	return v, true
}

// Compare returns the value the domain has for the setting, and whether it
// is the declared one. An absent key, or one of another type than declared,
// differs.
func (s Setting) Compare(d Domain) (string, bool) {
	path := []string{s.Key}
	expected := map[string]string{"bool": "bool", "hotkey": "bool", "int": "integer", "float": "float", "string": "string", "array": "array", "unordered-array": "array"}[s.Type]
	if s.Type == "hotkey" {
		path = append(path, s.Values[0], "enabled")
	}
	v, ok := d.lookup(path)
	if !ok {
		return "(not set)", false
	}
	actual := typeOf(v)
	if actual != expected {
		form := raw(v)
		if actual == "array" || actual == "dictionary" {
			form = jsonOf(v)
		}
		return form + " (" + actual + ")", false
	}
	switch s.Type {
	case "array", "unordered-array":
		current := jsonOf(v)
		var elements []string
		for _, e := range v.([]any) {
			str, ok := e.(string)
			if !ok {
				return current, false
			}
			elements = append(elements, str)
		}
		want := slices.Clone(s.Values)
		if s.Type == "unordered-array" {
			sort.Strings(elements)
			sort.Strings(want)
		}
		return current, slices.Equal(elements, want)
	case "float":
		want, _ := strconv.ParseFloat(s.Values[0], 64)
		switch f := v.(type) {
		case float32:
			return raw(v), f == float32(want)
		case float64:
			return raw(v), f == want
		}
	case "hotkey":
		return raw(v), v == false
	}
	return raw(v), raw(v) == s.Values[0]
}

// typeOf names a plist value's type as plutil -type does.
func typeOf(v any) string {
	switch v.(type) {
	case bool:
		return "bool"
	case int64, uint64:
		return "integer"
	case float32, float64:
		return "float"
	case string:
		return "string"
	case []any:
		return "array"
	case map[string]any:
		return "dictionary"
	case time.Time:
		return "date"
	case []byte:
		return "data"
	}
	return fmt.Sprintf("%T", v)
}

// raw returns a value as plutil -extract's raw form gives it.
func raw(v any) string {
	switch x := v.(type) {
	case bool:
		return strconv.FormatBool(x)
	case int64:
		return strconv.FormatInt(x, 10)
	case uint64:
		return strconv.FormatUint(x, 10)
	case float32:
		return fmt.Sprintf("%f", float64(x))
	case float64:
		return fmt.Sprintf("%f", x)
	case string:
		return x
	case time.Time:
		return x.UTC().Format("2006-01-02T15:04:05Z")
	case []byte:
		return base64.StdEncoding.EncodeToString(x)
	case []any:
		return strconv.Itoa(len(x))
	case map[string]any:
		keys := sortedKeys(x)
		return strings.Join(keys, "\n")
	}
	return fmt.Sprint(v)
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// jsonOf returns a value as plutil -extract's json form gives it: compact,
// with / escaped.
func jsonOf(v any) string {
	var b strings.Builder
	writeJSON(&b, v)
	return b.String()
}

func writeJSON(b *strings.Builder, v any) {
	switch x := v.(type) {
	case []any:
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJSON(b, e)
		}
		b.WriteByte(']')
	case map[string]any:
		b.WriteByte('{')
		for i, k := range sortedKeys(x) {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJSONString(b, k)
			b.WriteByte(':')
			writeJSON(b, x[k])
		}
		b.WriteByte('}')
	case string:
		writeJSONString(b, x)
	case float32:
		b.WriteString(jsonFloat(float64(x)))
	case float64:
		b.WriteString(jsonFloat(x))
	case bool, int64, uint64:
		b.WriteString(raw(x))
	default:
		writeJSONString(b, raw(x))
	}
}

func jsonFloat(f float64) string {
	if f == math.Trunc(f) && math.Abs(f) < 1e15 {
		return strconv.FormatInt(int64(f), 10)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

func writeJSONString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '/':
			b.WriteString(`\/`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		default:
			if r < 0x20 {
				fmt.Fprintf(b, `\u%04x`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
}

// WriteArgs returns the defaults arguments that write the setting's
// declared value.
func (s Setting) WriteArgs() []string {
	var args []string
	if s.CurrentHost {
		args = append(args, "-currentHost")
	}
	args = append(args, "write", s.Domain, s.Key)
	switch s.Type {
	case "array", "unordered-array":
		// Each element goes as a plist string, which defaults takes as is:
		// bare, one such as a lone " fails to parse.
		args = append(args, "-array")
		for _, v := range s.Values {
			v = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(v)
			args = append(args, "<string>"+v+"</string>")
		}
	case "hotkey":
		id, char, keycode, modifiers := s.Values[0], s.Values[1], s.Values[2], s.Values[3]
		args = append(args, "-dict-add", id, `
        <dict>
          <key>enabled</key><false/>
          <key>value</key>
          <dict>
            <key>parameters</key>
            <array>
              <integer>`+char+`</integer>
              <integer>`+keycode+`</integer>
              <integer>`+modifiers+`</integer>
            </array>
            <key>type</key><string>standard</string>
          </dict>
        </dict>`)
	default:
		args = append(args, "-"+s.Type, s.Values[0])
	}
	return args
}

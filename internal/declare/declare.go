// Package declare reads a declaration file, such as the manifest or the
// settings list: a declaration a line, each a name and its arguments as
// shell words, with comments, blank lines and backslash continuations.
// Quoting, a leading ~ and brace expansion work as in the shell; anything
// that would run something or read a variable is refused, since the file
// is read, not run.
package declare

import (
	"bytes"
	"fmt"
	"os"
	"strings"

	"mvdan.cc/sh/v3/expand"
	"mvdan.cc/sh/v3/syntax"
)

// Declaration is one declaration: its name, its arguments, and the line it
// starts on.
type Declaration struct {
	Name string
	Args []string
	Line int
}

// File is a declaration file read: its declarations, and each line that is
// none of the names it takes, as "<path>:<line>: <text>".
type File struct {
	Declarations []Declaration
	Stray        []string
}

// Read reads the file at path, taking the declarations names lists. It fails
// only when the file cannot be read or is not shell words; a line that is
// not a declaration it takes is Stray, and a declaration that is not plain
// words is an error naming its line.
func Read(path string, names []string) (*File, []string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	known := map[string]bool{}
	for _, n := range names {
		known[n] = true
	}
	lines := strings.Split(string(data), "\n")
	f := &File{Stray: strayLines(path, lines, known)}
	if len(f.Stray) > 0 {
		return f, nil, nil
	}
	parsed, err := syntax.NewParser(syntax.Variant(syntax.LangBash)).Parse(bytes.NewReader(data), path)
	if err != nil {
		return nil, nil, err
	}
	env := expand.ListEnviron("HOME=" + os.Getenv("HOME"))
	cfg := &expand.Config{Env: env}
	var errs []string
	for _, stmt := range parsed.Stmts {
		line := int(stmt.Pos().Line())
		call, ok := stmt.Cmd.(*syntax.CallExpr)
		name := ""
		if ok && len(call.Args) > 0 && len(call.Assigns) == 0 {
			name = literalName(call.Args[0])
		}
		// Such as a second command on a declaration's line.
		if !known[name] {
			f.Stray = append(f.Stray, fmt.Sprintf("%s:%d: %s", path, line, lines[line-1]))
			continue
		}
		if stmt.Negated || stmt.Background || stmt.Coprocess || stmt.Disown || len(stmt.Redirs) > 0 || !plainWords(call.Args) {
			errs = append(errs, fmt.Sprintf("%s:%d: %s: takes only plain words, not expansions, redirections or other shell syntax", path, line, name))
			continue
		}
		args, err := expand.Fields(cfg, call.Args[1:]...)
		if err != nil {
			errs = append(errs, fmt.Sprintf("%s:%d: %s: %v", path, line, name, err))
			continue
		}
		f.Declarations = append(f.Declarations, Declaration{Name: name, Args: args, Line: line})
	}
	return f, errs, nil
}

// strayLines returns each line that does not start a declaration, and is
// not a comment, a blank or the continuation of the line before it.
func strayLines(path string, lines []string, known map[string]bool) []string {
	var stray []string
	continued := false
	// A file's final newline ends its last line rather than starting one.
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	for i, line := range lines {
		trimmed := strings.TrimLeft(line, " \t\v\f\r")
		comment := strings.HasPrefix(trimmed, "#")
		if !continued && trimmed != "" && !comment && !known[firstWord(line)] {
			stray = append(stray, fmt.Sprintf("%s:%d: %s", path, i+1, line))
		}
		continued = !comment && strings.HasSuffix(line, "\\")
	}
	return stray
}

// firstWord returns the text a line starts with, up to a blank, when the
// line starts with no blank.
func firstWord(line string) string {
	if i := strings.IndexAny(line, " \t\v\f\r"); i >= 0 {
		return line[:i]
	}
	return line
}

// literalName returns a word that is a bare name, or "" for any other.
func literalName(w *syntax.Word) string {
	if len(w.Parts) != 1 {
		return ""
	}
	if lit, ok := w.Parts[0].(*syntax.Lit); ok {
		return lit.Value
	}
	return ""
}

// plainWords reports whether each word is literal text, quoted or not,
// which expands to itself but for its quotes, escapes, a leading ~ and
// braces.
func plainWords(words []*syntax.Word) bool {
	for _, w := range words {
		for _, part := range w.Parts {
			switch p := part.(type) {
			case *syntax.Lit:
			case *syntax.SglQuoted:
				if p.Dollar {
					return false
				}
			case *syntax.DblQuoted:
				if p.Dollar {
					return false
				}
				for _, inner := range p.Parts {
					if _, ok := inner.(*syntax.Lit); !ok {
						return false
					}
				}
			default:
				return false
			}
		}
	}
	return true
}

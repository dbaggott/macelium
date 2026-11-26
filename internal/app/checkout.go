package app

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/dbaggott/macelium/internal/declare"
	"github.com/dbaggott/macelium/internal/run"
)

// The manifest, macelium.conf at the state repo's root, is a declaration
// file of these, each path relative to the state repo's root:
//
//	contract <n>       the contract it is written to; required
//	brewfile <path>    default Brewfile
//	settings <path>    default macos.sh
//	apps <dir>         default apps
//	init_notes <path>  no default
var manifestDeclarations = []string{"contract", "brewfile", "settings", "apps", "init_notes"}

var contractRe = regexp.MustCompile(`^[1-9][0-9]*$`)

// chezmoiCheckout returns the checkout chezmoi's config names, or why it
// was not found.
func chezmoiCheckout() (string, bool) {
	command := "chezmoi source-path"
	out, status := run.Capture(os.Stdin, "chezmoi", "source-path")
	if status == 0 {
		// chezmoi source-path may name the .chezmoiroot directory inside the
		// checkout, so the checkout is the git top level of what it prints.
		command = "git -C " + out + " rev-parse --show-toplevel"
		out, status = run.Capture(nil, "git", "-C", out, "rev-parse", "--show-toplevel")
		if status == 0 {
			return out, true
		}
	}
	return run.Failure(command, out, status), false
}

// findCheckout sets the session's checkout to the one chezmoi's config
// names, or repoDetail to why it was not found.
func (s *Session) findCheckout() {
	if out, ok := chezmoiCheckout(); ok {
		s.useCheckout(out)
	} else {
		s.repo, s.repoDetail = "", "checkout not found: "+out
	}
}

// useCheckout sets the session's checkout once its manifest loads, or
// repoDetail to why the manifest refused.
func (s *Session) useCheckout(checkout string) {
	if s.loadManifest(checkout) {
		s.repo = checkout
	} else {
		s.repo, s.manifestFailed = "", true
	}
}

func (s *Session) chezmoiConfigDir() string {
	if dir := os.Getenv("XDG_CONFIG_HOME"); dir != "" {
		return filepath.Join(dir, "chezmoi")
	}
	return filepath.Join(s.home, ".config", "chezmoi")
}

// chezmoiConfigFile returns the path of chezmoi's config file, or "" when
// there is none.
func (s *Session) chezmoiConfigFile() string {
	for _, ext := range []string{"toml", "yaml", "json", "jsonc"} {
		config := filepath.Join(s.chezmoiConfigDir(), "chezmoi."+ext)
		if exists(config) {
			return config
		}
	}
	return ""
}

// refuseForeignChezmoi changes nothing. It fails, having said how to remove
// it, when this Mac has a chezmoi setup that is not macelium's, whose config
// bootstrap's chezmoi init would replace: a config file whose source is not
// in a checkout with macelium.conf at its root, or no config file and a
// source directory that is not empty.
func (s *Session) refuseForeignChezmoi() bool {
	sourceDir := filepath.Join(s.home, ".local", "share", "chezmoi")
	if dir := os.Getenv("XDG_DATA_HOME"); dir != "" {
		sourceDir = filepath.Join(dir, "chezmoi")
	}
	var reason string
	if found := s.chezmoiConfigFile(); found != "" {
		out, ok := chezmoiCheckout()
		switch {
		case !ok:
			reason = found + " names no source in a git checkout: " + out + "\nIf it named a macelium checkout that has moved or been removed, run `chezmoi init --source <checkout>` to name the checkout instead."
		case !isFile(filepath.Join(out, "macelium.conf")):
			reason = found + " names a source in " + out + ", which has no macelium.conf"
		default:
			return true
		}
	} else if isDir(sourceDir) && !emptyDir(sourceDir) {
		reason = sourceDir + " holds a chezmoi source, and there is no chezmoi config"
	} else {
		return true
	}
	s.printError("this Mac has a chezmoi setup that is not macelium's: " + reason)
	fmt.Fprintf(s.Err, "\n%s\n", strings.Join([]string{
		"macelium manages chezmoi itself. To switch to macelium:",
		"  1. Save the old chezmoi source if it holds anything not saved elsewhere, such as commits not pushed.",
		"  2. Keep a copy of any age or gpg key file the old setup uses, such as one in " + s.chezmoiConfigDir() + ".",
		"  3. Run `chezmoi purge`, which removes chezmoi's config, state and source, and leaves the files it manages in place.",
		"  4. Run macelium " + s.Sub + " again.",
		"The files left in place are what `macelium init` captures.",
	}, "\n"))
	return false
}

// loadManifest sets the state repo's paths from the checkout's
// macelium.conf, or fails with repoDetail set to why the manifest refused.
func (s *Session) loadManifest(checkout string) bool {
	manifest := checkout + "/macelium.conf"
	data, err := os.ReadFile(manifest)
	if err != nil {
		s.repoDetail = "no macelium.conf in " + checkout
		return false
	}
	// The contract is read first, so a manifest for a newer macelium, which
	// may make declarations this one does not know, asks for an upgrade
	// rather than being refused as malformed.
	declared := ""
	for _, line := range strings.Split(string(data), "\n") {
		if fields := strings.Fields(line); len(fields) > 0 && fields[0] == "contract" {
			if len(fields) > 1 {
				declared = fields[1]
			}
			break
		}
	}
	if !contractRe.MatchString(declared) {
		s.repoDetail = manifest + " has no `contract <n>` line naming the contract it is written to"
		return false
	}
	if n, err := strconv.Atoi(declared); err != nil || n > KnownContract {
		s.repoDetail = fmt.Sprintf("%s is written to contract %s, and this macelium reads contract %d: upgrade macelium (`brew upgrade macelium`)", manifest, declared, KnownContract)
		return false
	}
	f, errs, err := declare.Read(manifest, manifestDeclarations)
	if err != nil {
		s.repoDetail = manifest + " does not parse: " + err.Error()
		return false
	}
	if len(f.Stray) > 0 {
		s.repoDetail = manifest + " holds more than declarations and comments:\n" + strings.Join(f.Stray, "\n")
		return false
	}
	paths := map[string]string{
		"brewfile": checkout + "/Brewfile", "settings": checkout + "/macos.sh",
		"apps": checkout + "/apps", "init_notes": "",
	}
	seen := map[string]bool{}
	for _, d := range f.Declarations {
		wrong := func(msg string) { errs = append(errs, fmt.Sprintf("%s:%d: %s", manifest, d.Line, msg)) }
		if len(d.Args) != 1 {
			wrong(d.Name + " takes one argument")
			continue
		}
		if seen[d.Name] {
			wrong(d.Name + " is declared more than once")
			continue
		}
		seen[d.Name] = true
		arg := d.Args[0]
		if d.Name == "contract" {
			if !contractRe.MatchString(arg) {
				wrong("contract " + arg + ": not a contract number")
			}
			continue
		}
		if strings.HasPrefix(arg, "/") {
			wrong(d.Name + " " + arg + ": not a path relative to the state repo's root")
			continue
		}
		paths[d.Name] = checkout + "/" + arg
	}
	if len(errs) > 0 {
		s.repoDetail = manifest + " declares something wrongly:\n" + strings.Join(errs, "\n")
		return false
	}
	s.stateBrewfile, s.stateSettings = paths["brewfile"], paths["settings"]
	s.stateApps, s.stateInitNotes = paths["apps"], paths["init_notes"]
	return true
}

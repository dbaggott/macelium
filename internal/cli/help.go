package cli

import (
	"fmt"
	"io"
)

// commands is the commands macelium --help lists, in its order.
var commands = []string{"setup", "init", "bootstrap", "plan", "apply", "settings", "help"}

// synopsis returns a command's synopsis, the arguments after `macelium`, or
// "" when there is no such command; "" names macelium itself.
func synopsis(command string) string {
	switch command {
	case "":
		return "<command> [<options>]"
	case "setup":
		return "setup [<owner>/<repo>|<git URL>] [<path>]"
	case "init":
		return "init [--public] <path>"
	case "bootstrap":
		return "bootstrap [<checkout>]"
	case "plan":
		return "plan [--notify]"
	case "apply":
		return "apply"
	case "settings":
		return "settings [--file <path>]"
	case "help":
		return "help [<command>]"
	}
	return ""
}

var helpText = map[string]string{
	"": `Keep this Mac in line with a state repo: a chezmoi source with macelium.conf
at its root, listing its packages, runtimes, files and macOS settings.

Commands:
  setup      Find or create the state repo, and set this Mac up from it
  init       Capture this Mac into a new state repo
  bootstrap  Set up this Mac from a state repo
  plan       Show how this Mac differs from the state repo
  apply      Bring this Mac in line with the state repo
  settings   Write the macOS settings that differ from the settings list
  help       Show the help for macelium or one of its commands

Options:
  -h, --help     Show this help
  -V, --version  Print macelium's version

Run ` + "`macelium <command> --help`" + ` for a command's options.
`,
	"setup": `Set this Mac up from its state repo, cloning it to <path> and bootstrapping
it. With no arguments it guides you: it finds the state repo on GitHub, as
<you>/macelium-state, or on another git host, or, when there is none,
captures this Mac into a new one with init, scans it for secrets with
gitleaks, and pushes it once you say to. Running it again goes on from where
it stopped. It needs a terminal.

<path> defaults to the state repo's name in the first of ~/Developer, ~/git,
~/src, ~/code and ~/Projects this Mac has, else in your home directory.

Options:
  -h, --help  Show this help
`,
	"init": `Capture this Mac into a new state repo at <path>, a missing or empty
directory: a Brewfile of what Homebrew installed, your name and email, and,
each on a yes, ~/.gitconfig, ~/.zshrc and the mise config. It commits once,
and neither pushes nor bootstraps.

Options:
  --public    Say, when offering each file, that the repo will be public
  -h, --help  Show this help
`,
	"bootstrap": `Set up this Mac from <checkout>, or else from the checkout chezmoi's config
names: initialize chezmoi, apply the files, then run each chezmoi script,
brew bundle, mise install, the macOS settings and the apps hooks, each as a
step of its own. It can run again at any point. It needs a terminal.

Options:
  -h, --help  Show this help
`,
	"plan": `Show how this Mac differs from the state repo, changing nothing on it but a
git fetch in the checkout and a brew update. Exits 0 when nothing differs,
2 when anything but an available upgrade does, and 1 when a check failed.

Options:
  --notify    Print one log line, without the brew update, and post a macOS
              notification when the exit status is not 0
  -h, --help  Show this help
`,
	"apply": `Show the plan, ask, then bring this Mac in line with the state repo: chezmoi
apply, brew bundle, mise install, the macOS settings and the apps hooks. It
never removes anything. It needs a terminal.

Options:
  -h, --help  Show this help
`,
	"settings": `Write the macOS settings that differ from the state repo's settings list,
without asking, and restart the apps that read them.

Options:
  --file <path>  Read this settings list instead of the state repo's
  -h, --help     Show this help
`,
	"help": `Show the help for macelium, or for <command>.

Options:
  -h, --help  Show this help
`,
}

// printHelp prints a command's help, or macelium's for "".
func printHelp(w io.Writer, command string) {
	fmt.Fprintf(w, "Usage: macelium %s\n\n%s", synopsis(command), helpText[command])
}

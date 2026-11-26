// Package cli is macelium's command line: its commands, their arguments,
// the help, and the usage errors.
package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/dbaggott/macelium/internal/app"
)

// Version is macelium's version, set at build time.
var Version = "dev"

// harnessCommands returns the test build's hidden commands.
var harnessCommands func() []*cobra.Command

// usageError is what is wrong with a command's arguments.
type usageError struct {
	command string
	msg     string
}

func (e *usageError) Error() string { return e.msg }

func unexpected(command, arg string) error {
	if strings.HasPrefix(arg, "-") {
		return &usageError{command, "unknown option '" + arg + "'"}
	}
	return &usageError{command, "unexpected argument '" + arg + "'"}
}

// exitCode carries a command's exit status out of cobra.
type exitCode int

func (e exitCode) Error() string { return fmt.Sprintf("exit status %d", int(e)) }

func status(code int) error {
	if code == 0 {
		return nil
	}
	return exitCode(code)
}

// maxArgs refuses more than n arguments, naming the first extra one.
func maxArgs(n int) cobra.PositionalArgs {
	return func(cmd *cobra.Command, args []string) error {
		if len(args) > n {
			return unexpected(cmd.Name(), args[n])
		}
		return nil
	}
}

func session(cmd *cobra.Command) *app.Session {
	return app.NewSession(cmd.Name(), Version)
}

// newRoot returns macelium's command tree.
func newRoot() *cobra.Command {
	var version bool
	root := &cobra.Command{
		Use:           "macelium",
		SilenceErrors: true,
		SilenceUsage:  true,
		Args: func(cmd *cobra.Command, args []string) error {
			if len(args) == 0 {
				return nil
			}
			if version {
				return unexpected("", args[0])
			}
			return &usageError{"", "unknown command '" + args[0] + "'"}
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			if version {
				fmt.Println("macelium " + Version)
				return nil
			}
			printHelp(os.Stderr, "")
			return exitCode(1)
		},
		CompletionOptions: cobra.CompletionOptions{HiddenDefaultCmd: true},
	}
	root.Flags().BoolVarP(&version, "version", "V", false, "Print macelium's version")
	root.Flags().SortFlags = false

	setup := &cobra.Command{
		Use: "setup", Short: "Find or create the state repo, and set this Mac up from it",
		Args: func(cmd *cobra.Command, args []string) error {
			if len(args) > 2 {
				return unexpected("setup", args[2])
			}
			if len(args) > 0 && !app.NamesStateRepo(args[0]) {
				return &usageError{"setup", "'" + args[0] + "' is neither <owner>/<repo> nor a git URL"}
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) error { return status(session(cmd).Setup(args)) },
	}

	var public bool
	initCmd := &cobra.Command{
		Use: "init", Short: "Capture this Mac into a new state repo",
		Args: func(cmd *cobra.Command, args []string) error {
			if len(args) == 0 {
				return &usageError{"init", "missing <path>"}
			}
			return maxArgs(1)(cmd, args)
		},
		RunE: func(cmd *cobra.Command, args []string) error { return status(session(cmd).Init(public, args[0])) },
	}
	initCmd.Flags().BoolVar(&public, "public", false, "Say, when offering each file, that the repo will be public")

	bootstrap := &cobra.Command{
		Use: "bootstrap", Short: "Set up this Mac from a state repo", Args: maxArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			checkout := ""
			if len(args) > 0 {
				checkout = args[0]
			}
			return status(session(cmd).Bootstrap(checkout))
		},
	}

	var notify bool
	plan := &cobra.Command{
		Use: "plan", Short: "Show how this Mac differs from the state repo", Args: maxArgs(0),
		RunE: func(cmd *cobra.Command, args []string) error { return status(session(cmd).Plan(notify)) },
	}
	plan.Flags().BoolVar(&notify, "notify", false, "Print one log line, and post a notification when the exit status is not 0")

	apply := &cobra.Command{
		Use: "apply", Short: "Bring this Mac in line with the state repo", Args: maxArgs(0),
		RunE: func(cmd *cobra.Command, args []string) error { return status(session(cmd).Apply()) },
	}

	var file string
	settings := &cobra.Command{
		Use: "settings", Short: "Write the macOS settings that differ from the settings list", Args: maxArgs(0),
		RunE: func(cmd *cobra.Command, args []string) error {
			if cmd.Flags().Changed("file") && file == "" {
				return &usageError{"settings", "--file needs a path"}
			}
			return status(session(cmd).Settings(file))
		},
	}
	settings.Flags().StringVar(&file, "file", "", "Read this settings list instead of the state repo's")

	help := &cobra.Command{
		Use: "help", Short: "Show the help for macelium or one of its commands",
		Args: func(cmd *cobra.Command, args []string) error {
			if len(args) > 1 {
				return unexpected("help", args[1])
			}
			if len(args) == 1 && synopsis(args[0]) == "" {
				return &usageError{"help", "unknown command '" + args[0] + "'"}
			}
			return nil
		},
		ValidArgsFunction: func(cmd *cobra.Command, args []string, toComplete string) ([]string, cobra.ShellCompDirective) {
			var offered []string
			for _, c := range commands {
				if len(args) == 0 && strings.HasPrefix(c, toComplete) {
					offered = append(offered, c)
				}
			}
			return offered, cobra.ShellCompDirectiveNoFileComp
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			name := ""
			if len(args) > 0 {
				name = args[0]
			}
			printHelp(os.Stdout, name)
			return nil
		},
	}

	for _, c := range []*cobra.Command{setup, initCmd, bootstrap, plan, apply, settings} {
		if c.ValidArgsFunction == nil {
			c.ValidArgsFunction = filesFor(c)
		}
	}
	root.AddCommand(setup, initCmd, bootstrap, plan, apply, settings, help)
	if harnessCommands != nil {
		root.AddCommand(harnessCommands()...)
	}
	root.SetHelpCommand(help)
	root.SetHelpFunc(func(cmd *cobra.Command, _ []string) {
		name := cmd.Name()
		if cmd == root {
			name = ""
		}
		printHelp(os.Stdout, name)
	})
	root.SetFlagErrorFunc(func(cmd *cobra.Command, err error) error {
		name := cmd.Name()
		if cmd == root {
			name = ""
		}
		msg := err.Error()
		switch {
		case strings.HasPrefix(msg, "flag needs an argument:") && cmd.Name() == "settings":
			return &usageError{name, "--file needs a path"}
		case strings.HasPrefix(msg, "unknown flag: "):
			return &usageError{name, "unknown option '" + strings.TrimPrefix(msg, "unknown flag: ") + "'"}
		case strings.HasPrefix(msg, "unknown shorthand flag: "):
			// "unknown shorthand flag: 'x' in -x"
			if i := strings.LastIndex(msg, " in "); i >= 0 {
				return &usageError{name, "unknown option '" + msg[i+4:] + "'"}
			}
		}
		return &usageError{name, msg}
	})
	return root
}

// filesFor completes a command's arguments as paths where it takes them:
// init's and bootstrap's one, and setup's second.
func filesFor(c *cobra.Command) func(*cobra.Command, []string, string) ([]string, cobra.ShellCompDirective) {
	return func(cmd *cobra.Command, args []string, _ string) ([]string, cobra.ShellCompDirective) {
		switch c.Name() {
		case "init", "bootstrap":
			if len(args) == 0 {
				return nil, cobra.ShellCompDirectiveDefault
			}
		case "setup":
			if len(args) == 1 {
				return nil, cobra.ShellCompDirectiveDefault
			}
		}
		return nil, cobra.ShellCompDirectiveNoFileComp
	}
}

// Execute runs macelium with the process's arguments, and returns its exit
// status.
func Execute() int {
	// brew bundle runs brew update first unless this is set, which in apply
	// would upgrade past what the plan showed; plan runs brew update itself.
	os.Setenv("HOMEBREW_NO_AUTO_UPDATE", "1")
	return execute(newRoot(), os.Args[1:], os.Stderr)
}

func execute(root *cobra.Command, args []string, stderr io.Writer) int {
	root.SetArgs(args)
	// The help is the only thing -h prints, whatever follows it.
	if len(args) >= 2 && (args[0] == "-h" || args[0] == "--help") {
		return usage(stderr, unexpected("", args[1]).(*usageError))
	}
	err := root.Execute()
	var code exitCode
	var ue *usageError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &code):
		return int(code)
	case errors.As(err, &ue):
		return usage(stderr, ue)
	}
	fmt.Fprintf(stderr, "macelium: %v\n", err)
	return 1
}

// usage prints what is wrong with the arguments, with the command's
// synopsis, and returns 1.
func usage(w io.Writer, e *usageError) int {
	name, run := "macelium", "macelium "
	if e.command != "" {
		name += " " + e.command
		run += e.command + " "
	}
	fmt.Fprintf(w, "%s: %s\n", name, e.msg)
	fmt.Fprintf(w, "Usage: macelium %s\n", synopsis(e.command))
	fmt.Fprintf(w, "Run `%s--help` for more.\n", run)
	return 1
}

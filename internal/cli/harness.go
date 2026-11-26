//go:build harness

package cli

import (
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/spf13/cobra"

	"github.com/dbaggott/macelium/internal/app"
	"github.com/dbaggott/macelium/internal/run"
	"github.com/dbaggott/macelium/internal/term"
)

// The test build's hidden commands, which run one part of macelium on its
// own for the tests that watch what it draws on a terminal.
func init() {
	harnessCommands = func() []*cobra.Command {
		banner := &cobra.Command{
			Use: "__banner", Hidden: true,
			Run: func(cmd *cobra.Command, args []string) { term.Banner(os.Stdout, Version) },
		}
		var tick int
		var results bool
		step := &cobra.Command{
			Use: "__logged-step <name> <command>...", Hidden: true, Args: cobra.MinimumNArgs(2),
			RunE: func(cmd *cobra.Command, args []string) error {
				log := os.Getenv("HOME") + "/bootstrap.log"
				code, recorded := app.HarnessLoggedStep(args[0], log, time.Duration(tick)*time.Second, args[1:])
				if results {
					fmt.Fprintf(os.Stderr, "results: %s\n", recorded)
				}
				return status(code)
			},
		}
		step.Flags().IntVar(&tick, "tick", 5, "seconds between status updates")
		step.Flags().BoolVar(&results, "results", false, "print the recorded step")
		step.Flags().SetInterspersed(false)
		spinner := &cobra.Command{
			Use: "__with-spinner <label> <command>...", Hidden: true, Args: cobra.MinimumNArgs(2),
			RunE: func(cmd *cobra.Command, args []string) error {
				var code int
				term.WithSpinner(os.Stdout, args[0], func() {
					c := exec.Command(args[1], args[2:]...)
					c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
					code = run.Status(c.Run())
				})
				return status(code)
			},
		}
		spinner.Flags().SetInterspersed(false)
		return []*cobra.Command{banner, step, spinner}
	}
}

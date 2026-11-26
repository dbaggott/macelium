package main

import (
	"os"

	"github.com/dbaggott/macelium/internal/cli"
)

func main() {
	os.Exit(cli.Execute())
}

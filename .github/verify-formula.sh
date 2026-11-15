#!/usr/bin/env bash
# shellcheck disable=SC2016 # the $prefix and $log in the tests are jq's
# Installs the macelium formula, runs its test, starts its service, and checks
# the launchd plist Homebrew writes for it: the 09:00 schedule and no run on
# load, `plan --notify`, Homebrew's bin on PATH and the drift log. release.yml's
# verify job runs it on a macOS runner after writing the tap. It starts a
# service, so it is for a runner, not for a Mac in use.
#
# Usage: .github/verify-formula.sh <formula>   e.g. dbaggott/tap/macelium
set -euo pipefail

(($# == 1)) || {
  echo "usage: $0 <formula>" >&2
  exit 2
}

brew install "$1"
brew test macelium
brew services start macelium

# The plist's name differs between Homebrew versions (homebrew.mxcl.<name>,
# sh.brew.<name>), so brew services names it.
plist=$(brew services info macelium --json | jq -r '.[0].file')
echo "plist: $plist"
case $plist in
  "$HOME"/Library/LaunchAgents/*.plist) ;;
  *)
    echo "FAILED: the service's plist is not in ~/Library/LaunchAgents"
    exit 1
    ;;
esac
prefix=$(brew --prefix)
log=$HOME/Library/Logs/macelium-drift.log
json=$(plutil -convert json -o - "$plist")
echo "$json" | jq .

failed=0
# Takes a jq test of the plist, which must hold.
expect() {
  if jq -e --arg prefix "$prefix" --arg log "$log" "$1" <<<"$json" >/dev/null; then
    echo "ok: $1"
  else
    echo "FAILED: $1"
    failed=1
  fi
}

expect '.ProgramArguments == [$prefix + "/opt/macelium/bin/macelium", "plan", "--notify"]'
expect '.StartCalendarInterval == {"Hour": 9, "Minute": 0}'
expect '.RunAtLoad == false'
expect '.EnvironmentVariables.PATH | split(":") | index($prefix + "/bin") != null'
expect '.StandardOutPath == $log'
expect '.StandardErrorPath == $log'

exit "$failed"

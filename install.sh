#!/bin/bash
# Installs Homebrew, when it is missing, and macelium, or upgrades it, then
# hands over to macelium setup, which finds or creates the state repo and
# sets the Mac up from it:
#   curl -fsSL https://github.com/dbaggott/macelium/releases/latest/download/install.sh | bash
# or, naming the state repo:
#   curl -fsSL https://github.com/dbaggott/macelium/releases/latest/download/install.sh | bash -s <owner>/<repo>|<git URL> [<path>]
#
# Bash reads this script from the pipe as it runs it, so the whole of it is
# one function, called on the last line, and every step that can prompt
# reads /dev/tty, since stdin is the pipe. Written for the bash macOS ships,
# 3.2.

install_macelium() {
  set -uo pipefail

  has_terminal() {
    (: </dev/tty) 2>/dev/null && return 0
    echo "install.sh: needs a terminal for its prompts" >&2
    return 1
  }

  # Sets brew to the first of the prefixes Homebrew installs to that holds
  # it, or to nothing.
  local brew=''
  find_brew() {
    local prefix
    for prefix in /opt/homebrew /usr/local; do
      if [[ -x $prefix/bin/brew ]]; then
        brew=$prefix/bin/brew
        return
      fi
    done
  }

  # macelium's spinner (macelium, "spinner"), which install.sh runs before
  # macelium is installed.
  local spinner=('n  ' 'T  ' 'T  ' '/  ' '_. ' '., ' ' o ' ' n ' ' T ' ' T ' ' \ ' '._ ' ',. ' 'o  ')

  # Takes what is being done, and redraws it on the cursor's line, led by the
  # spinner and followed by the time so far, until killed or this run exits.
  spin() {
    local frame=0 start=$SECONDS elapsed
    while kill -0 "$$" 2>/dev/null; do
      elapsed=$((SECONDS - start))
      printf '\r\033[K  %s %s... %dm%02ds' "${spinner[frame % ${#spinner[@]}]}" "$1" $((elapsed / 60)) $((elapsed % 60))
      ((frame++))
      sleep 0.15
    done
  }

  # Takes what is being done and a command. Runs the command while the
  # spinner turns, setting spun to its output, which is shown only when it
  # fails.
  local spun
  with_spinner() {
    local label=$1 spinner_pid output status
    shift
    output=$(mktemp) || return 1
    spin "$label" >/dev/tty &
    spinner_pid=$!
    "$@" >"$output" 2>&1
    status=$?
    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    printf '\r\033[K' >/dev/tty
    spun=$(cat "$output")
    rm -f "$output"
    ((status == 0)) || printf '%s\n' "$spun" >&2
    return "$status"
  }

  # Installs the Command Line Tools, which Homebrew's installer needs, unless
  # they are installed, the way that installer does but with the spinner,
  # since softwareupdate shows no progress while it downloads and installs
  # them. When softwareupdate offers none, Homebrew's installer is left to
  # install them.
  install_command_line_tools() {
    local placeholder=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress label
    xcode-select -p >/dev/null 2>&1 && return 0
    # softwareupdate lists the tools only while this file exists.
    touch "$placeholder"
    with_spinner "Finding the Command Line Tools for Xcode" softwareupdate -l
    label=$(sed -n 's/^ *\* Label: \(Command Line Tools.*\)$/\1/p' <<<"$spun" | sort -V | tail -n 1)
    if [[ -z $label ]]; then
      rm -f "$placeholder"
      echo "==> Command Line Tools for Xcode: Homebrew's installer installs them, and macOS shows no progress while it does, which can take 15 minutes or more"
      return 0
    fi
    echo "==> Installing $label"
    echo "    macOS shows no progress for this download, and it can take 15 minutes or more."
    # shellcheck disable=SC2024 # the terminal is sudo's input, not a file it writes
    sudo -v </dev/tty || {
      rm -f "$placeholder"
      echo "install.sh: stopped: installing the Command Line Tools needs sudo" >&2
      return 1
    }
    # One sudo for both, since the install can outlast sudo's cached
    # credentials.
    # shellcheck disable=SC2016 # $1 is the inner shell's
    if ! with_spinner "Installing $label" sudo -n /bin/sh -c \
      'softwareupdate -i "$1" && xcode-select --switch /Library/Developer/CommandLineTools' sh "$label"; then
      rm -f "$placeholder"
      echo "install.sh: stopped: installing $label failed" >&2
      return 1
    fi
    rm -f "$placeholder"
    echo "==> $label: installed"
  }

  # Upgrades macelium when its tap has a newer one, and says which version
  # this run goes on with. brew upgrade refreshes the tap first, as it does
  # for any command naming a tap's formula unless it did so in the last five
  # minutes, and leaves a macelium that is the latest as it is.
  upgrade_macelium() {
    local before after
    before=$(brew list --versions dbaggott/tap/macelium)
    if ! with_spinner "Upgrading macelium if a newer one is out" brew upgrade dbaggott/tap/macelium; then
      echo "install.sh: stopped: brew upgrade dbaggott/tap/macelium failed" >&2
      return 1
    fi
    after=$(brew list --versions dbaggott/tap/macelium)
    if [[ $after == "$before" ]]; then
      echo "==> macelium: already installed, the latest version (${after##* })"
    else
      echo "==> macelium: upgraded from ${before##* } to ${after##* }"
    fi
  }

  # Installs Homebrew and macelium, each unless it already is, and upgrades
  # a macelium already installed to the latest. Leaves brew, and so
  # macelium, on PATH.
  install_tools() {
    if command -v brew >/dev/null; then
      echo "==> Homebrew: already installed"
    else
      find_brew
      if [[ -n $brew ]]; then
        echo "==> Homebrew: already installed"
      else
        install_command_line_tools || return 1
        echo "==> Installing Homebrew"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty || {
          echo "install.sh: stopped: the Homebrew installer failed" >&2
          return 1
        }
        find_brew
        if [[ -z $brew ]]; then
          echo "install.sh: stopped: no brew in /opt/homebrew or /usr/local after Homebrew's installer" >&2
          return 1
        fi
      fi
      eval "$("$brew" shellenv bash)"
    fi

    if brew list --formula dbaggott/tap/macelium >/dev/null 2>&1; then
      upgrade_macelium || return 1
    else
      echo "==> Installing macelium"
      brew install dbaggott/tap/macelium </dev/tty || {
        echo "install.sh: stopped: brew install dbaggott/tap/macelium failed" >&2
        return 1
      }
    fi
  }

  has_terminal && install_tools || return 1
  # A tap whose formula is not yet the release this script came from, or
  # that brew did not refresh, can install a macelium from before setup.
  if ! macelium help setup >/dev/null 2>&1; then
    echo "install.sh: stopped: the macelium Homebrew installed has no setup command; run brew update && brew upgrade dbaggott/tap/macelium, then install.sh again" >&2
    return 1
  fi
  exec macelium setup "$@" </dev/tty
}

install_macelium "$@"

#!/bin/bash
# Sets up a Mac from a state repo (README.md, "Install"):
#   curl -fsSL https://raw.githubusercontent.com/dbaggott/macelium/main/install.sh | bash -s <owner>/<repo> [<path>]
#
# Bash reads this script from the pipe as it runs it, so the whole of it is
# one function, called on the last line, and every step that can prompt
# reads /dev/tty, since stdin is the pipe. Each step is skipped when it is
# already done, so running it again picks up where it stopped. Written for
# the bash macOS ships, 3.2.

install_macelium() {
  set -uo pipefail
  local usage='usage: curl -fsSL https://raw.githubusercontent.com/dbaggott/macelium/main/install.sh | bash -s <owner>/<repo> [<path>]'

  if (($# < 1 || $# > 2)) || ! [[ $1 =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "$usage" >&2
    return 1
  fi
  local slug=$1 url="https://github.com/$1"
  local path=${2:-$HOME/git/${1#*/}}

  # Takes a git remote URL, and succeeds when it names $slug on GitHub, over
  # HTTPS or SSH, with or without .git. GitHub's names ignore case.
  names_state_repo() {
    local remote
    remote=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    remote=${remote%/}
    remote=${remote%.git}
    case $remote in
      https://github.com/*) remote=${remote#https://github.com/} ;;
      ssh://git@github.com/*) remote=${remote#ssh://git@github.com/} ;;
      git@github.com:*) remote=${remote#git@github.com:} ;;
      *) return 1 ;;
    esac
    [[ $remote == "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" ]]
  }

  # The path is checked before anything is installed, so a wrong one changes
  # nothing. Empty, or missing, it is cloned to; a clone of the state repo is
  # used as it is.
  local cloned=no
  if [[ -e $path ]]; then
    if [[ -d $path && -z $(ls -A "$path") ]]; then
      :
    elif [[ -d $path && $(git -C "$path" rev-parse --show-toplevel 2>/dev/null) == "$(cd "$path" && pwd -P)" ]] &&
      names_state_repo "$(git -C "$path" config --get remote.origin.url)"; then
      cloned=yes
    else
      echo "install.sh: $path holds something other than a clone of $slug: name another path, as the second argument" >&2
      return 1
    fi
  fi
  if ! (: </dev/tty) 2>/dev/null; then
    echo "install.sh: needs a terminal for its prompts" >&2
    return 1
  fi

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
  if command -v brew >/dev/null; then
    echo "==> Homebrew: already installed"
  else
    find_brew
    if [[ -n $brew ]]; then
      echo "==> Homebrew: already installed"
    else
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
    echo "==> macelium: already installed"
  else
    echo "==> Installing macelium"
    brew install dbaggott/tap/macelium </dev/tty || {
      echo "install.sh: stopped: brew install dbaggott/tap/macelium failed" >&2
      return 1
    }
  fi

  if GIT_TERMINAL_PROMPT=0 git ls-remote "$url" >/dev/null 2>&1; then
    echo "==> GitHub sign-in: not needed, $slug can be read without it"
  else
    if gh auth status --hostname github.com >/dev/null 2>&1; then
      echo "==> GitHub sign-in: gh is already signed in"
    else
      echo "==> Signing in to GitHub"
      gh auth login --hostname github.com --git-protocol https --web </dev/tty || {
        echo "install.sh: stopped: gh auth login failed" >&2
        return 1
      }
    fi
    gh auth setup-git --hostname github.com || {
      echo "install.sh: stopped: gh auth setup-git failed" >&2
      return 1
    }
  fi

  if [[ $cloned == yes ]]; then
    echo "==> Clone: $path is already a clone of $slug"
  else
    echo "==> Cloning $slug to $path"
    if ! { mkdir -p "$(dirname "$path")" && git clone "$url" "$path" </dev/tty; }; then
      echo "install.sh: stopped: git clone $url failed" >&2
      return 1
    fi
  fi

  echo "==> macelium bootstrap $path"
  macelium bootstrap "$path" </dev/tty
}

install_macelium "$@"

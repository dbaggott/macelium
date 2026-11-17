#!/bin/bash
# Sets up a Mac from a state repo (README.md, "Install"):
#   curl -fsSL https://github.com/dbaggott/macelium/releases/latest/download/install.sh | bash -s <owner>/<repo>|<git URL> [<path>]
#
# Bash reads this script from the pipe as it runs it, so the whole of it is
# one function, called on the last line, and every step that can prompt
# reads /dev/tty, since stdin is the pipe. Each step is skipped when it is
# already done, so running it again picks up where it stopped. Written for
# the bash macOS ships, 3.2.

install_macelium() {
  set -uo pipefail
  local usage='usage: curl -fsSL https://github.com/dbaggott/macelium/releases/latest/download/install.sh | bash -s <owner>/<repo>|<git URL> [<path>]'

  lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
  }

  # Takes a git URL: https://, ssh:// or scp form, [user@]host:path. Sets
  # url_host, and url_path without its leading /, trailing / or .git, and
  # fails for anything else. A user name or a port is no part of either.
  local url_host url_path
  parse_git_url() {
    local re_url='^(https|ssh)://([^/@]+@)?([^/@:]+)(:[0-9]+)?/(.*)$'
    local re_scp='^([^/@:]+@)?([^/@:]+):(.*)$'
    if [[ $1 =~ $re_url ]]; then
      url_host=${BASH_REMATCH[3]} url_path=${BASH_REMATCH[5]}
    elif [[ $1 != *://* && $1 =~ $re_scp ]]; then
      url_host=${BASH_REMATCH[2]} url_path=${BASH_REMATCH[3]}
    else
      return 1
    fi
    url_path=${url_path#/}
    url_path=${url_path%/}
    url_path=${url_path%.git}
    [[ -n $url_path && $url_path != *[[:space:]]* ]]
  }

  # The state repo: its host, its path there, which GitHub's names compare
  # in any case, the URL to clone, and how to name it.
  local host repo_path url name
  if (($# < 1 || $# > 2)); then
    echo "$usage" >&2
    return 1
  fi
  if [[ $1 =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
    host=github.com repo_path=${1%.git} url=https://github.com/${1%.git}
  elif parse_git_url "$1"; then
    host=$url_host repo_path=$url_path url=$1
  else
    echo "$usage" >&2
    return 1
  fi
  local github=no
  if [[ $(lower "$host") == github.com ]]; then
    github=yes
    if ! [[ $repo_path =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
      echo "$usage" >&2
      return 1
    fi
    name=$repo_path
  else
    name=$url
  fi

  # Takes a git remote URL, and succeeds when it names the state repo: on
  # GitHub, in any case; elsewhere, the same host and path exactly.
  names_state_repo() {
    parse_git_url "$1" || return 1
    if [[ $github == yes ]]; then
      [[ $(lower "$url_host") == github.com && $(lower "$url_path") == "$(lower "$repo_path")" ]]
    else
      [[ $url_host == "$host" && $url_path == "$repo_path" ]]
    fi
  }

  # With no path given, the repo goes in the first of the directories people
  # keep code in that this Mac has, else the home directory.
  local path=${2:-} dir
  if [[ -z $path ]]; then
    path=$HOME
    for dir in Developer git src code Projects; do
      if [[ -d $HOME/$dir ]]; then
        path=$HOME/$dir
        break
      fi
    done
    path=$path/${repo_path##*/}
  fi
  echo "==> Path: $path"

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
      echo "install.sh: $path holds something other than a clone of $name: name another path, as the second argument" >&2
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

  # Signs in to GitHub with gh, and has git use it.
  sign_in_to_github() {
    if gh auth status --hostname github.com >/dev/null 2>&1; then
      echo "==> GitHub sign-in: gh is already signed in"
    else
      echo "==> Signing in to GitHub"
      gh auth login --hostname github.com --git-protocol https --web </dev/tty || {
        echo "install.sh: gh auth login failed" >&2
        return 1
      }
    fi
    gh auth setup-git --hostname github.com || {
      echo "install.sh: gh auth setup-git failed" >&2
      return 1
    }
  }

  # A GitHub repo is probed over HTTPS, whatever form names it, since that
  # is what an anonymous read and gh's sign-in both use.
  local offer_sign_in=no
  if [[ $github == no ]]; then
    if [[ $cloned == no ]]; then
      echo "==> $host sign-in: needs a personal access token or a registered SSH key, since account passwords are refused over HTTPS; git asks for what it needs"
    fi
  elif GIT_TERMINAL_PROMPT=0 git ls-remote "https://github.com/$repo_path" >/dev/null 2>&1; then
    echo "==> GitHub sign-in: not needed, git can read $name"
    offer_sign_in=yes
  elif ! sign_in_to_github; then
    echo "install.sh: stopped: git can't read $name without a GitHub sign-in" >&2
    return 1
  fi

  if [[ $cloned == yes ]]; then
    echo "==> Clone: $path is already a clone of $name"
  else
    echo "==> Cloning $name to $path"
    if ! { mkdir -p "$(dirname "$path")" && git clone "$url" "$path" </dev/tty; }; then
      echo "install.sh: stopped: git clone $url failed" >&2
      return 1
    fi
  fi

  echo "==> macelium bootstrap $path"
  macelium bootstrap "$path" </dev/tty || return

  # The repo read without a sign-in, so pushing to it still needs one.
  # End-of-file on the terminal, as when it has gone away, means no. The
  # Mac is set up by now, so a failed sign-in is reported, not a failure.
  if [[ $offer_sign_in == yes ]] && ! gh auth status --hostname github.com >/dev/null 2>&1; then
    local answer
    printf '%s ' "Sign in to GitHub with gh, so you can push changes from this machine? [Y/n]" >/dev/tty
    if read -r answer </dev/tty && [[ -z $answer || $answer == [yY] || $answer == [yY][eE][sS] ]]; then
      sign_in_to_github || echo "==> GitHub sign-in: failed; run gh auth login and gh auth setup-git to push from this machine"
    else
      [[ -n ${answer:-} ]] || echo >/dev/tty
      echo "==> GitHub sign-in: skipped; run gh auth login and gh auth setup-git to push from this machine"
    fi
  fi
}

install_macelium "$@"

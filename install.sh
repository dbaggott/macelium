#!/bin/bash
# Sets up a Mac from a state repo, creating the state repo first when there
# is none (README.md, "Install"):
#   curl -fsSL https://github.com/dbaggott/macelium/releases/latest/download/install.sh | bash
# or, naming the state repo:
#   curl -fsSL https://github.com/dbaggott/macelium/releases/latest/download/install.sh | bash -s <owner>/<repo>|<git URL> [<path>]
#
# Bash reads this script from the pipe as it runs it, so the whole of it is
# one function, called on the last line, and every step that can prompt
# reads /dev/tty, since stdin is the pipe. Each step is skipped when it is
# already done, so running it again picks up where it stopped. Written for
# the bash macOS ships, 3.2.

install_macelium() {
  set -uo pipefail
  local usage='usage: curl -fsSL https://github.com/dbaggott/macelium/releases/latest/download/install.sh | bash [-s <owner>/<repo>|<git URL> [<path>]]'
  local sign_in_needs='needs a personal access token or a registered SSH key, since account passwords are refused over HTTPS; git asks for what it needs'

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

  # The state repo: its host, whether that is GitHub, its path there, which
  # GitHub's names compare in any case, the URL to clone, and how to name it.
  local host github repo_path url name
  # Takes <owner>/<repo>, meaning GitHub, or a git URL, and sets the state
  # repo's fields from it. Fails for anything else.
  set_repo() {
    if [[ $1 =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
      host=github.com repo_path=${1%.git} url=https://github.com/${1%.git}
    elif parse_git_url "$1"; then
      host=$url_host repo_path=$url_path url=$1
    else
      return 1
    fi
    github=no name=$url
    if [[ $(lower "$host") == github.com ]]; then
      github=yes name=$repo_path
      [[ $repo_path =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]
    fi
  }

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

  # Prints where the state repo goes when no path is given: in the first of
  # the directories people keep code in that this Mac has, else the home
  # directory.
  default_path() {
    local dir
    for dir in Developer git src code Projects; do
      if [[ -d $HOME/$dir ]]; then
        printf '%s\n' "$HOME/$dir/${repo_path##*/}"
        return
      fi
    done
    printf '%s\n' "$HOME/${repo_path##*/}"
  }

  # Sets path_state to what the path holds: empty, when it is missing or an
  # empty directory; named, a repo whose remote names the state repo;
  # unpushed, a repo with macelium.conf and no remote, as macelium init
  # leaves it; else other. A repo counts only at its top level.
  local path path_state
  read_path_state() {
    local remote
    path_state=other
    if [[ ! -e $path ]] || [[ -d $path && -z $(ls -A "$path") ]]; then
      path_state=empty
    elif [[ -d $path && $(git -C "$path" rev-parse --show-toplevel 2>/dev/null) == "$(cd "$path" && pwd -P)" ]]; then
      remote=$(git -C "$path" config --get remote.origin.url)
      if [[ -n $remote ]]; then
        if names_state_repo "$remote"; then path_state=named; fi
      elif [[ -f $path/macelium.conf ]]; then
        path_state=unpushed
      fi
    fi
  }

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
    before=$(macelium --version)
    if ! with_spinner "Checking for a newer macelium" brew upgrade dbaggott/tap/macelium; then
      echo "install.sh: stopped: brew upgrade dbaggott/tap/macelium failed" >&2
      return 1
    fi
    after=$(macelium --version)
    if [[ $after == "$before" ]]; then
      echo "==> macelium: already installed, the latest version (${after#macelium })"
    else
      echo "==> macelium: upgraded from ${before#macelium } to ${after#macelium }"
    fi
  }

  # Installs Homebrew and macelium, each unless it already is, and upgrades
  # a macelium already installed to the latest.
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

  # Sets login to the account gh is signed in to GitHub as, failing when it
  # is signed in to none.
  local login
  read_login() {
    login=$(gh api user --jq .login 2>/dev/null) && [[ -n $login ]]
  }

  # Runs gh's browser sign-in to GitHub, which adds the account to any gh is
  # already signed in to and makes it the active one.
  gh_auth_login() {
    gh auth login --hostname github.com --git-protocol https --web </dev/tty || {
      echo "install.sh: gh auth login failed" >&2
      return 1
    }
  }

  # Signs in to GitHub with gh, unless it is, has git use it, and says who
  # it is signed in as, once a run. Sets login.
  local signed_in=no
  sign_in_to_github() {
    [[ $signed_in == no ]] || return 0
    if ! gh auth status --hostname github.com >/dev/null 2>&1; then
      echo "==> Signing in to GitHub"
      gh_auth_login || return 1
    fi
    gh auth setup-git --hostname github.com || {
      echo "install.sh: gh auth setup-git failed" >&2
      return 1
    }
    if ! read_login; then
      echo "install.sh: gh api user did not say who is signed in" >&2
      return 1
    fi
    echo "==> Signed in to GitHub as $login"
    signed_in=yes
  }

  # The prompts. Each reads one line of the terminal, and fails at
  # end-of-file, even after a partly typed reply, so a run whose terminal has
  # gone away stops at a question and takes no at an offer, rather than guess
  # (README.md, "Install").

  # Takes a question and its default, which may be empty. Sets answer to the
  # reply, or to the default when the reply is empty. At end-of-file, says
  # the run stopped.
  local answer
  ask() {
    local hint=''
    [[ -n $2 ]] && hint=" [$2]"
    printf '%s%s: ' "$1" "$hint" >/dev/tty
    if ! read -r answer </dev/tty; then
      echo >/dev/tty
      echo "install.sh: stopped: no answer" >&2
      return 1
    fi
    [[ -n $answer ]] || answer=$2
  }

  # Takes a question, the number of the default choice or nothing, and two
  # choices. Asks until the reply is 1 or 2, or empty with a default, and
  # sets choice to it.
  local choice
  choose() {
    printf '%s\n  1) %s\n  2) %s\n' "$1" "$3" "$4" >/dev/tty
    while true; do
      ask "Choose 1 or 2" "$2" || return 1
      if [[ $answer == [12] ]]; then
        choice=$answer
        return 0
      fi
    done
  }

  # Takes a yes-or-no question and its default, yes or no. Sets yes to the
  # reply, or to the default when the reply is empty. Fails at end-of-file,
  # for the caller to stop or take no.
  local yes
  ask_yes() {
    local reply hint='[y/N]'
    [[ $2 == no ]] || hint='[Y/n]'
    printf '%s %s ' "$1" "$hint" >/dev/tty
    if ! read -r reply </dev/tty; then
      echo >/dev/tty
      return 1
    fi
    case $reply in
      '') yes=$2 ;;
      [yY] | [yY][eE][sS]) yes=yes ;;
      *) yes=no ;;
    esac
  }

  # Takes the question. Sets path to the answer to where the state repo
  # goes, R5's default offered, with a leading ~ expanded and a relative path
  # made absolute. A directory to hold it that is missing is created on a
  # yes, and a no asks again.
  ask_path() {
    local parent
    while true; do
      ask "$1" "$(default_path)" || return 1
      path=$answer
      # shellcheck disable=SC2088 # the reply's ~, not the shell's
      if [[ $path == "~" || $path == "~/"* ]]; then path=$HOME${path#\~}; fi
      [[ $path == /* ]] || path=$PWD/$path
      parent=$(dirname "$path")
      [[ ! -d $parent ]] || return 0
      if ! ask_yes "The path $parent does not exist, should I create it?" yes; then
        echo "install.sh: stopped: no answer" >&2
        return 1
      fi
      [[ $yes == yes ]] || continue
      mkdir -p "$parent" && return 0
      echo "install.sh: could not create $parent" >/dev/tty
    done
  }

  # Prints the line saying how a host other than GitHub signs in, once a run.
  local told_sign_in=no
  tell_sign_in() {
    [[ $told_sign_in == no ]] || return 0
    echo "==> $1 sign-in: $sign_in_needs"
    told_sign_in=yes
  }

  # Finds the state repo set_repo named, setting found to refs, empty (a repo
  # with no refs) or missing, and public to yes when git reads it without a
  # sign-in. On GitHub it reads anonymously, then, unless given anonymous,
  # signs in and asks gh; elsewhere it reads with git, and a repo git can't
  # read stops the run.
  local found public
  find_repo() {
    local refs view
    found=missing public=no
    if [[ $github == yes ]]; then
      # No credential helper, so a gh signed in before this run can't make a
      # private repo read as public. Once this run has signed in, gh decides.
      if [[ $signed_in == no ]] &&
        refs=$(GIT_TERMINAL_PROMPT=0 git -c credential.helper= ls-remote "https://github.com/$repo_path" 2>/dev/null); then
        public=yes found=refs
        [[ -n $refs ]] || found=empty
        return 0
      fi
      [[ ${1:-} != anonymous ]] || return 0
      sign_in_to_github || {
        echo "install.sh: stopped: looking for $name needs a GitHub sign-in" >&2
        return 1
      }
      # Only gh's not-found error means there is no repo; any other, such as
      # a network failure, stops rather than offer to create one.
      if ! view=$(gh repo view "$repo_path" --json isEmpty,visibility --jq '"\(.isEmpty) \(.visibility)"' 2>&1); then
        [[ $view == *"Could not resolve to a Repository"* ]] && return 0
        printf '%s\n' "$view" >&2
        echo "install.sh: stopped: gh repo view $repo_path failed" >&2
        return 1
      fi
      found=refs
      [[ $view != true* ]] || found=empty
      [[ $view != *PUBLIC ]] || public=yes
      return 0
    fi
    tell_sign_in "$host"
    if ! refs=$(git ls-remote "$url" </dev/tty); then
      echo "install.sh: stopped: git can't read $url. $host sign-in: $sign_in_needs" >&2
      return 1
    fi
    found=refs
    [[ -n $refs ]] || found=empty
  }

  # Takes whether to offer the GitHub sign-in after the bootstrap, and
  # whether the path already holds the clone. Clones the state repo to the
  # path, unless it does, and bootstraps it.
  clone_and_bootstrap() {
    if [[ $2 == yes ]]; then
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
    if [[ $1 == yes ]] && ! gh auth status --hostname github.com >/dev/null 2>&1; then
      if ask_yes "Sign in to GitHub with gh, so you can push changes from this machine?" yes && [[ $yes == yes ]]; then
        sign_in_to_github || echo "==> GitHub sign-in: failed; run gh auth login and gh auth setup-git to push from this machine"
      else
        echo "==> GitHub sign-in: skipped; run gh auth login and gh auth setup-git to push from this machine"
      fi
    fi
  }

  # The no-argument form's clone: offers the clone at the default path when
  # there is one, unless given ask, else asks the path, then clones and
  # bootstraps, offering the sign-in after when GitHub read the repo without
  # one.
  clone_asked_path() {
    if [[ ${1:-} != ask ]]; then
      path=$(default_path)
      read_path_state
      if [[ $path_state == named ]]; then
        if ! ask_yes "It is already cloned at $path. Set up this Mac from that clone?" yes; then
          echo "install.sh: stopped: no answer" >&2
          return 1
        fi
        if [[ $yes == yes ]]; then
          clone_and_bootstrap "$public" yes
          return
        fi
      fi
    fi
    ask_path "Where do you want to clone the state repo?" || return 1
    read_path_state
    case $path_state in
      empty) clone_and_bootstrap "$public" no ;;
      named) clone_and_bootstrap "$public" yes ;;
      *)
        echo "install.sh: $path holds something other than a clone of $name: run install.sh again and answer another path" >&2
        return 1
        ;;
    esac
  }

  # Pushes the state repo's branch to its remote, setting its upstream.
  push_state_repo() {
    echo "==> Pushing $path to $name"
    git -C "$path" push -u origin HEAD </dev/tty || {
      echo "install.sh: stopped: git push to $name failed" >&2
      return 1
    }
  }

  # Takes --private or --public. Creates the state repo on GitHub from the
  # path, pushing it.
  gh_repo_create() {
    echo "==> gh repo create $repo_path $1 --source $path --push"
    gh repo create "$repo_path" "$1" --source "$path" --push </dev/tty
  }

  # Creates the state repo on GitHub from the path and pushes it. A private
  # repo GitHub refuses is offered as a public one, no by default.
  create_on_github() {
    local visibility=--private
    [[ $public == no ]] || visibility=--public
    gh_repo_create "$visibility" && return 0
    if gh repo view "$repo_path" >/dev/null 2>&1; then
      echo "install.sh: stopped: gh created $repo_path but did not push to it; run install.sh again to push" >&2
      return 1
    fi
    if [[ $visibility == --private ]]; then
      if ask_yes "GitHub did not create a private repo, for the reason above. Create a public one, which anyone can read, everything captured in it included?" no &&
        [[ $yes == yes ]]; then
        gh_repo_create --public && return 0
      fi
    fi
    echo "install.sh: stopped: gh repo create $repo_path failed" >&2
    return 1
  }

  # Takes new, for a GitHub repo to create, or existing, for a repo with no
  # refs. Asks the path, captures this Mac there with macelium init, pushes
  # it, and bootstraps it, each step skipped when the path shows it done.
  create_state_repo() {
    if [[ $github == yes ]] && ! sign_in_to_github; then
      echo "install.sh: stopped: pushing to $name needs a GitHub sign-in" >&2
      return 1
    fi
    ask_path "Where do you want to keep the new state repo?" || return 1
    read_path_state
    # A clone of the empty repo has nothing to push, and init refuses it.
    if [[ $path_state == named ]] && ! git -C "$path" rev-parse -q --verify HEAD >/dev/null; then
      path_state=other
    fi
    if [[ $path_state == other ]]; then
      echo "install.sh: $path holds something other than a new state repo for $name: run install.sh again and answer another path" >&2
      return 1
    fi
    if [[ $1 == new && $path_state == named ]]; then
      echo "install.sh: stopped: $path's remote names $name, which GitHub does not have: run git -C $path remote remove origin, then install.sh again, to create it" >&2
      return 1
    fi
    if [[ $1 == new ]]; then
      choose "Who can read the new repo?" 1 "only you (private)" "anyone (public), including everything init captures" || return 1
      public=no
      [[ $choice == 1 ]] || public=yes
    fi

    if [[ $path_state == empty ]]; then
      echo
      echo "Macelium will now record your computer's current setup, this includes: your"
      echo "Homebrew applications and, if you choose, your git, shell and mise settings."
      echo "You'll be asked a few questions about what to include. Nothing is installed or"
      echo "changed on your computer during this step."
      echo
      if [[ $public == yes ]]; then
        echo "==> macelium init --public $path"
        macelium init --public "$path" </dev/tty
      else
        echo "==> macelium init $path"
        macelium init "$path" </dev/tty
      fi || {
        echo "install.sh: stopped: macelium init failed" >&2
        return 1
      }
    else
      echo "==> macelium init: $path already holds the new state repo"
    fi

    if [[ $1 == new ]]; then
      create_on_github || return 1
    else
      if [[ $path_state != named ]] && ! git -C "$path" remote add origin "$url"; then
        echo "install.sh: stopped: git remote add origin $url failed" >&2
        return 1
      fi
      push_state_repo || return 1
    fi

    echo "==> macelium bootstrap $path"
    macelium bootstrap "$path" </dev/tty
  }

  # Takes new, the step for a state repo find_repo found missing: create, or
  # stop. Goes on from what find_repo found.
  go_on_from_found() {
    case $found in
      refs) clone_asked_path "${1:-}" ;;
      empty) create_state_repo existing ;;
      *)
        if [[ ${1:-} == new ]]; then
          create_state_repo new
        else
          echo "install.sh: stopped: found no repo $name to read" >&2
          return 1
        fi
        ;;
    esac
  }

  # Asks for the state repo by name or URL, then goes on as the argument form
  # does for it.
  ask_repo() {
    while true; do
      ask "Your state repo, as <owner>/<repo> on GitHub or a git URL" "" || return 1
      set_repo "$answer" && break
      echo "install.sh: that is neither <owner>/<repo> nor a git URL" >/dev/tty
    done
    find_repo || return 1
    go_on_from_found
  }

  # With no argument: asks where the state repo is, finds it, and clones it,
  # or creates it when there is none (README.md, "Install").
  guided_install() {
    has_terminal && install_tools || return 1
    printf '\n\nWelcome to Macelium!  You will now be guided through the setup.\n\n' >/dev/tty
    choose "What source control provider do you want to use for managing your environment?" 1 "GitHub" "another git provider" || return 1
    if [[ $choice == 2 ]]; then
      tell_sign_in "Git host"
      while true; do
        ask "The state repo's git URL" "" || return 1
        set_repo "$answer" && break
        echo "install.sh: that is not a git URL" >/dev/tty
      done
      find_repo || return 1
      go_on_from_found
      return
    fi

    if gh auth status --hostname github.com >/dev/null 2>&1 && read_login; then
      confirm_signed_in || return 1
    else
      ask_username || return
      [[ $went_on == no ]] || return 0
    fi

    set_repo "$login/macelium-state"
    find_repo || return 1
    case $found in
      refs) echo "Found $url." ;;
      empty) echo "Found $url, with nothing in it yet." ;;
      *)
        choose "No macelium-state repo found for $login. Are you setting this up for the first time, or is your repo named something else?" '' \
          "first time: capture this Mac into a new $login/macelium-state" "something else: give its name or URL" || return 1
        if [[ $choice == 1 ]]; then go_on_from_found new; else ask_repo; fi
        return
        ;;
    esac
    go_on_from_found
  }

  # With gh signed in already: says as whom, and asks whether to go on as
  # that account or sign in to another, then signs in.
  confirm_signed_in() {
    echo "gh is signed in to GitHub as $login."
    choose "Continue as $login?" 1 "yes" "no, sign in to another account" || return 1
    if [[ $choice == 2 ]]; then
      echo "==> Signing in to GitHub"
      gh_auth_login || return 1
    fi
    sign_in_to_github
  }

  # With gh signed out: asks the GitHub username. With none, has the user
  # create an account first; with one, looks for its macelium-state without
  # signing in, and on finding it, goes on from there, setting went_on.
  # Otherwise signs in, and when the account is not the one named, asks
  # whether to sign in as it or go on.
  local went_on=no
  ask_username() {
    local user
    while true; do
      ask "GitHub username (empty if you do not have an account yet)" "" || return 1
      user=$answer
      [[ -z $user || $user =~ ^[A-Za-z0-9-]+$ ]] && break
      echo "install.sh: that is not a GitHub username" >/dev/tty
    done
    if [[ -z $user ]]; then
      echo "You'll need a GitHub account. Opening https://github.com/signup in your browser."
      open https://github.com/signup 2>/dev/null
      if ! ask "Create the account there, then come back and press Enter to sign in" ""; then
        return 1
      fi
    else
      set_repo "$user/macelium-state"
      find_repo anonymous
      if [[ $found != missing ]]; then
        went_on=yes
        found_without_sign_in
        return
      fi
      echo "No public $user/macelium-state found; signing in to look for a private one."
    fi
    sign_in_to_github || {
      echo "install.sh: stopped: finding your state repo needs a GitHub sign-in" >&2
      return 1
    }
    [[ -n $user && $(lower "$login") != "$(lower "$user")" ]] || return 0
    choose "gh is signed in as $login, not $user." 1 "sign in as $user" "continue as $login" || return 1
    [[ $choice == 1 ]] || return 0
    echo "==> Signing in to GitHub as $user"
    echo "    ($login stays signed in too; gh auth switch moves between them)"
    gh_auth_login || return 1
    signed_in=no
    sign_in_to_github || return 1
    if [[ $(lower "$login") != "$(lower "$user")" ]]; then
      echo "install.sh: stopped: signed in as $login, not $user" >&2
      return 1
    fi
  }

  # The state repo find_repo found without a sign-in: confirms it, offering
  # a clone of it at the default path, then goes on from it, or asks for
  # another repo.
  found_without_sign_in() {
    local question="Set up this Mac from it?" cloned=no
    if [[ $found == refs ]]; then
      echo "Found $url."
      path=$(default_path)
      read_path_state
      if [[ $path_state == named ]]; then
        cloned=yes question="It is already cloned at $path. Set up this Mac from that clone?"
      fi
    else
      echo "Found $url, with nothing in it yet."
      question="Capture this Mac into it?"
    fi
    if ! ask_yes "$question" yes; then
      echo "install.sh: stopped: no answer" >&2
      return 1
    fi
    if [[ $cloned == yes ]]; then
      if [[ $yes == yes ]]; then clone_and_bootstrap "$public" yes; else clone_asked_path ask; fi
    elif [[ $yes == yes ]]; then
      go_on_from_found ask
    else
      ask_repo
    fi
  }

  if (($# == 0)); then
    guided_install
    return
  fi

  if (($# > 2)) || ! set_repo "$1"; then
    echo "$usage" >&2
    return 1
  fi
  path=${2:-$(default_path)}
  echo "==> Path: $path"

  # The path is checked before anything is installed, so a wrong one changes
  # nothing. Empty, or missing, it is cloned to; a clone of the state repo is
  # used as it is.
  local cloned=no
  read_path_state
  case $path_state in
    empty) ;;
    named) cloned=yes ;;
    *)
      echo "install.sh: $path holds something other than a clone of $name: name another path, as the second argument" >&2
      return 1
      ;;
  esac
  has_terminal && install_tools || return 1

  # A GitHub repo is probed over HTTPS, whatever form names it, since that
  # is what an anonymous read and gh's sign-in both use.
  local offer_sign_in=no
  if [[ $github == no ]]; then
    if [[ $cloned == no ]]; then
      tell_sign_in "$host"
    fi
  elif GIT_TERMINAL_PROMPT=0 git ls-remote "https://github.com/$repo_path" >/dev/null 2>&1; then
    echo "==> GitHub sign-in: not needed, git can read $name"
    offer_sign_in=yes
  elif ! sign_in_to_github; then
    echo "install.sh: stopped: git can't read $name without a GitHub sign-in" >&2
    return 1
  fi
  clone_and_bootstrap "$offer_sign_in" "$cloned"
}

install_macelium "$@"

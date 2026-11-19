# shellcheck shell=bash disable=SC2154,SC2034 # tests/lib.sh sets tool, sandbox and state, and reads out, err and status
# install.sh, with Homebrew and macelium stubbed and the state repo's GitHub
# URL pointed at a local one.

installer=$(dirname "$tool")/install.sh

# Takes install.sh's arguments. Runs it with no terminal, as run does.
run_installer() {
  out=$sandbox/out err=$sandbox/err
  bash "$installer" "$@" >"$out" 2>"$err" </dev/null
  status=$?
}

# A state repo that https://github.com/example/state clones, and so do
# https://git.example.org/me/state and its SSH forms; a brew whose
# `list` fails until `install` has run, and whose `upgrade` fails when
# $STUB_BREW_UPGRADE_FAILS is set and otherwise moves macelium to
# $STUB_MACELIUM_LATEST when that is set; a gh that records its call and fails,
# so a test never signs in; and a macelium that prints its version for
# --version, 1.0.0 until an upgrade, and otherwise records its call and
# whether stdin is a terminal, and exits $STUB_MACELIUM_STATUS.
installable_state() {
  make_state macelium.conf $'contract 1\n'
  local form
  for form in https://github.com/example/state https://git.example.org/me/state \
    ssh://git@git.example.org/me/state git@git.example.org:me/state; do
    git config --global --add url."file://$sandbox/state.git".insteadOf "$form"
  done
  cat >"$sandbox/bin/macelium" <<'STUB'
#!/bin/bash
if [[ $1 == --version ]]; then
  echo "macelium $(cat "$STUB_LOG.version" 2>/dev/null || echo 1.0.0)"
  exit
fi
tty=no
[[ -t 0 ]] && tty=yes
echo "macelium $* tty=$tty" >>"$STUB_LOG"
exit "${STUB_MACELIUM_STATUS:-0}"
STUB
  cat >"$sandbox/bin/brew" <<'STUB'
#!/bin/bash
echo "brew $*" >>"$STUB_LOG"
case $1 in
  install) touch "$STUB_LOG.installed" ;;
  list) [[ -e $STUB_LOG.installed ]] ;;
  upgrade)
    if [[ -n ${STUB_BREW_UPGRADE_FAILS:-} ]]; then
      echo "Error: the upgrade failed" >&2
      exit 1
    fi
    [[ -z ${STUB_MACELIUM_LATEST:-} ]] || echo "$STUB_MACELIUM_LATEST" >"$STUB_LOG.version"
    ;;
esac
STUB
  cat >"$sandbox/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >>"$STUB_LOG"
exit 1
STUB
  chmod +x "$sandbox/bin/macelium" "$sandbox/bin/brew" "$sandbox/bin/gh"
}

test_install_refuses_without_a_repo() {
  local args
  for args in "state" "example/state/extra" "example/" "example/state $sandbox/a $sandbox/b" \
    https://github.com/example/state/extra git@github.com:example https://git.example.org/ ftp://git.example.org/me/state; do
    # shellcheck disable=SC2086 # each case is its words
    run_installer $args
    assert_status 1
    assert_contains "$err" "usage: curl -fsSL"
  done
}

test_install_with_no_argument_needs_a_terminal() {
  run_installer
  assert_status 1
  assert_contains "$err" "install.sh: needs a terminal for its prompts"
  [[ ! -s $STUB_LOG ]] || fail "it ran: $(cat "$STUB_LOG")"
}

test_install_refuses_a_path_holding_something_else() {
  mkdir -p "$sandbox/other"
  touch "$sandbox/other/file"
  run_installer example/state "$sandbox/other"
  assert_status 1
  assert_contains "$err" "$sandbox/other holds something other than a clone of example/state"
  [[ ! -s $STUB_LOG ]] || fail "it ran: $(cat "$STUB_LOG")"
}

test_install_refuses_a_clone_of_another_repo() {
  git init -q "$sandbox/other"
  git -C "$sandbox/other" remote add origin https://github.com/example/other.git
  run_installer example/state "$sandbox/other"
  assert_status 1
  assert_contains "$err" "holds something other than a clone of example/state"
}

test_install_installs_clones_and_bootstraps_then_resumes() {
  installable_state
  mkdir -p "$HOME/git"
  run_tty -- bash "$installer" example/state
  assert_status 0
  assert_contains "$STUB_LOG" "brew install dbaggott/tap/macelium"
  assert_contains "$out" "GitHub sign-in: not needed, git can read example/state"
  ! grep -v '^gh auth status ' "$STUB_LOG" | grep -q '^gh ' || fail "it called gh beyond auth status: $(cat "$STUB_LOG")"
  [[ -f $HOME/git/state/macelium.conf ]] || fail "not cloned to ~/git/state"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/git/state tty=yes"

  : >"$STUB_LOG"
  run_tty -- bash "$installer" example/state
  assert_status 0
  assert_contains "$out" "==> Homebrew: already installed"
  assert_contains "$out" "==> macelium: already installed, the latest version (1.0.0)"
  assert_contains "$out" "==> Clone: $HOME/git/state is already a clone of example/state"
  assert_not_contains "$STUB_LOG" "brew install"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/git/state tty=yes"
}

test_install_upgrades_an_installed_macelium_before_the_bootstrap() {
  installable_state
  touch "$STUB_LOG.installed"
  export STUB_MACELIUM_LATEST=1.1.0
  run_tty -- bash "$installer" example/state "$sandbox/clone"
  assert_status 0
  assert_contains "$out" "==> macelium: upgraded from 1.0.0 to 1.1.0"
  assert_order "$STUB_LOG" "brew upgrade dbaggott/tap/macelium" "macelium bootstrap $sandbox/clone tty=yes"
  assert_not_contains "$STUB_LOG" "brew install"
}

test_install_stops_when_the_macelium_upgrade_fails() {
  installable_state
  touch "$STUB_LOG.installed"
  export STUB_BREW_UPGRADE_FAILS=1
  run_tty -- bash "$installer" example/state "$sandbox/clone"
  assert_status 1
  assert_contains "$out" "Error: the upgrade failed"
  assert_contains "$out" "install.sh: stopped: brew upgrade dbaggott/tap/macelium failed"
  assert_not_contains "$STUB_LOG" "macelium bootstrap"
}

test_install_takes_a_path_and_a_dot_git_name_and_exits_with_the_bootstrap_status() {
  installable_state
  export STUB_MACELIUM_STATUS=3
  run_tty -- bash "$installer" example/state.git "$sandbox/elsewhere"
  assert_status 3
  assert_contains "$STUB_LOG" "macelium bootstrap $sandbox/elsewhere tty=yes"
}

test_install_accepts_owner_and_repo_and_https_ssh_and_scp_urls() {
  installable_state
  local arg n=0
  for arg in example/state https://github.com/example/state https://git.example.org/me/state \
    ssh://git@git.example.org/me/state git@git.example.org:me/state; do
    n=$((n + 1))
    : >"$STUB_LOG"
    run_tty -- bash "$installer" "$arg" "$sandbox/clone-$n"
    assert_status 0
    [[ -f $sandbox/clone-$n/macelium.conf ]] || fail "$arg: not cloned"
    assert_contains "$STUB_LOG" "macelium bootstrap $sandbox/clone-$n tty=yes"
  done
}

# Takes a remote URL and install.sh's first argument. Makes a repo with that
# remote, and runs install.sh on it with no terminal, so a path it accepts
# stops at the terminal check.
run_installer_on_clone_of() {
  rm -rf "$sandbox/clone"
  git init -q "$sandbox/clone"
  git -C "$sandbox/clone" remote add origin "$1"
  run_installer "$2" "$sandbox/clone"
}

test_install_takes_a_clone_naming_the_repo_in_another_form() {
  local pair remote arg
  for pair in "https://github.com/example/state|git@github.com:Example/State.git" \
    "ssh://git@github.com/EXAMPLE/state/|example/state" \
    "https://git.example.org/me/state|git@git.example.org:me/state" \
    "git@git.example.org:me/state.git|https://git.example.org/me/state/" \
    "ssh://other@git.example.org:2222/me/state|https://git.example.org/me/state.git"; do
    remote=${pair%%|*} arg=${pair#*|}
    run_installer_on_clone_of "$remote" "$arg"
    assert_status 1
    assert_contains "$err" "needs a terminal"
  done
}

test_install_refuses_a_clone_naming_another_case_on_another_host() {
  run_installer_on_clone_of https://git.example.org/Me/State https://git.example.org/me/state
  assert_status 1
  assert_contains "$err" "$sandbox/clone holds something other than a clone of https://git.example.org/me/state"
}

test_install_defaults_the_path_to_the_first_code_directory_else_home() {
  run_installer example/state
  assert_contains "$out" "==> Path: $HOME/state"
  mkdir -p "$HOME/Projects" "$HOME/src"
  run_installer example/state
  assert_contains "$out" "==> Path: $HOME/src/state"
  mkdir -p "$HOME/Developer"
  run_installer https://git.example.org/me/state.git
  assert_contains "$out" "==> Path: $HOME/Developer/state"
}

test_install_from_another_host_says_how_it_signs_in_and_never_calls_gh() {
  installable_state
  run_tty -- bash "$installer" https://git.example.org/me/state "$sandbox/clone"
  assert_status 0
  assert_order "$out" "==> git.example.org sign-in: needs a personal access token or a registered SSH key" \
    "==> Cloning https://git.example.org/me/state to $sandbox/clone"
  assert_not_contains "$STUB_LOG" "gh "
}

test_install_offers_a_github_sign_in_after_the_bootstrap_and_takes_end_of_file_as_no() {
  installable_state
  run_tty -- bash "$installer" example/state "$sandbox/clone"
  assert_status 0
  assert_order "$out" "==> macelium bootstrap" \
    "Sign in to GitHub with gh, so you can push changes from this machine? [Y/n]" \
    "==> GitHub sign-in: skipped"
  assert_not_contains "$STUB_LOG" "gh auth login"
}

test_install_signs_in_after_the_bootstrap_on_yes_and_survives_its_failure() {
  installable_state
  run_tty y -- bash "$installer" example/state "$sandbox/clone"
  assert_order "$STUB_LOG" "macelium bootstrap" "gh auth login"
  # The gh stub fails, which the Mac, already set up, survives.
  assert_status 0
  assert_order "$out" "install.sh: gh auth login failed" "==> GitHub sign-in: failed"
}

test_install_signs_in_before_the_clone_when_github_refuses_an_anonymous_read() {
  installable_state
  git config --global url."file://$sandbox/missing.git".insteadOf https://github.com/example/private
  run_tty -- bash "$installer" example/private "$sandbox/clone"
  assert_status 1
  assert_contains "$out" "==> Signing in to GitHub"
  assert_contains "$STUB_LOG" "gh auth login"
  assert_contains "$out" "install.sh: stopped: git can't read example/private without a GitHub sign-in"
  assert_not_contains "$out" "==> Cloning"
  assert_not_contains "$STUB_LOG" "macelium bootstrap"
}

# The no-argument form.

# A Mac for the no-argument form, on top of installable_state's. GitHub's
# repos are bare repos under $sandbox/github, <owner>/<repo>.git, which git
# reads at their GitHub URL without a sign-in when github_repo makes them
# public, and after gh auth setup-git otherwise; any other GitHub URL reads
# nothing. gh is signed out until auth login, which signs in as the next of
# the logins $STUB_GH_LOGIN lists, the last again once they run out, and
# fails when it is unset; sign_in_as signs it in before a run. Its repo create
# refuses --private when $STUB_GH_PRIVATE_REFUSED is set, and creates the
# repo but fails to push to it when $STUB_GH_PUSH_FAILS is; its repo view
# fails as on a network error when $STUB_GH_VIEW_FAILS is. macelium's init
# writes a repo with macelium.conf and one commit, as the real one does.
guided_mac() {
  installable_state
  mkdir -p "$sandbox/github"
  git config --global url."file://$sandbox/nowhere/".insteadOf https://github.com/
  cat >"$sandbox/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >>"$STUB_LOG"
root=$(dirname "$STUB_LOG")/github signed=$STUB_LOG.signed-in
# Takes <owner>/<repo>, and has git read its bare repo at its GitHub URL.
expose() {
  git config --global url."file://$root/$1.git".insteadOf "https://github.com/$1"
}
case "$1 ${2:-}" in
  "auth status") [[ -e $signed ]] ;;
  "auth login")
    [[ -n ${STUB_GH_LOGIN:-} ]] || exit 1
    n=$(($(cat "$STUB_LOG.logins" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$STUB_LOG.logins"
    read -ra logins <<<"$STUB_GH_LOGIN"
    ((n <= ${#logins[@]})) || n=${#logins[@]}
    printf '%s\n' "${logins[n - 1]}" >"$signed"
    ;;
  "auth setup-git")
    for repo in "$root"/*/*.git; do
      [[ -e $repo ]] || continue
      repo=${repo#"$root"/}
      expose "${repo%.git}"
    done
    ;;
  "api user") [[ -e $signed ]] && cat "$signed" ;;
  "repo view")
    [[ -e $signed ]] || exit 1
    [[ -z ${STUB_GH_VIEW_FAILS:-} ]] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    if [[ ! -d $root/$3.git ]]; then
      echo "GraphQL: Could not resolve to a Repository with the name '$3'. (repository)" >&2
      exit 1
    fi
    empty=true visibility=PRIVATE
    [[ -z $(git -C "$root/$3.git" for-each-ref) ]] || empty=false
    [[ ! -e $root/$3.public ]] || visibility=PUBLIC
    [[ ${4:-} != --json ]] || echo "$empty $visibility"
    ;;
  "repo create")
    # gh repo create <name> --private|--public --source <dir> --push
    if [[ $4 == --private && -n ${STUB_GH_PRIVATE_REFUSED:-} ]]; then
      echo "GraphQL: private repositories are not available on this plan" >&2
      exit 1
    fi
    git init -q --bare "$root/$3.git"
    [[ $4 != --public ]] || touch "$root/$3.public"
    expose "$3"
    git -C "$6" remote add origin "https://github.com/$3"
    [[ -z ${STUB_GH_PUSH_FAILS:-} ]] || exit 1
    git -C "$6" push -q -u origin HEAD
    ;;
  *) exit 1 ;;
esac
STUB
  cat >"$sandbox/bin/macelium" <<'STUB'
#!/bin/bash
if [[ $1 == --version ]]; then
  echo "macelium $(cat "$STUB_LOG.version" 2>/dev/null || echo 1.0.0)"
  exit
fi
tty=no
[[ -t 0 ]] && tty=yes
echo "macelium $* tty=$tty" >>"$STUB_LOG"
if [[ $1 == init ]]; then
  path=${!#}
  mkdir -p "$path" && printf 'contract 1\n' >"$path/macelium.conf" && git init -q -b main "$path" &&
    git -C "$path" add -A && git -C "$path" -c user.name=init -c user.email=init@example.com commit -q -m init
  exit
fi
exit "${STUB_MACELIUM_STATUS:-0}"
STUB
  chmod +x "$sandbox/bin/gh" "$sandbox/bin/macelium"
  unset STUB_GH_LOGIN STUB_GH_PRIVATE_REFUSED STUB_GH_PUSH_FAILS STUB_GH_VIEW_FAILS
}

# Takes a login, and has gh signed in as it, as before install.sh runs.
sign_in_as() {
  printf '%s\n' "$1" >"$STUB_LOG.signed-in"
}

# Takes <owner>/<repo>, then public or private, then empty, for a repo with
# no refs, or nothing, for a copy of the state repo. Makes it on the GitHub
# guided_mac fakes.
github_repo() {
  local bare=$sandbox/github/$1.git
  mkdir -p "$(dirname "$bare")"
  if [[ ${3:-} == empty ]]; then
    git init -q --bare "$bare"
  else
    git clone -q --bare "$sandbox/state.git" "$bare"
  fi
  if [[ $2 == public ]]; then
    touch "$sandbox/github/$1.public"
    git config --global url."file://$bare".insteadOf "https://github.com/$1"
  fi
}

# Takes <owner>/<repo>, a private repo on the GitHub guided_mac fakes, and
# has git no longer read it, as on a fresh run, before gh auth setup-git.
forget_private_repo() {
  git config --global --remove-section url."file://$sandbox/github/$1.git"
}

# Takes a bare repo, and fails the test unless it has a ref.
assert_pushed() {
  [[ -n $(git -C "$1" for-each-ref) ]] || fail "nothing pushed to $1"
}

# Takes a checkout, and fails the test unless its branch has an upstream.
assert_upstream() {
  git -C "$1" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || fail "$1's branch has no upstream"
}

test_guided_finds_a_public_github_repo_with_no_sign_in() {
  guided_mac
  github_repo me/macelium-state public
  mkdir -p "$HOME/Developer"
  run_tty '' me '' '' n -- bash "$installer"
  assert_status 0
  # The terminal shows each prompt on the line its answer's echo ends, so the
  # prompts are checked for, not their order.
  assert_order "$out" "Welcome to Macelium!  You will now be guided through the setup." \
    "What source control provider do you want to use for managing your environment?" "1) GitHub" "2) another git provider"
  assert_contains "$out" "GitHub username (empty if you do not have an account yet):"
  assert_contains "$out" "Found https://github.com/me/macelium-state."
  assert_contains "$out" "Set up this Mac from it? [Y/n]"
  assert_contains "$out" "Where do you want to clone the state repo? [$HOME/Developer/macelium-state]:"
  assert_order "$out" "==> Cloning me/macelium-state to $HOME/Developer/macelium-state" \
    "==> macelium bootstrap $HOME/Developer/macelium-state" \
    "Sign in to GitHub with gh, so you can push changes from this machine? [Y/n]"
  [[ -f $HOME/Developer/macelium-state/macelium.conf ]] || fail "not cloned"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/Developer/macelium-state tty=yes"
  assert_not_contains "$STUB_LOG" "gh auth login"
  assert_not_contains "$STUB_LOG" "gh repo"
}

test_guided_asks_for_another_repo_when_the_found_one_is_declined() {
  guided_mac
  github_repo me/macelium-state public
  github_repo me/dotfiles public
  run_tty '' me n me/dotfiles '' n -- bash "$installer"
  assert_status 0
  assert_contains "$out" "Your state repo, as <owner>/<repo> on GitHub or a git URL:"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/dotfiles tty=yes"
}

test_guided_finds_a_private_github_repo_after_the_sign_in() {
  guided_mac
  export STUB_GH_LOGIN=me
  github_repo me/macelium-state private
  run_tty '' me '' -- bash "$installer"
  assert_status 0
  assert_order "$STUB_LOG" "gh auth login" "gh auth setup-git" "gh api user" "gh repo view me/macelium-state" \
    "macelium bootstrap $HOME/macelium-state tty=yes"
  assert_order "$out" "No public me/macelium-state found; signing in to look for a private one." \
    "==> Signed in to GitHub as me" "Found https://github.com/me/macelium-state."
  assert_not_contains "$out" "so you can push changes from this machine"
  [[ -f $HOME/macelium-state/macelium.conf ]] || fail "not cloned"
}

test_guided_has_an_account_created_with_no_username() {
  guided_mac
  export STUB_GH_LOGIN=me
  github_repo me/macelium-state private
  run_tty '' '' '' '' -- bash "$installer"
  assert_status 0
  assert_order "$out" "You'll need a GitHub account. Opening https://github.com/signup in your browser." \
    "Create the account there, then come back and press Enter to sign in" "==> Signed in to GitHub as me"
  assert_order "$STUB_LOG" "open https://github.com/signup" "gh auth login" "gh api user"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/macelium-state tty=yes"
}

test_guided_takes_another_name_when_none_is_found() {
  guided_mac
  export STUB_GH_LOGIN=me
  github_repo me/dotfiles private
  run_tty '' me 2 me/dotfiles '' -- bash "$installer"
  assert_status 0
  assert_order "$out" \
    "No macelium-state repo found for me. Are you setting this up for the first time, or is your repo named something else?" \
    "1) first time: capture this Mac into a new me/macelium-state" "2) something else: give its name or URL"
  assert_contains "$out" "Where do you want to clone the state repo? [$HOME/dotfiles]:"
  [[ -f $HOME/dotfiles/macelium.conf ]] || fail "not cloned"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/dotfiles tty=yes"
}

test_guided_creates_a_private_github_repo_the_first_time_then_resumes_at_the_bootstrap() {
  guided_mac
  export STUB_GH_LOGIN=me
  run_tty '' me 1 '' '' -- bash "$installer"
  assert_status 0
  assert_order "$out" "Who can read the new repo?" "1) only you (private)" "2) anyone (public), including everything init captures"
  assert_order "$STUB_LOG" "macelium init $HOME/macelium-state tty=yes" \
    "gh repo create me/macelium-state --private --source $HOME/macelium-state --push" \
    "macelium bootstrap $HOME/macelium-state tty=yes"
  assert_pushed "$sandbox/github/me/macelium-state.git"
  assert_upstream "$HOME/macelium-state"
  [[ ! -e $sandbox/github/me/macelium-state.public ]] || fail "created public"

  forget_private_repo me/macelium-state
  : >"$STUB_LOG"
  run_tty '' '' '' -- bash "$installer"
  assert_status 0
  assert_contains "$out" "==> Clone: $HOME/macelium-state is already a clone of me/macelium-state"
  assert_not_contains "$STUB_LOG" "macelium init"
  assert_not_contains "$STUB_LOG" "gh repo create"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/macelium-state tty=yes"
}

test_guided_creates_a_public_github_repo() {
  guided_mac
  export STUB_GH_LOGIN=me
  run_tty '' me 1 '' 2 -- bash "$installer"
  assert_status 0
  assert_order "$STUB_LOG" "macelium init --public $HOME/macelium-state tty=yes" \
    "gh repo create me/macelium-state --public --source $HOME/macelium-state --push" \
    "macelium bootstrap $HOME/macelium-state tty=yes"
  [[ -e $sandbox/github/me/macelium-state.public ]] || fail "not created public"
}

test_guided_offers_public_when_github_refuses_a_private_repo() {
  guided_mac
  export STUB_GH_LOGIN=me STUB_GH_PRIVATE_REFUSED=1
  run_tty '' me 1 '' '' y -- bash "$installer"
  assert_status 0
  assert_order "$out" "GraphQL: private repositories are not available on this plan" \
    "GitHub did not create a private repo, for the reason above. Create a public one, which anyone can read, everything captured in it included? [y/N]"
  assert_order "$STUB_LOG" "gh repo create me/macelium-state --private" "gh repo create me/macelium-state --public" \
    "macelium bootstrap $HOME/macelium-state tty=yes"
  assert_pushed "$sandbox/github/me/macelium-state.git"
}

test_guided_stops_when_public_is_declined_after_github_refuses_private() {
  guided_mac
  export STUB_GH_LOGIN=me STUB_GH_PRIVATE_REFUSED=1
  run_tty '' me 1 '' '' "$eof" "$eof" -- bash "$installer"
  assert_status 1
  assert_contains "$out" "install.sh: stopped: gh repo create me/macelium-state failed"
  assert_not_contains "$STUB_LOG" "--public"
  assert_not_contains "$STUB_LOG" "macelium bootstrap"
}

test_guided_resumes_at_the_push_when_gh_created_the_repo_but_did_not_push() {
  guided_mac
  export STUB_GH_LOGIN=me STUB_GH_PUSH_FAILS=1
  run_tty '' me 1 '' '' -- bash "$installer"
  assert_status 1
  assert_contains "$out" "install.sh: stopped: gh created me/macelium-state but did not push to it; run install.sh again to push"
  assert_not_contains "$STUB_LOG" "macelium bootstrap"

  unset STUB_GH_PUSH_FAILS
  forget_private_repo me/macelium-state
  : >"$STUB_LOG"
  run_tty '' '' '' -- bash "$installer"
  assert_status 0
  assert_contains "$out" "==> macelium init: $HOME/macelium-state already holds the new state repo"
  assert_order "$out" "==> Pushing $HOME/macelium-state to me/macelium-state" "==> macelium bootstrap"
  assert_not_contains "$STUB_LOG" "macelium init"
  assert_not_contains "$STUB_LOG" "gh repo create"
  assert_pushed "$sandbox/github/me/macelium-state.git"
  assert_upstream "$HOME/macelium-state"
}

test_guided_resumes_at_the_create_when_init_has_run() {
  guided_mac
  export STUB_GH_LOGIN=me
  "$sandbox/bin/macelium" init "$HOME/macelium-state" </dev/null
  : >"$STUB_LOG"
  run_tty '' me 1 '' '' -- bash "$installer"
  assert_status 0
  assert_contains "$out" "==> macelium init: $HOME/macelium-state already holds the new state repo"
  assert_not_contains "$STUB_LOG" "macelium init"
  assert_order "$STUB_LOG" "gh repo create me/macelium-state --private --source $HOME/macelium-state --push" \
    "macelium bootstrap $HOME/macelium-state tty=yes"
}

test_guided_pushes_into_an_empty_github_repo() {
  guided_mac
  export STUB_GH_LOGIN=me
  github_repo me/macelium-state private empty
  run_tty '' me '' -- bash "$installer"
  assert_status 0
  assert_not_contains "$out" "Who can read the new repo?"
  assert_order "$STUB_LOG" "macelium init $HOME/macelium-state tty=yes" "macelium bootstrap $HOME/macelium-state tty=yes"
  assert_not_contains "$STUB_LOG" "gh repo create"
  [[ $(git -C "$HOME/macelium-state" config --get remote.origin.url) == https://github.com/me/macelium-state ]] ||
    fail "origin: $(git -C "$HOME/macelium-state" config --get remote.origin.url)"
  assert_pushed "$sandbox/github/me/macelium-state.git"
}

test_guided_confirms_an_empty_public_github_repo_before_capturing_into_it() {
  guided_mac
  export STUB_GH_LOGIN=me
  github_repo me/macelium-state public empty
  run_tty '' me '' '' -- bash "$installer"
  assert_status 0
  assert_contains "$out" "Found https://github.com/me/macelium-state, with nothing in it yet."
  assert_contains "$out" "Capture this Mac into it? [Y/n]"
  assert_order "$STUB_LOG" "gh auth login" "macelium init --public $HOME/macelium-state tty=yes" \
    "macelium bootstrap $HOME/macelium-state tty=yes"
  assert_not_contains "$STUB_LOG" "gh repo create"
  assert_pushed "$sandbox/github/me/macelium-state.git"
}

test_guided_stops_when_gh_cannot_say_whether_the_repo_exists() {
  guided_mac
  export STUB_GH_LOGIN=me STUB_GH_VIEW_FAILS=1
  run_tty '' me "$eof" "$eof" -- bash "$installer"
  assert_status 1
  assert_order "$out" "HTTP 502: Bad Gateway" "install.sh: stopped: gh repo view me/macelium-state failed"
  assert_not_contains "$out" "No macelium-state repo found"
  assert_not_contains "$STUB_LOG" "macelium init"
}

test_guided_refuses_to_create_for_a_path_whose_remote_names_a_missing_repo() {
  guided_mac
  export STUB_GH_LOGIN=me
  "$sandbox/bin/macelium" init "$HOME/macelium-state" </dev/null
  git -C "$HOME/macelium-state" remote add origin https://github.com/me/macelium-state
  : >"$STUB_LOG"
  run_tty '' me 1 '' "$eof" "$eof" -- bash "$installer"
  assert_status 1
  assert_contains "$out" "install.sh: stopped: $HOME/macelium-state's remote names me/macelium-state, which GitHub does not have"
  assert_not_contains "$STUB_LOG" "gh repo create"
  assert_not_contains "$STUB_LOG" "macelium bootstrap"
}

test_guided_refuses_a_clone_of_the_empty_repo_it_would_push_into() {
  guided_mac
  git init -q --bare "$sandbox/empty.git"
  git config --global url."file://$sandbox/empty.git".insteadOf https://git.example.org/me/empty
  git clone -q https://git.example.org/me/empty "$HOME/empty" 2>/dev/null
  run_tty 2 https://git.example.org/me/empty '' -- bash "$installer"
  assert_status 1
  assert_contains "$out" "install.sh: $HOME/empty holds something other than a new state repo for https://git.example.org/me/empty"
  assert_not_contains "$STUB_LOG" "macelium init"
  assert_not_contains "$out" "==> Pushing"
}

test_guided_refuses_a_path_holding_something_else_before_init() {
  guided_mac
  export STUB_GH_LOGIN=me
  mkdir -p "$HOME/macelium-state"
  touch "$HOME/macelium-state/file"
  run_tty '' me 1 '' -- bash "$installer"
  assert_status 1
  assert_contains "$out" "install.sh: $HOME/macelium-state holds something other than a new state repo for me/macelium-state: run install.sh again and answer another path"
  assert_not_contains "$STUB_LOG" "macelium init"
  assert_not_contains "$STUB_LOG" "gh repo create"
}

test_guided_clones_from_another_host_to_the_path_given() {
  guided_mac
  # shellcheck disable=SC2088 # the answer's ~, for install.sh to expand
  run_tty 2 https://git.example.org/me/state '~/elsewhere/state' '' -- bash "$installer"
  assert_status 0
  assert_order "$out" "==> Git host sign-in: needs a personal access token or a registered SSH key" "The state repo's git URL:"
  assert_contains "$out" "Where do you want to clone the state repo? [$HOME/state]:"
  assert_contains "$out" "The path $HOME/elsewhere does not exist, should I create it? [Y/n]"
  assert_contains "$out" "==> Cloning https://git.example.org/me/state to $HOME/elsewhere/state"
  [[ $(grep -c 'sign-in: needs' "$out") == 1 ]] || fail "the sign-in line is not printed once"
  [[ -f $HOME/elsewhere/state/macelium.conf ]] || fail "not cloned"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/elsewhere/state tty=yes"
  assert_not_contains "$STUB_LOG" "gh "
}

test_guided_stops_at_another_host_git_cannot_read() {
  guided_mac
  git config --global url."file://$sandbox/missing.git".insteadOf https://git.example.org/me/missing
  run_tty 2 https://git.example.org/me/missing "$eof" "$eof" -- bash "$installer"
  assert_status 1
  assert_contains "$out" "install.sh: stopped: git can't read https://git.example.org/me/missing. git.example.org sign-in: needs a personal access token or a registered SSH key"
  assert_not_contains "$out" "Where do you want to clone the state repo?"
  assert_not_contains "$STUB_LOG" "macelium init"
  assert_not_contains "$STUB_LOG" "macelium bootstrap"
}

test_guided_pushes_into_an_empty_repo_on_another_host_at_an_empty_path() {
  guided_mac
  git init -q --bare "$sandbox/empty.git"
  git config --global url."file://$sandbox/empty.git".insteadOf https://git.example.org/me/empty
  mkdir -p "$HOME/empty"
  run_tty 2 https://git.example.org/me/empty '' -- bash "$installer"
  assert_status 0
  assert_not_contains "$out" "Who can read the new repo?"
  assert_order "$STUB_LOG" "macelium init $HOME/empty tty=yes" "macelium bootstrap $HOME/empty tty=yes"
  [[ $(git -C "$HOME/empty" config --get remote.origin.url) == https://git.example.org/me/empty ]] ||
    fail "origin: $(git -C "$HOME/empty" config --get remote.origin.url)"
  assert_pushed "$sandbox/empty.git"
  assert_upstream "$HOME/empty"
  assert_not_contains "$STUB_LOG" "gh "
}

test_guided_resumes_at_the_push_on_another_host() {
  guided_mac
  git init -q --bare "$sandbox/empty.git"
  git config --global url."file://$sandbox/empty.git".insteadOf https://git.example.org/me/empty
  "$sandbox/bin/macelium" init "$HOME/empty" </dev/null
  git -C "$HOME/empty" remote add origin https://git.example.org/me/empty
  : >"$STUB_LOG"
  run_tty 2 https://git.example.org/me/empty '' -- bash "$installer"
  assert_status 0
  assert_not_contains "$STUB_LOG" "macelium init"
  assert_order "$out" "==> Pushing $HOME/empty to https://git.example.org/me/empty" "==> macelium bootstrap"
  assert_pushed "$sandbox/empty.git"
}

# Takes the answers before an end-of-file, and what a test of that prompt
# needs set up first. Fails the test unless install.sh stops, exit 1, with
# nothing created.
assert_stops_at_end_of_file() {
  rm -f "$STUB_LOG.signed-in"
  run_tty "$@" "$eof" "$eof" -- bash "$installer"
  assert_status 1
  assert_contains "$out" "install.sh: stopped: no answer"
  assert_not_contains "$STUB_LOG" "macelium init"
  assert_not_contains "$STUB_LOG" "macelium bootstrap"
  assert_not_contains "$STUB_LOG" "gh repo create"
  [[ ! -e $HOME/macelium-state && ! -e $HOME/state ]] || fail "it wrote the path"
}

test_guided_stops_at_end_of_file_on_the_host_username_url_and_path() {
  guided_mac
  assert_stops_at_end_of_file
  assert_stops_at_end_of_file ''
  assert_stops_at_end_of_file 2
  github_repo me/macelium-state public
  assert_stops_at_end_of_file '' me
  assert_stops_at_end_of_file '' me ''
}

test_guided_stops_at_end_of_file_on_the_first_time_question_another_name_and_visibility() {
  guided_mac
  export STUB_GH_LOGIN=me
  assert_stops_at_end_of_file '' me
  assert_stops_at_end_of_file '' me 2
  assert_stops_at_end_of_file '' me 1
  assert_stops_at_end_of_file '' me 1 ''
}

# Who it signs in as.

test_guided_confirms_the_account_gh_is_signed_in_as() {
  guided_mac
  sign_in_as me
  github_repo me/macelium-state private
  run_tty '' '' '' -- bash "$installer"
  assert_status 0
  assert_order "$out" "gh is signed in to GitHub as me." "Continue as me?" "1) yes" "2) no, sign in to another account" \
    "==> Signed in to GitHub as me" "Found https://github.com/me/macelium-state."
  assert_not_contains "$out" "GitHub username"
  assert_not_contains "$STUB_LOG" "gh auth login"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/macelium-state tty=yes"
}

test_guided_signs_in_to_another_account_when_the_signed_in_one_is_declined() {
  guided_mac
  sign_in_as me
  export STUB_GH_LOGIN=bob
  github_repo bob/macelium-state private
  run_tty '' 2 '' -- bash "$installer"
  assert_status 0
  assert_order "$out" "Continue as me?" "==> Signing in to GitHub" "==> Signed in to GitHub as bob"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/macelium-state tty=yes"
  assert_contains "$STUB_LOG" "gh repo view bob/macelium-state"
}

test_guided_signs_in_as_the_username_given_when_gh_signs_in_as_another() {
  guided_mac
  export STUB_GH_LOGIN="me bob"
  github_repo bob/macelium-state private
  run_tty '' bob '' '' -- bash "$installer"
  assert_status 0
  assert_order "$out" "==> Signed in to GitHub as me" "gh is signed in as me, not bob." "1) sign in as bob" "2) continue as me" \
    "==> Signing in to GitHub as bob" "==> Signed in to GitHub as bob"
  assert_contains "$STUB_LOG" "gh repo view bob/macelium-state"
}

test_guided_goes_on_as_the_signed_in_account_when_asked_to() {
  guided_mac
  export STUB_GH_LOGIN=me
  github_repo me/macelium-state private
  run_tty '' bob 2 '' -- bash "$installer"
  assert_status 0
  assert_contains "$out" "gh is signed in as me, not bob."
  assert_contains "$STUB_LOG" "gh repo view me/macelium-state"
  [[ $(grep -c 'gh auth login' "$STUB_LOG") == 1 ]] || fail "it signed in again"
}

test_guided_stops_when_the_second_sign_in_is_not_the_username_given() {
  guided_mac
  export STUB_GH_LOGIN=me
  run_tty '' bob 1 "$eof" "$eof" -- bash "$installer"
  assert_status 1
  assert_contains "$out" "install.sh: stopped: signed in as me, not bob"
  assert_not_contains "$STUB_LOG" "macelium init"
  assert_not_contains "$STUB_LOG" "macelium bootstrap"
}

# A clone already at the default path.

test_guided_offers_a_clone_already_at_the_default_path() {
  guided_mac
  github_repo me/macelium-state public
  git clone -q https://github.com/me/macelium-state "$HOME/macelium-state"
  run_tty '' me '' n -- bash "$installer"
  assert_status 0
  assert_contains "$out" "Found https://github.com/me/macelium-state."
  assert_contains "$out" "It is already cloned at $HOME/macelium-state. Set up this Mac from that clone? [Y/n]"
  assert_contains "$out" "==> Clone: $HOME/macelium-state is already a clone of me/macelium-state"
  assert_not_contains "$out" "Where do you want to clone"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/macelium-state tty=yes"
}

test_guided_asks_the_path_when_the_clone_at_the_default_path_is_declined() {
  guided_mac
  github_repo me/macelium-state public
  git clone -q https://github.com/me/macelium-state "$HOME/macelium-state"
  run_tty '' me n "$HOME/other" n -- bash "$installer"
  assert_status 0
  assert_contains "$out" "Where do you want to clone the state repo? [$HOME/macelium-state]:"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/other tty=yes"
}

test_guided_offers_a_clone_of_a_private_repo_at_the_default_path() {
  guided_mac
  sign_in_as me
  github_repo me/macelium-state private
  git clone -q "$sandbox/github/me/macelium-state.git" "$HOME/macelium-state"
  git -C "$HOME/macelium-state" remote set-url origin https://github.com/me/macelium-state
  run_tty '' '' '' -- bash "$installer"
  assert_status 0
  assert_order "$out" "Found https://github.com/me/macelium-state." "It is already cloned at $HOME/macelium-state."
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/macelium-state tty=yes"
}

# A path whose directory is missing.

test_guided_asks_the_path_again_when_creating_its_directory_is_declined() {
  guided_mac
  github_repo me/macelium-state public
  run_tty '' me '' "$HOME/a/state" n "$HOME/b/state" y n -- bash "$installer"
  assert_status 0
  assert_contains "$out" "The path $HOME/a does not exist, should I create it? [Y/n]"
  assert_contains "$out" "The path $HOME/b does not exist, should I create it? [Y/n]"
  [[ ! -e $HOME/a ]] || fail "created $HOME/a"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/b/state tty=yes"
}

test_guided_says_what_init_records_before_it_runs() {
  guided_mac
  export STUB_GH_LOGIN=me
  run_tty '' me 1 '' '' -- bash "$installer"
  assert_status 0
  assert_contains "$out" "Where do you want to keep the new state repo? [$HOME/macelium-state]:"
  assert_order "$out" "Macelium will now record your computer's current setup" "==> macelium init $HOME/macelium-state"
}

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
# `list` fails until `install` has run; a gh that records its call and fails,
# so a test never signs in; and a macelium that records its call and whether
# stdin is a terminal, and exits $STUB_MACELIUM_STATUS.
installable_state() {
  make_state macelium.conf $'contract 1\n'
  local form
  for form in https://github.com/example/state https://git.example.org/me/state \
    ssh://git@git.example.org/me/state git@git.example.org:me/state; do
    git config --global --add url."file://$sandbox/state.git".insteadOf "$form"
  done
  cat >"$sandbox/bin/macelium" <<'STUB'
#!/bin/bash
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
  for args in "" "state" "example/state/extra" "example/" "example/state $sandbox/a $sandbox/b" \
    https://github.com/example/state/extra git@github.com:example https://git.example.org/ ftp://git.example.org/me/state; do
    # shellcheck disable=SC2086 # each case is its words
    run_installer $args
    assert_status 1
    assert_contains "$err" "usage: curl -fsSL"
  done
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
  assert_not_contains "$STUB_LOG" "gh auth login"
  [[ -f $HOME/git/state/macelium.conf ]] || fail "not cloned to ~/git/state"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/git/state tty=yes"

  : >"$STUB_LOG"
  run_tty -- bash "$installer" example/state
  assert_status 0
  assert_contains "$out" "==> Homebrew: already installed"
  assert_contains "$out" "==> macelium: already installed"
  assert_contains "$out" "==> Clone: $HOME/git/state is already a clone of example/state"
  assert_not_contains "$STUB_LOG" "brew install"
  assert_contains "$STUB_LOG" "macelium bootstrap $HOME/git/state tty=yes"
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

test_install_signs_in_after_the_bootstrap_on_yes() {
  installable_state
  run_tty y -- bash "$installer" example/state "$sandbox/clone"
  assert_order "$STUB_LOG" "macelium bootstrap" "gh auth login"
  # The gh stub fails.
  assert_status 1
  assert_contains "$out" "install.sh: stopped: gh auth login failed"
}

test_install_signs_in_before_the_clone_when_github_refuses_an_anonymous_read() {
  installable_state
  git config --global url."file://$sandbox/missing.git".insteadOf https://github.com/example/private
  run_tty -- bash "$installer" example/private "$sandbox/clone"
  assert_status 1
  assert_contains "$out" "==> Signing in to GitHub"
  assert_contains "$STUB_LOG" "gh auth login"
  assert_not_contains "$out" "==> Cloning"
  assert_not_contains "$STUB_LOG" "macelium bootstrap"
}

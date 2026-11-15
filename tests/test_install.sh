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

# A state repo that https://github.com/example/state clones; a brew whose
# `list` fails until `install` has run; a gh that records its call and fails,
# so a test never signs in; and a macelium that records its call and whether
# stdin is a terminal, and exits $STUB_MACELIUM_STATUS.
installable_state() {
  make_state macelium.conf $'contract 1\n'
  git config --global url."file://$sandbox/state.git".insteadOf https://github.com/example/state
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

test_install_refuses_without_owner_and_repo() {
  local args
  for args in "" "state" "example/state/extra" "example/" "example/state $sandbox/a $sandbox/b"; do
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
  run_tty -- bash "$installer" example/state
  assert_status 0
  assert_contains "$STUB_LOG" "brew install dbaggott/tap/macelium"
  assert_contains "$out" "GitHub sign-in: not needed, git can read example/state"
  assert_not_contains "$STUB_LOG" "gh "
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

# shellcheck shell=bash disable=SC2154,SC2034 # tests/lib.sh sets tool and sandbox, and reads out, err and status
# install.sh, with Homebrew and macelium stubbed.

installer=$(dirname "$tool")/install.sh

# Takes install.sh's arguments. Runs it with no terminal, as run does.
run_installer() {
  out=$sandbox/out err=$sandbox/err
  bash "$installer" "$@" >"$out" 2>"$err" </dev/null
  status=$?
}

# A brew whose `list` fails until `install` has run, with `--versions`
# naming macelium 1.0.0 until an upgrade, and whose `upgrade` fails when
# $STUB_BREW_UPGRADE_FAILS is set and otherwise moves macelium to
# $STUB_MACELIUM_LATEST when that is set; and a macelium that records its
# call and whether stdin is a terminal, and exits $STUB_MACELIUM_STATUS, but
# for its help, which fails when $STUB_MACELIUM_NO_SETUP is set.
installable_mac() {
  cat >"$sandbox/bin/macelium" <<'STUB'
#!/bin/bash
tty=no
[[ -t 0 ]] && tty=yes
echo "macelium $* tty=$tty" >>"$STUB_LOG"
if [[ $1 == help ]]; then
  [[ -z ${STUB_MACELIUM_NO_SETUP:-} ]]
  exit
fi
exit "${STUB_MACELIUM_STATUS:-0}"
STUB
  cat >"$sandbox/bin/brew" <<'STUB'
#!/bin/bash
echo "brew $*" >>"$STUB_LOG"
case $1 in
  install) touch "$STUB_LOG.installed" ;;
  list)
    [[ -e $STUB_LOG.installed ]] || exit 1
    [[ $2 != --versions ]] || echo "macelium $(cat "$STUB_LOG.version" 2>/dev/null || echo 1.0.0)"
    ;;
  upgrade)
    if [[ -n ${STUB_BREW_UPGRADE_FAILS:-} ]]; then
      echo "Error: the upgrade failed" >&2
      exit 1
    fi
    [[ -z ${STUB_MACELIUM_LATEST:-} ]] || echo "$STUB_MACELIUM_LATEST" >"$STUB_LOG.version"
    ;;
esac
STUB
  chmod +x "$sandbox/bin/macelium" "$sandbox/bin/brew"
}

test_install_needs_a_terminal() {
  installable_mac
  run_installer example/state
  assert_status 1
  assert_contains "$err" "install.sh: needs a terminal for its prompts"
  [[ ! -s $STUB_LOG ]] || fail "it ran: $(cat "$STUB_LOG")"
}

test_install_installs_macelium_and_hands_over_to_setup_with_its_arguments() {
  installable_mac
  export STUB_MACELIUM_STATUS=3
  run_tty -- bash "$installer" example/state "$sandbox/a path"
  assert_status 3
  assert_contains "$out" "==> Homebrew: already installed"
  assert_contains "$out" "==> Installing macelium"
  assert_order "$STUB_LOG" "brew install dbaggott/tap/macelium" "macelium setup example/state $sandbox/a path tty=yes"
}

test_install_with_no_argument_hands_over_to_the_guided_setup() {
  installable_mac
  run_tty -- bash "$installer"
  assert_status 0
  assert_contains "$STUB_LOG" "macelium setup tty=yes"
}

test_install_says_an_installed_macelium_is_the_latest() {
  installable_mac
  touch "$STUB_LOG.installed"
  run_tty -- bash "$installer"
  assert_status 0
  assert_contains "$out" "==> macelium: already installed, the latest version (1.0.0)"
  assert_not_contains "$STUB_LOG" "brew install"
}

test_install_upgrades_an_installed_macelium_before_the_setup() {
  installable_mac
  touch "$STUB_LOG.installed"
  export STUB_MACELIUM_LATEST=1.1.0
  run_tty -- bash "$installer" example/state
  assert_status 0
  assert_contains "$out" "==> macelium: upgraded from 1.0.0 to 1.1.0"
  assert_order "$STUB_LOG" "brew upgrade dbaggott/tap/macelium" "macelium setup example/state tty=yes"
  assert_not_contains "$STUB_LOG" "brew install"
}

test_install_stops_when_the_macelium_upgrade_fails() {
  installable_mac
  touch "$STUB_LOG.installed"
  export STUB_BREW_UPGRADE_FAILS=1
  run_tty -- bash "$installer" example/state
  assert_status 1
  assert_contains "$out" "Error: the upgrade failed"
  assert_contains "$out" "install.sh: stopped: brew upgrade dbaggott/tap/macelium failed"
  assert_not_contains "$STUB_LOG" "macelium setup"
}

test_install_stops_when_the_installed_macelium_has_no_setup() {
  installable_mac
  export STUB_MACELIUM_NO_SETUP=1
  run_tty -- bash "$installer" example/state
  assert_status 1
  assert_contains "$out" "install.sh: stopped: the macelium Homebrew installed has no setup command; run brew update && brew upgrade dbaggott/tap/macelium"
  assert_not_contains "$STUB_LOG" "macelium setup"
}

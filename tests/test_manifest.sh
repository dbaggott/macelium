# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, sandbox, state, out and err
# The manifest: its contract is read first, it refuses what it does not
# declare, and a part it names that is missing is skipped.

test_newer_contract_asks_for_an_upgrade_and_runs_nothing() {
  make_state macelium.conf $'contract 2\nsomething_newer yes\n' \
    Brewfile $'brew "hello"\n'
  run plan
  assert_status 1
  assert_contains "$err" "is written to contract 2, and this macelium reads contract 1: upgrade macelium"
  assert_not_contains "$err" "holds more than declarations"

  run_tty y -- "$tool" apply
  assert_status 1
  assert_contains "$out" "upgrade macelium"

  run_tty -- "$tool" bootstrap "$state"
  assert_status 1
  assert_contains "$out" "upgrade macelium"

  # Each run asked chezmoi where the checkout is, and ran nothing else.
  if grep -v '^chezmoi source-path$' "$STUB_LOG" | grep -q .; then
    fail "ran more than chezmoi source-path: $(cat "$STUB_LOG")"
  fi
}

test_unknown_declaration_is_refused() {
  make_state macelium.conf $'contract 1\nbogus x\n'
  run plan
  assert_status 1
  assert_contains "$err" "macelium.conf holds more than declarations and comments:"
  assert_contains "$err" "macelium.conf:2: bogus x"
}

test_wrong_declaration_is_refused() {
  make_state macelium.conf $'contract 1\nbrewfile\nsettings /etc/macos.sh\n'
  run plan
  assert_status 1
  assert_contains "$err" "macelium.conf:2: brewfile takes one argument"
  assert_contains "$err" "macelium.conf:3: settings /etc/macos.sh: not a path relative to the state repo's root"
}

test_no_contract_is_refused() {
  make_state macelium.conf $'brewfile Brewfile\n'
  run plan
  assert_status 1
  assert_contains "$err" "has no \`contract <n>\` line"
}

test_missing_parts_drop_their_sections() {
  make_state macelium.conf $'contract 1\nbrewfile nowhere/Brewfile\nsettings nowhere.sh\napps nowhere\n'
  # The cleanup stub would list it, were the Homebrew checks run.
  export STUB_BREW_UNLISTED=hello
  run plan
  assert_status 0
  assert_contains "$out" "No changes."
  assert_not_contains "$out" "Homebrew"
  assert_not_contains "$err" "failed"
  assert_not_contains "$STUB_LOG" "brew"
}

test_default_parts_are_read() {
  make_state macelium.conf $'contract 1\n' \
    Brewfile $'brew "hello"\n'
  export STUB_BREW_UNLISTED=extra
  run plan
  assert_status 2
  assert_contains "$out" "formula extra"
  assert_contains "$STUB_LOG" "brew bundle cleanup"
}

test_notify_on_a_refused_manifest_logs_and_notifies_and_checks_nothing() {
  make_state macelium.conf $'contract 2\n'
  run plan --notify
  assert_status 1
  assert_contains "$out" "manifest=error notified=yes manifest_error="
  assert_contains "$out" "upgrade\\ macelium"
  assert_contains "$STUB_LOG" "The state repo's macelium.conf was refused."
  if grep -v -e '^chezmoi source-path$' -e '^osascript ' "$STUB_LOG" | grep -q .; then
    fail "ran a check: $(cat "$STUB_LOG")"
  fi
}

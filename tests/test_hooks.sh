# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, sandbox, state, out and err
# The apps hooks run when a hook, a watches list or a watched file changed
# since every hook last succeeded, and plan counts a pending run.

hooks_state() {
  make_state macelium.conf $'contract 1\n' \
    apps/one/after-apply $'echo "hook one ran" >>"$STUB_LOG"\n' \
    apps/one/watches $'config/one\n' \
    config/one/settings $'first\n'
}

hook_runs() {
  grep -c '^hook one ran$' "$STUB_LOG"
}

test_hooks_run_on_first_apply() {
  hooks_state
  run plan
  assert_status 2
  assert_contains "$out" "Apps hooks"
  assert_contains "$out" "run one (not run on this machine yet)"
  assert_contains "$out" "1 to change"

  run_tty y -- "$tool" apply
  assert_status 0
  [[ $(hook_runs) == 1 ]] || fail "hook ran $(hook_runs) times, expected 1"
  [[ -s $HOME/.local/state/macelium/apps-hooks.sha256 ]] || fail "no hash recorded"
}

test_hooks_do_not_rerun_when_nothing_changed() {
  hooks_state
  run_tty y -- "$tool" apply
  run plan
  assert_status 0
  assert_contains "$out" "No changes."
  run_tty y -- "$tool" apply
  assert_contains "$out" "No changes."
  [[ $(hook_runs) == 1 ]] || fail "hook ran $(hook_runs) times, expected 1"
}

test_hooks_rerun_after_a_watched_file_changes() {
  hooks_state
  run_tty y -- "$tool" apply
  echo second >"$state/config/one/settings"
  run plan
  assert_status 2
  assert_contains "$out" "run one (a hook, or a file one watches, changed since they last ran)"
  run_tty y -- "$tool" apply
  assert_status 0
  [[ $(hook_runs) == 2 ]] || fail "hook ran $(hook_runs) times, expected 2"

  # An untracked file a watches list names counts too.
  echo new >"$state/config/one/added"
  run plan
  assert_status 2
}

test_failed_hook_records_no_hash() {
  make_state macelium.conf $'contract 1\n' \
    apps/one/after-apply $'exit 3\n' \
    apps/two/after-apply $'echo "hook two ran" >>"$STUB_LOG"\n'
  run_tty y -- "$tool" apply
  assert_status 1
  assert_contains "$out" "after-apply failed for one"
  assert_contains "$STUB_LOG" "hook two ran"
  [[ ! -e $HOME/.local/state/macelium/apps-hooks.sha256 ]] || fail "hash recorded after a failed hook"
}

test_hook_reading_stdin_leaves_the_rest_to_run() {
  make_state macelium.conf $'contract 1\n' \
    apps/one/after-apply $'cat >/dev/null\n' \
    apps/two/after-apply $'echo "hook two ran" >>"$STUB_LOG"\n'
  run_tty y -- "$tool" apply
  assert_status 0
  assert_contains "$STUB_LOG" "hook two ran"
}

# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, sandbox, state, out and err
# Touch ID for sudo is offered only when the settings list declares
# touch_id_sudo.

# Takes a settings list's content. Runs macelium settings over it, sourced so
# that sudo's PAM file is a sandbox one and the offer is recorded, not asked.
offer_touch_id() {
  printf '%s' "$1" >"$sandbox/list.sh"
  : >"$sandbox/sudo_local"
  # shellcheck disable=SC2016 # expanded by the inner bash
  run_tty -- bash -c '
    source "$1"
    sudo_local=$2
    confirm() { echo "OFFERED: $1"; return 1; }
    settings_command --file "$3"
  ' _ "$tool" "$sandbox/sudo_local" "$sandbox/list.sh"
}

test_touch_id_offered_only_when_declared() {
  offer_touch_id $'# no declarations\n'
  assert_status 0
  assert_not_contains "$out" "OFFERED"

  offer_touch_id $'touch_id_sudo\n'
  assert_status 0
  assert_contains "$out" "OFFERED: Enable Touch ID for sudo"
}

test_touch_id_takes_no_arguments() {
  offer_touch_id $'touch_id_sudo yes\n'
  assert_status 1
  assert_contains "$out" "touch_id_sudo takes no arguments"
}

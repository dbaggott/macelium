# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, sandbox, out and err
# The settings list's touch_id_sudo. Whether it offers Touch ID for sudo,
# and only once a run, is internal/app's tests, which can stand in for
# sudo's PAM file.

test_touch_id_takes_no_arguments() {
  printf 'touch_id_sudo yes\n' >"$sandbox/list.sh"
  run settings --file "$sandbox/list.sh"
  assert_status 1
  assert_contains "$err" "touch_id_sudo takes no arguments"
}

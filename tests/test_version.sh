# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, out and status
# --version: what the formula's test asserts.

test_version_prints_the_version_line() {
  run --version
  assert_status 0
  [[ $(cat "$out") == "macelium $version" ]] || fail "--version printed: $(cat "$out")"
  run -V
  assert_status 0
  [[ $(cat "$out") == "macelium $version" ]] || fail "-V printed: $(cat "$out")"
}

test_version_takes_no_argument() {
  run --version extra
  assert_status 1
  assert_contains "$err" "Usage: macelium"
}

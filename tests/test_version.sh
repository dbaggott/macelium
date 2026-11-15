# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, out and status
# --version: what the formula's test asserts.

test_version_prints_the_version_line() {
  local version
  version=$(grep -E '^VERSION=' "$tool" | head -n 1 | cut -d '"' -f 2)
  [[ -n $version ]] || fail "no VERSION= line in $tool"
  run --version
  assert_status 0
  [[ $(cat "$out") == "macelium $version" ]] || fail "--version printed: $(cat "$out")"
  run -V
  assert_status 0
  assert_contains "$out" "macelium $version"
}

test_version_takes_no_argument() {
  run --version extra
  assert_status 1
  assert_contains "$err" "usage: macelium"
}

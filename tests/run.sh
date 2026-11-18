#!/bin/bash
# Runs every test_* function in tests/test_*.sh, each in a subshell of its own
# with a fresh sandbox (tests/lib.sh), several at once, and exits 1 if any
# failed. Each test's output is printed whole, above its result, in the order
# the tests are found.
#
# Usage: tests/run.sh [<name pattern>]
set -uo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
pattern=${1:-}
# More than the cores: the tests spend most of their time asleep, waiting on
# a terminal's answers or a step's ticks.
jobs=8
passed=0 failed=()

results=$(mktemp -d)
trap 'rm -rf "$results"' EXIT

# Takes the test's place in the run, its file and its name. Runs the test,
# keeping its output in $results/<place>, and marks a pass with
# $results/<place>.ok.
run_test() {
  if (
    # shellcheck source=/dev/null
    source "$tests_dir/lib.sh"
    # shellcheck source=/dev/null
    source "$2"
    setup_sandbox
    "$3"
  ) >"$results/$1" 2>&1 </dev/null; then
    : >"$results/$1.ok"
  fi
}
export -f run_test
export tests_dir results

files=() names=()
for file in "$tests_dir"/test_*.sh; do
  for name in $(bash -c 'source "$1"; declare -F' _ "$file" | awk '$3 ~ /^test_/ { print $3 }'); do
    [[ -z $pattern || $name == *$pattern* ]] || continue
    files+=("$file") names+=("$name")
  done
done

for i in ${names[@]+"${!names[@]}"}; do
  printf '%s\0%s\0%s\0' "$i" "${files[i]}" "${names[i]}"
done | xargs -0 -n 3 -P "$jobs" "$BASH" -c 'run_test "$@"' _

for i in ${names[@]+"${!names[@]}"}; do
  name=${names[i]}
  cat "$results/$i"
  if [[ -e $results/$i.ok ]]; then
    echo "ok: $name"
    ((passed++))
  else
    echo "FAILED: $name"
    failed+=("$name")
  fi
done

echo
echo "$passed passed, ${#failed[@]} failed"
((${#failed[@]} == 0))

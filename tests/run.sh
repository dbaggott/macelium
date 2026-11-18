#!/bin/bash
# Runs every test_* function in tests/test_*.sh, each in a subshell of its own
# with a fresh sandbox (tests/lib.sh), several at once, and exits 1 if any
# failed. Each test's output is printed whole, above its result, in the order
# the tests are found, once it and every test before it have ended.
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

# Takes lib.sh, the directory for results, and the test's place in the run,
# its file and its name. Runs the test, keeping its output in
# <results>/<place>, then its exit status in <results>/<place>.status.
run_test() {
  (
    # shellcheck source=/dev/null
    source "$1"
    # shellcheck source=/dev/null
    source "$4"
    setup_sandbox
    "$5"
  ) >"$2/$3" 2>&1 </dev/null
  echo $? >"$2/$3.status.part" && mv "$2/$3.status.part" "$2/$3.status"
}

files=() names=()
for file in "$tests_dir"/test_*.sh; do
  for name in $(bash -c 'source "$1"; declare -F' _ "$file" | awk '$3 ~ /^test_/ { print $3 }'); do
    [[ -z $pattern || $name == *$pattern* ]] || continue
    files+=("$file") names+=("$name")
  done
done

for i in ${names[@]+"${!names[@]}"}; do
  printf '%s\0%s\0%s\0' "$i" "${files[i]}" "${names[i]}"
done | xargs -0 -n 3 -P "$jobs" "$BASH" -c "$(declare -f run_test); run_test \"\$@\"" _ "$tests_dir/lib.sh" "$results" &
runner=$!

for i in ${names[@]+"${!names[@]}"}; do
  name=${names[i]}
  # Once xargs has ended, a test with no status is one it never started.
  while [[ ! -e $results/$i.status ]] && kill -0 "$runner" 2>/dev/null; do
    sleep 0.1
  done
  if [[ -e $results/$i.status ]]; then
    cat "$results/$i"
    status=$(<"$results/$i.status")
  else
    echo "  never ran"
    status=
  fi
  if [[ $status == 0 ]]; then
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

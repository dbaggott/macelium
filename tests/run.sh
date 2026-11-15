#!/bin/bash
# Runs every test_* function in tests/test_*.sh, each in a subshell of its own
# with a fresh sandbox (tests/lib.sh), and exits 1 if any failed.
#
# Usage: tests/run.sh [<name pattern>]
set -uo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
pattern=${1:-}
passed=0 failed=()

for file in "$tests_dir"/test_*.sh; do
  for name in $(bash -c 'source "$1"; declare -F' _ "$file" | awk '$3 ~ /^test_/ { print $3 }'); do
    [[ -z $pattern || $name == *$pattern* ]] || continue
    if (
      # shellcheck source=/dev/null
      source "$tests_dir/lib.sh"
      # shellcheck source=/dev/null
      source "$file"
      setup_sandbox
      "$name"
    ); then
      echo "ok: $name"
      ((passed++))
    else
      echo "FAILED: $name"
      failed+=("$name")
    fi
  done
done

echo
echo "$passed passed, ${#failed[@]} failed"
((${#failed[@]} == 0))

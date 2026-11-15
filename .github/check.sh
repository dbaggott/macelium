#!/usr/bin/env bash
# The checks behind the ci-required job, all but the example's bootstrap,
# runnable locally from any checkout:
#   - gitleaks over the commits in a range (default origin/main..HEAD)
#   - shellcheck over every shell script in the repo
#   - the tests, tests/run.sh
# Needs gitleaks and shellcheck on PATH (exits 2 naming any that is missing).
# Runs every check and exits 1 if any failed.
#
# Usage: .github/check.sh [<git log range>]
set -euo pipefail

range=${1:-origin/main..HEAD}

missing=()
for tool in gitleaks shellcheck; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if ((${#missing[@]})); then
  echo "not on PATH: ${missing[*]}" >&2
  exit 2
fi

cd "$(git rev-parse --show-toplevel)"
failed=()

echo "== gitleaks ($range)"
gitleaks git --no-banner --redact --verbose --log-opts="$range" . || failed+=(gitleaks)

# Takes a file, and succeeds when it is a shell script: by its extension, or
# by its shebang.
is_shell_script() {
  case "$1" in
    *.sh | *.bash) return 0 ;;
  esac
  head -n 1 "$1" | grep -Eq '^#!.*[/ ](ba|da|k)?sh([[:space:]]|$)'
}

echo "== shellcheck"
while IFS= read -r -d '' f; do
  if [[ ! -f $f ]] || ! is_shell_script "$f"; then continue; fi
  if shellcheck "$f"; then
    echo "ok: $f"
  else
    failed+=("shellcheck $f")
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

echo "== tests"
tests/run.sh || failed+=(tests)

if ((${#failed[@]})); then
  echo
  echo "failed:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
echo
echo "all checks passed"

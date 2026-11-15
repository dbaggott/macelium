# shellcheck shell=bash
# Sourced by tests/run.sh into each test's subshell: the sandbox, ways to run
# macelium in it, and assertions. An assertion that fails prints why and
# exits the test's subshell.

tool=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/macelium

# A temporary home, the stubs first on PATH, and an empty call log.
setup_sandbox() {
  # pwd -P, since macOS's temporary directory is under a symlink.
  sandbox=$(cd "$(mktemp -d)" && pwd -P)
  trap 'rm -rf "$sandbox"' EXIT
  export HOME=$sandbox/home STUB_LOG=$sandbox/calls.log
  mkdir -p "$HOME" "$sandbox/bin"
  cp "$(dirname "$tool")"/tests/stubs/* "$sandbox/bin/"
  export PATH=$sandbox/bin:$PATH
  unset XDG_CONFIG_HOME STUB_SOURCE_PATH STUB_CHEZMOI_STATUS STUB_BREW_UNLISTED
  : >"$STUB_LOG"
}

# Takes the state repo's files as pairs of a path and its content. Makes it a
# clone of a bare repo, so it has an upstream, at $state, which the chezmoi
# stub names as its source path.
make_state() {
  state=$sandbox/state
  git init -q --bare "$sandbox/state.git"
  git init -q "$state"
  while (($#)); do
    mkdir -p "$(dirname "$state/$1")"
    printf '%s' "$2" >"$state/$1"
    shift 2
  done
  git -C "$state" add -A
  git -C "$state" -c user.name=test -c user.email=test@example.com commit -q -m state
  git -C "$state" remote add origin "$sandbox/state.git"
  git -C "$state" push -q -u origin HEAD 2>/dev/null
  export STUB_SOURCE_PATH=$state
}

# Takes macelium's arguments. Runs it with no terminal, setting status, and
# out and err to the files holding its output.
run() {
  out=$sandbox/out err=$sandbox/err
  "$tool" "$@" >"$out" 2>"$err" </dev/null
  status=$?
}

# Takes the answers to give, a line each, then --, then the command and its
# arguments. Runs it on a terminal, setting status, and out to the file
# holding what the terminal showed. The answers wait a second, since a
# terminal that script has just opened drops what arrives before the command
# starts.
run_tty() {
  local answers=()
  while [[ $1 != -- ]]; do
    answers+=("$1")
    shift
  done
  shift
  out=$sandbox/out err=$sandbox/out
  {
    if ((${#answers[@]})); then
      sleep 1
      printf '%s\n' "${answers[@]}"
    fi
    sleep 1
  } | script -q /dev/null "$@" | tr -d '\r' >"$out"
  status=${PIPESTATUS[1]}
}

fail() {
  echo "  $1" >&2
  if [[ -n ${out:-} && -f $out ]]; then
    echo "  --- output" >&2
    sed 's/^/  /' "$out" >&2
  fi
  if [[ -n ${err:-} && $err != "${out:-}" && -f $err ]]; then
    echo "  --- stderr" >&2
    sed 's/^/  /' "$err" >&2
  fi
  exit 1
}

assert_status() {
  [[ $status == "$1" ]] || fail "exit status $status, expected $1"
}

# Takes a file and a fixed string it must hold.
assert_contains() {
  grep -qF -- "$2" "$1" || fail "$(basename "$1") lacks: $2"
}

assert_not_contains() {
  if grep -qF -- "$2" "$1"; then fail "$(basename "$1") holds: $2"; fi
}

# Takes a file and fixed strings, each of which must first appear on a later
# line than the one before it.
assert_order() {
  local file=$1 line previous=0 text
  shift
  for text in "$@"; do
    line=$(grep -nF -- "$text" "$file" | head -n 1 | cut -d : -f 1)
    [[ -n $line ]] || fail "$(basename "$file") lacks: $text"
    ((line > previous)) || fail "$(basename "$file"): '$text' comes before what precedes it"
    previous=$line
  done
}

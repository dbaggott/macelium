# shellcheck shell=bash
# Sourced by tests/run.sh into each test's subshell: the sandbox, ways to run
# macelium in it, and assertions. An assertion that fails prints why and
# exits the test's subshell.

# The terminal's end-of-file character, ^D, as an answer to run_tty.
eof=$'\x04'

tool=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/macelium

# A temporary home, the stubs first on PATH, and an empty call log.
setup_sandbox() {
  # pwd -P, since macOS's temporary directory is under a symlink.
  sandbox=$(cd "$(mktemp -d)" && pwd -P)
  trap 'rm -rf "$sandbox"' EXIT
  export HOME=$sandbox/home STUB_LOG=$sandbox/calls.log STUB_MACELIUM=$tool
  mkdir -p "$HOME" "$sandbox/bin"
  cp "$(dirname "$tool")"/tests/stubs/* "$sandbox/bin/"
  export PATH=$sandbox/bin:$PATH
  unset XDG_CONFIG_HOME XDG_DATA_HOME STUB_SOURCE_PATH STUB_CHEZMOI_STATUS STUB_CHEZMOI_MANAGED STUB_CHEZMOI_APPLY_READS STUB_BREW_UNLISTED STUB_BREW_OUTDATED \
    STUB_BREW_UPGRADE_FAILS STUB_BREW_BUNDLE_OUTPUT STUB_BREW_BUNDLE_FAILS STUB_BREW_PREFIX STUB_BREW_CACHE STUB_BREW_DUMP STUB_SUDO_ASKS STUB_FDESETUP_STATUS STUB_FDESETUP_FAILS GIT_CONFIG_GLOBAL MACELIUM_UPGRADED_FROM \
    STUB_GITLEAKS_FINDS STUB_GITLEAKS_FAILS STUB_MACELIUM_NO_SETUP STUB_MACELIUM_STATUS STUB_MACELIUM_LATEST
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
# starts. An answer ending in $eof is sent with no newline, so the $eof ends
# one read: once the answers run out, only the first read gets end-of-file and
# any later one blocks, so a test of end-of-file sends one per read it expects,
# and one more.
run_tty() {
  local answers=''
  while [[ $1 != -- ]]; do
    if [[ $1 == *"$eof" ]]; then answers+=$1; else answers+=$1$'\n'; fi
    shift
  done
  shift
  out=$sandbox/out err=$sandbox/out
  {
    if [[ -n $answers ]]; then
      sleep 1
      printf '%s' "$answers"
    fi
    sleep 1
  } | script -q /dev/null "$@" | tr -d '\r' >"$out"
  status=${PIPESTATUS[1]}
}

# Takes how many seconds to hold the terminal's input open, then the command
# and its arguments. Runs it on a terminal as run_tty does, with no answers,
# keeping what the terminal showed as raw bytes, \r and escapes included.
run_tty_raw() {
  local hold=$1
  shift
  out=$sandbox/out err=$sandbox/out
  sleep "$hold" | script -q /dev/null "$@" >"$out"
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

# A chezmoi setup that is not macelium's (refuse_foreign_chezmoi), as each
# case sets it up, and its refusal.

# Takes the source the chezmoi stub names, and writes a chezmoi config file,
# whose content the stub ignores. With no source, chezmoi source-path fails,
# as on a config chezmoi can't parse.
chezmoi_config() {
  mkdir -p "$HOME/.config/chezmoi"
  printf '[data]\nemail = "me@example.com"\n' >"$HOME/.config/chezmoi/chezmoi.toml"
  if [[ -n ${1:-} ]]; then export STUB_SOURCE_PATH=$1; else unset STUB_SOURCE_PATH; fi
}

# A git tree with no macelium.conf, as chezmoi's own source.
other_source() {
  other=$sandbox/other
  git init -q "$other"
  printf 'x\n' >"$other/dot_zshrc"
}

# Sets listing to every path under the sandbox but the stub log and the
# output, to compare before and after a refusal.
listing_now() {
  listing=$(cd "$sandbox" && find . ! -path ./calls.log ! -path ./out ! -path ./err | sort)
}

# Takes the command refused. Checks the run that the last listing_now came
# before: exit 1, the refusal's guidance, and nothing changed.
assert_refused() {
  local before=$listing
  assert_status 1
  assert_contains "$out" "macelium $1: this Mac has a chezmoi setup that is not macelium's:"
  assert_contains "$out" "Save the old chezmoi source if it holds anything not saved elsewhere"
  assert_contains "$out" "Keep a copy of any age or gpg key file"
  assert_contains "$out" "Run \`chezmoi purge\`"
  assert_contains "$out" "The files left in place are what \`macelium init\` captures."
  assert_not_contains "$out" "checkout not found"
  assert_not_contains "$STUB_LOG" "chezmoi init"
  assert_not_contains "$STUB_LOG" "sudo"
  listing_now
  [[ $listing == "$before" ]] || fail "files changed: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$listing"))"
}

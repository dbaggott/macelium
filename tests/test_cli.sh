# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, sandbox, out, err and status
# The help, usage errors and shell completions.

# Prints the commands macelium --help lists, a line each.
listed_commands() {
  "$tool" --help | awk '/^Commands:$/ { on = 1; next } on && NF == 0 { exit } on { print $1 }'
}

# Takes a command, or nothing, and prints the long options its help lists.
listed_options() {
  "$tool" ${1:+"$1"} --help | grep -oE '^  (-[[:alpha:]], )?--[a-z-]+' | grep -oE -- '--[a-z-]+'
}

test_help_prints_the_usage_and_every_command() {
  run --help
  assert_status 0
  assert_contains "$out" "Usage: macelium <command> [<options>]"
  local command
  for command in init bootstrap plan apply settings help; do
    grep -qE "^  $command " "$out" || fail "--help does not list $command"
  done
  run -h
  assert_status 0
  assert_contains "$out" "Usage: macelium <command> [<options>]"
  run help
  assert_status 0
  assert_contains "$out" "Usage: macelium <command> [<options>]"
}

test_no_command_prints_the_help_and_fails() {
  run
  assert_status 1
  assert_contains "$err" "Usage: macelium <command> [<options>]"
  [[ ! -s $out ]] || fail "printed to stdout: $(cat "$out")"
}

test_a_command_help_prints_its_usage_and_runs_nothing() {
  local command
  for command in init bootstrap plan apply settings; do
    run "$command" --help
    assert_status 0
    assert_contains "$out" "Usage: macelium $command"
    run help "$command"
    assert_status 0
    assert_contains "$out" "Usage: macelium $command"
  done
  # A list named -h is a list, not a request for the help.
  run settings --file -h
  assert_status 1
  assert_contains "$err" "cannot read the settings list ./-h"
  run init --public -h
  assert_status 0
  assert_contains "$out" "Usage: macelium init [--public] <path>"
  [[ ! -s $STUB_LOG ]] || fail "a --help ran something: $(cat "$STUB_LOG")"
}

# shellcheck disable=SC2016 # the backticks quote a command
test_an_unknown_command_or_option_names_it_with_the_usage() {
  run frobnicate
  assert_status 1
  assert_contains "$err" "macelium: unknown command 'frobnicate'"
  assert_contains "$err" 'Run `macelium --help` for more.'
  run plan --bogus
  assert_status 1
  assert_contains "$err" "macelium plan: unknown option '--bogus'"
  assert_contains "$err" "Usage: macelium plan [--notify]"
  assert_contains "$err" 'Run `macelium plan --help` for more.'
  run apply now
  assert_status 1
  assert_contains "$err" "macelium apply: unexpected argument 'now'"
  run settings --file
  assert_status 1
  assert_contains "$err" "macelium settings: --file needs a path"
  run settings --file ''
  assert_status 1
  assert_contains "$err" "macelium settings: --file needs a path"
  run help frobnicate
  assert_status 1
  assert_contains "$err" "macelium help: unknown command 'frobnicate'"
  [[ ! -s $STUB_LOG ]] || fail "a usage error ran something: $(cat "$STUB_LOG")"
}

test_the_completions_offer_every_command_and_option_the_help_lists() {
  local completions bash_commands command option
  completions=$(dirname "$tool")/completions
  bash_commands=$(sed -n "s/^ *local commands='\(.*\)'$/\1/p" "$completions/macelium.bash")
  for option in $(listed_options); do
    grep -qF -- "$option" "$completions/_macelium" || fail "_macelium does not offer $option"
    grep -qF -- "$option" "$completions/macelium.bash" || fail "macelium.bash does not offer $option"
  done
  for command in $(listed_commands); do
    grep -qE "'$command:" "$completions/_macelium" || fail "_macelium does not offer $command"
    [[ " $bash_commands " == *" $command "* ]] || fail "macelium.bash does not offer $command"
    for option in $(listed_options "$command"); do
      grep -qF -- "$option" "$completions/_macelium" || fail "_macelium does not offer $command $option"
      grep -qF -- "$option" "$completions/macelium.bash" || fail "macelium.bash does not offer $command $option"
    done
  done
  zsh -n "$completions/_macelium" || fail "_macelium does not parse"
}

# Takes the words of a command line, the last being the one to complete, and
# prints what the bash completion offers, a line each.
bash_completes() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  bash -c 'source "$1"; shift; COMP_WORDS=("$@"); COMP_CWORD=$(($# - 1)); _macelium; printf "%s\n" "${COMPREPLY[@]}"' \
    _ "$(dirname "$tool")/completions/macelium.bash" "$@"
}

test_the_bash_completion_completes_commands_options_and_paths() {
  [[ $(bash_completes macelium pl) == plan ]] || fail "macelium pl: $(bash_completes macelium pl)"
  [[ $(bash_completes macelium plan --n) == --notify ]] || fail "plan --n: $(bash_completes macelium plan --n)"
  [[ $(bash_completes macelium help se) == settings ]] || fail "help se: $(bash_completes macelium help se)"
  mkdir -p "$sandbox/a-dir"
  touch "$sandbox/a-file"
  cd "$sandbox" || fail "no sandbox"
  [[ $(bash_completes macelium init a-) == a-dir ]] || fail "init a-: $(bash_completes macelium init a-)"
  [[ $(bash_completes macelium settings --file a-f) == a-file ]] || fail "settings --file a-f: $(bash_completes macelium settings --file a-f)"
}

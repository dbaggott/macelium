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

# Takes the words after macelium, the last being the one to complete, and
# prints what macelium's completion offers, a line each.
offers() {
  "$tool" __complete "$@" 2>/dev/null | grep -v '^:' | cut -f 1
}

# Takes the words as offers does, and prints the completion's directive to
# the shell: :0 leaves the shell to complete a path.
directive() {
  "$tool" __complete "$@" 2>/dev/null | grep '^:'
}

test_the_completion_offers_every_command_and_option_the_help_lists() {
  local command option
  for option in $(listed_options); do
    offers "$option" | grep -qxF -- "$option" || fail "the completion does not offer $option"
  done
  for command in $(listed_commands); do
    offers '' | grep -qxF "$command" || fail "the completion does not offer $command"
    for option in $(listed_options "$command"); do
      offers "$command" "$option" | grep -qxF -- "$option" || fail "the completion does not offer $command $option"
    done
  done
}

test_the_completion_completes_commands_options_and_paths() {
  [[ $(offers pl) == plan ]] || fail "macelium pl: $(offers pl)"
  [[ $(offers plan --n) == --notify ]] || fail "plan --n: $(offers plan --n)"
  [[ $(offers help sett) == settings ]] || fail "help sett: $(offers help sett)"
  local words
  for words in 'init a-' 'bootstrap a-' 'setup me/state a-' 'settings --file a-f'; do
    # shellcheck disable=SC2086 # each case is its words
    [[ -z $(offers $words) && $(directive $words) == :0 ]] || fail "$words: not left to the shell's path completion"
  done
}

test_the_generated_completions_parse() {
  "$tool" completion bash | bash -n || fail "the bash completion does not parse"
  "$tool" completion zsh | zsh -n || fail "the zsh completion does not parse"
}

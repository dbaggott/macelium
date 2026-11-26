# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, sandbox, state, out and err
# plan's warnings about per-machine Brewfiles it does not read, and its
# comparison of the macOS settings.

test_plan_warns_when_local_brewfile_has_no_state_brewfile() {
  make_state macelium.conf $'contract 1\n'
  run plan
  assert_status 0
  assert_not_contains "$err" "Brewfile.local"

  mkdir -p "$HOME/.config/macelium"
  echo 'brew "jq"' >"$HOME/.config/macelium/Brewfile.local"
  run plan
  assert_status 0
  assert_contains "$err" "Warning: macelium reads ~/.config/macelium/Brewfile.local only with the state repo's Brewfile, and $state/Brewfile does not exist: its packages are not checked or installed"

  echo 'brew "git"' >"$state/Brewfile"
  run plan
  assert_not_contains "$err" "Brewfile.local"
}

# A settings domain may be a plist's path, which macOS's defaults accepts.
test_plan_compares_a_setting_whose_domain_is_a_path() {
  make_state macelium.conf $'contract 1\n' \
    macos.sh $'setting ~/Library/Preferences/com.example.plist greeting string hello\n'
  run plan
  assert_status 2
  assert_contains "$out" "$HOME/Library/Preferences/com.example.plist greeting: (not set) → hello"
  assert_contains "$STUB_LOG" "defaults export $HOME/Library/Preferences/com.example.plist -"
}

# The spinner while plan and apply check.

test_with_spinner_turns_beside_its_label_then_clears_its_line() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run_tty_raw 2 /bin/bash -c '"$1" __with-spinner "Working it out" sleep 0.5; printf "[done]\n"' _ "$harness"
  assert_status 0
  local raw
  raw=$(cat "$out")
  [[ $raw == *$'\r  '???' Working it out'* ]] || fail "no spinner frame was drawn beside the label"
  [[ $raw == *$'\r\033[K[done]'* ]] || fail "the line was not cleared"
}

test_with_spinner_off_a_terminal_draws_nothing() {
  local status
  "$harness" __with-spinner "Working it out" false >"$sandbox/out" </dev/null
  status=$?
  ((status == 1)) || fail "with_spinner returned $status, not the command's 1"
  [[ ! -s $sandbox/out ]] || fail "drew: $(cat "$sandbox/out")"
}

test_plan_on_a_terminal_shows_the_spinner_then_the_plan() {
  make_state macelium.conf $'contract 1\n'
  run_tty_raw 2 "$tool" plan
  assert_status 0
  local raw
  raw=$(cat "$out")
  [[ $raw == *' Comparing this machine with the state repo'* ]] || fail "no spinner while comparing"
  [[ $raw == *$'\r\033[K'*'No changes. This machine matches the state repo.'* ]] || fail "the spinner's line was not cleared before the plan"
}

test_with_spinner_cuts_its_line_to_the_terminal_width_and_turns_in_place() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run_tty_raw 2 /bin/bash -c 'stty cols 20; "$1" __with-spinner "a label far wider than the terminal" sleep 0.5' _ "$harness"
  assert_status 0
  local raw
  raw=$(cat "$out")
  [[ $raw == *$'\r  '???' a label far w'$'\0337\r  '???$'\0338'* ]] || fail "the line was not cut to 19 columns, or no frame was drawn in place"
}

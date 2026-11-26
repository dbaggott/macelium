# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, sandbox, state, out and err
# bootstrap's checkout, and the state repo's init_notes.

test_bootstrap_refuses_a_directory_without_manifest() {
  mkdir -p "$sandbox/not-state"
  run_tty -- "$tool" bootstrap "$sandbox/not-state"
  assert_status 1
  assert_contains "$out" "macelium bootstrap: no macelium.conf in $sandbox/not-state"
}

test_bootstrap_without_argument_uses_chezmoi_source_path() {
  # The stray line stops the bootstrap at its preflight, naming the list.
  make_state macelium.conf $'contract 1\n' \
    macos.sh $'defaults write com.example key -bool true\n'
  run_tty -- "$tool" bootstrap
  assert_status 1
  assert_contains "$STUB_LOG" "chezmoi source-path"
  assert_contains "$out" "$state/macos.sh:1: defaults write com.example key -bool true"
}

notes_state() {
  make_state macelium.conf $'contract 1\ninit_notes notes.txt\n' \
    notes.txt $'NOTES: chezmoi asks for your name.\n'
}

test_bootstrap_prints_init_notes_before_chezmoi_init() {
  notes_state
  run_tty -- "$tool" bootstrap "$state"
  assert_order "$out" "NOTES: chezmoi asks for your name." "==> chezmoi init" "STUB chezmoi init"
}

test_bootstrap_skips_init_notes_with_a_chezmoi_config() {
  notes_state
  mkdir -p "$HOME/.config/chezmoi"
  touch "$HOME/.config/chezmoi/chezmoi.toml"
  run_tty -- "$tool" bootstrap "$state"
  assert_contains "$out" "STUB chezmoi init"
  assert_not_contains "$out" "NOTES:"
}

# The banner.

test_bootstrap_opens_with_the_banner() {
  make_state macelium.conf $'contract 1\n'
  run_tty -- "$tool" bootstrap "$state"
  assert_order "$out" "________" "m a c e l i u m" "Checking what the bootstrap needs from macOS..."
}

test_banner_skips_a_terminal_too_narrow_or_short() {
  local size
  for size in 'rows 24 cols 63' 'rows 14 cols 80'; do
    # shellcheck disable=SC2016 # expanded by the inner bash
    run_tty_raw 1 /bin/bash -c 'stty $2; "$1" __banner' _ "$harness" "$size"
    assert_status 0
    [[ ! -s $out ]] || fail "the banner drew with $size"
  done
}

test_banner_shows_the_cursor_it_hid() {
  run_tty_raw 1 "$harness" __banner
  assert_status 0
  local raw
  raw=$(cat "$out")
  [[ $raw == *$'\033[?25l'* ]] || fail "the cursor was not hidden"
  [[ ${raw##*$'\033[?25l'} == *$'\033[?25h'* ]] || fail "the cursor was not shown again"
}

test_banner_without_color_under_no_color() {
  run_tty_raw 1 /usr/bin/env NO_COLOR=1 "$harness" __banner
  assert_status 0
  assert_contains "$out" "m a c e l i u m"
  if grep -qE $'\033\\[[0-9;]*m' "$out"; then fail "a color escape under NO_COLOR"; fi
}

test_banner_names_the_version_after_macelium() {
  run_tty_raw 1 /usr/bin/env NO_COLOR=1 "$harness" __banner
  assert_status 0
  assert_contains "$out" "m a c e l i u m  $version"
}

test_banner_ends_on_a_blank_line() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run_tty_raw 1 /usr/bin/env NO_COLOR=1 /bin/bash -c '"$1" __banner; echo after' _ "$harness"
  assert_status 0
  grep -A1 -F "m a c e l i u m" "$out" | tail -n 1 | grep -qx $'\r*' ||
    fail "no blank line after the banner"
}

# What the bootstrap says before sudo asks.

test_bootstrap_says_what_it_does_before_sudo_asks() {
  make_state macelium.conf $'contract 1\n' Brewfile $'cask "example"\n'
  export STUB_SUDO_ASKS=1
  run_tty -- "$tool" bootstrap "$state"
  assert_order "$out" "Macelium will now configure your computer according to your specifications." \
    "password one or more times as part of installation." "STUB sudo Password:"
}

# A logged step's display, its sudo detection, and its output. Its status
# line and the sudo detection on their own are internal/term's tests.

# Takes a step's command. Runs it as a logged step on a terminal, with a
# tick of a second, keeping what the terminal showed as raw bytes.
logged_step_on_tty() {
  run_tty_raw 4 "$harness" __logged-step --tick 1 step "$@"
}

waiting_hint_text='waiting for input above (likely a password)'

test_logged_step_leaves_a_sudo_prompt_on_screen() {
  # ps names a symlink by its own name, where the sudo stub is /bin/bash.
  mkdir -p "$sandbox/standin"
  ln -s /bin/bash "$sandbox/standin/sudo"
  logged_step_on_tty "$sandbox/standin/sudo" -c 'printf Password: >/dev/tty; read -r _ </dev/tty; echo answered >/dev/tty'
  assert_status 0
  local raw after waited
  raw=$(cat "$out")
  after=${raw#*Password:}
  [[ $after != "$raw" ]] || fail "no Password: prompt"
  # A spinner frame drawn between its sudo check and the prompt repaints only
  # the frame's cells, so the line holds no clear.
  [[ ${after%%$'\n'*} != *$'\033[K'* ]] || fail "the prompt's line was cleared"
  waited=${after%%answered*}
  [[ $waited != *$'\033[K'* && $waited != *" step,"* ]] || fail "the status was drawn while sudo waited"
  [[ $(grep -cF "$waiting_hint_text" "$out") == 1 ]] || fail "the waiting line is not shown once"
}

test_logged_step_stops_its_spinner_while_a_sudo_asks() {
  mkdir -p "$sandbox/standin"
  ln -s /bin/bash "$sandbox/standin/sudo"
  # The sudo starts once the status is drawn, between the step's ticks.
  # shellcheck disable=SC2016 # expanded by the inner bash
  logged_step_on_tty bash -c 'sleep 0.5; exec "$1" -c "printf Password: >/dev/tty; read -r _ </dev/tty; echo answered >/dev/tty"' \
    _ "$sandbox/standin/sudo"
  assert_status 0
  local raw waited frames
  raw=$(cat "$out")
  [[ $raw == *$'\0337'*Password:* ]] || fail "no spinner frame before the prompt"
  waited=${raw#*Password:}
  waited=${waited%%answered*}
  # One frame may fall between its sudo check and the prompt.
  frames=${waited//$'\0337'/$'\001'}
  frames=${frames//[!$'\001']/}
  ((${#frames} <= 1)) || fail "the spinner turned ${#frames} times while the sudo asked"
}

test_logged_step_clears_the_status_after_a_sudo_that_never_prompted() {
  mkdir -p "$sandbox/standin"
  ln -s /bin/bash "$sandbox/standin/sudo"
  mkfifo "$sandbox/answer"
  # Only the tick at 1 s sees the sudo, so no hint moves the cursor off the
  # status line. The output line comes once it has gone, with no Return typed.
  # shellcheck disable=SC2016 # expanded by the inner bash
  logged_step_on_tty bash -c 'sleep 0.5; { sleep 1; echo >"$2"; } & "$1" -c "read -r _ <\"\$0\"" "$2"; echo "Installing b"' \
    _ "$sandbox/standin/sudo" "$sandbox/answer"
  assert_status 0
  local raw before
  raw=$(cat "$out")
  [[ $raw == *"Installing b"* ]] || fail "no output line"
  before=${raw%%Installing b*}
  [[ $before == *$'\033[K' || $before == *$'\n' ]] || fail "the output line follows status text"
}

test_logged_step_starts_each_output_line_on_a_clear_line() {
  logged_step_on_tty bash -c 'echo "Installing a"; sleep 1.5; echo unfiltered; echo "Installing b"; sleep 1.5'
  assert_status 0
  local raw rest before count=0
  raw=$(cat "$out")
  rest=$raw
  while [[ $rest == *Installing* ]]; do
    before=${rest%%Installing*}
    [[ $before == *$'\033[K' || $before == *$'\n' ]] || fail "an output line follows status text"
    rest=${rest#*Installing}
    ((count++))
  done
  ((count == 2)) || fail "expected 2 output lines, got $count"
  [[ $raw == *" step, 1 s"* ]] || fail "no status line was drawn"
  assert_not_contains "$out" unfiltered
}

test_logged_step_turns_its_spinner_in_place() {
  logged_step_on_tty sleep 1.5
  assert_status 0
  local raw
  raw=$(cat "$out")
  [[ $raw == *$'\0337\r  '???$'\0338'* ]] || fail "no spinner frame was drawn in place"
}

test_logged_step_cuts_its_status_to_the_terminal_width() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run_tty_raw 3 /bin/bash -c 'stty cols 30; "$1" __logged-step --tick 1 "a step with a long name" sleep 1.5' \
    _ "$harness"
  assert_status 0
  local raw shown
  raw=$(cat "$out")
  [[ $raw == *" a step with a long"* ]] || fail "no status line was drawn"
  shown=${raw#*$'\r\033[K'}
  # A spinner frame starts by saving the cursor.
  shown=${shown%%[$'\r\033']*}
  # The row keeps room for sudo's Password: prompt.
  ((${#shown} == 20)) || fail "status is ${#shown} columns wide: $shown"
}

# Takes a step's name and command. Runs it as a logged step with no
# terminal and Homebrew's cache in the sandbox, setting status, out to its
# output and results to how it recorded the step.
logged_step_off_tty() {
  export STUB_BREW_CACHE=$sandbox/cache
  mkdir -p "$STUB_BREW_CACHE/downloads"
  out=$sandbox/out
  "$harness" __logged-step --results "$@" >"$out" 2>&1 </dev/null
  # shellcheck disable=SC2034 # assert_status reads it
  status=$?
  results=$(sed -n 's/^results: //p' "$out")
}

test_logged_step_off_a_terminal_prints_plain_lines() {
  logged_step_off_tty "brew bundle" brew bundle
  [[ $(cat "$out") != *[$'\r\033']* ]] || fail "a \\r or escape in the output"
  assert_contains "$out" "==> brew bundle (output in $HOME/bootstrap.log)"
  assert_contains "$STUB_LOG" "brew --cache"
  [[ $results == $'brew bundle\tok' ]] || fail "results: $results"
}

test_logged_step_records_a_failing_command() {
  logged_step_off_tty fails bash -c 'echo "Installing x"; echo "Error: it broke"; exit 3'
  assert_status 3
  assert_contains "$out" "Installing x"
  assert_contains "$out" "Failed, exit status 3:"
  assert_contains "$out" "Error: it broke"
  [[ $results == $'fails\tfailed' ]] || fail "results: $results"
  assert_not_contains "$STUB_LOG" "brew --cache"
}

test_logged_step_returns_at_once_when_its_command_does() {
  local started=$SECONDS
  logged_step_off_tty quick true
  ((SECONDS - started < 2)) || fail "took $((SECONDS - started)) s with a tick of 5 s"
}

test_bootstrap_applies_a_script_whose_path_has_a_space() {
  make_state macelium.conf $'contract 1\n'
  export STUB_CHEZMOI_MANAGED=$'.local/run once/setup.sh\n.local/other.sh\n'
  run_tty -- "$tool" bootstrap "$state"
  # The log joins arguments with spaces, so it shows a split path as one
  # apply line for each fragment.
  local applies
  applies=$(grep "^chezmoi apply --source $state $HOME/" "$STUB_LOG")
  [[ $applies == "chezmoi apply --source $state $HOME/.local/run once/setup.sh"$'\n'"chezmoi apply --source $state $HOME/.local/other.sh" ]] ||
    fail "the scripts' apply lines are:"$'\n'"$applies"
}

test_bootstrap_script_reading_input_leaves_the_list_alone() {
  make_state macelium.conf $'contract 1\n'
  export STUB_CHEZMOI_MANAGED=$'.local/first.sh\n.local/second.sh\n' STUB_CHEZMOI_APPLY_READS=1
  run_tty -- "$tool" bootstrap "$state"
  assert_contains "$STUB_LOG" "chezmoi apply --source $state $HOME/.local/first.sh"
  assert_contains "$STUB_LOG" "chezmoi apply --source $state $HOME/.local/second.sh"
  assert_not_contains "$STUB_LOG" "read stdin: .local/"
  assert_not_contains "$STUB_LOG" "read fd 3: .local/"
}

# A chezmoi setup that is not macelium's is refused, with a checkout named
# and with none, before anything changes. The checkout named is a state repo.

# Bootstraps with the checkout and without, each refused.
assert_bootstrap_refused() {
  listing_now
  run_tty -- "$tool" bootstrap "$state"
  assert_refused bootstrap
  run_tty -- "$tool" bootstrap
  assert_refused bootstrap
}

test_bootstrap_refuses_a_config_naming_a_git_tree_without_manifest() {
  make_state macelium.conf $'contract 1\n'
  other_source
  chezmoi_config "$other"
  assert_bootstrap_refused
  assert_contains "$out" "names a source in $other, which has no macelium.conf"
}

test_bootstrap_refuses_a_config_naming_a_missing_source() {
  make_state macelium.conf $'contract 1\n'
  chezmoi_config "$sandbox/missing"
  assert_bootstrap_refused
  assert_contains "$out" "If it named a macelium checkout that has moved or been removed, run \`chezmoi init --source <checkout>\`"
}

test_bootstrap_names_a_missing_directory_before_refusing_a_setup() {
  other_source
  chezmoi_config "$other"
  run_tty -- "$tool" bootstrap "$sandbox/missing"
  assert_status 1
  assert_contains "$out" "macelium bootstrap: no directory $sandbox/missing"
  assert_not_contains "$out" "not macelium's"
}

test_bootstrap_refuses_a_config_chezmoi_cannot_read() {
  make_state macelium.conf $'contract 1\n'
  chezmoi_config
  assert_bootstrap_refused
}

test_bootstrap_refuses_a_source_without_config() {
  make_state macelium.conf $'contract 1\n'
  mkdir -p "$HOME/.local/share/chezmoi"
  printf 'x\n' >"$HOME/.local/share/chezmoi/dot_zshrc"
  assert_bootstrap_refused
  assert_contains "$out" "$HOME/.local/share/chezmoi holds a chezmoi source, and there is no chezmoi config"
}

test_bootstrap_takes_a_config_naming_another_checkout() {
  make_state macelium.conf $'contract 1\n'
  local named=$state
  git clone -q "$sandbox/state.git" "$sandbox/second"
  chezmoi_config "$named"
  run_tty -- "$tool" bootstrap "$sandbox/second"
  assert_contains "$out" "STUB chezmoi init"
  assert_not_contains "$out" "not macelium's"
}

test_bootstrap_takes_a_config_naming_the_chezmoiroot_directory() {
  make_state macelium.conf $'contract 1\n' .chezmoiroot $'home\n' home/dot_zshrc $'x\n'
  chezmoi_config "$state/home"
  run_tty -- "$tool" bootstrap
  assert_contains "$out" "STUB chezmoi init"
  assert_not_contains "$out" "not macelium's"
}

test_bootstrap_takes_no_config_and_an_empty_source_directory() {
  make_state macelium.conf $'contract 1\n'
  mkdir -p "$HOME/.local/share/chezmoi"
  run_tty -- "$tool" bootstrap "$state"
  assert_contains "$out" "STUB chezmoi init"
  assert_not_contains "$out" "not macelium's"
}

# FileVault.

test_bootstrap_warns_when_filevault_is_off_and_goes_on() {
  make_state macelium.conf $'contract 1\n'
  export STUB_FDESETUP_STATUS='FileVault is Off.'
  run_tty -- "$tool" bootstrap "$state"
  assert_order "$out" "FYI: Your macOS FileVault is off." "Macelium will now configure your computer" "==> chezmoi init" "Steps:"
  grep -A2 -F "FYI: Your macOS FileVault is off." "$out" | tail -n 2 | head -n 1 | grep -q '^best practice' ||
    fail "the FileVault note's lines are not consecutive"
  sed -n '/^Steps:/,$p' "$out" | grep -qF "FileVault is off: enable it through System Settings -> Privacy & Security -> FileVault" ||
    fail "no FileVault warning at the end"
  assert_contains "$out" "Bootstrap complete, with 1 warning."
  export STUB_FDESETUP_STATUS=$'FileVault is Off.\nA line after it.'
  run_tty -- "$tool" bootstrap "$state"
  assert_contains "$out" "FYI: Your macOS FileVault is off."
}

test_bootstrap_says_nothing_of_filevault_when_on_or_unknown() {
  make_state macelium.conf $'contract 1\n'
  run_tty -- "$tool" bootstrap "$state"
  assert_contains "$STUB_LOG" "fdesetup status"
  assert_contains "$out" "STUB chezmoi init"
  assert_not_contains "$out" "FileVault"
  export STUB_FDESETUP_FAILS=1
  run_tty -- "$tool" bootstrap "$state"
  assert_contains "$out" "STUB chezmoi init"
  assert_not_contains "$out" "FileVault"
}

# The plan at the end.

test_bootstrap_says_where_unlisted_packages_came_from_only_when_there_are_some() {
  make_state macelium.conf $'contract 1\n' Brewfile $'brew "hello"\n'
  run_tty -- "$tool" bootstrap "$state"
  assert_order "$out" "==> Differences from the state repo (macelium plan)" "No changes. This machine matches the state repo." "Steps:"
  assert_not_contains "$out" "before the bootstrap"
  export STUB_BREW_UNLISTED=extra
  run_tty -- "$tool" bootstrap "$state"
  assert_order "$out" "Homebrew: installed but not listed" "They were on this Mac before the bootstrap" "formula extra"
}

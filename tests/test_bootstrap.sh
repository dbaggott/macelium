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
    run_tty_raw 1 /bin/bash -c 'stty $2; source "$1"; print_banner' _ "$tool" "$size"
    assert_status 0
    [[ ! -s $out ]] || fail "the banner drew with $size"
  done
}

test_banner_keeps_an_exit_trap_set_before_it() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run_tty_raw 1 /bin/bash -c 'source "$1"; trap "echo earlier trap ran" EXIT; print_banner' _ "$tool"
  assert_status 0
  assert_contains "$out" "earlier trap ran"
}

test_banner_without_color_under_no_color() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run_tty_raw 1 /usr/bin/env NO_COLOR=1 /bin/bash -c 'source "$1"; print_banner' _ "$tool"
  assert_status 0
  assert_contains "$out" "m a c e l i u m"
  if grep -qE $'\033\\[[0-9;]*m' "$out"; then fail "a color escape under NO_COLOR"; fi
}

test_banner_ends_on_a_blank_line() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run_tty_raw 1 /usr/bin/env NO_COLOR=1 /bin/bash -c 'source "$1"; print_banner; echo after' _ "$tool"
  assert_status 0
  grep -A1 -F "m a c e l i u m" "$out" | tail -n 1 | grep -qx $'\r*' ||
    fail "no blank line after the banner"
}

# What the bootstrap says before sudo asks.

homebrew_asks_text='Homebrew will ask you to authenticate again'

test_bootstrap_with_a_brewfile_says_homebrew_asks_again() {
  make_state macelium.conf $'contract 1\n' Brewfile $'cask "example"\n'
  run_tty -- "$tool" bootstrap "$state"
  assert_order "$out" "$homebrew_asks_text" "==> chezmoi init"
}

test_bootstrap_says_when_it_asks_for_the_password() {
  make_state macelium.conf $'contract 1\n'
  export STUB_SUDO_ASKS=1
  run_tty -- "$tool" bootstrap "$state"
  assert_order "$out" "You'll be asked to authenticate now." "STUB sudo Password:"
  assert_not_contains "$out" "$homebrew_asks_text"
}

test_bootstrap_with_cached_credentials_and_no_brewfile_says_neither() {
  make_state macelium.conf $'contract 1\n'
  run_tty -- "$tool" bootstrap "$state"
  assert_contains "$out" "==> chezmoi init"
  assert_not_contains "$out" "You'll be asked to authenticate"
  assert_not_contains "$out" "$homebrew_asks_text"
}

# A logged step's status line, its sudo detection, and its output.

sha=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# Sources macelium for its functions, with Homebrew's cache in the sandbox.
source_macelium() {
  # shellcheck source=/dev/null
  source "$tool"
  export STUB_BREW_CACHE=$sandbox/cache
  mkdir -p "$STUB_BREW_CACHE/downloads"
  step_log=$sandbox/bootstrap.log
  sizes=$sandbox/sizes
}

# Takes a download's name and a byte count, which it grows by.
grow() {
  head -c "$2" /dev/zero >>"$STUB_BREW_CACHE/downloads/$sha--$1.incomplete"
}

# Takes a tick's number, setting line to brew bundle's status at it.
status_at() {
  line=$(step_status "brew bundle" $(($1 * tick)) "$(brew --cache)" "$sizes" "$1")
}

test_step_status_shows_the_growing_download_with_its_rate() {
  source_macelium
  grow Name.dmg 10240
  grow Stale.dmg 4096
  status_at 0
  grow Name.dmg 2097152
  status_at 1
  [[ $line == "  ... brew bundle, 5 s: downloading Name.dmg, 2 MB, 409 KB/s" ]] || fail "status: $line"
}

test_step_status_shows_a_stopped_download_as_stalled() {
  source_macelium
  status_at 0
  grow Name.dmg 2097152
  status_at 1
  status_at 2
  status_at 3
  [[ $line == *"downloading Name.dmg"* ]] || fail "status before three ticks: $line"
  status_at 4
  [[ $line == "  ... brew bundle, 20 s: Name.dmg stalled at 2 MB, no growth for 15 s" ]] || fail "status: $line"
}

test_step_status_counts_the_other_growing_downloads() {
  source_macelium
  status_at 0
  grow Big.dmg 2097152
  grow Small.dmg 1024
  grow Other.pkg 1024
  status_at 1
  [[ $line == *"downloading Big.dmg, 2 MB, 409 KB/s (+2 more)" ]] || fail "status: $line"
}

test_step_status_without_downloads_shows_the_step_and_time() {
  source_macelium
  grow Stale.dmg 4096
  status_at 0
  status_at 13
  [[ $line == "  ... brew bundle, 1 min" ]] || fail "status: $line"
}

ps_output='    1     0 /sbin/launchd
  500     1 /bin/zsh
  600   500 /bin/bash
  601   600 /usr/bin/sudo
  602   600 /usr/bin/sudo
  603   602 /usr/sbin/installer
  700     1 /usr/bin/sudo'

test_prompting_sudo_finds_a_childless_sudo_below_the_root() {
  source_macelium
  [[ $(prompting_sudo "$ps_output" 500) == 601 ]] || fail "expected 601"
}

test_prompting_sudo_ignores_a_sudo_with_a_child_or_outside_the_root() {
  source_macelium
  if prompting_sudo "$(grep -v ' 601 ' <<<"$ps_output")" 500; then
    fail "found a sudo running a command, or one outside the tree"
  fi
}

# Takes a step's command. Runs it as a logged step on a terminal, with a
# tick of a second, keeping what the terminal showed as raw bytes.
logged_step_on_tty() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run_tty_raw 4 /bin/bash -c 'source "$1"; shift; tick=1 step_log=$HOME/bootstrap.log; run_logged_step step "$@"' \
    _ "$tool" "$@"
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

test_every_spinner_frame_is_as_wide_as_the_status_it_replaces() {
  source_macelium
  local frame
  for frame in "${spinner[@]}"; do
    ((${#frame} == 3)) || fail "frame [$frame] is ${#frame} columns wide"
  done
}

test_logged_step_cuts_its_status_to_the_terminal_width() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run_tty_raw 3 /bin/bash -c 'stty cols 30; source "$1"; tick=1 step_log=$HOME/bootstrap.log; run_logged_step "a step with a long name" sleep 1.5' \
    _ "$tool"
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

test_logged_step_off_a_terminal_prints_plain_lines() {
  source_macelium
  run_logged_step "brew bundle" brew bundle >"$sandbox/out" 2>&1
  out=$sandbox/out
  [[ $(cat "$out") != *[$'\r\033']* ]] || fail "a \\r or escape in the output"
  assert_contains "$out" "==> brew bundle (output in $step_log)"
  assert_contains "$STUB_LOG" "brew --cache"
  [[ $step_results == $'brew bundle\tok\n' ]] || fail "results: $step_results"
}

test_logged_step_records_a_failing_command() {
  source_macelium
  run_logged_step fails bash -c 'echo "Installing x"; echo "Error: it broke"; exit 3' >"$sandbox/out" 2>&1
  # shellcheck disable=SC2034 # assert_status reads it
  status=$?
  out=$sandbox/out
  assert_status 3
  assert_contains "$out" "Installing x"
  assert_contains "$out" "Failed, exit status 3:"
  assert_contains "$out" "Error: it broke"
  [[ $step_results == $'fails\tfailed\n' ]] || fail "results: $step_results"
  assert_not_contains "$STUB_LOG" "brew --cache"
}

test_logged_step_returns_at_once_when_its_command_does() {
  source_macelium
  local started=$SECONDS
  run_logged_step quick true >/dev/null
  ((SECONDS - started < 2)) || fail "took $((SECONDS - started)) s with a tick of $tick s"
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
  assert_order "$out" "Warning: FileVault is off" "==> chezmoi init" "Steps:"
  sed -n '/^Steps:/,$p' "$out" | grep -qF "Warning: FileVault is off" || fail "no FileVault warning at the end"
  assert_contains "$out" "System Settings -> Privacy & Security -> FileVault"
  assert_contains "$out" "Bootstrap complete, with 1 warning."
  export STUB_FDESETUP_STATUS=$'FileVault is Off.\nA line after it.'
  run_tty -- "$tool" bootstrap "$state"
  assert_contains "$out" "Warning: FileVault is off"
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

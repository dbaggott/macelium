# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, sandbox, state, out and err
# plan's warnings about per-machine Brewfiles it does not read, and its
# comparison of the macOS settings.

test_plan_warns_while_old_local_brewfile_exists() {
  make_state macelium.conf $'contract 1\n'
  run plan
  assert_status 0
  assert_not_contains "$err" "Brewfile.local"

  touch "$HOME/.Brewfile.local"
  run plan
  assert_status 0
  assert_contains "$err" "Warning: macelium does not read ~/.Brewfile.local: move it to ~/.config/macelium/Brewfile.local"
  [[ -e $HOME/.Brewfile.local ]] || fail "plan moved ~/.Brewfile.local"
}

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

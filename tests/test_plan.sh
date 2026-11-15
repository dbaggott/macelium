# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, sandbox, state, out and err
# plan's warnings about per-machine Brewfiles it does not read.

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

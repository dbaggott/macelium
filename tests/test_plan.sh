# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, sandbox, state, out and err
# plan's warning about the dotfiles command's per-machine Brewfile.

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

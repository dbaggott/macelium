# shellcheck shell=bash disable=SC2154 # tests/lib.sh sets tool, sandbox, state, out and err
# apply runs its steps in order: chezmoi apply, brew bundle over the state
# repo's Brewfile then the local one, mise install, the settings, the hooks.

test_apply_runs_steps_in_order() {
  make_state macelium.conf $'contract 1\n' \
    Brewfile $'brew "hello"\n' \
    macos.sh $'setting com.example.macelium-test greeting string hello\nrestart_on_change com.example.macelium-test MaceliumTest\n' \
    apps/one/after-apply $'echo "hook one ran" >>"$STUB_LOG"\n'
  mkdir -p "$HOME/.config/macelium"
  echo 'brew "tree"' >"$HOME/.config/macelium/Brewfile.local"
  export STUB_CHEZMOI_STATUS=' M .zshrc'$'\n'
  run_tty y -- "$tool" apply
  assert_status 0
  assert_contains "$out" "Apply complete"
  assert_order "$STUB_LOG" \
    "chezmoi apply --force" \
    "brew bundle --file=$state/Brewfile" \
    "brew bundle --file=$HOME/.config/macelium/Brewfile.local" \
    "mise -C $HOME install" \
    "defaults write com.example.macelium-test greeting -string hello" \
    "hook one ran"
}

test_apply_declined_changes_nothing() {
  make_state macelium.conf $'contract 1\n' \
    apps/one/after-apply $'echo "hook one ran" >>"$STUB_LOG"\n'
  run_tty n -- "$tool" apply
  assert_status 0
  assert_contains "$out" "No changes made."
  assert_not_contains "$STUB_LOG" "hook one ran"
  assert_not_contains "$STUB_LOG" "chezmoi apply"
}

test_apply_rereads_the_manifest_after_pulling() {
  make_state macelium.conf $'contract 1\n'
  # Another clone pushes a manifest for a newer macelium.
  git clone -q "$sandbox/state.git" "$sandbox/other"
  printf 'contract 2\n' >"$sandbox/other/macelium.conf"
  git -C "$sandbox/other" -c user.name=test -c user.email=test@example.com commit -q -am newer
  git -C "$sandbox/other" push -q
  run_tty y -- "$tool" apply
  assert_status 1
  assert_contains "$out" "upgrade macelium"
  assert_not_contains "$STUB_LOG" "chezmoi apply"
}

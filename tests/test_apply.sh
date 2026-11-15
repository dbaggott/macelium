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

# The self-upgrade: with macelium in the plan's upgrades, apply upgrades it
# before any other step and execs the upgraded command's apply, which plans
# and asks again.

# Takes the state repo's files after the manifest. Lists macelium as having an
# upgrade, and puts at $sandbox/prefix/bin/macelium, where brew --prefix
# leads, a macelium that records how it was run.
make_outdated_self() {
  make_state macelium.conf $'contract 1\n' \
    Brewfile $'brew "dbaggott/tap/macelium", trusted: true, start_service: true\n' "$@"
  export STUB_BREW_OUTDATED='Formula dbaggott/tap/macelium'
  export STUB_BREW_PREFIX=$sandbox/prefix
  mkdir -p "$STUB_BREW_PREFIX/bin"
  # shellcheck disable=SC2016 # expanded when the upgraded macelium runs
  printf '#!/bin/bash\necho "upgraded macelium $* MACELIUM_UPGRADED_FROM=$MACELIUM_UPGRADED_FROM" >>"$STUB_LOG"\n' \
    >"$STUB_BREW_PREFIX/bin/macelium"
  chmod +x "$STUB_BREW_PREFIX/bin/macelium"
}

test_apply_upgrades_itself_first_then_execs_the_new_version() {
  local version
  version=$(grep -E '^VERSION=' "$tool" | head -n 1 | cut -d '"' -f 2)
  make_outdated_self apps/one/after-apply $'echo "hook one ran" >>"$STUB_LOG"\n'
  export STUB_CHEZMOI_STATUS=' M .zshrc'$'\n'
  run_tty y -- "$tool" apply
  assert_status 0
  assert_contains "$out" "1 to upgrade"
  assert_order "$STUB_LOG" \
    "brew upgrade macelium" \
    "upgraded macelium apply MACELIUM_UPGRADED_FROM=$version"
  assert_not_contains "$STUB_LOG" "chezmoi apply"
  assert_not_contains "$STUB_LOG" "brew bundle --file"
  assert_not_contains "$STUB_LOG" "mise -C $HOME install"
  assert_not_contains "$STUB_LOG" "hook one ran"
}

test_apply_after_a_self_upgrade_leaves_macelium_to_brew_bundle() {
  make_outdated_self
  export MACELIUM_UPGRADED_FROM=0.0.1
  run_tty y -- "$tool" apply
  assert_status 0
  assert_contains "$out" "upgraded from 0.0.1"
  assert_contains "$out" "Apply complete"
  assert_not_contains "$STUB_LOG" "brew upgrade macelium"
  assert_not_contains "$STUB_LOG" "upgraded macelium"
  assert_contains "$STUB_LOG" "brew bundle --file=$state/Brewfile"
}

test_apply_stops_when_the_self_upgrade_fails() {
  make_outdated_self
  export STUB_BREW_UPGRADE_FAILS=1
  run_tty y -- "$tool" apply
  assert_status 1
  assert_order "$out" "the upgrade failed" "No changes made."
  assert_not_contains "$STUB_LOG" "upgraded macelium"
  assert_not_contains "$STUB_LOG" "chezmoi apply"
  assert_not_contains "$STUB_LOG" "brew bundle --file"
  assert_not_contains "$STUB_LOG" "mise -C $HOME install"
}

test_apply_declined_with_macelium_outdated_runs_nothing() {
  make_outdated_self
  run_tty n -- "$tool" apply
  assert_status 0
  assert_contains "$out" "No changes made."
  assert_not_contains "$STUB_LOG" "brew upgrade"
  assert_not_contains "$STUB_LOG" "upgraded macelium"
  assert_not_contains "$STUB_LOG" "chezmoi apply"
}

test_apply_with_another_formula_outdated_does_not_upgrade_itself() {
  make_outdated_self
  export STUB_BREW_OUTDATED='Formula hello'
  run_tty y -- "$tool" apply
  assert_status 0
  assert_contains "$out" "Apply complete"
  assert_not_contains "$STUB_LOG" "brew upgrade"
  assert_not_contains "$STUB_LOG" "upgraded macelium"
  assert_contains "$STUB_LOG" "brew bundle --file=$state/Brewfile"
}

test_apply_stops_when_the_upgraded_macelium_is_not_under_the_prefix() {
  make_outdated_self
  export STUB_BREW_PREFIX=$sandbox/empty-prefix
  run_tty y -- "$tool" apply
  assert_status 1
  assert_order "$STUB_LOG" "brew upgrade macelium" "brew --prefix"
  assert_contains "$out" "stopped: macelium was upgraded, but not found under brew --prefix to run"
  assert_not_contains "$STUB_LOG" "chezmoi apply"
  assert_not_contains "$STUB_LOG" "brew bundle --file"
}

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

# apply's brew bundle and mise install steps run as logged steps: their
# output goes to macelium-apply.log, and the terminal shows only Homebrew's
# progress lines.

apply_log_path() {
  echo "$HOME/Library/Logs/macelium-apply.log"
}

test_apply_logs_its_brew_bundle_and_mise_install_steps() {
  make_state macelium.conf $'contract 1\n' Brewfile $'brew "hello"\n'
  export STUB_CHEZMOI_STATUS=' M .zshrc'$'\n'
  export STUB_BREW_BUNDLE_OUTPUT=$'Using hello\nInstalling tree\nUpgrading wget\nTapping some/tap\nDownloading tree.tar.gz'
  run_tty y -- "$tool" apply
  assert_status 0
  local log
  log=$(apply_log_path)
  assert_contains "$out" "==> brew bundle, the state repo's Brewfile (output in $log)"
  assert_contains "$out" "==> mise install (output in $log)"
  assert_contains "$out" "Installing tree"
  assert_contains "$out" "Upgrading wget"
  assert_contains "$out" "Tapping some/tap"
  assert_not_contains "$out" "Using hello"
  assert_not_contains "$out" "Downloading tree.tar.gz"
  assert_contains "$log" "brew bundle --file=$state/Brewfile"
  assert_contains "$log" "mise -C $HOME install"
  assert_contains "$log" "Using hello"
  assert_contains "$log" "Downloading tree.tar.gz"
  assert_contains "$log" "Installing tree"
  assert_contains "$out" "Apply complete"
}

test_apply_stops_when_brew_bundle_fails() {
  make_state macelium.conf $'contract 1\n' Brewfile $'brew "hello"\n'
  export STUB_CHEZMOI_STATUS=' M .zshrc'$'\n'
  export STUB_BREW_BUNDLE_FAILS=1
  run_tty y -- "$tool" apply
  assert_status 1
  assert_order "$out" "Failed, exit status 1:" "Error: the bundle failed" "macelium apply: stopped: brew bundle, the state repo's Brewfile failed"
  assert_contains "$(apply_log_path)" "Error: the bundle failed"
  assert_not_contains "$STUB_LOG" "mise -C $HOME install"
  assert_not_contains "$out" "Apply complete"
}

test_apply_says_what_to_do_when_macos_refuses_a_cask_upgrade() {
  make_state macelium.conf $'contract 1\n' Brewfile $'cask "shottr"\n'
  export STUB_CHEZMOI_STATUS=' M .zshrc'$'\n'
  export STUB_BREW_BUNDLE_OUTPUT="chown: /Applications/Shottr.app/Contents: Operation not permitted
Error: shottr: It seems there is already an App at '/opt/homebrew/Caskroom/shottr/1.10.0/Shottr.app'."
  export STUB_BREW_BUNDLE_FAILS=1
  run_tty y -- "$tool" apply
  assert_status 1
  assert_order "$out" "Error: the bundle failed" "App Management (System Settings → Privacy & Security → App Management)" \
    "mv /opt/homebrew/Caskroom/shottr/1.10.0/Shottr.app ~/.Trash/" "macelium apply: stopped: brew bundle, the state repo's Brewfile failed"
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
    Brewfile $'brew "dbaggott/tap/macelium", trusted: true, restart_service: :always\n' "$@"
  export STUB_BREW_OUTDATED='Formula dbaggott/tap/macelium'
  export STUB_BREW_PREFIX=$sandbox/prefix
  mkdir -p "$STUB_BREW_PREFIX/bin"
  # shellcheck disable=SC2016 # expanded when the upgraded macelium runs
  printf '#!/bin/bash\necho "upgraded macelium $* MACELIUM_UPGRADED_FROM=$MACELIUM_UPGRADED_FROM" >>"$STUB_LOG"\n' \
    >"$STUB_BREW_PREFIX/bin/macelium"
  chmod +x "$STUB_BREW_PREFIX/bin/macelium"
}

test_apply_upgrades_itself_first_then_execs_the_new_version() {
  make_outdated_self apps/one/after-apply $'echo "hook one ran" >>"$STUB_LOG"\n' \
    macos.sh $'setting com.example.macelium-test greeting string hello\n'
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

# apply compares the settings twice, at its plan and again before writing
# them, and each comparison exports a domain once, apart from its current-host
# settings.
test_apply_exports_each_domain_once_per_comparison() {
  make_state macelium.conf $'contract 1\n' \
    macos.sh $'setting com.example.a one string x\nsetting com.example.a two string y\nsetting --current-host com.example.a three string z\nsetting --current-host com.example.a four string w\n'
  run_tty y -- "$tool" apply
  assert_status 0
  local n
  n=$(grep -cxF "defaults export com.example.a -" "$STUB_LOG")
  ((n == 2)) || fail "exported com.example.a $n times, expected 2"
  n=$(grep -cxF "defaults -currentHost export com.example.a -" "$STUB_LOG")
  ((n == 2)) || fail "exported com.example.a for the current host $n times, expected 2"
}

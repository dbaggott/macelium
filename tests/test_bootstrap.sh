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

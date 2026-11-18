# shellcheck shell=bash disable=SC2154,SC2034 # tests/lib.sh sets tool, sandbox, eof, and reads out, err and status
# shellcheck disable=SC2088,SC2016 # a ~ or $ in quotes is text init prints or a file holds
# init, with brew bundle dump and gh stubbed.

# A Mac whose Homebrew dumps $STUB_BREW_DUMP, macelium's line as dump writes
# it included, and whose gh is signed in as $STUB_GH_USER, a gh api user
# reply, when that is set, and else signed out. The state repo goes to
# $repo.
init_mac() {
  repo=$sandbox/state
  export STUB_BREW_DUMP=$'tap "dbaggott/tap"\nbrew "jq"\nbrew "dbaggott/tap/macelium", trusted: true\ncask "firefox"'
  cat >"$sandbox/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >>"$STUB_LOG"
[[ -n ${STUB_GH_USER:-} ]] || exit 1
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "api user") printf '%s\n' "$STUB_GH_USER" ;;
esac
STUB
  chmod +x "$sandbox/bin/gh"
  unset STUB_GH_USER
}

# Takes a file under the home directory and its content.
home_file() {
  mkdir -p "$(dirname "$HOME/$1")"
  printf '%s' "$2" >"$HOME/$1"
}

# A ~/.gitconfig naming its user, which the name and email default to.
git_user() {
  git config --global user.name 'Git Name'
  git config --global user.email git@example.com
}

test_init_writes_the_layout_and_one_commit() {
  init_mac
  git_user
  run_tty '' '' n -- "$tool" init "$repo"
  assert_status 0
  [[ $(cat "$repo/macelium.conf") == *$'\ncontract 1' ]] || fail "macelium.conf: $(cat "$repo/macelium.conf")"
  [[ $(cat "$repo/.chezmoiroot") == home ]] || fail ".chezmoiroot: $(cat "$repo/.chezmoiroot")"
  ! grep -qv '^#' "$repo/macos.sh" || fail "macos.sh holds more than comments"
  assert_contains "$repo/macos.sh" "https://github.com/dbaggott/macelium#the-settings-list"
  assert_contains "$repo/home/.chezmoi.toml.tmpl" 'sourceDir = {{ .chezmoi.workingTree | quote }}'
  assert_contains "$repo/home/.chezmoidata.toml" 'name = "Git Name"'
  assert_contains "$repo/home/.chezmoidata.toml" 'email = "git@example.com"'
  [[ ! -e $repo/init-notes.txt ]] || fail "init wrote init-notes.txt"
  [[ $(git -C "$repo" ls-files) == $'.chezmoiroot\nBrewfile\nhome/.chezmoi.toml.tmpl\nhome/.chezmoidata.toml\nmacelium.conf\nmacos.sh' ]] ||
    fail "files: $(git -C "$repo" ls-files)"
  [[ $(git -C "$repo" rev-list --count HEAD) == 1 ]] || fail "more than one commit"
  [[ -z $(git -C "$repo" status --porcelain) ]] || fail "uncommitted: $(git -C "$repo" status --porcelain)"
  [[ -z $(git -C "$repo" remote) ]] || fail "a remote: $(git -C "$repo" remote)"
  assert_not_contains "$STUB_LOG" "chezmoi"
  assert_contains "$out" "State repo: $repo, with one commit and no remote."
}

test_init_writes_the_brewfile_from_the_dump() {
  init_mac
  git_user
  run_tty '' '' n -- "$tool" init "$repo"
  assert_status 0
  assert_contains "$STUB_LOG" "brew bundle dump --formula --cask --tap --file=-"
  [[ $(cat "$repo/Brewfile") == $'tap "dbaggott/tap"\nbrew "jq"\nbrew "dbaggott/tap/macelium", trusted: true, restart_service: :always\ncask "firefox"' ]] ||
    fail "Brewfile: $(cat "$repo/Brewfile")"
}

test_init_adds_the_macelium_line_when_the_dump_has_none() {
  init_mac
  git_user
  export STUB_BREW_DUMP=$'brew "jq"'
  run_tty '' '' n -- "$tool" init "$repo"
  assert_status 0
  [[ $(cat "$repo/Brewfile") == $'brew "jq"\nbrew "dbaggott/tap/macelium", trusted: true, restart_service: :always' ]] ||
    fail "Brewfile: $(cat "$repo/Brewfile")"
}

test_init_defaults_to_the_git_config_before_gh() {
  init_mac
  git_user
  export STUB_GH_USER='{"name":"Gh Name","id":42,"login":"gh-user"}'
  run_tty 'Edited Name' '' n -- "$tool" init "$repo"
  assert_status 0
  assert_contains "$out" "Name [Git Name]:"
  assert_contains "$out" "Email [git@example.com]:"
  assert_contains "$repo/home/.chezmoidata.toml" 'name = "Edited Name"'
  assert_contains "$repo/home/.chezmoidata.toml" 'email = "git@example.com"'
}

test_init_defaults_to_gh_and_commits_with_no_git_identity() {
  init_mac
  export GIT_CONFIG_NOSYSTEM=1
  export STUB_GH_USER='{"name":"Gh Name","id":42,"login":"gh-user"}'
  run_tty '' '' -- "$tool" init "$repo"
  assert_status 0
  assert_contains "$out" "Name [Gh Name]:"
  assert_contains "$out" "Email [42+gh-user@users.noreply.github.com]:"
  [[ $(git -C "$repo" log -1 --format='%an <%ae> %cn <%ce>') == 'Gh Name <42+gh-user@users.noreply.github.com> Gh Name <42+gh-user@users.noreply.github.com>' ]] ||
    fail "commit: $(git -C "$repo" log -1 --format='%an <%ae> %cn <%ce>')"
}

test_init_asks_with_no_default_when_neither_names_one() {
  init_mac
  run_tty 'Typed "Name"' '' typed@example.com -- "$tool" init "$repo"
  assert_status 0
  assert_contains "$out" "Name: "
  assert_contains "$repo/home/.chezmoidata.toml" 'name = "Typed \"Name\""'
  assert_contains "$repo/home/.chezmoidata.toml" 'email = "typed@example.com"'
}

test_init_offers_only_the_files_that_exist() {
  init_mac
  home_file .zshrc $'alias ll="ls -l"\n'
  run_tty Name me@example.com n -- "$tool" init "$repo"
  assert_status 0
  assert_contains "$out" "~/.zshrc goes into the state repo, and will be published if the repo is public."
  assert_contains "$out" "a password manager or the Keychain"
  assert_not_contains "$out" "~/.gitconfig goes"
  assert_not_contains "$out" "config.toml goes"
  [[ ! -e $repo/home/dot_zshrc ]] || fail "captured on no"
}

test_init_public_says_the_files_will_be_published() {
  init_mac
  git_user
  home_file .config/mise/config.toml $'[tools]\nnode = "22"\n'
  run_tty '' '' y y -- "$tool" init --public "$repo"
  assert_status 0
  assert_contains "$out" "~/.gitconfig goes into the state repo, and will be published with it, since the repo is public."
  assert_contains "$out" "~/.config/mise/config.toml goes into the state repo, and will be published with it, since the repo is public."
  assert_not_contains "$out" "if the repo is public"
  cmp -s "$HOME/.config/mise/config.toml" "$repo/home/dot_config/mise/config.toml" || fail "the mise config changed"
}

test_init_templates_the_gitconfig() {
  init_mac
  home_file .gitconfig $'[user]\n\tname = Git Name\n\temail = git@example.com\n[alias]\n\tps = !docker ps --format \'{{.Names}}\'\n'
  run_tty '' '' y -- "$tool" init "$repo"
  assert_status 0
  local captured=$repo/home/dot_gitconfig.tmpl
  assert_contains "$captured" $'\tname = {{ .name }}'
  assert_contains "$captured" $'\temail = {{ .email }}'
  assert_contains "$captured" $'--format \'{{ "{{" }}.Names}}\''
  [[ $(tail -n 2 "$captured") == $'[include]\n\tpath = ~/.gitconfig.local' ]] || fail "last: $(tail -n 2 "$captured")"
  assert_contains "$HOME/.gitconfig" $'\tname = Git Name'
  [[ ! -e $HOME/.gitconfig.local ]] || fail "wrote ~/.gitconfig.local with nothing to move"
}

test_init_gitconfig_template_renders_as_the_original() {
  init_mac
  home_file .gitconfig $'[user]\n\tname = Git Name\n\temail = git@example.com\n[alias]\n\tps = !docker ps --format \'{{.Names}} {{ .Image }}\'\n'
  run_tty '' '' y -- "$tool" init "$repo"
  assert_status 0
  # The real chezmoi, past the stub.
  local chezmoi rendered
  chezmoi=$(PATH=${PATH#"$sandbox/bin:"} command -v chezmoi) || fail "chezmoi is not installed"
  rendered=$("$chezmoi" --source "$repo/home" execute-template <"$repo/home/dot_gitconfig.tmpl") ||
    fail "the template did not render: $rendered"
  [[ $rendered == "$(cat "$HOME/.gitconfig")"$'\n\n[include]\n\tpath = ~/.gitconfig.local' ]] ||
    fail "rendered: $rendered"
}

test_init_keeps_a_gitconfig_include_that_is_already_last() {
  init_mac
  home_file .gitconfig $'[core]\n\teditor = vim\n[include]\n\tpath = ~/.gitconfig.local\n'
  home_file .gitconfig.local $'[user]\n\tname = Local Name\n\temail = local@example.com\n'
  run_tty '' '' y -- "$tool" init "$repo"
  assert_status 0
  assert_contains "$out" "Name [Local Name]:"
  [[ $(grep -c '^\[include\]' "$repo/home/dot_gitconfig.tmpl") == 1 ]] || fail "dot_gitconfig.tmpl: $(cat "$repo/home/dot_gitconfig.tmpl")"
}

test_init_commits_past_a_global_hook_and_signing() {
  init_mac
  git_user
  mkdir -p "$sandbox/hooks"
  printf '#!/bin/sh\nexit 1\n' >"$sandbox/hooks/pre-commit"
  chmod +x "$sandbox/hooks/pre-commit"
  git config --global core.hooksPath "$sandbox/hooks"
  git config --global commit.gpgsign true
  git config --global gpg.program false
  run_tty '' '' n -- "$tool" init "$repo"
  assert_status 0
  [[ $(git -C "$repo" rev-list --count HEAD) == 1 ]] || fail "no commit"
}

test_init_ends_the_zshrc_with_the_local_line() {
  init_mac
  git_user
  home_file .zshrc $'alias ll="ls -l"\n'
  run_tty '' '' n y -- "$tool" init "$repo"
  assert_status 0
  [[ $(cat "$repo/home/dot_zshrc") == $'alias ll="ls -l"\n[[ -r ~/.zshrc.local ]] && source ~/.zshrc.local' ]] ||
    fail "dot_zshrc: $(cat "$repo/home/dot_zshrc")"
}

secret_zshrc=$'export PATH="$HOME/bin:$PATH"
export GITHUB_TOKEN=abc
export MY_SECRET_THING=abc
export API_KEY=abc
export DB_PASSWORD=abc
alias gh1="GH=ghp_abc1 gh"
PAT=github_pat_abc2
OPENAI="sk-abc3"
AWS=AKIAABC4
SLACK=xoxb-abc5
proxy=https://me:pw@proxy.example.com
alias ll="ls -l"
'

secret_gitconfig=$'[user]
\tname = Git Name
\temail = git@example.com
[http "https://example.com"]
\tsslVerify = true
\textraHeader = Authorization: Bearer abc
[url "https://me:abc@github.com/"]
\tinsteadOf = https://github.com/
[core]
\teditor = vim
'

test_init_moves_the_lines_that_look_like_secrets() {
  init_mac
  home_file .zshrc "$secret_zshrc"
  home_file .gitconfig "$secret_gitconfig"
  run_tty '' '' y y y y -- "$tool" init "$repo"
  assert_status 0
  local line
  while IFS= read -r line; do
    [[ $line == 'export PATH='* || $line == 'alias ll='* || -z $line ]] && continue
    assert_contains "$out" "  $line"
    assert_contains "$HOME/.zshrc.local" "$line"
    assert_not_contains "$repo/home/dot_zshrc" "$line"
  done <<<"$secret_zshrc"
  assert_contains "$repo/home/dot_zshrc" 'alias ll="ls -l"'
  assert_contains "$repo/home/dot_zshrc" 'export PATH="$HOME/bin:$PATH"'
  [[ $(cat "$HOME/.gitconfig.local") == $'[http "https://example.com"]\n\textraHeader = Authorization: Bearer abc\n[url "https://me:abc@github.com/"]\n\tinsteadOf = https://github.com/' ]] ||
    fail ".gitconfig.local: $(cat "$HOME/.gitconfig.local")"
  local captured=$repo/home/dot_gitconfig.tmpl
  assert_contains "$captured" $'[http "https://example.com"]\n'
  assert_contains "$captured" $'\tsslVerify = true'
  assert_not_contains "$captured" 'extraHeader'
  assert_not_contains "$captured" 'me:abc'
  assert_contains "$captured" $'\teditor = vim'
  [[ $(stat -f %Lp "$HOME/.zshrc.local") == 600 ]] || fail ".zshrc.local mode $(stat -f %Lp "$HOME/.zshrc.local")"
  [[ $(stat -f %Lp "$HOME/.gitconfig.local") == 600 ]] || fail ".gitconfig.local mode $(stat -f %Lp "$HOME/.gitconfig.local")"
  [[ $(cat "$HOME/.zshrc") == "${secret_zshrc%$'\n'}" ]] || fail "~/.zshrc changed"
  [[ $(cat "$HOME/.gitconfig") == "${secret_gitconfig%$'\n'}" ]] || fail "~/.gitconfig changed"
}

test_init_appends_to_a_local_file_and_keeps_declined_lines() {
  init_mac
  git_user
  home_file .zshrc $'export GITHUB_TOKEN=abc\n'
  home_file .zshrc.local $'export EARLIER=1\n'
  chmod 644 "$HOME/.zshrc.local"
  run_tty '' '' n y y -- "$tool" init "$repo"
  assert_status 0
  [[ $(cat "$HOME/.zshrc.local") == $'export EARLIER=1\nexport GITHUB_TOKEN=abc' ]] || fail ".zshrc.local: $(cat "$HOME/.zshrc.local")"
  [[ $(stat -f %Lp "$HOME/.zshrc.local") == 600 ]] || fail ".zshrc.local mode $(stat -f %Lp "$HOME/.zshrc.local")"

  rm -rf "$repo"
  run_tty '' '' n y n -- "$tool" init "$repo"
  assert_status 0
  assert_contains "$repo/home/dot_zshrc" 'export GITHUB_TOKEN=abc'
}

test_init_refuses_a_path_that_is_not_empty() {
  init_mac
  mkdir -p "$sandbox/full"
  touch "$sandbox/full/file" "$sandbox/plain-file"
  local path
  for path in "$sandbox/full" "$sandbox/plain-file"; do
    run init "$path"
    assert_status 1
    assert_contains "$err" "macelium init: $path exists and is not empty"
  done
  [[ $(ls -A "$sandbox/full") == file && ! -s $sandbox/plain-file ]] || fail "it wrote to the path"
  [[ ! -s $STUB_LOG ]] || fail "it ran: $(cat "$STUB_LOG")"
}

test_init_takes_an_empty_directory() {
  init_mac
  git_user
  mkdir -p "$repo"
  run_tty '' '' n -- "$tool" init "$repo"
  assert_status 0
  [[ -f $repo/macelium.conf ]] || fail "no macelium.conf"
}

test_init_without_a_path_prints_usage() {
  run init --public
  assert_status 1
  assert_contains "$err" "Usage: macelium init [--public] <path>"
}

test_init_end_of_file_takes_the_defaults_and_declines_every_capture() {
  init_mac
  git_user
  home_file .zshrc $'alias ll="ls -l"\n'
  home_file .config/mise/config.toml $'[tools]\n'
  # The name, the email, three captures, and one more.
  run_tty "$eof" "$eof" "$eof" "$eof" "$eof" "$eof" -- "$tool" init "$repo"
  assert_status 0
  assert_contains "$repo/home/.chezmoidata.toml" 'name = "Git Name"'
  [[ $(git -C "$repo" ls-files home) == $'home/.chezmoi.toml.tmpl\nhome/.chezmoidata.toml' ]] ||
    fail "captured: $(git -C "$repo" ls-files home)"
}

test_init_end_of_file_with_no_default_stops_with_nothing_written() {
  init_mac
  # The email, and one more.
  run_tty Name "$eof" "$eof" -- "$tool" init "$repo"
  assert_status 1
  assert_contains "$out" "macelium init: no answer, so nothing was written"
  [[ ! -e $repo ]] || fail "it wrote $repo"
  assert_not_contains "$STUB_LOG" "brew"
}

test_init_end_of_file_after_a_partly_typed_name_stops_with_nothing_written() {
  init_mac
  git_user
  # The first $eof hands bash the typed text, the second ends its read, then
  # one more.
  run_tty "Part$eof$eof" "$eof" -- "$tool" init "$repo"
  assert_status 1
  assert_contains "$out" "macelium init: no answer, so nothing was written"
  [[ ! -e $repo ]] || fail "it wrote $repo"
}

test_ci_checks_step_has_a_timeout() {
  awk '/- name: Run the checks/ { step = 1; next } step && /- name:/ { exit } step && /timeout-minutes:/ { found = 1 } END { exit !found }' \
    "$(dirname "$tool")/.github/workflows/ci.yml" || fail "Run the checks has no timeout-minutes"
}

# A chezmoi setup that is not macelium's is refused before any prompt or
# write.

# Runs init, refused, with nothing written at the path or under ~.
assert_init_refused() {
  listing_now
  run_tty -- "$tool" init "$repo"
  assert_refused init
  [[ ! -e $repo ]] || fail "init wrote $repo"
}

test_init_refuses_a_config_naming_a_git_tree_without_manifest() {
  init_mac
  other_source
  chezmoi_config "$other"
  assert_init_refused
}

test_init_refuses_a_config_naming_a_missing_source() {
  init_mac
  chezmoi_config "$sandbox/missing"
  assert_init_refused
}

test_init_refuses_a_config_chezmoi_cannot_read() {
  init_mac
  chezmoi_config
  assert_init_refused
}

test_init_refuses_a_source_without_config() {
  init_mac
  mkdir -p "$HOME/.local/share/chezmoi"
  printf 'x\n' >"$HOME/.local/share/chezmoi/dot_zshrc"
  assert_init_refused
}

# Takes the path to init, and checks that init runs to its end there.
assert_init_passes() {
  init_mac
  repo=$1
  git_user
  run_tty '' '' n -- "$tool" init "$repo"
  assert_status 0
  assert_not_contains "$out" "not macelium's"
  assert_contains "$out" "State repo: $repo, with one commit and no remote."
}

test_init_takes_a_config_naming_a_macelium_checkout() {
  make_state macelium.conf $'contract 1\n' .chezmoiroot $'home\n' home/dot_zshrc $'x\n'
  chezmoi_config "$state"
  assert_init_passes "$sandbox/new"
  chezmoi_config "$state/home"
  assert_init_passes "$sandbox/new2"
}

test_init_takes_no_config_and_an_empty_source_directory() {
  mkdir -p "$HOME/.local/share/chezmoi"
  assert_init_passes "$sandbox/new"
}

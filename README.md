# macelium

Sets up a Mac from a state repo, and keeps it there. The state repo holds
the machine's dotfiles as a [chezmoi](https://www.chezmoi.io) source, its
Homebrew packages as a Brewfile, its macOS settings as a list, and hooks
for the apps that need one. macelium compares the machine with it, in the
shape of terraform's plan and apply:

- `macelium plan` prints every difference, and changes nothing.
- `macelium apply` prints the plan, asks, and then brings the machine in line.
- `macelium bootstrap` sets up a new machine from a checkout.
- `macelium init` captures a Mac into a new state repo.
- A daily `macelium plan --notify`, the Homebrew formula's service, posts a
  notification when the machine has drifted.

It needs macOS, Homebrew, chezmoi, mise and jq.

## Install

On a new Mac, paste this into Terminal, with your state repo, and follow
what it asks:

```sh
curl -fsSL https://github.com/dbaggott/macelium/releases/latest/download/install.sh | bash -s <repo> [<path>]
```

`<repo>` is a GitHub `<owner>/<repo>`, or the repo's git URL on any host:
`https://host/path`, `ssh://user@host/path`, or `user@host:path`.

`<path>` is where the state repo is cloned. Unless given, it is
`<dir>/<name>`, with the repo's name, where `<dir>` is the first of `~/Developer`, `~/git`,
`~/src`, `~/code` and `~/Projects` that exists, else your home directory.
The installer prints the path it chose.

[`install.sh`](install.sh), in order:

1. installs Homebrew, when neither `/opt/homebrew` nor `/usr/local` holds it
2. installs macelium, `brew install dbaggott/tap/macelium`
3. on GitHub, when the state repo can't be read without signing in, signs in
   with `gh auth login`, unless `gh` already is, and runs
   `gh auth setup-git`, so git can fetch it. On another host, it says the
   host needs a personal access token or a registered SSH key, since account
   passwords are refused over HTTPS, and leaves the sign-in to git and its
   credential helper.
4. clones the state repo to `<path>`
5. runs `macelium bootstrap <path>`, and exits with its status if it fails
6. on GitHub, when the state repo was read without signing in and `gh` isn't
   signed in, offers the same sign-in, so you can push changes from this
   machine. It defaults to yes.

`gh auth login` asks for its minimum scopes, `repo`, `read:org` and `gist`,
and `repo` reaches every repo the account can, not only the state repo.

It skips each step already done, so pasting it again picks up where it
stopped. It refuses a `<path>` that holds anything but a clone of the state
repo, before changing anything. A clone counts whichever URL form names its
remote; on GitHub, in any case.

## The state repo

A state repo is a git checkout with an upstream. At its root:

```
macelium.conf        the manifest (below)
Brewfile             the Homebrew packages every machine has
macos.sh             the macOS settings list
apps/<app>/          hooks and manual steps for one app
.chezmoiroot         optional: the chezmoi source is a subdirectory
<chezmoi source>     the dotfiles, as chezmoi lays them out
```

Every part but `macelium.conf` is optional, and the manifest can name other
paths for them. A part that is missing is skipped, and has no section in the
plan. [`example/`](example/) is a state repo using every part, and CI
bootstraps a runner from it.

### The chezmoi config

macelium finds the state repo through `chezmoi source-path`, so after
`bootstrap` the chezmoi config has to name the checkout as its `sourceDir`.
The state repo's config template writes it:

```
sourceDir = {{ .chezmoi.workingTree | quote }}
```

`.chezmoi.workingTree` is the checkout that `chezmoi init --source` names.
Run `chezmoi init --source` on a git worktree of the state repo, and the
config names the worktree, so chezmoi, and with it macelium, then reads the
worktree in place of the checkout. Run `chezmoi init --source <checkout>`
again to go back.

### Person values and machine differences

What every machine shares and what one machine needs differently go in
different places, and secrets in neither:

- **Values every machine shares**, such as your name and email, go in
  `home/.chezmoidata.toml`, which templates read: a `dot_gitconfig.tmpl` can
  write `name = {{ .name }}`. `macelium init` writes `name` and `email`
  there.
- **One machine's differences**, such as a work email or work shell setup, go
  in `~/.gitconfig.local` and `~/.zshrc.local`. They are not in the state
  repo, and the managed files include them when present: `~/.gitconfig` ends
  with

  ```
  [include]
  	path = ~/.gitconfig.local
  ```

  and `~/.zshrc` with

  ```sh
  [[ -r ~/.zshrc.local ]] && source ~/.zshrc.local
  ```

  `macelium init` adds both when it captures those files.
- **Secrets never enter the state repo**, private or not: a private repo is
  still copied to every machine, to its host and to backups, and a setting
  makes it public. Resolve a secret when it is used, from a password manager
  or the Keychain, read by the command that needs it. Failing that, export it
  from `~/.zshrc.local`, mode `0600`, though there it is plain text in every
  shell's environment. A chezmoi template must not read a secret: the daily
  `plan --notify` renders the templates from a background service, where a
  password manager's or the Keychain's prompt blocks or fails.

### The Brewfile's macelium line

The state repo's Brewfile lists macelium itself:

```ruby
brew "dbaggott/tap/macelium", trusted: true, restart_service: :always
```

- `trusted: true`, because Homebrew won't load a formula from a third-party
  tap through a Brewfile line without it.
- `restart_service: :always`, because the daily drift check is the formula's
  service, and this starts it. It isn't `start_service: true`: for a line
  naming its tap, `brew bundle` tries to start the service on every run, and
  starting it again once it is loaded fails, so every `brew bundle` after the
  first would fail. A restart unloads the service before loading it again.
  `restart_service: :changed`, which `brew bundle dump` writes, fails the
  same way when nothing changed.

Without the line, `plan` reports macelium as installed but not listed, and no
drift check runs.

## The manifest

`macelium.conf` is a list of declarations, a line each, with `#` comments.
Each path is relative to the state repo's root.

| Declaration | Default | |
| --- | --- | --- |
| `contract <n>` | none, required | the contract the state repo is written to (below) |
| `brewfile <path>` | `Brewfile` | |
| `settings <path>` | `macos.sh` | the settings list |
| `apps <dir>` | `apps` | |
| `init_notes <path>` | none | printed by `bootstrap` before `chezmoi init` first asks its questions |

macelium reads the `contract` line before any other. A contract newer than
its own makes every command exit 1, before any check runs, with a message to
upgrade macelium. Under a contract it knows, a line whose first word is not
one of these declarations, and that is not a comment or a blank, refuses the
manifest unrun, the same way. `plan --notify` writes a refusal to its log
line, and posts a notification that the manifest was refused. The check reads
only the word each line starts with, skipping a line that continues another,
and the manifest is then sourced as shell, so it catches mistakes, not hostile
content: a state repo is trusted as much as the chezmoi scripts it runs.

```
contract 1
init_notes init-notes.txt
```

## The settings list

The settings list is the macOS settings every machine has, a declaration a
line, with `#` comments; a line ending in `\` continues on the next. Like the
manifest, a list holding a line whose first word is not a declaration, such as
a `defaults write`, is refused unrun. Its check is the manifest's, and the
list is then sourced as shell, so it too catches mistakes, not hostile
content.

- `setting [--current-host] <domain> <key> <type> <value>...`: a defaults
  key. `<domain>` is a defaults domain, or `-g` for the global one. `<type>`
  is `bool`, `int`, `float`, `string`, `array` or `unordered-array`; an
  array's values are its string elements, and an unordered one compares as a
  set.
- `disabled_hotkey <id> <character> <key code> <modifiers>`: a
  `com.apple.symbolichotkeys` entry turned off. Only its enabled flag is
  compared; a write writes the whole entry, keeping the key combination macOS
  stores with it.
- `restart_on_change <domain> <app>`: the app to restart after a write to
  the domain. A write to a domain with none declared restarts the Dock,
  Finder, SystemUIServer and ControlCenter.
- `sandboxed_app <domain> <app>`: the domain is that sandboxed app's, kept in
  `~/Library/Containers/<domain>`. Its keys are compared only when the
  terminal has Full Disk Access, which `bootstrap` then requires; the app is
  quit for the writes, and reopened if it was running.
- `touch_id_sudo`: offer to turn on Touch ID for sudo, in
  `/etc/pam.d/sudo_local`, on a Mac with a finger enrolled.

## Apps

Each `apps/<app>/` can hold:

- `after-apply`: run with bash after `apply`'s other steps, and again
  whenever a hook, a `watches` list, or a file one names changes. A hook
  must be safe to run again. A hook that fails stops none after it, and the
  hooks run again on the next `apply`.
- `watches`: git pathspecs, a line each, relative to the state repo's root.
  The files they match, tracked or untracked and not ignored, are hashed
  along with the hooks.
- `manual-steps`: lines `bootstrap` prints among the manual steps at its end.

## Commands

```
macelium init [--public] <path>
macelium bootstrap [<checkout>]
macelium plan [--notify]
macelium apply
macelium settings [--file <path>]
macelium --version
```

**`plan`** changes nothing on the machine but a `git fetch` in the checkout
and, without `--notify`, a `brew update`, and never prompts. It prints every
difference by section, then a count line. Upgrades available for what the
Brewfiles list are shown and counted, but leave the exit status alone.

It checks that:

- the files chezmoi manages match the source (`chezmoi status`)
- Homebrew has no formula, cask or tap that neither Brewfile lists
- every entry either Brewfile lists is installed, tapped and linked
- the checkout is not behind its upstream
- every runtime the mise global config pins is installed
- every macOS setting the list declares has its value
- the apps hooks have run since a hook, or a file one watches, last changed.

With `--notify`, it prints one log line in place of the sections, and posts a
macOS notification when the exit status is not 0.

**`apply`** prints the plan and asks. On yes, it runs, in order:

1. `chezmoi apply`, which runs the state repo's own chezmoi scripts too
2. `brew bundle` over the state repo's Brewfile, then the machine's own
3. `mise install`
4. the macOS settings that still differ
5. the apps hooks, when the plan listed them.

While `brew bundle` or `mise install` runs, a status line shows the step's
time so far and the download Homebrew is making, behind a growing mushroom,
and gives way to any sudo password prompt. The terminal shows only
Homebrew's `Tapping`, `Installing` and `Upgrading` lines, and the step's
full output is in
`~/Library/Logs/macelium-apply.log`. When a step fails, `apply` prints its
errors and stops.

It upgrades only when the plan showed upgrades. When a check failed, the plan
is partial and `apply` stops without asking. It never removes anything: a
package installed but not listed stays until it is listed or uninstalled by
hand. It needs a terminal.

When the plan lists macelium itself under the upgrades, `apply` upgrades it
first, on the same yes: it runs `brew upgrade macelium` before any other
step, then hands over to the upgraded macelium's `apply`, run from
`$(brew --prefix)/bin/macelium` with `MACELIUM_UPGRADED_FROM` set to the old
version. The new version prints its own plan and asks again, and what it
applies is what it showed. While `MACELIUM_UPGRADED_FROM` is set, `apply`
never upgrades itself, so a macelium still listed then, from a stale tap, is
left to `brew bundle` with the rest. When
`brew upgrade macelium` fails, `apply` prints its output and
`No changes made.`, and exits 1, having run no other step.

**`bootstrap`** sets up a machine from `<checkout>`, which must hold
`macelium.conf`, or else from the checkout chezmoi's config names. It can run
again at any point after. It opens with a banner of mycelium spreading and
fruiting, in color unless `NO_COLOR` is set, then refuses a chezmoi setup
that is not macelium's, as `init` does (below). It checks what it needs from
macOS, App Management and Full Disk Access for the terminal, and stops naming
each that is missing. When `fdesetup status` says FileVault is off, it warns,
since FileVault is what protects the state repo's files on the Mac at rest,
and goes on. It then asks for sudo once for its own steps, prints
the manifest's `init_notes` when the machine has no chezmoi config, runs
`chezmoi init`, and applies the files. Each chezmoi script, and each of
`apply`'s steps, then runs as its own step, so one that fails stops none
after it, with its output in `~/Library/Logs/macelium-bootstrap.log`. While a
step runs, a status line shows its time so far and the download Homebrew is
making, behind a growing mushroom, and gives way to any sudo password prompt.
Homebrew discards sudo's credentials the first time it needs sudo, so each
`brew bundle` step that installs a cask needing sudo asks to authenticate
again, once. It ends with the plan, each step's result, and the manual steps.
It needs a terminal.

**`init`** captures this Mac into a new state repo at `<path>`, which must
be missing or an empty directory: otherwise it exits 1, having written
nothing.

Both `init` and `bootstrap` refuse, exit 1, before changing anything, a Mac
with a chezmoi setup that is not macelium's: a chezmoi config file under
`~/.config/chezmoi/` whose source is not in a checkout with `macelium.conf`
at its root, or, with no config file, a `~/.local/share/chezmoi` that is not
empty. A config naming a macelium checkout, at any path, passes.
`bootstrap`'s `chezmoi init` would replace that config. macelium manages
chezmoi itself, so to switch to it, save the old source if it holds anything
not saved elsewhere, keep a copy of any `age` or `gpg` key file, run
`chezmoi purge`, which removes chezmoi's config, state and source and leaves
the files it manages in place, and run the command again. Those files are
what `init` captures.

`init` writes [`example/`](example/)'s layout, at the contract this
macelium knows:

- `macelium.conf`, `.chezmoiroot` naming `home`, a `macos.sh` holding only a comment, and
  `home/.chezmoi.toml.tmpl` writing `sourceDir`
- a `Brewfile` from `brew bundle dump --formula --cask --tap`, with
  macelium's line as above
- `home/.chezmoidata.toml` with your `name` and `email`. It asks for each,
  defaulting to `git config --global`, else, when `gh` is signed in, to
  your GitHub name and `<id>+<login>@users.noreply.github.com`.

Then, for each of `~/.gitconfig`, `~/.zshrc` and
`~/.config/mise/config.toml` that exists, it shows the file and asks whether
to capture it. The question says the file will be published if the repo is
public, or, with `--public`, that it will be. A captured `~/.gitconfig`
becomes `dot_gitconfig.tmpl`, its `[user]` name and email read from
`.chezmoidata.toml`, and both it and `~/.zshrc` gain the include of their
`.local` file (above). In those two, it lists the lines that look like
secrets: an `export` of a name holding `TOKEN`, `SECRET`, `KEY` or
`PASSWORD`; a value starting `ghp_`, `github_pat_`, `sk-`, `AKIA` or `xox`;
a URL with a password; a `.gitconfig` `extraHeader`. It offers to move them
to `~/.gitconfig.local` or `~/.zshrc.local`, which it leaves mode `0600`,
out of the state repo. The `.local` file loads last, so a line that uses a
moved one belongs there too. A moved `.gitconfig` line takes its section's
header with it, and a moved header its whole section. `init` changes only the
state repo and the `.local` files, never `~/.gitconfig` or `~/.zshrc`
themselves: they gain the includes when `bootstrap` applies the captured
copies.

It makes one commit, authored with the name and email it asked for, so a Mac
with no git identity works, and adds no remote. It neither pushes nor
bootstraps: push it to a new repo, then run `macelium bootstrap <path>`. With
no terminal, or at end-of-file, a name or email takes its default, a capture
or a move is declined, and a name or email with no default, or partly typed,
stops `init` with nothing written.

**`settings`** writes the macOS settings that differ from the list, the state
repo's unless `--file` names another, without asking, and restarts the apps
that read them.

**`--version`** (or `-V`) prints `macelium <version>`.

### Exit status

| Status | `plan` | the others |
| --- | --- | --- |
| 0 | nothing differs | done |
| 1 | a check failed, or the manifest was refused | failed, or refused |
| 2 | something differs | |

## Files on the machine

- `~/.config/macelium/Brewfile.local`: packages for this machine only, read
  after the state repo's Brewfile, and only alongside it: with no state repo
  Brewfile, `plan` warns that the local file's packages are not checked or
  installed. `plan` also warns while `~/.Brewfile.local`, which macelium
  doesn't read, exists.
- `~/.local/state/macelium/apps-hooks.sha256`: the hash the apps hooks last
  all succeeded at.
- `~/Library/Logs/macelium-apply.log`: the output of each `apply`'s
  `brew bundle` and `mise install` steps.
- `~/Library/Logs/macelium-bootstrap.log`: each bootstrap step's output.
- `~/Library/Logs/macelium-drift.log`: the daily `plan --notify`'s line, and
  anything it prints to stderr, from the formula's service.

## Contract

The contract is what a state repo relies on: the state repo's layout, the
manifest, the settings list's declarations, the apps files, the commands and
their flags and exit statuses, and the files above. A change a state repo
would have to follow bumps the contract number, which `contract` in the
manifest names. [`CHANGELOG.md`](CHANGELOG.md) records each contract.

These may change without a bump:

- the `--notify` log line, and the notification's text
- the wording and layout of the plan, the prompts, and the other messages
- the bootstrap log's content.

## Releasing

A merge to `main` that changes `VERSION=` in `macelium` is a release:
`.github/workflows/release.yml` tags the commit `v<VERSION>`, publishes a
GitHub release, writes `Formula/macelium.rb` in
[`dbaggott/homebrew-tap`](https://github.com/dbaggott/homebrew-tap), and then
installs the formula on a macOS runner and checks its service. A merge that
leaves `VERSION=` as it was publishes nothing.

To release, bump `VERSION=` and move the `CHANGELOG.md` entries under
"Unreleased" to a heading for the new version, in the same pull request.

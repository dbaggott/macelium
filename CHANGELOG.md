# Changelog

## Contract

The contract a state repo's `macelium.conf` names with `contract <n>`
(README.md, "Contract"). A macelium refuses a state repo written to a newer
contract than its own.

- **1**: the state repo's layout, the manifest's `contract`, `brewfile`,
  `settings`, `apps` and `init_notes` declarations, the settings list's
  declarations including `touch_id_sudo`, the apps' `after-apply`, `watches`
  and `manual-steps` files, the commands `bootstrap [<checkout>]`,
  `plan [--notify]`, `apply`, `settings [--file <path>]` and
  `--version` and their exit statuses, and the files macelium keeps on the
  machine.

## 0.7.0

- `macelium --help`, `-h` and `macelium help [<command>]` print the commands,
  or one command's usage and options, and `macelium <command> --help` a
  command's. A command given an argument it doesn't take names it, prints
  the command's usage and exits 1, as before; the usage line starts
  `Usage:`. `macelium` with no command prints the help to stderr and exits
  1.
- The formula installs zsh and bash completions of the commands, their
  options, and the paths they take.
- `plan` and `apply` show the spinner while they fetch the state repo and
  compare the machine with it, which can take a while before the plan
  prints.
- The `brew bundle` steps of `apply` and `bootstrap` name their Brewfile:
  `brew bundle, the state repo's Brewfile` and
  `brew bundle, this machine's Brewfile.local`.
- `bootstrap`'s closing plan says the packages installed but not listed were
  on the Mac before the bootstrap only when there are some, under their
  heading, and a plan with no differences says
  `No changes. This machine matches the state repo.`

## 0.6.0

- `bootstrap`'s banner spells dnbg's name, a letter every few columns, into
  one of the mycelium's threads as it spreads, and leaves a blank line after
  macelium's name before the messages that follow.
- `install.sh` with no argument finds or creates your state repo: it asks
  whether it is on GitHub or another git host, looks for
  `<username>/macelium-state` on GitHub, first without a sign-in, and asks
  the path. With a state repo, it clones and bootstraps it. With none, or an
  empty one, it captures this Mac with `macelium init`, creates the repo on
  GitHub with `gh repo create`, private by default, or pushes to the empty
  one, and bootstraps. Run again, it picks up where it stopped. The README's
  "Install" leads with it; naming the repo still works as before.

## 0.5.0

- `macelium init` and `macelium bootstrap` refuse, exit 1, before changing
  anything, a Mac with a chezmoi setup that is not macelium's: a chezmoi
  config whose source is not in a checkout with `macelium.conf`, or no config
  and a non-empty `~/.local/share/chezmoi`. The refusal says how to switch:
  save the old source, keep any `age` or `gpg` key file, run `chezmoi purge`,
  and run the command again. A config naming a macelium checkout passes.
- `bootstrap` warns, and goes on, when FileVault is off.

## 0.4.1

- The status line's spinner is two mushrooms side by side, each growing and
  falling over onto the other's spot, where its spore sprouts the next, so it
  turns in a loop rather than growing and fading in place.

## 0.4.0

- `macelium init [--public] <path>` captures this Mac into a new state repo:
  `example/`'s layout, a Brewfile from `brew bundle dump`, your name and
  email in `home/.chezmoidata.toml`, and, each on a yes, `~/.gitconfig`,
  `~/.zshrc` and the mise config. It offers to move the lines that look like
  secrets to `~/.gitconfig.local` and `~/.zshrc.local`, and makes one
  commit, with no remote.
- The README says where values every machine shares, one machine's
  differences, and secrets go, and warns that `chezmoi init --source` on a
  worktree points macelium at the worktree.
- `example/`'s greeting is a template reading `home/.chezmoidata.toml`.

## 0.3.1

- `bootstrap`'s banner opens with a spore drifting down onto the ground line
  and sinking just below it, and the mycelium spreads from there along
  branching paths rather than as an even front. The largest mushroom has a
  rounder cap, and the banner takes a little longer to play.

## 0.3.0

- `install.sh` takes a git URL on any host, `https://`, `ssh://` or
  `user@host:path`, as well as a GitHub `<owner>/<repo>`. An existing clone
  counts whichever form names its remote. For a host other than GitHub it
  says the host needs a personal access token or a registered SSH key, and
  leaves the sign-in to git.
- With no path, `install.sh` clones to the first of `~/Developer`, `~/git`,
  `~/src`, `~/code` and `~/Projects` that exists, else the home directory,
  and prints the path.
- After bootstrapping a GitHub repo it read without a sign-in, `install.sh`
  offers `gh auth login` and `gh auth setup-git`, so you can push from the
  Mac.
- Each release attaches `install.sh`, and the README's command fetches it
  from the latest release rather than `main`.

## 0.2.5

- `bootstrap` opens with a banner: mycelium spreads under a ground line, and
  mushrooms fruit above it. It is in color unless `NO_COLOR` is set, and a
  terminal smaller than 64 columns by 15 rows skips it.
- The status line that `bootstrap` and `apply` show while a step runs leads
  with a growing mushroom in place of its `...`. The mushroom stops while sudo
  asks for a password, and never draws over the prompt.

## 0.2.4

- `apply` shows `bootstrap`'s status line while it runs `brew bundle` or
  `mise install`: the step's time so far and the download Homebrew is
  making, giving way to any sudo password prompt. The
  terminal shows only Homebrew's `Tapping`, `Installing` and `Upgrading`
  lines, and the steps' full output is in
  `~/Library/Logs/macelium-apply.log`. A long source build or cask download
  no longer looks like a hang.

## 0.2.3

- `bootstrap` no longer implies the casks won't ask for the password again.
  Homebrew discards sudo's credentials the first time it needs sudo, so each
  `brew bundle` step that installs a cask needing sudo asks once. With a
  Brewfile, `bootstrap` says so up front, and it still says when it is about
  to ask itself.

## 0.2.2

- `bootstrap` asks about Touch ID for sudo once: declining it before the
  password prompt no longer brings a second offer after the macOS settings
  are written.
- While a `bootstrap` step runs, one status line, redrawn in place, shows its
  time so far and the download Homebrew is making, with its rate, or that it
  stalled. It replaces the line each minute saying the step is still running,
  which is still what a log gets. A sudo password prompt is left on screen,
  with a line pointing at it.
- `plan` warns when `~/.config/macelium/Brewfile.local` exists and the state
  repo has no Brewfile, since macelium reads the local file only alongside
  it.
- A setting whose domain is a plist's path, such as
  `~/Library/Preferences/com.example.plist`, is compared, rather than making
  every `plan` report an error in the macOS settings.
- `bootstrap` runs a chezmoi script whose path holds a space, rather than
  splitting the path into steps that apply nothing.

## 0.2.1

- The state repo's Brewfile line for macelium is now
  `brew "dbaggott/tap/macelium", trusted: true, restart_service: :always`
  (README.md, "The Brewfile's macelium line"). With `start_service: true`,
  every `brew bundle` after the first fails, so change a line that has it.

## 0.2.0

- `apply` upgrades macelium itself first when the plan lists it, then hands
  over to the upgraded version, which prints its own plan and asks again
  (README.md, "Commands"). A failed upgrade stops `apply` before any other
  step.

## 0.1.0

- macelium, published from the `dotfiles` command it was: the state repo it
  applies is named by a manifest, and macelium runs `brew bundle`,
  `mise install`, the settings and the apps hooks itself, with no chezmoi
  script in the state repo.
- `macelium --version`.
- Released to `dbaggott/homebrew-tap` as `macelium`, whose formula's service
  runs `macelium plan --notify` daily at 09:00, logging to
  `~/Library/Logs/macelium-drift.log`.

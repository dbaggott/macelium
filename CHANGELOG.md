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

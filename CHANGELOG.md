# Changelog

## Contract

The contract a state repo's `macelium.conf` names with `contract <n>`
(README.md, "Contract"). A macelium refuses a state repo written to a newer
contract than its own.

- **1**: the state repo's layout, the manifest's `contract`, `brewfile`,
  `settings`, `apps` and `init_notes` declarations, the settings list's
  declarations including `touch_id_sudo`, the apps' `after-apply`, `watches`
  and `manual-steps` files, the commands `bootstrap [<checkout>]`,
  `plan [--notify]`, `apply` and `settings [--file <path>]` and their exit
  statuses, and the files macelium keeps on the machine.

## Unreleased

## 0.1.0

- macelium, published from the `dotfiles` command it was: the state repo it
  applies is named by a manifest, and macelium runs `brew bundle`,
  `mise install`, the settings and the apps hooks itself, with no chezmoi
  script in the state repo.
- `macelium --version`.
- Released to `dbaggott/homebrew-tap` as `macelium`, whose formula's service
  runs `macelium plan --notify` daily at 09:00, logging to
  `~/Library/Logs/macelium-drift.log`.

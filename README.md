> **ma·ce·li·um** | `/mækˈsiːliəm/` (*mac-SEAL-ium*)  
> *noun*  
> Stupidly simple macOS environment management.

## Why Macelium?

Macelium streamlines macOS setup and dotfile management:

* **Edit normally:** Make changes and let scheduled checks track drift.
* **Adopt your current Mac:** Run `macelium setup` to snapshot your environment and scan for secrets via [gitleaks](https://github.com).
* **Smart macOS settings:** `macos.sh` monitors real system state and safely handles service restarts.
* **Zero lock-in:** Built on standard tools like `chezmoi` and `Brewfile`.

## Adopt

Bootstrap or capture your environment with a single command:

**Without Homebrew:**
```bash
curl -fsSL https://github.com/dbaggott/macelium/releases/latest/download/install.sh | bash
```

**With Homebrew:**
```bash
brew install dbaggott/tap/macelium && macelium setup
```

## How it works

1. **Use your Mac normally:** Make direct changes to your setup.
2. **Automatic drift detection:** Scheduled background checks run `macelium plan --notify` to catch discrepancies.
3. **Sync on demand:** Run `macelium apply` to align your machine and repo, or `macelium bootstrap` to replicate your setup onto a new Mac.

---

## Commands

| Command | What it does |
| :--- | :--- |
| `macelium setup [<owner>/<repo>\|<git URL>] [<path>]` | Locates or creates a state repository to set up or capture your Mac, handling secret scans and resuming where it left off. |
| `macelium init [--public] <path>` | Initializes a new state repository with your current Homebrew apps, dotfiles, and settings. |
| `macelium bootstrap [<checkout>]` | Configures a Mac using an existing state repository. |
| `macelium plan [--notify]` | Compares your Mac against your state repo to report drift, with optional macOS notifications. |
| `macelium apply` | Applies updates to packages, settings, dotfiles, and app hooks to resolve drift. |
| `macelium settings [--file <path>]` | Applies macOS settings that deviate from your configured list. |

## Inside the state repo

A state repo is a standard git repository. Only `macelium.conf` is required; everything else is optional and skipped if missing (see [`example/`](example/) for a complete setup).

```text
macelium.conf        Manifest configuring paths and contract version
Brewfile             Homebrew formulas, casks, and services
macos.sh             Declarative macOS defaults and hotkeys
apps/<app>/          Per-app post-apply hooks, file watches, and manual steps
<chezmoi source>     Your dotfiles (managed via chezmoi; optional .chezmoiroot)
```

### Shared values, machine overrides, and secrets
* **Shared across Macs:** Personal values like your name and email live in `home/.chezmoidata.toml` (populated by `macelium init`) and render into templates like `dot_gitconfig.tmpl`.
* **Machine-specific overrides:** Keep work emails or machine-only shell tweaks out of the repo in `~/.gitconfig.local` and `~/.zshrc.local`. `macelium init` automatically wires `[include]` and `source` hooks into your managed configs.
* **Never commit secrets:** Even in a private repo, secrets end up on every machine and backup. Resolve secrets on demand via a password manager or macOS Keychain—never inside a chezmoi template, as background `plan --notify` runs will block or fail on interactive prompts.

## Configuration reference

<details>
<summary><strong><code>macelium.conf</code> (Manifest)</strong></summary>

`macelium.conf` is a line-by-line manifest with `#` comments. Paths are relative to the repo root.

| Declaration | Default | Description |
| :--- | :--- | :--- |
| `contract <n>` | *Required* | Schema version; exits early if Macelium needs an upgrade. |
| `brewfile <path>` | `Brewfile` | Path to your Brewfile. |
| `settings <path>` | `macos.sh` | Path to your macOS settings list. |
| `apps <dir>` | `apps` | Directory containing per-app hooks and notes. |
| `init_notes <path>` | *None* | Notes printed by `bootstrap` before `chezmoi init` prompts run. |

```sh
contract 1
init_notes init-notes.txt
```
</details>

<details>
<summary><strong><code>macos.sh</code> (Settings list)</strong></summary>

Declarative macOS settings, one per line (`\` supported for line continuation). Unknown directives abort execution before anything runs.

* `setting [--current-host] <domain> <key> <type> <value>...` — Sets a `defaults` key (`-g` for global). Types: `bool`, `int`, `float`, `string`, `array`, or `unordered-array` (compared as a set).
* `disabled_hotkey <id> <character> <key code> <modifiers>` — Disables a `com.apple.symbolichotkeys` entry while preserving its key combination.
* `restart_on_change <domain> <app>` — App to restart after modifying `<domain>` (defaults to restarting Dock, Finder, SystemUIServer, and ControlCenter).
* `sandboxed_app <domain> <app>` — Manages preferences in `~/Library/Containers/<domain>` (requires Full Disk Access; quits and reopens the app if running).
* `touch_id_sudo` — Offers to enable Touch ID for `sudo` in `/etc/pam.d/sudo_local` when Touch ID is enrolled.
</details>

<details>
<summary><strong><code>apps/&lt;app&gt;/</code> (App hooks & manual steps)</strong></summary>

Each app folder can include:
* `after-apply` — Idempotent bash script run after `apply`, and re-run whenever the hook or any watched file changes. Failures are logged without blocking other hooks.
* `watches` — Git pathspecs (one per line, relative to repo root) whose matching files trigger `after-apply` when modified.
* `manual-steps` — Checklist items printed at the end of `macelium bootstrap`.
</details>

<details>
<summary><strong>Under the hood (Chezmoi & Brewfile internals)</strong></summary>

* **Chezmoi `sourceDir`:** Macelium locates your state repo via `chezmoi source-path`. Your repo's config template sets `sourceDir = {{ .chezmoi.workingTree | quote }}`, making it easy to test changes against a git worktree via `chezmoi init --source <worktree>`.
* **Brewfile service line:** `macelium init` adds `brew "dbaggott/tap/macelium", trusted: true, restart_service: :always` to your `Brewfile`. `trusted: true` allows third-party tap execution, and `:always` avoids `brew bundle` errors when reloading an already-running background drift-check service.
</details>

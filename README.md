> **ma·ce·li·um** | `/mækˈsiːliəm/` (*mac-SEAL-ium*)  
> *noun*  
> Stupidly simple macOS environment management.

## Why Macelium?

* **Nothing new to remember:** Keep changing your Mac the way you already do (installing apps, adjusting System Settings, editing dotfiles). Macelium notices; you don't have to record anything.
* **Start from the Mac you have:** No writing config from scratch. Your current setup becomes the starting point.
* **More than dotfiles:** Homebrew packages, macOS settings and per-app setup are tracked alongside your dotfiles.
* **A new Mac in one step:** Point a fresh machine at your repo and it ends up like the old one.
* **Zero lock-in:** Your state is a plain git repo built on `chezmoi` and a `Brewfile`. Stop using Macelium and it still works.

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

*(Already a Macelium user? Either command above handles that too!)*

## How it works

1. **Capture:** `macelium setup` snapshots your apps, dotfiles and macOS settings into a git state repo. It scans the snapshot for secrets with [gitleaks](https://github.com/gitleaks/gitleaks) and pushes only when you say so.
2. **Detect:** A background service periodically runs `macelium plan --notify` and notifies you when your Mac and the repo have drifted apart.
3. **Reconcile:** `macelium apply` brings them back in line: packages, settings, dotfiles and app hooks.
4. **Replicate:** On a new Mac, the same Adopt command (or `macelium bootstrap`) sets it up from your repo.

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

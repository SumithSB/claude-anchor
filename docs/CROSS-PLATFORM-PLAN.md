# Windows and Linux plan

The macOS app (`Sources/Anchor`, Swift) stays as it is. Windows and Linux get:

- `cross/core`: Rust library + `anchor` CLI. All logic lives here.
- `cross/tray`: Tauri 2 tray app on top of the library (phase 2).

Both read and write the same files the Swift app uses under `~/.claude-anchor`
(`config.json`, `routes`, `usage.json`, `copied`, `accounts/<id>/`), so the on-disk contract is shared.

## Verified facts (Claude Code 2.1.299)

- Outside macOS, credentials are `<config dir>/.credentials.json` (`{"claudeAiOauth": {accessToken, expiresAt (ms), subscriptionType, …}}`).
  The config dir is `CLAUDE_CONFIG_DIR` or `~/.claude`. macOS uses the Keychain instead.
- Project folders: `cwd.replace(/[^a-zA-Z0-9]/g, "-")` over UTF-16 code units. Over 200 chars it becomes
  `slug[..200] + "-" + abs(h).toString(36)`, `h` = Java-style int32 hash (`h = (h<<5) - h + unit | 0`) over the original cwd's UTF-16 units.
  So `C:\Users\me\proj` → `C--Users-me-proj`.
- The VS Code extension runs `<wrapper> <claude binary> <args…>` when `claudeCode.claudeProcessWrapper` is set.

## How routing works off macOS

There is one implementation: `anchor exec -- <program> [args]`.

- bash/zsh hook line: `[ -x "$HOME/.claude-anchor/bin/anchor" ] && claude() { "$HOME/.claude-anchor/bin/anchor" exec -- claude "$@"; }  # claude-anchor`
- PowerShell profile line: `if (Test-Path "$HOME\.claude-anchor\bin\anchor.exe") { function claude { & "$HOME\.claude-anchor\bin\anchor.exe" exec -- claude @args } }  # claude-anchor`
- Editors: `claudeProcessWrapper` = `<anchor>/bin/claude-wrapper[.exe]`, a copy of `anchor`. When the binary's file stem is `claude-wrapper`, it behaves as `anchor exec -- <argv[1..]>`.

`exec` rules (same as `anchor.zsh claude()`):
1. If `CLAUDE_ANCHOR_OFF` is set, `CLAUDE_CONFIG_DIR` is already set, or the routes file is unreadable, run the program unchanged.
2. Otherwise resolve cwd → config dir from routes, run `sync_project` (unless `CLAUDE_ANCHOR_NO_SYNC`), then run with
   `CLAUDE_CONFIG_DIR=<dir>` and `CLAUDE_ANCHOR_ACCOUNT=<dir basename>`, or for primary: `CLAUDE_CONFIG_DIR` removed and `CLAUDE_ANCHOR_ACCOUNT=primary`.
3. Unix: replace the process (`CommandExt::exec`). Windows: spawn, ignore Ctrl+C in the parent (`SetConsoleCtrlHandler(None, TRUE)`), wait, return the child's exit code. If the program isn't found and it is `claude`, use `claude_path()`; run `.cmd`/`.bat` through `cmd /C`.

## Platform mapping

| Concern | Linux | Windows |
|---|---|---|
| Credentials | `<dir>/.credentials.json` | same |
| Editor settings | `$XDG_CONFIG_HOME` or `~/.config` / `{Code,Cursor,Code - Insiders,VSCodium}/User/settings.json` | `%APPDATA%\{…}\User\settings.json` |
| Shared files for new accounts | symlinks | junctions for folders (`cmd /C mklink /J`), copies for files |
| Remove account folder | `trash` crate | `trash` crate (Recycle Bin) |
| Find `claude` | `~/.local/bin/claude`, `/usr/local/bin/claude`, `/usr/bin/claude`, `~/.claude/local/claude`, `~/.npm-global/bin/claude`, then `bash -lc 'command -v claude'` | `~\.local\bin\claude.exe`, `%APPDATA%\npm\claude.cmd`, `%LOCALAPPDATA%\Programs\claude\claude.exe`, then `where claude` |
| Continue in a terminal | `$TERMINAL`, `x-terminal-emulator`, `gnome-terminal --`, `konsole -e`, `xfce4-terminal -x`, `kitty`, `alacritty -e`, `wezterm start --`, `xterm -e`, each running `bash -lc '<cmd>; exec bash'` | `wt.exe -d <cwd> powershell -NoExit -Command <cmd>`, else `powershell -NoExit` |
| Rule paths | must start with `/` | drive (`C:\`) or UNC (`\\server\share`); `/` accepted and normalised to `\`; case-insensitive matching |
| Login item, notifications, hotkey, tray | Tauri plugins (phase 2) | same |
| Floating button | X11 only; skipped on Wayland | yes |

## Phase 1: `cross/core`

Module signatures are fixed in `cross/core/src/*.rs`. Do not change a public signature without saying so.
Each module ports the named Swift/zsh code, keeping its behaviour and user-facing messages; macOS-only
paths (Keychain, `~/Library`) are replaced by the table above. `cfg(target_os = "macos")` may keep a
Keychain path so the CLI is testable on a Mac.

| File | Ports | Tests that must exist |
|---|---|---|
| `routes.rs` | Store.swift `routesText`; anchor.zsh `_anchor_resolve`; slug rule above; Store.swift `addRule` path checks | the 4 zsh selftest cases; overflow routes to default; Windows case-insensitive + `\` (cfg(windows)); slug short, long (>200) and non-ASCII |
| `editor.rs` | Store.swift `setWrapper`, `setEditorIntegration`, `parses` | insert into `{}` and non-empty object; replace ours; refuse foreign; remove when last entry (comma fix); comments kept; Windows path JSON-escaped |
| `creds.rs` | Store.swift `claudeJSON`, `email`, `keychainPlan`, `signedIn`; Limits.swift `keychainService` (macOS) | reads a temp `.credentials.json` |
| `limits.rs` | Limits.swift `fetchLimits`, `parseLimits`, `evaluateFresh` | parse fixture; expired token → needsSignIn without a network call; cache fallback |
| `usage.rs` | Usage.swift `UsageIndex` (incremental offsets, dedup, ledger, 90-day keep, price, prettyModel) | scan a temp transcript; appended lines counted once; ledger-copied history not counted |
| `sync.rs` | anchor.zsh `_anchor_sync`; Store.swift `copyTranscript` | prefix extend; diverged left alone; ledger lines written |
| `accounts.rs` | Store.swift load/seed/save, accounts, rules, `finishSignIn`, `continueSession`, `claudePath`, `signIn` | load/seed; broken config backed up; add/remove account in temp home; rule validation |
| `terminal.rs` | Store.swift `continueSession` terminal step | command string quoting (POSIX single quotes, PowerShell `''`) |
| `exec.rs`, `hook.rs`, `main.rs` | anchor.zsh `claude()`, editor wrapper, install.sh hook line | `anchor which` end to end; hook add/remove idempotent |

CLI (`main.rs`, hand-parsed, no clap):

```
anchor exec -- <program> [args…]
anchor which [dir]
anchor status
anchor limits [--json]
anchor usage [--by account|project|model] [--days N]
anchor account list | add <name> | login <id> | remove <id> [--to <id>] | rename <id> <name>
anchor default <id>
anchor rule list | add <folder> <account> [--overflow] | remove <folder>
anchor editor on|off
anchor continue <account>
anchor install | uninstall
```

Acceptance: `cargo test` and `cargo clippy -- -D warnings` pass on ubuntu, windows and macos in CI.
On Linux and Windows, `anchor install` + `anchor rule add` routes `claude` in bash and PowerShell.

## Phase 2: `cross/tray` (Tauri 2, vanilla HTML/CSS/JS, no bundler)

- Tray icon with the usage ring (PNG drawn in Rust); left click toggles the main window near the tray.
- Main window (340×640, no decorations, hidden on blur): Home (harbor switcher, last conversation card, usage),
  Accounts, Rules and Settings, matching the Swift app's layout and the Clay tokens in `docs/DESIGN.md`.
- Floating button + glance card: always-on-top, transparent, skip taskbar. Not created on Wayland.
- Plugins: autostart, notification, global-shortcut (Ctrl+Alt+A), dialog (folder picker), single-instance.
- File watching with `notify` on each account's `projects/`, limits timer from `refreshSeconds`.
- Commands are thin wrappers over `accounts::Store`; the frontend gets a single `state` object and an event when it changes.

## Phase 3: packaging

- CI matrix builds `.msi`/NSIS and `.AppImage`/`.deb` with `tauri-action`, plus `anchor` CLI archives and `.sha256` files.
- `install.sh` Linux branch, new `install.ps1`, uninstall on both.
- README and user guide sections per OS. Windows builds are unsigned (SmartScreen), documented like the macOS ad-hoc signing.

## Out of scope for now

fish shell, cmd.exe hook, Flatpak, AUR/winget/Flathub, Windows code signing, Wayland floating button and hotkey, WSL ↔ Windows bridging.

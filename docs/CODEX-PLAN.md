# Codex CLI plan

Status: in progress for 0.7.0, macOS app only. `cross/` (Windows/Linux) follows in a later release.

Goal: route the `codex` CLI across ChatGPT accounts by folder, the way `claude` is routed today. Show Codex
5h/weekly limits and token usage alongside Claude. Codex accounts are **their own berths**, with their own default
and their own folder rules. A Claude rule and a Codex rule can name the same folder.

Out of scope for 0.7.0:
- conversation sync across Codex accounts, and Continue on <Name> for Codex;
- per-folder routing inside VS Code (the extension doesn't allow it, see below);
- the `cross/` port;
- API prices for GPT models.

## Verified facts (codex-cli 0.164.0-alpha.11, VS Code extension openai.chatgpt 26.1021)

- **Config folder and login.** The config folder is `CODEX_HOME`, default `~/.codex`. The login is
  `<CODEX_HOME>/auth.json` (0600):
  `{auth_mode, OPENAI_API_KEY, tokens: {access_token, account_id, id_token, refresh_token}, last_refresh}`.
  Storage defaults to a file. With `cli_auth_credentials_store = "keyring"` there is no `auth.json`, so
  `codex login status` (exit 0, prints "Logged in using …") is the fallback check.
- **`id_token`** is a JWT. Its payload holds `email`, plus `chatgpt_plan_type` and `chatgpt_account_id` under
  `https://api.openai.com/auth`. One email can belong to several ChatGPT workspaces, so **identity is
  `tokens.account_id`, not the email.**
- **Sessions.** They live in `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`. **A session resumed later
  is appended to its original file**: 3 of 35 local rollouts were written after their date folder. So "newest" means
  newest event timestamp, never newest path.
  - `session_meta` (line 1) has `cwd`.
  - `turn_context` has `cwd` and `model`.
  - `event_msg` / `token_count` has `info.total_token_usage` / `info.last_token_usage` (`input_tokens`,
    `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`, `total_tokens`).
    `info` can be null.
  - `rate_limits` is `{primary|secondary: {used_percent, window_minutes (300 | 10080), resets_at (epoch s)}, plan_type}`
    and can be null (API key logins).
- **Token counting.** `token_count` repeats with an unchanged total (125 of 3082 events locally), and the total never
  went backwards. **Count usage as the delta of `total_token_usage`.** Summing `last_token_usage` would double count.
- **Limits are local.** They come from the newest `rate_limits` event, with no network call. They only update when
  Codex runs on that account; `aged()` zeroes a window once its `resets_at` has passed.
- **The binary** is often not on PATH. Here it only lives at
  `~/.vscode/extensions/openai.chatgpt-*/bin/macos-aarch64/codex`. `codex login` supports `status` and `--device-auth`.
- **VS Code extension** (read from `out/extension.js`):
  - It spawns `<cliExecutable or bundled codex> -c … app-server …` with **no `cwd`**, so a wrapper can't tell which
    folder is open.
  - It runs one long-lived app-server per window.
  - The child's env is `process.env` plus `PATH = process.env.PATH + ":" + <ext>/bin/<platform>`, so a wrapper can
    find the real binary in the **last PATH entry**.
  - `CODEX_HOME` comes from the VS Code process env. The login-shell lookup only runs for remote windows.
  - `chatgpt.cliExecutable` is marked "DEVELOPMENT ONLY".
  - So VS Code can follow **one machine-wide Codex account** (the Codex default) and pick up a change on window
    reload, but it can't route per folder.

## Security review (applied below)

1. **Old app versions must not misread Codex accounts.** A 0.6.x app (or the Rust core) that saw Codex accounts in
   `accounts` would treat them as Claude: Keychain lookups, `claude auth login` into a Codex folder, and Claude rules
   routed to the primary. → Codex lives in **new keys** (`codexAccounts`, `codexRules`, `codexDefaultID`) that old
   readers ignore. Every existing loop over `accounts` stays Claude-only by construction: no Keychain calls, no
   transcript sync and no `projects/` scan ever touch a Codex folder.
2. **Removing an account left a live refresh token in the Trash.** `trashItem` would move `auth.json` there. → Run
   `codex logout` with that `CODEX_HOME`, then delete `auth.json` itself, and only then trash the folder.
3. **Tokens never leave `auth.json`.** Only `email`, plan and `account_id` are read: the JWT payload is
   base64url-decoded without verification, for display only. Refuse an `auth.json` over 64 KB. Never put tokens or
   CLI output in banners, logs, `config.json` or `usage.json`. Treat `auth.json` as absent if it's a symlink, so one
   account can't silently share another's login.
4. **Only numbers leave the rollouts.** The usage parser keeps only numbers, `cwd` and `model`. Rollouts contain whole
   conversations, and none of that may reach `usage.json`.
5. **Sign-ins run one at a time.** `codex login` listens on a fixed local callback port, so a second login at the same
   time would fail or take over the first. → One Codex sign-in at a time. Its env is the app env with `CODEX_HOME` set
   (or removed for the primary).
6. **Twin check by `account_id`, among Codex accounts only.** The same email on Claude and Codex is normal, and one
   email can have two workspaces.
7. **Shared files are symlinks, never logins or history.** `config.toml`, `AGENTS.md`, `skills`, `rules`, `hooks.json`
   are symlinked from `~/.codex`. Never `auth.json`, `sessions`, `archived_sessions`, `history.jsonl`, `*.sqlite*`,
   `memories` or `log`. Note: Codex replaces `config.toml` atomically when it writes it, which turns the symlink into a
   private copy. That's safe (0600 temp file), just no longer shared.
8. **Account folders.** `codex-accounts/` and every account folder are 0700 (`ensureDir`). A folder is removed only if
   it's a standardized direct child of `codex-accounts` and not the primary.
9. **VS Code wrapper.**
   - It's `#!/bin/zsh -f` with no `eval`, and reads only the `default` line of `codex-routes`.
   - It never execs itself: it compares the real paths of the target and of `$0`.
   - An explicit `CODEX_HOME` other than `~/.codex` is left alone.
   - It never overwrites a `chatgpt.cliExecutable` that it didn't write, and removes the key only when the value is
     ours. Turning it on is an opt-in toggle, off by default. Uninstall removes it.
10. **Routes files** are written 0600, rule paths with tabs or newlines are skipped (as today), and the shell treats
    each line as data, never as code.

## Phase 1: model, config, routes, shell (Sonnet)

`Sources/Anchor/Models.swift`
- `enum Tool: String, Codable, CaseIterable { case claude, codex }`.
- `Paths.codexPrimaryDir = home + "/.codex"`, `Paths.codexAccounts = anchor + "/codex-accounts"`,
  `Paths.codexRoutes = anchor + "/codex-routes"`.
- `Account`: `var tool: Tool?` (optional, so older files decode). Add `var kind: Tool { tool ?? .claude }` and
  `var accountID: String?` (ChatGPT account id, Codex only). `isPrimary` = `dir == Paths.primaryDir || dir == Paths.codexPrimaryDir`.
- `Config`: `codexAccounts: [Account] = []`, `codexRules: [Rule] = []`, `codexDefaultID: String = "codex"`, all read
  with decodeIfPresent. Helpers: `accounts(_ t: Tool)`, `rules(_ t: Tool)`, `defaultID(_ t: Tool)`, and a setter for
  each of these.
- `AppModel`:
  - `account(_:)` searches both lists.
  - `accounts` keeps meaning Claude accounts, and `active` stays Claude.
  - Add `codexAccounts` and `activeCodex`.
- Account ids are unique across both lists: `addAccount` checks both, and the Codex primary's id is `"codex"`.

`Sources/Anchor/Store.swift` (routes only)
- `routesText(config:limits:tool:)` and `routedAccount(cwd:config:limits:tool:)` use that tool's rules and default.
- `writeRoutes()` always writes `routes`. It writes `codex-routes` only when `codexAccounts` isn't empty, and removes
  `codex-routes` otherwise.
- Rule add/remove/overflow functions take a `tool`.

`shell/anchor.zsh`
- `_anchor_resolve [dir] [routes-file]`. The second argument defaults to today's routes path.
- `codex()`:
  - Plain `command codex "$@"` when `CLAUDE_ANCHOR_OFF` or `CODEX_HOME` is set, or when `codex-routes` is unreadable
    (`${CLAUDE_ANCHOR_CODEX_ROUTES:-$HOME/.claude-anchor/codex-routes}`).
  - `-` (primary) → `command codex`; otherwise `CODEX_HOME=$cfg command codex "$@"`.
  - No sync.
- `anchor-which [--codex] [dir]`.
- Selftest: codex default route, codex rule to the primary, `CODEX_HOME` preset, no `codex-routes`, and claude
  routing unchanged with a `codex-routes` present.

Shared helper (Store.swift): `nonisolated static func codexAuth(dir:) -> (email: String?, plan: String?, accountID: String?)?`
returns nil when the account isn't signed in by file. It enforces review items 3 and 7.

Acceptance:
- `swift build`, then `.build/debug/Anchor --self-test` (run from the repo root) and `zsh shell/anchor.zsh --selftest`
  all pass.
- New `AppModel.selfTest` cases: a mixed config gives two routes texts with no cross-tool rules; a 0.6 `config.json`
  (no codex keys) decodes; `codexAuth` reads a fixture `auth.json` with a hand-built JWT and rejects a symlinked one.

## Phase 2: Codex usage and limits (Sonnet)

`Sources/Anchor/Usage.swift`
- `scan(accounts:codexAccounts:)`: for Codex accounts, enumerate `<dir>/sessions/**/rollout-*.jsonl`.
- `FileState` gains optional `cwd`, `model` and `lastTotal` (a struct with the 4 counters), so an incremental read
  mid-file keeps its context:
  - `session_meta` / `turn_context` → update `cwd` / `model`;
  - `token_count` with `info` → delta = total − lastTotal, per field, clamped at 0. If the total ever drops, use
    `last_token_usage`. Then apply the record as input = `input − cached`, cacheRead = `cached`,
    cacheWrite = `cache_write`, output = `output`, at cost 0
    (`// ponytail: no GPT price table; add one when someone pays Codex per token`).
- Newest `rate_limits` per account, by event timestamp, is kept in the persisted state (`codexLimits[accountID]`).
  Read it with `usage.codexLimits(for:)`.
- `prettyModel` passes `gpt-*` through, e.g. "GPT 6 Sol".
- `lastSession` comes from Claude files only.

`Sources/Anchor/Limits.swift`
- `refreshLimits` also covers Codex accounts:
  - Build `Limits` from `usage.codexLimits` (no network call). Map primary/secondary to fiveHour/weekly by
    `window_minutes`, then `aged()`.
  - Add a `note` when the data is over 5h old: "From Codex's last run, <relative>."
  - No data yet → no bars and no error.
  - Not signed in (no `codexAuth` and `codex login status` fails) → error "<Name> isn't signed in to Codex." with
    `needsSignIn`.
- `evaluateOverflow` / `evaluateFresh` run per tool, with candidates from the same tool only. Each tool has its own
  `lastMove`. The texts name Codex ("Codex switched to Work…").
- `routes` and `codex-routes` are both rewritten after an evaluation.

Acceptance: self-test passes, with new `UsageIndex.selfTest` cases:
- repeated `token_count` counts once;
- reading in two chunks keeps `cwd`/`model`;
- `info: null` and `rate_limits: null` are ignored;
- an older file appended later wins on its event timestamp;
- a past `resets_at` reads as 0%;
- no message text ends up in the persisted state (assert a marker string from the fixture is absent).

## Phase 3: Codex accounts (Sonnet)

`Sources/Anchor/Store.swift`
- `seed` / `reconcile`: if `~/.codex/auth.json` exists (or `codex login status` succeeds), ensure a `codex` account
  named "Codex" with the next free flag, `dir = Paths.codexPrimaryDir` and `tool: .codex`. Refresh email/plan/accountID
  from `codexAuth`.
- `addAccount(name:flag:tool:)`: a Codex folder is `codex-accounts/<id>` (0700), with the symlinks from review item 7.
- `codexPath()`:
  1. `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`;
  2. `zsh -lc 'command -v codex'` (last line);
  3. the newest `~/.vscode/extensions/openai.chatgpt-*/bin/macos-*/codex`, then the same under `~/.cursor/extensions`.
- `signIn` for Codex runs `codex login` with the review item 5 env. Only one Codex login runs at a time; a second shows
  "Finish the other Codex sign-in first." Timeout and cancel work as they do for Claude.
- `finishSignIn` for Codex reads `codexAuth`. The twin check compares `accountID` among Codex accounts.
- `removeAccount` for Codex follows review item 2. Rules and the default are reassigned to an account of the same tool.
  It never calls `security`.
- `signOutCodexPrimary` runs `codex logout` with `CODEX_HOME` removed.
- `restartWatch` also watches Codex `<dir>/sessions`, or `<dir>` until that folder exists.
- `cliInstalled` splits into `claudeInstalled` and `codexInstalled`.

VS Code (opt-in):
- A `codexWrapperScript` in `~/.claude-anchor/bin/codex-wrapper` (review item 9).
  - It reads `default` from `codex-routes` and exports `CODEX_HOME` unless it's `-`.
  - The real binary is the `codex` in the last PATH entry that isn't the wrapper itself. If there is none, it uses the
    newest bundled binary under `~/.vscode`/`~/.cursor` extensions.
  - Then it runs `exec "$bin" "$@"`.
- `setWrapper(in:path:)` is generalized to take `(key, ourSuffix)`. Add `setCodexEditorIntegration(_:)`, which writes
  `chatgpt.cliExecutable`, and `Config.codexEditorIntegration: Bool?`.
- `codexWrapperSelfTest`: in a scratch home it checks
  - the default account → `CODEX_HOME`;
  - primary → unset;
  - a preset `CODEX_HOME` is kept;
  - the binary is found through PATH;
  - the wrapper never execs itself.

Acceptance: self-test passes. Unit cases cover
- Codex folder creation: the symlink set, no `auth.json` link, 0700;
- removal: `auth.json` deleted before the trash step, and the path guard refusing `../` and the primary;
- the twin check by `accountID`.

Use a scratch HOME; no real `codex login` in tests.

## Phase 4: UI (Sonnet)

`Sources/Anchor/Views.swift`, `Sources/Anchor/Harbor.swift`
- PopoverHome: a `Seg` "Claude | Codex" above the harbor, shown when `codexAccounts` isn't empty or the Codex CLI is
  installed. `@AppStorage("harborTool")`. The harbor gets the selected tool's accounts, and docking sets that tool's
  default.
- Add-account: a tool picker. Codex is disabled with "Install Codex first" when there's no CLI.
- RulesPane: one list per tool, under "Claude" and "Codex" headers. The account picker lists only that tool's accounts.
- Settings: a "VS Code Codex follows the Codex default (reload the window to apply)" toggle, off by default.
- Usage by account: Codex rows show a small "Codex" tag.
- The menu bar ring and floating dial stay on the Claude default.

Acceptance: build, self-test, then launch the app and screenshot the popover with one Codex account (`run` skill).

## Phase 5: docs (Haiku)

- README:
  - a Codex section: accounts, rules, local limits that update only when Codex runs, and VS Code following the
    default account on reload;
  - remove Codex from the Roadmap;
  - Limitations: no per-folder routing in VS Code, no Codex sync, macOS only.
- USER-GUIDE: adding a Codex account.
- CHANGELOG 0.7.0.
- `uninstall.sh`: remove `chatgpt.cliExecutable` only when it points at our wrapper. Keep `codex-accounts/`.

## Execution

- The main session did the review and the spike, and reviews each phase: rebuild, rerun the self-tests, read the diff.
- Phases run one after another on `feat/codex`, in the main tree (they share `.build`). Phases 1–4 use Sonnet,
  phase 5 uses Haiku.
- Subagents never commit or push.

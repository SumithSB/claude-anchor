# Changelog

All notable changes to Claude Anchor are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.6.0] - 2026-10-20

### Added

- Linux: `claude` is routed in fish, through `~/.config/fish/conf.d/claude-anchor.fish` (only when fish's config folder exists).
- Windows: `claude` is routed in cmd.exe, through a doskey macro in cmd's AutoRun registry value. An existing AutoRun command is kept, and uninstall removes only the macro.

### Changed

- Windows and Linux: the fresh card is one row of account chips, like the macOS app.

### Fixed

- macOS: conversations in folders whose path is longer than 200 characters are now shared between accounts. The shell hook computed a different folder name from Claude Code's for those paths.

## [0.5.0] - 2026-10-19

### Added

- Every berth shows when its 5-hour window resets ("resets in 1h 39m"), not only accounts near their limit. Fresh accounts say "ready now".
- **Settings > Usage > Show API-price estimates** (`showAPIPrices`). Dollar estimates are hidden by default on Pro, Max and Team plans, which are a flat fee.
- **Reopen in VS Code** after continuing a VS Code or Cursor conversation on another account (macOS).
- `Anchor --self-test` runs the usage and limits self-tests, and CI runs it.

### Changed

- API-price estimates use current list prices: Opus 5.5, Sonnet 5, Haiku 5.5 (with its long-prompt tier), Fable, per-model cache reads, and 1-hour cache writes at 2x input. Costs already stored are re-priced once.
- Continue on a conversation from VS Code or Cursor anchors at the target account instead of opening Terminal. A folder rule that would keep it on the old account blocks this with a message (macOS).
- The fresh card is one row of account chips instead of a button per account (macOS).
- The pop-out can be minimized, and its width stays between 340 and 420 pt (macOS).
- The pop-out refreshes at least once a minute unless refresh is set to manual (macOS).

### Fixed

- Limits shown from old data no longer count usage from a window that has already reset. Such a window reads as unused.
- One failed limits check (a 429 or a network blip) keeps the last numbers quietly. "Couldn't reach Anthropic" shows only after 10 minutes (macOS).
- Much lower memory and CPU on macOS: with the pop-out open, 149 MB to 34 MB and 4.8% to 0.8% CPU. The harbor sea animates only while the anchor moves, the fresh glow pulses five times instead of forever, and unchanged usage isn't rewritten to disk.

## [0.4.2] - 2026-10-15

### Fixed

- Windows: `anchor.exe` and the tray app no longer need the Visual C++ Redistributable. Without it they couldn't start, and `install.ps1` stopped with "anchor install failed." The C runtime is now linked into the executables.
- `install.ps1` explains a missing system DLL instead of a bare failure.

## [0.4.1] - 2026-10-15

### Fixed

- Windows install no longer fails when VS Code or Cursor settings have comments after a value, `/* */` comments, or a byte order mark. Editor integration that can't be set up is now skipped with a message instead of stopping the install.
- `install.ps1` shows what `anchor install` printed, so a failure says why.

## [0.4.0] - 2026-10-15

### Added

- Windows 10/11 and Linux (x86_64) support. A tray app with the same harbor switcher, limit rings, usage, last-conversation card, Accounts, Rules and Settings panes, and floating button as the macOS app. Install with `install.ps1` on Windows or `install.sh` on Linux.
- `anchor` command line for Windows and Linux: `which`, `status`, `limits`, `usage`, `account`, `default`, `rule`, `editor`, `continue`, `install` and `uninstall`.
- `claude` is routed in bash, zsh and PowerShell through `anchor exec`, and in VS Code and Cursor through the `claude-wrapper` process wrapper.
- Release builds for Windows (setup.exe, MSI) and Linux (AppImage, deb), each with a `.sha256` checksum.

### Changed

- The macOS installer only picks the `ClaudeAnchor-*.zip` asset, so the Windows command-line zip on the same release is never used on a Mac.

### Notes

- Windows and Linux builds are unsigned. Windows SmartScreen asks once: More info, then Run anyway.
- On Wayland the floating button and the Ctrl+Alt+A shortcut aren't available. GNOME needs the AppIndicator extension to show the tray icon.
- cmd.exe and fish aren't routed yet. Use `anchor exec -- claude` there.

## [0.3.2] - 2026-10-15

### Added

- App icon: a white anchor on a clay tile, matching the logo in the menu. It shows in Finder, Spotlight, Launchpad and notifications. `scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`.

### Fixed

- Building from source no longer leaves a second copy of the app in Spotlight and Launchpad. Builds go to `build.noindex/`, which macOS doesn't index.

## [0.3.1] - 2026-10-15

### Fixed

- Dragging the anchor right to left in the floating button's glance card no longer makes it jump. The card now resizes to fit its content instead of swapping in a second, scrolling copy.

## [0.3.0] - 2026-10-15

### Added

- Fresh resets. When an account's 5-hour window has reset and is unused, it is marked fresh: a teal FRESH badge on its berth, an "Anchor at <Name>" card in the popover (or a "<Name> has a full 5-hour window" card when only the account you're on is fresh), a teal glow and ↻ badge on the floating button, and a reset countdown for near-limit accounts (for example `92% · ↻ 22m`).
- Optional notification when an account's window resets: "<Name>'s 5-hour window reset. Full window available." For the account you're on: "You're on a full window." Turn it off in Settings (`notifyFresh`).
- Over-limit overflow prefers a fresh account.
- Refresh button in the header, which spins while refreshing, and an "Updated 2 min ago" line under the title (amber when outdated).
- Settings > Refresh limits: Live (every 30 s), 1 min, 5 min (default), 15 min, or Manual only (`refreshSeconds`). Live mode calls Anthropic's usage endpoint more often.
- The popover refreshes when opened if its data is older than 30 seconds.
- Pop-out window: move the full menu into a small floating panel. It stays above other windows, doesn't take focus and adds no Dock icon.
- Floating button: a draggable, always-on-top 44 pt round button, on by default, starting at the bottom right. Its ring shows the 5-hour usage of the default account, with a flag badge, a pulsing teal glow and ↻ badge when the account you're on or another account is fresh, and a red badge at 90% and above. Settings: show or hide (also ⌥⌘A), snap to screen edges, fade when idle (off by default), show on every Space. The position is remembered.
- Glance card: click the floating button for the harbor, the 5-hour and weekly bars, "<Name> has a full 5-hour window" when the account you're on is fresh, an "Anchor at <Name> · full 5h" button when another account is fresh, "Open full menu →" and a refresh button.
- Config keys in `~/.claude-anchor/config.json`, all optional: `refreshSeconds`, `notifyFresh`, `floatingButton`, `floatingSnap`, `floatingFade`, `floatingAllSpaces`, `floatingX`, `floatingY`.

### Changed

- Redesigned interface, the "Clay" palette: warm paper (light) and warm charcoal (dark) surfaces with a clay-orange accent. Rings show the 5-hour and weekly limits, teal when fine, amber from 75%, and red from 90%. Cards replace the old layout, with bottom navigation: Accounts, Rules, Settings, Quit. The orange is inspired by Claude's look and is not Anthropic branding.
- The "drop anchor" account switcher replaces the half-dial. Drag the anchor onto an account's berth to make it the default, or click a berth and the anchor sails there. Arrow keys work. It scales from one account to ten or more: roomy berths up to about four, compact berths up to about six, then a scrolling quay with arrows and edge auto-scroll. An Add berth appears when there is room, and long names are truncated.
- The "Last conversation" card replaces the unclear Continue on menu. It shows the folder, one account menu (fresh accounts first) and one button, "Continue on <Name>", which opens a new Terminal tab. A confirmation follows.
- Folder rules are restyled, and show a status line when their account is near its limit. Each rule is a row with the folder, an account menu, an Overflow switch and a ⋯ menu. "Add folder" also accepts a dropped folder, and a Default card shows the account every other folder uses. The large drop box is gone.
- Settings, Accounts and Folder rules share one pane style: uppercase captions, rounded cards, hairline rows, a footnote and a rounded back button. Settings is grouped into General, Limits and Floating button.
- The menu bar window has a fixed height of 640 pt and scrolls, with hidden scroll bars.
- The pop-out panel is quiet: it stays on top, doesn't take focus and adds no Dock icon.
- Accounts are reordered with "Move up" and "Move down" in the ⋯ menu instead of dragging. "Add account" is the last row of the Signed in card.

### Upgrading

- Homebrew: `brew update && brew upgrade --cask claude-anchor`.
- Curl installer: re-run the installer.
- Settings and accounts in `~/.claude-anchor` are untouched. Config files from earlier versions still load.

## [0.2.x] - not tagged

The git history has no 0.2.x version tags or version bumps. The commits below fall between 0.1.0 and 0.3.0, and are grouped here under 0.2.x.

### Added

- Shared conversation history per folder across accounts. Before `claude` starts, the folder's conversations are synced, so `--resume`, `-c` and the VS Code history list keep working after switching. Diverged copies are left alone.
- A per-session account indicator, `CLAUDE_ANCHOR_ACCOUNT`, so a session can tell which account it runs on.
- Source install shell hook (`CLAUDE_ANCHOR_FROM_SOURCE`) and a documented roadmap.
- A native macOS UI pass: grouped forms in the Accounts, Folder rules and Settings panes, native progress bars and switches, Increase Contrast support, and a 20-second tour video.
- Homebrew install and a "read first" install option in the README, which also explains what the app touches.

### Changed

- VS Code and Cursor are routed by default. On first launch, the app enables the Claude process wrapper when either editor is installed, backing up settings first.
- The tour is shown as an inline GIF in the README.
- Credits for claude-swap and brag in the README.
- Built with Swift tools 5.9 so CI and Xcode 15 can compile it, and SwiftUI views are marked MainActor for older SDKs. CI runs on macos-15.

## [0.1.0] - 2026-10-14

### Added

- Initial release: a macOS menu bar account switcher for Claude Code.
- Route Claude Code to the right account per folder, run accounts side by side, auto-switch near rate limits, continue a conversation on another account, and track usage by account, project and model.
- One-line install script, VS Code and Cursor routing through the process wrapper setting, and a zsh shell hook for the terminal.

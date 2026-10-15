# Changelog

All notable changes to Claude Anchor are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.3.0] - 2026-10-15

### Added

- Fresh resets. When another account's 5-hour window has reset and is unused, it is marked fresh: a teal FRESH badge on its berth, an "Anchor at <Name>" card in the popover, a teal dot on the floating button, and a reset countdown for near-limit accounts (for example `92% · ↻ 22m`).
- Optional notification when an account's window resets: "<Name>'s 5-hour window reset. Full window available." Turn it off in Settings (`notifyFresh`).
- Over-limit overflow prefers a fresh account.
- Refresh button in the header, which spins while refreshing, and an "Updated 2 min ago" line under the title (amber when outdated).
- Settings > Refresh limits: Live (every 30 s), 1 min, 5 min (default), 15 min, or Manual only (`refreshSeconds`). Live mode calls Anthropic's usage endpoint more often.
- The popover refreshes when opened if its data is older than 30 seconds.
- Pop-out window: move the full menu into its own resizable window, with a "keep on top" pin and a Dock action to return it. While the window is open, the app also shows a Dock icon.
- Floating button: a draggable, always-on-top round button. Its ring shows the 5-hour usage of the default account, with a flag badge, a teal dot when an account is fresh, and a red badge at 90% and above. A click opens a quick panel with limits, the fresh card, the harbor switcher and the continue card. Settings: show or hide, snap to screen edges, fade when idle, show on every Space. The position is remembered.
- Config keys in `~/.claude-anchor/config.json`, all optional: `refreshSeconds`, `notifyFresh`, `floatingButton`, `floatingSnap`, `floatingFade`, `floatingAllSpaces`, `floatingX`, `floatingY`.

### Changed

- Redesigned interface, the "Clay" palette: warm paper (light) and warm charcoal (dark) surfaces with a clay-orange accent. Rings show the 5-hour and weekly limits, teal when fine, amber from 75%, and red from 90%. Cards replace the old layout, with bottom navigation: Accounts, Rules, Settings, Quit. The orange is inspired by Claude's look and is not Anthropic branding.
- The "drop anchor" account switcher replaces the half-dial. Drag the anchor onto an account's berth to make it the default, or click a berth and the anchor sails there. Arrow keys work. It scales from one account to ten or more: roomy berths up to about four, compact berths up to about six, then a scrolling quay with arrows and edge auto-scroll. An Add berth appears when there is room, and long names are truncated.
- The "Last conversation" card replaces the unclear Continue on menu. It shows the folder, the source account, the last prompt for context, a plain explanation, and the target accounts (fresh first). It has one button, "Continue on <Name>", and a confirmation after.
- Folder rules are restyled, and show a status line when their account is near its limit.

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

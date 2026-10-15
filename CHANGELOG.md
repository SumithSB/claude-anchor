# Changelog

All notable changes to Claude Anchor are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

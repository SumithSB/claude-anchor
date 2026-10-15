# User guide

This guide walks through the common tasks in Claude Anchor 0.3. For what the app touches on disk and the settings reference, see the [README](../README.md).

Contents:

- [First run](#first-run)
- [The menu](#the-menu)
- [Adding accounts](#adding-accounts)
- [Switching the default account](#switching-the-default-account)
- [Folder rules and overflow](#folder-rules-and-overflow)
- [Reading the rings](#reading-the-rings)
- [Fresh resets](#fresh-resets)
- [Refresh settings](#refresh-settings)
- [Pop-out window](#pop-out-window)
- [Floating button](#floating-button)
- [Continuing a conversation](#continuing-a-conversation)
- [Troubleshooting](#troubleshooting)

## First run

1. Install the app with the [installer or Homebrew](../README.md#install). The app opens from the menu bar.
2. If you have VS Code or Cursor installed, the app turns on routing for them. Your editor settings are backed up first, as `settings.json.anchor-backup`. You can turn this off in Settings > "Use in VS Code and Cursor".
3. Your existing Claude Code login is the primary account. It stays in `~/.claude`, and you don't need to change anything for it.
4. To use a second account, [add it](#adding-accounts). Until you add one, the menu asks you to add an account to start.
5. The [floating button](#floating-button) appears at the bottom right of the screen. Hide it in Settings or with ⌥⌘A.

## The menu

Click the anchor in the menu bar. The window is a fixed height and scrolls. From top to bottom:

- **Header:** the app name, how many accounts are routed, the Updated line, and two buttons: pop-out and refresh.
- **Harbor switcher:** your accounts as berths. See [Switching the default account](#switching-the-default-account).
- **Fresh card:** "Anchor at <Name>" when another account is fresh. When only the account you're on is fresh, a teal card says "<Name> has a full 5-hour window" and that your limit just reset.
- **Account card:** the default account, with its 5-hour and weekly rings.
- **Usage card:** tokens and estimated API cost for Today, 7 days or 30 days, by account, project or model.
- **Last conversation card:** see [Continuing a conversation](#continuing-a-conversation).
- **Bottom bar:** **Accounts**, **Rules**, **Settings**, and a Quit button.

Accounts, Rules and Settings open as panes. Each pane groups its rows in cards under a small caption, with a note below. Click the back button at the top left to return.

Settings has three cards:

- **General:** launch at login, bell sound, auto-switch near limit, and use in VS Code and Cursor.
- **Limits:** how often limits refresh, and the fresh-reset notification.
- **Floating button:** show the button (⌥⌘A), snap to screen edges, fade when idle, and show on every Space.

## Adding accounts

1. Open the menu and choose **Accounts**, then click **Add account**, the last row of the Signed in card.
2. Sign in with the Claude account you want to add. Each extra account gets its own folder under `~/.claude-anchor/accounts/`.
3. The account appears as a berth in the harbor switcher. Its limits start showing after the next refresh.

Each account's login is kept in the Keychain as Claude Code's own item. Use an account's ⋯ menu to rename it, change its flag, reorder it with **Move up** and **Move down**, or remove it. Its history stays in `~/.claude-anchor/accounts/` until you delete it.

## Switching the default account

The default account is where new Claude Code sessions start. The harbor switcher shows your accounts as berths on a chain, with the anchor on the default.

- **Drag** the anchor onto another account's berth.
- Or **click** a berth. The anchor sails there.
- Arrow keys work too.

Running sessions keep the account they started with. A change applies to the next session you start.

With a few accounts, the berths are roomy. With more, they get compact. Past about six accounts, the berths scroll along a quay. Use the arrows at the edges, or drag the anchor toward an edge to scroll. An **Add berth** appears when there is room for one more account. Long account names are cut short with an ellipsis.

## Folder rules and overflow

Folder rules send a folder, and everything inside it, to a specific account.

1. Open **Rules**. In the Folders card, click **Add folder**, or drop a folder from Finder onto that row.
2. Pick the account it should use from the menu in the rule's row.
3. Turn on **Overflow** if the folder may use the default account when its own account is near its limit.

Use the ⋯ menu on a row to change or remove the rule. The **Default** card shows the account every other folder uses.

When rules overlap, the most specific one wins. A rule for `~/Work/client-a` beats a rule for `~/Work`. Folders with no rule use the default account.

Rules show a status line when their account is near its limit. If the account has used most of its window, the line says so.

**Overflow:** when the active account nears its limit, the app moves the default to an account with headroom. If an account is over its limit, the overflow goes to a [fresh account](#fresh-resets) first when one is available.

## Reading the rings

Each account has two rings, one for the 5-hour limit and one for the weekly limit. The ring fills as you use the window.

- **Teal:** fine.
- **Amber:** 75% and above.
- **Red:** 90% and above.

The number next to a ring is the percentage used. The colour is a guide, so check the number when it matters.

The floating button's ring shows the 5-hour usage of the default account only.

## Fresh resets

An account is **fresh** when its 5-hour window has reset and it has not been used since. A fresh account has a full window available, so it is free to use. This works for the account you're on as well as the others.

Where you'll see it:

- A teal **FRESH** badge on the account's berth.
- In the menu, an **Anchor at <Name>** card when another account is fresh. Click it to make that account the default. When only the account you're on is fresh, a teal card says "<Name> has a full 5-hour window" instead.
- A pulsing teal glow and ↻ badge on the floating button.
- For accounts near their limit, a countdown to the reset, such as `92% · ↻ 22m`.
- A notification: "<Name>'s 5-hour window reset. Full window available." For the account you're on, it says "<Name>'s 5-hour window reset. You're on a full window."

To turn the notification off, open Settings and turn off the fresh-reset notification. The config key is `notifyFresh`.

## Refresh settings

The app refreshes limits on a timer. You can see when they were last updated.

- **Refresh button:** in the header. It spins while the refresh runs.
- **Updated line:** under the title, for example "Updated 2 min ago". It turns amber when the data is outdated.
- **On open:** the popover refreshes when you open it, if the data is more than 30 seconds old.

To change the interval, open **Settings > Refresh limits** and pick one:

- **Live:** every 30 seconds. This calls Anthropic's usage endpoint more often.
- **1 min**
- **5 min:** the default.
- **15 min**
- **Manual only:** refresh with the button.

The config key is `refreshSeconds`, in seconds. `0` means manual.

## Pop-out window

Pop the full menu out of the menu bar when you want it to stay open.

1. Click the pop-out button in the menu's header.
2. The menu opens in a small floating panel that stays above other windows. It doesn't take focus from the app you're in, and no Dock icon appears.
3. Close the panel to return to the menu bar.

## Floating button

The floating button is on by default. It is a 44 pt round button that starts at the bottom right of the screen. Drag it anywhere; it stays above other windows.

What the parts mean:

- **Ring:** 5-hour usage of the default account.
- **Flag badge:** the account's flag.
- **Teal glow and ↻ badge:** the account you're on, or another account, has a full 5-hour window.
- **Red badge:** usage is 90% or more.

Hover over it for a tooltip with the account and its usage. It adds "full 5h window" when the account you're on is fresh. Click it to open a small glance card:

- The harbor, to switch the default account.
- The 5-hour and weekly bars.
- "<Name> has a full 5-hour window", when the account you're on is fresh.
- **Anchor at <Name> · full 5h**, shown when another account has a fresh 5-hour window. Click it to make that account the default.
- **Open full menu →**, which opens the menu bar menu, and a refresh button.

Settings for the button, under **Settings > Floating button**:

- **Show floating button** (`floatingButton`, on by default). ⌥⌘A also shows or hides it.
- **Snap to screen edges** (`floatingSnap`, on).
- **Fade when idle** (`floatingFade`, off).
- **Show on every Space** (`floatingAllSpaces`, on).

The button remembers where you left it (`floatingX` and `floatingY`).

## Continuing a conversation

Use this when a conversation has hit the limit on one account and you want to keep going on another.

1. Find the **Last conversation** card in the menu. It shows the folder the conversation is in.
2. Pick the target account from the menu below the folder. Fresh accounts are listed first.
3. Click **Continue on <Name>**.

The app copies the transcript to that account and resumes it in a new Terminal tab, with the full history. A confirmation appears when it is done.

The continued conversation runs on the target account, so its usage is counted there.

## Troubleshooting

### `brew upgrade` says the cask is not installed

`Error: Cask 'claude-anchor' is not installed` means Homebrew didn't install the app on this Mac (it came from the curl installer, a zip or a source build). Re-run the curl installer to upgrade, or switch to Homebrew:

```sh
brew install --cask --force sumithsb/tap/claude-anchor
```

After that, `brew upgrade --cask claude-anchor` works. Your settings and accounts in `~/.claude-anchor` are kept either way.

### The menu is not updating

- Look at the **Updated** line. If it is amber, the data is old.
- Click the refresh button.
- Check **Settings > Refresh limits**. If it is set to **Manual only**, the numbers change only when you refresh.
- Make sure the account is signed in to Claude Code. The app reads the login that Claude Code keeps in the Keychain, and it never refreshes tokens itself. Run `claude` once in that account; Claude Code refreshes the token.
- If the network is down or `api.anthropic.com` can't be reached, the numbers stay old until it comes back.

### A session is on the wrong account

- A running session keeps its account. Start a new session after you change the default or a folder rule.
- To see which account a session uses, run `/status` in it, or check `$CLAUDE_ANCHOR_ACCOUNT`. Don't go by `~/.claude.json`: it always belongs to your primary account.
- In a terminal, run `anchor-which` in the folder to see which account `claude` will use there.
- If `CLAUDE_ANCHOR_OFF=1` is set, or `CLAUDE_CONFIG_DIR` is already exported in the shell, the shell function is bypassed. Unset them to route through the app again.
- In VS Code or Cursor, check that the setting "Use in VS Code and Cursor" is on. New conversations follow the default account and folder rules.

### Notifications do not appear

- Check the fresh-reset notification setting (`notifyFresh`) in Settings.
- Check macOS notification permission for Claude Anchor in System Settings > Notifications.

### Uninstall

Use the uninstall command in the [README](../README.md#uninstall). It removes the app, the `~/.zshrc` line and the editor setting, and asks before it deletes `~/.claude-anchor`. Your `~/.claude` folder is not changed.

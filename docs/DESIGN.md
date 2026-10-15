# Design notes

These notes describe how Claude Anchor 0.3 looks and why. The palette is called "Clay". The clay-orange accent is inspired by Claude's look. It is not Anthropic branding, and the app is not affiliated with Anthropic.

## Palette

Colours are defined as tokens. Light and dark values are listed below.

| Token | Light | Dark | Used for |
|---|---|---|---|
| paper | `#F5F3EE` | `#1D1C1A` | window and popover background |
| surface | `#FFFFFF` | `#272624` | cards and grouped rows |
| surface2 | `#F0EDE6` | `#302E2B` | nested areas, berths and wells |
| accent | `#D97757` | `#D97757` | identity marks and primary actions |
| accent text | `#A64A28` | `#EB9475` | accent-coloured text and links |
| accent fill | `#B9583A` | not defined | filled primary buttons (white label) |
| fresh | `#2A7262` | `#72C2AF` | fresh accounts and resets |
| amber | `#8C5F0B` | `#E8BA5A` | limits from 75%, outdated data |
| limit | `#B5352E` | `#F27D72` | limits from 90% |

The accent fill is only defined for light mode.

### Contrast

Text must meet 4.5:1 against its background. The ratios below were checked against the values in the table.

- Light, on any surface (white, paper or `surface2`): accent text 4.95 to 6.31, fresh 4.88 to 5.70, amber 4.78 to 5.59, limit 5.11 to 5.98. All pass.
- Dark, on any surface: all text colours pass (5.13 to 9.41).
- White label on accent fill `#B9583A`: 4.65. Dark label on the dark accent `#D97757`: 5.45. Both pass.
- Secondary text (`#6B6760` light, `#A9A49B` dark) passes on every surface (4.81 to 6.87).

## Principles

- **The accent marks identity and primary actions only.** The clay orange appears on the anchor, the account identity marks and the main button. It does not colour ordinary status text, borders or backgrounds.
- **Status never relies on hue alone.** Limit colours are always paired with the percentage, and the FRESH badge is text.
- **Reduced motion is respected.**
- **Text meets 4.5:1 contrast**.
- **Increase Contrast is supported**, as it was in 0.1.
- **Long names truncate** instead of wrapping, so rows stay the same height.

## Menu and panes

- **Menu bar window:** 340 pt wide and a fixed 640 pt tall. The content scrolls, with the scroll bars hidden, so the window never jumps in size as cards come and go.
- **Header:** two icon buttons, pop-out and refresh. The floating button is toggled from Settings or with ⌥⌘A, not from the header.
- **Bottom bar:** Accounts, Rules and Settings with labels, and Quit as an icon only.
- **Panes:** Settings, Accounts and Folder rules share one style. A rounded back button and the title sit at the top. Rows are grouped in rounded cards under an uppercase caption, separated by hairlines, with a footnote below when one is needed. Account and rule actions sit in a ⋯ menu on each row; the last row of a card adds an item (Add account, Add folder).
- **Pop-out:** the same content in a small floating panel that stays on top, doesn't take focus and adds no Dock icon.

## Harbor switcher layout

The harbor switcher shows accounts as berths on a chain. The anchor sits on the chain and marks the default account.

Layout rules:

- **1 to about 4 accounts:** roomy berths.
- **About 5 to 6 accounts:** compact berths.
- **More than about 6 accounts:** a scrolling quay. Arrow buttons appear at the edges. Dragging the anchor toward an edge auto-scrolls the quay.
- **Add berth:** shown after the last account only when there is room. It is not shown on a full quay.
- **Long names:** truncate.
- **Badges:** a FRESH badge on a berth is teal and text. Near-limit accounts show a reset countdown, such as `92% · ↻ 22m`.
- **Interaction:** drag the anchor onto a berth, or click a berth and the anchor sails there. Arrow keys work too.

## Floating button

The floating button is a 44 pt round, draggable, always-on-top control. It is on by default and starts at the bottom right of the screen.

States:

| State | Appearance |
|---|---|
| Default | Ring shows the 5-hour usage of the default account, in teal, amber or red by threshold. |
| Fresh | Pulsing teal glow and a ↻ badge when the account you're on, or another account, has a full 5-hour window. |
| Over limit | Red badge when usage is 90% or more. |
| Idle | Fades after a few idle seconds, if fade is on. Fade is off by default. |
| Snapped | Sits against a screen edge when snap is on. |
| Hidden | Not shown when the floating button setting is off. ⌥⌘A toggles it. |

Clicking the button opens a glance card: the harbor switcher, the 5-hour and weekly bars, a "<Name> has a full 5-hour window" line when the account you're on is fresh, an "Anchor at <Name> · full 5h" button when another account is fresh, "Open full menu →" and a refresh button. The position is stored as `floatingX` and `floatingY` in `config.json`. Show on every Space is controlled by `floatingAllSpaces`.

## Motion

Motion is limited to feedback: the refresh button spins while refreshing, the anchor sails to a selected berth, the floating button glows while an account is fresh, and it fades when idle if that setting is on. Reduced motion is respected throughout.

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
| accent text | `#B5532F` | `#EB9475` | accent-coloured text and links |
| accent fill | `#B9583A` | not defined | filled primary buttons (white label) |
| fresh | `#2F7F6F` | `#72C2AF` | fresh accounts and resets |
| amber | `#9A6A0E` | `#E8BA5A` | limits from 75%, outdated data |
| limit | `#B5352E` | `#F27D72` | limits from 90% |

The accent fill is only defined for light mode.

### Contrast

Text must meet 4.5:1 against its background. The ratios below were checked against the values in the table.

- Light, on white (`surface`): accent text 4.95, fresh 4.79, amber 4.73, limit 5.98. Passes.
- Light, on paper or `surface2`: accent text 4.23 to 4.46, fresh 4.10 to 4.32, amber 4.04 to 4.26. **Below 4.5:1.** Limit passes on all three (5.11 to 5.39).
- Dark, on any surface: all text colours pass (5.13 to 9.41).
- White label on accent fill `#B9583A`: 4.65. Passes.

Known gap: in light mode, the accent text, fresh and amber colours fall just short of 4.5:1 when used as text on paper or `surface2`. Use them on `surface` where they are text, or darken them before relying on them for small text on the paper background. The values above are the current spec and have not been changed.

## Principles

- **The accent marks identity and primary actions only.** The clay orange appears on the anchor, the account identity marks and the main button. It does not colour ordinary status text, borders or backgrounds.
- **Status never relies on hue alone.** Limit colours are always paired with the percentage, and the FRESH badge is text.
- **Reduced motion is respected.**
- **Text meets 4.5:1 contrast** (see the gap above).
- **Increase Contrast is supported**, as it was in 0.1.
- **Long names truncate** instead of wrapping, so rows stay the same height.

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

The floating button is a round, draggable, always-on-top control.

States:

| State | Appearance |
|---|---|
| Default | Ring shows the 5-hour usage of the default account, in teal, amber or red by threshold. |
| Fresh | Teal dot on the button when any account is fresh. |
| Over limit | Red badge when usage is 90% or more. |
| Idle | Fades when idle, if fade is on. |
| Snapped | Sits against a screen edge when snap is on. |
| Hidden | Not shown when the floating button setting is off. |

Clicking the button opens a quick panel with the limits, the fresh card, the harbor switcher and the continue card. The position is stored as `floatingX` and `floatingY` in `config.json`. Show on every Space is controlled by `floatingAllSpaces`.

## Motion

Motion is limited to feedback: the refresh button spins while refreshing, the anchor sails to a selected berth, and the floating button fades when idle. Reduced motion is respected throughout.

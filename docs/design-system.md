# Design system

The app's visual language lives in `lib/theme/`. Screens import
`theme/app_theme.dart`, which re-exports everything below.

| File | Contents |
| --- | --- |
| `tokens.dart` | `AppColors`, `AppSpace`, `AppRadius`, `AppFontSize` |
| `typography.dart` | `AppText`, the named text styles |
| `app_theme.dart` | `AppTheme.light`, the Material theme built from the tokens |

Shared components (`PrimaryButton`, `StatusPill`, `SurfaceCard`, header, bottom
nav) are in `lib/widgets/app_widgets.dart` and `lib/widgets/shell_widgets.dart`.

## Principles ("Calm field", October 2026)

- **Low glare.** The page is a soft sage-grey (`canvas`), text is green-charcoal
  (`ink`), not black, and the primary colour is a muted slate-teal. Status colours
  are desaturated (jade, ochre, clay). Nothing on a normal screen is pure black.
- **Room to breathe.** 20 pt page gutter (`AppSpace.page`), 20 pt inside cards
  (`AppSpace.card`), 28 pt between sections (`AppSpace.section`). List rows are
  at least 56 pt tall; buttons 50–54 pt.
- **One job per screen.** Show the few things needed now: a summary, the next
  steps, the primary action. Put the breakdown one tap away (a details page, a
  sheet, or a line that expands), never stacked underneath.
- **Quiet surfaces.** White cards with a hairline border and 18 pt corners, no
  shadows. Group related rows in one card with dividers instead of a card per row.
- **Medium weights.** Body 400, emphasis 500, titles 600. 700 and 800 are not
  used: Poppins is already strong at 600.
- **One primary action per screen**, in `navy`. Secondary actions are outlined or
  text buttons.
- **Notes, not banners.** Status and caveats are a line of muted text, not a
  boxed alert, unless the user must act on them.

## Typography

Poppins, bundled in `assets/fonts/` (SIL Open Font License) so it renders offline.
Weights 400, 500 and 600 are used (700 is bundled but not used).

| Style | Size | Weight | Use |
| --- | --- | --- | --- |
| `AppText.display` | 32 | 600 | Large figures |
| `AppText.headline` | 24 | 600 | Rare, page headlines |
| `AppText.title` | 20 | 600 | Screen and card titles |
| `AppText.subtitle` | 16.5 | 500 | Section titles |
| `AppText.body` | 15 (line height 1.55) | 400 | Body text |
| `AppText.bodyStrong` | 15 | 500 | Emphasised body, list item names |
| `AppText.secondary` | 13.5 | 400 | Supporting text (muted) |
| `AppText.label` | 15 | 500 | Buttons |
| `AppText.small` | 12 | 400 | Metadata (muted) |
| `AppText.caption` | 11 | 400 | Captions, attribution (muted) |

Every font size in the app is an `AppFontSize` step: 11, 12, 13.5, 15, 16.5, 20,
24, 32, 40. Use a named style where one fits; otherwise use `AppFontSize`, never a
literal size.

Button `textStyle` replaces the inherited style rather than merging with it,
so button styles must start from an `AppText` style (which carries the font
family), not a bare `TextStyle`.

## Colour

| Role | Tokens |
| --- | --- |
| Text | `ink`, `inkMuted`, `inkSubtle` |
| Surfaces | `canvas` (page), `surface` (cards), `surfaceAlt` (quiet fills), `border` |
| Primary | `navy` |
| Success | `emeraldDark` (text/marks), `emerald`, `mint` (fill) |
| Warning | `amberInk` (text), `amber` (marks), `amberSoft` (fill) |
| Error | `red`, `redSoft` (fill) |

The camera, live-scan and sphere screens use their own dark overlay colours
because they sit on top of the camera feed.

## Spacing and shape

- Spacing on a 4 pt grid: `AppSpace.xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 24,
  `xxl` 32. Page gutter is `AppSpace.page` (16).
- Radii: controls `AppRadius.control` (12), cards `AppRadius.card` (14), sheets
  `AppRadius.sheet` (20 top corners).

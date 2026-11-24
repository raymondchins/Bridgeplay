# Bridgeplay UI guideline

Read this before touching any UI: the app, the Setup Assistant, the installer, or the in-game
overlay and quick settings. It records the UI as built after the Mac HIG pass (2026-11), with
the value and the file behind each rule.

Our users are Mac players who know Steam and don't know Wine. Reuse what is here. If nothing
fits, say so in the PR; don't add a colour, size or control.

## Principles

1. **Answer "can I play?" first.** One headline, then the details.
2. **When unsure, do what macOS does.** Native controls, dialogs, menus, sidebar and wording.
3. **Layered greys, never pure black.** Each step up (page, card, control) is a little lighter,
   as Dark Mode draws elevation. Near-white type, hairlines. Shadows only on things that float.
4. **One accent for controls:** blue `#1F75FE` on switches, sliders and the chosen sidebar icon.
5. **The brand gradient marks emphasis only:** progress, the ready headline, the frame-time line.
   Never a button or a control. Never removed.
6. **One white button** per row or step.
7. **Say what is kept** whenever something installs, repairs or removes.
8. **Stay quiet.** News waits in a banner. Motion stops under Reduce Motion.

## Leave to macOS

| Need | Use | Not |
|---|---|---|
| On or off | `Toggle` with `.toggleStyle(.switch)` | A custom switch |
| A number in a range | `Slider` with min and max labels | A custom slider |
| One of several | `Picker` (menu or `.segmented`) | Buttons in a row |
| A choice with a cost | `.confirmationDialog`, title visible | A custom modal |
| Page actions | Toolbar items with a symbol and `.help` | Buttons in the page |
| Commands | The menu bar, with ⌘ shortcuts | A hamburger or gear menu |
| A list with columns | `Table` | A hand-built grid |
| Nothing to show | `ContentUnavailableView` | "No data" |
| Choosing a file | `NSOpenPanel` | A path field |
| Updates, About | Sparkle's window, the standard About panel | Our own |
| Sidebar and toolbar background | The system's glass: give them no background | `BP.bg` behind them |

Controls take the accent from `.tint(BP.accent)` on the window; don't tint them one by one.

## Colour

Tokens: `BP.*` in `app/Sources/BridgeplayUI/BridgeplayTheme.swift`. The app is dark only.

| Token | Value | Use |
|---|---|---|
| `bg` | `#111113` | Page, behind the detail column |
| `raise` | `#1A1A1D` | Cards, banners, the floating card |
| `raise2` | `#242428` | Controls drawn by hand: tracks, badges, step segments, disabled pill |
| `fg` | `#F5F5F7` | Titles, values that matter |
| `fg2` | `#A1A1A6` (`#C7C7CC`) | Descriptions, values, section headers |
| `fg3` | `#86868B` (`#AEAEB2`) | Captions, inactive, min and max labels |
| `line` | white 8% (24%) | Card borders, dividers |
| `lineStrong` | white 18% (42%) | Secondary button, floating card |
| `chipFill` `chipLine` | white 7% (12%) · white 12% (32%) | A hero chip's pill and its border |
| `accent` | `#1F75FE` | Switch on, slider fill, chosen sidebar icon, links in controls |
| `iridescent` | `#8B7BFF` → `#4FB3FF` → `#FF7AC6` | Progress, the ready headline, the frame-time line |
| `violet` `blue` `pink` | `#8B7BFF` `#4FB3FF` `#FF7AC6` | One per hero chip's dot, in that order |
| `green` `orange` `red` | `#30D158` `#FF9F0A` `#FF453A` | Ready · needs attention · failed |

- Values in brackets are what the token gives with Increase Contrast on (System Settings ›
  Accessibility › Display). Use the token, never the hex, so this keeps working.
- Status is a dot plus words (`StatusTone`): filled green, orange or red; a hollow ring for
  info (`fg2`) and neutral (`fg3`).
- The chosen sidebar item is white 9% with a `line` hairline and an accent icon; hover is
  white 4%. That is the app's one selection style; the quick settings' focused row uses it too.
- `overlay-shim/perfhud.m` repeats these as hex (`PH_*`, `ph_style`). Change both together.

## Type

Geist via `BP.sans(size, weight)`; default 13. Unbounded (`BP.display`) is the wordmark only.

| Role | Size / weight / tracking | Colour |
|---|---|---|
| Page headline | 30 semibold, −1 | `fg` |
| Step title | 28 semibold, −0.9 | `fg` |
| Hero headline | 24 semibold, −0.7 | `fg`; gradient when ready |
| Section title | 20 semibold, −0.5 | `fg` |
| Sheet title | 17 semibold | `fg` |
| Lead | 14 regular | `fg2` |
| Wordmark | Unbounded 14 (sidebar); 13 beside the tiled mark (Setup Assistant, installer) | `fg` in the sidebar; gradient in the other two |
| Row title | 13 semibold, −0.1 (wizard: 14, −0.2) | `fg` |
| Sidebar item | 13 regular; semibold when chosen | `fg2`; `fg` when chosen |
| Body, value | 13 regular | `fg2` |
| Section header | 12 semibold, +0.2 | `fg2` |
| Hero chip | 12 medium | `fg` |
| Caption | 12 regular | `fg2` or `fg3` |
| Small | 11 regular or medium | `fg3` |

- Weights: regular, medium, semibold. Nothing under 11 pt.
- Changing numbers use `.monospacedDigit()` (in game: tabular figures from `ph_font`).

## Space, radius, size

There are no spacing tokens. Pick from the values in use.

| Space | Where |
|---|---|
| 2 | Title to caption |
| 6 · 8 | Between chips · between buttons |
| 9 | Sidebar icon to label |
| 12 | Icon to text; text inside a card; between cards in game |
| 16 | Row and banner side padding |
| 20 (`BP.pageMargin`) | Page side margin, sheet padding, quick settings margin |
| 24 · 28 | Hero padding · wizard gutter |

| Radius | Where |
|---|---|
| 12 (`BP.radius`) | Cards, heroes, the detailed overlay, quick settings cards |
| 8 | Sidebar item, focused row, one-line overlay, graph well |
| 7 | 24 pt badge, 32 pt game icon, segmented control |
| Capsule | Buttons, chips, switches, slider knobs, progress |

- Rounded rectangles are `.continuous`. Borders are 1 pt, inside.

| Thing | Size |
|---|---|
| Main window | 900 × 760, minimum 800 × 600 |
| Sidebar | 180 to 260 wide (ideal 200); item 32 high with 2 pt above and below in its click area |
| Content column | Status, Game Defaults and Guide: at most 720 wide (`BP.pageWidth`), centred |
| Hero | 148 high, 14 from the top |
| Wizard, installer | 780 × 580; art rail 240 |
| Sheets | 440 or 460 wide |
| Floating card | 360 wide |
| Quick settings | 320 wide (the window's width below 380), full height, right edge |
| Performance overlay | 28 high; Detailed 240 wide; 12 from the top-left corner |

## Sidebar

`RootView.swift`. The system's sidebar in a `NavigationSplitView`, with the toggle.

- No background: it shows the system glass. No hairline of our own between it and the page.
- Top: the mark without its tile (`BridgeplayMark(size: 26, tile: false)` in an 18 wide
  column, over the icons) and the wordmark in `fg`, no gradient.
- Items are `SidebarItem` buttons: SF Symbol 13 medium in an 18 pt column (`fg3`, accent
  when chosen), label 13. A press picks the page on mouse down, as Finder's does; Tab and Space
  still work.
- Bottom: the credits in 11 `fg3`, one per line (NotProton, CodeWeavers, Apple's Game Porting
  Toolkit, "Buy CrossOver"), then the library card, then the version. Keep the credits.
- ⌘1 to ⌘5 and Help › Guide (⌘?) are in `App.swift`.

## Motion

| What | Timing | Code |
|---|---|---|
| Press (scale 0.97) | ease-out 0.18 s | `PillButtonStyle` |
| Step labels | ease-out 0.2 s | `StepBar` |
| Row highlight | ease-in-out 0.3 s | `StatusView.engineRow` |
| Wizard page | spring 0.42 / 0.86 | `pageSpring` |
| Wizard rows | spring 0.32 / 0.8; 260 ms, then every 210 ms | `rowSpring`, `wave()` |
| Corner card | spring 0.45 s, bounce 0.18 | `RootView` |
| Aurora | ease-in-out 0.9 s, 30 fps | `Aurora` |
| Skeleton shimmer | linear 1.4 s | `Skeleton.swift` |

- New motion: under `accessibilityReduceMotion`, fades only; shimmer, aurora and art stop.
- New ambient motion pauses when `appearsActive` is false, as the aurora does. Some older
  motion doesn't follow these two yet (see Known gaps).
- Nothing animates in the game.

## Icons

- SF Symbols only. No emoji.
- Small glyphs: 11 semibold. Badge glyphs: 10 bold.
- Decorative icons are hidden from VoiceOver. Icon-only buttons have a label.
- The mark is `BridgeplayMark(size:)`: 22, 26 (sidebar, no tile), 52 or 136. `GlassMark` never
  sits beside the wordmark.

## Components

Files are in `app/Sources/BridgeplayApp/Views/` unless a path is given.

| Need | Use | Spec | File |
|---|---|---|---|
| Main action | `.pill` · `.pillLarge` | 28 high, 13 semibold · 34 high, 14 semibold. White, black text | `BridgeplayUI/BridgeplayTheme.swift` |
| Other action | `.pillSecondary` | Clear, 1 pt `lineStrong` | same |
| Back, Cancel, Not Now | `.pillPlain` | `fg2`, no border | same |
| On or off | `Toggle`, `.switch`, `.labelsHidden()` | Native, accent when on | `StatusView.swift`, `GameDefaultsView.swift` |
| A number in a range | `Slider` | Native; min and max labels in `fg3`; whole numbers by rounding, not `step:` | `GameDefaultsView.swift` |
| One of several | `Picker` menu | Value tinted `fg` | `GameDefaultsView.swift` |
| State or setting | `StatusRow` in a grouped `Form` | 8 pt dot, title, value, one control | `StatusView.swift` |
| The same in a wizard | `SetupCard` + `WizardRow` | Badge 24 × 24; padding 16 × 13; hairline inset 54 | `BridgeplayUI/SetupCard.swift`, `SetupAssistantView.swift` |
| A fact | `HeroChip` | 6 pt dot in violet, blue, pink; 12 medium on `chipFill`, `chipLine` border; VoiceOver reads a hero's chips as one line | `StatusHero.swift` |
| Known progress | `GradientProgress` · `DownloadStrip` | 4 pt, with a count or bytes | `SetupAssistantView.swift`, `DownloadStrip.swift` |
| Steps | `StepBar` + `StepHeader` | 3 pt segments, 6 pt gaps | `SetupAssistantView.swift` |
| Page top | `StatusHero` | Aurora, headline, one line, chips | `StatusHero.swift` |
| Page loading | `SkeletonPage` · `SkeletonTable` | Bars white 7% | `Skeleton.swift` |
| Background news | `UpdateBannerRow` | `raise`, padding 16 × 10 | `UpdateBanner.swift` |
| An optional ask | `StarPromptCard` | 360 wide, `raise`, `lineStrong`, the only shadow | `StarPromptCard.swift` |

- A row is a title, one short line and one control.
- A switch acts at once. If turning it on has a cost, it opens a confirmation first.
- A changed setting shows `ResetButton`. A default shows nothing.
- A disabled button says why, in `.help` or the row's text.

## States

Every page has all four: loading, empty, failed, loaded.

| Situation | Use |
|---|---|
| Page loading | Skeleton, with an accessibility label |
| Work running | Small spinner and what it is doing |
| Known amount | `GradientProgress` and "2 of 3" |
| Nothing yet | `ContentUnavailableView`: symbol, title, when it fills |
| Worked | `StatusRow` "Done", tone ok |
| Failed | `StatusRow`, tone bad: the reason, a remedy button, Report under "More" |
| Needs the user | `StatusRow`, tone warning, one `.pill` |

## In the game

The overlay and quick settings are C in the game's process (`overlay-shim/`). They can't use
SwiftUI, so they draw the app's look by hand with Core Graphics. Same tokens, same type, same
control shapes. Nothing animates, and they have no symbols.

| Token in C | App token | Value |
|---|---|---|
| `PH_PAGE` | `bg` | `#111113` |
| `PH_CARD` | `raise` | `#1A1A1D` |
| `PH_CONTROL` | `raise2` | `#242428` |
| `PH_ACCENT` | `accent` | `#1F75FE` |
| `PH_FG2` `PH_FG3` `PH_LINE` `PH_LINE_STRONG` | `fg2` `fg3` `line` `lineStrong` | With their Increase Contrast values, read through `NSWorkspace` on the main thread |

**Performance overlay** (`perfhud.m`): a floating card over the game.

- `PH_CARD` at 90%, a 1 pt `PH_LINE_STRONG` border, no shadow. Radius 8 for FPS and Summary
  (28 high, 12 side padding), 12 for Detailed (240 wide, 16 side padding).
- Values 13 semibold `fg`; the big FPS 22 semibold. Labels ("FPS", "CPU") 11 medium `fg2`,
  +0.3. Detailed row labels 12 regular `fg2`. Units in `fg2` on the number's baseline.
- Detailed: the frame-time graph in a `PH_CONTROL` well (radius 8), drawn in the brand gradient,
  amber where a frame runs half again over budget; the budget line in `PH_LINE_STRONG`; a
  `PH_LINE` hairline before the readings.
- Leave out a value the Mac does not report. Never guess one.

**Quick settings** (`sidebar.m`): the app's grouped settings page, in small.

- Panel `PH_PAGE` at 97% over a black 32% scrim, a `PH_LINE` hairline on its left edge. 20 pt
  margins. Title "Quick Settings" 17 semibold; ⌥⌘P at the right in `fg3`.
- Battery line under the title: label `fg2`, value `fg`, a 4 pt gauge on `PH_CONTROL`, `fg3`
  fill, amber when 20% or less and not on power.
- Settings on `PH_CARD` cards (radius 12, `PH_LINE` border, 12 between cards, text 12 in).
  Rows split by `PH_LINE` hairlines. Overlay, limit and its switch share a card; the scaling
  filter has its own.
- Row titles 13 semibold `fg`; a readout ("60 FPS") 13 regular `fg2` at the right.
- The focused row is the app's chosen sidebar item: white 9%, a `PH_LINE` border, radius 8,
  4 pt in from the card.
- Controls copy macOS 26's: a 6 pt track (`#3A3A3E`) filled in the accent to a 20 × 16 white
  capsule knob with a soft shadow; a 36 × 16 switch, accent when on; a 24 pt segmented control
  (`#333337` well, `#58585C` chosen segment, radius 7). Disabled: grey fill and knob.
- Ordered choices are a stepped slider with a tick under each stop and its name under the tick.
  Unordered choices are a segmented control. A number is a slider with its ends beside it.
- Footer: what happened in 11 `fg2` (`fg` right after a change), then the keys in 11 `fg3`.
- It must fit a 280 pt wide window: text is not wrapped, so a line that might not fit gets a
  shorter wording (the scaling note does).

**Shortcut hint**: the overlay's floating card, radius 8, "⌥⌘P" 13 semibold and the text 12
`fg2`. Shows once per Mac, for 8 s, top right.

**Bridgeplay tab in Steam Properties** (`dylib/feats/webpatch.c`): Steam's own controls, classes
and colours. It lives in Steam's page.

- An option has one name and one order in the Steam tab, the Guide, Game Defaults and quick
  settings. Names are the app's Title Case: Performance Overlay, Frame Rate Limit, Enable Frame
  Limit, Scaling Filter.
- No game art ships. The Setup Assistant's cover wall uses the covers in the player's Steam
  library cache, and with fewer than six it adds a fixed list from Steam's CDN (`GameCovers`).

## Copy

Capitalization and punctuation follow macOS.

| Kind | Rule | Example |
|---|---|---|
| Button, menu item, page, setting | Title Case; verb and object | "Open Input Monitoring" |
| Headline, state, description | Sentence case | "Steam is running" |
| Value, note | A sentence with a full stop | "Not installed." |
| Dialog title · button | A question · the verb and object | "Block Steam client updates?" · "Block Updates" |
| Error | What happened, then what to do | "Steam is running. Close Steam before continuing." |
| Empty | What appears, and when | "A prefix appears here once a Windows game has been launched through Bridgeplay." |
| In progress | Participle and "…" | "Checking…" |

- "…" is one character. It ends a button that asks for more, and a status still running.
- "could not", not "couldn't". No "Oops", no "Please", no exclamation marks.
- Paths use "›": "Steam Properties › Bridgeplay".
- Product names as their makers write them: CrossOver, WineCX, D3DMetal, DXMT.
- Our words: engine, prefix, compatibility tool.
- Sizes use `.byteCount(style: .file)`. Join parts with " · ".
- Every app string is in en, it, ru and zh-Hans: `make l10ncheck`.

## Definition of done

- [ ] One sentence says what the screen is for.
- [ ] macOS draws whatever it can: native switches, sliders, pickers, sidebar, toolbar.
- [ ] Only `BP.*` colours (or their `PH_*` copies in game) and sizes from the tables.
- [ ] Page, card, control: each layer one step lighter. No pure black.
- [ ] Content in the 720 column with 20 pt margins.
- [ ] Spacing and radii from the tables; `.continuous`.
- [ ] Pill buttons; at most one `.pill` per row or step.
- [ ] The accent on controls; the gradient only for emphasis.
- [ ] Readable with Increase Contrast on.
- [ ] Loading, empty and failed states; failed offers a next step.
- [ ] Destructive actions ask first and say what is kept.
- [ ] Copy follows the table, in all four languages.
- [ ] State changes take 0.45 s or less and respect Reduce Motion.
- [ ] SF Symbols; icon-only buttons are labelled.
- [ ] Works at 800 × 600 and with the longest translation.
- [ ] Checked in `BridgeplayApp --setup-preview` or `BridgeplayInstaller --preview`, not a built
      app. In-game changes are checked in a real game.
- [ ] Screenshots are tight crops with no game covers and no personal paths.

## Recorded exceptions

On purpose. Don't fix them.

| Where | What | Why |
|---|---|---|
| The app | Dark only | The brand is a dark look |
| Dialogs, menus, toolbar, sidebar glass, `Table`, About | macOS's own look | See "Leave to macOS" |
| Update window | Sparkle's | `SPUStandardUpdaterController` |
| `ProgressPanel` | System font, app icon, system appearance | Follows the alert before it, while Steam is in front |
| Guide and Setup Assistant drawings of Steam | Steam's colours, radius 2 | They show Steam |
| Bridgeplay tab in Steam | Steam's classes | It lives in Steam's page |
| `perfhud.m`, `sidebar.m` | Hex tokens, hand-drawn controls, no symbols, no animation, no shadow on the overlay | C in the game's process |
| In-game strings | English only | No string tables in the shim yet |
| Pill border | `Capsule(style: .circular)` | The continuous curve leaves a tick on redraw |
| Wordmark | Unbounded | The display face's only use |
| Setup art | `#7DFF8A`, monospaced digits | Imitates the Metal HUD |
| DMG background | Monospaced labels, radius 28 | Sits behind Finder icons |

## Known gaps

Inconsistencies in today's UI. Don't copy them. Fix each in its own PR and remove its row.

| # | Gap | Where |
|---|---|---|
| 1 | System buttons beside pills | `PatchBanner`, `PlayReportCard`, report sheets, Game Defaults "Apply" |
| 2 | A second banner style: `.bar` material, system type and orange | `PatchBanner`, play report bars |
| 3 | Two progress styles: the gradient bar in the app, the system bar in the installer | `GradientProgress`, `InstallerView` |
| 4 | Section headers styled on Game Defaults, system on Status | `GameDefaultsView`, `StatusView` |
| 5 | `StatusRow` uses `.secondary` and `.callout`, not tokens | `StatusView` |
| 6 | Step bar written twice; the installer's differs | `StepBar`, `InstallerView.steps` |
| 7 | Hero frame written twice | `StatusHero`, `DefaultsHero` |
| 8 | Sheet titles 15 and 17 | `WhatsNewSheet`, report sheets |
| 9 | Off-scale: 12.5, 15, 19 pt; a radius 6 that is not continuous | `GuideView`, `InstallerView`, `RowWash` |
| 10 | Mixed case: "Has issues" beside "Smooth"; "Last used" beside "Private Size"; "Enable frame limit" instead of "Enable Frame Limit" | `PlayReportCard`, `PrefixesView`, `webpatch.c`, `GuideView` |
| 11 | Engine rows are not localized ("Download & Set Up", "Rescan") | `StatusView.crossOverSection` |
| 12 | Languages: app 4; Steam tab 3; game English; `Install.command` Indonesian | `webpatch.c`, `sidebar.m`, `installer/` |
| 13 | ⌘1 to ⌘5 are not in the sidebar's order | `App.swift` |
| 14 | Failures titled "Failed" or "Something went wrong"; red in the app, orange in the installer | Status, Setup Assistant, installer |
| 15 | "Thanks!", "Prefix rebuild failed!", five "Please", one "couldn't" | `Localizable.xcstrings`, `webpatch.c` |
| 16 | The installer's first step is a lone spinner | `InstallerView` |
| 17 | Under Reduce Motion, the pill press still scales, and the wizard's art and step bar still use their scale and spring | `PillButtonStyle`, `SetupArt`, `StepBar` |
| 18 | The Setup Assistant art and the skeleton shimmer keep running while the window is inactive | `SetupArt`, `Skeleton.swift` |
| 19 | The Setup Assistant and installer still draw the wordmark in the gradient, beside the tiled mark | `SetupAssistantView`, `InstallerView` |
| 20 | No spacing tokens | All views |

## Where things live

| What | File |
|---|---|
| Tokens, fonts, pills, the mark | `app/Sources/BridgeplayUI/BridgeplayTheme.swift` |
| Window shell, sidebar · menus | `Views/RootView.swift` · `App.swift` |
| Setup Assistant · its art | `Views/SetupAssistantView.swift` · `Views/SetupArt.swift` |
| Installer | `app/Sources/BridgeplayInstaller/InstallerView.swift` |
| Strings | `Resources/Localization/Localizable.xcstrings` in each target |
| Dialog wording | `Model/PrefixPrompt.swift`, `Support/BetaUpdatesUI.swift` |
| In-game overlay · quick settings · Steam tab | `overlay-shim/perfhud.m` · `overlay-shim/sidebar.m` · `dylib/feats/webpatch.c` |
| DMG background · the mark as SVG | `installer/dmg/background.html` · `helpers/icon/bridgeplay-mark.svg` |

A PR that changes a token, a shared component or a rule updates this file in the same PR.

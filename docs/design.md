# Airc design language

Airc should feel like Arc: coloured Spaces, the page as a soft card, a calm sidebar, springy motion. It
borrows conductor.build's restraint and typographic precision, and T3 Code's polish in the details. It is a
native Mac app, not a web page in a frame.

The design ships as code in [`packages/AircDesign`](../packages/AircDesign) (Swift 6, macOS 14+, no
dependencies). Every number below is a token there. Mockups are in [`docs/design/mockups`](design/mockups).
Arc's measured sizes and timings come from [research/arc_behavior_spec.md](research/arc_behavior_spec.md)
("Arc ref" below). Where Arc has a measurement, Airc matches it; everything else here is a design decision.

## Decisions (2026-11-04)

The owner reviewed the mockups. These are final:

1. **Display titles use SF Pro Rounded** (onboarding titles, the member card). Everything else is SF Pro.
2. **Bright dark themes are toned down slightly** so the contrast guarantee holds (Ocean draws its colour at 0.455
   instead of Arc's 0.646). The dark Work Space stays as it looks today.
3. **Very light themes stay light in dark mode**, as in Arc (average OKLab L ≥ 0.80).
4. **Window translucency ships in v1**: the desktop shows through the themed window faintly, as in Arc
   (§4.1). It is a setting: Off · **Subtle** (default) · More.
5. **Warm stone greys** (conductor.build) for chrome outside a Space.
6. **Onboarding is a floating window, not full screen** (spec ON-5): a 760 × 540 card over the desktop with no
   title bar and no traffic lights, which expands into the first browser window (§7, onboarding window).

## Decisions (design pass 3, 2026-11-05)

Taken after the owner called the first profile UX "bad, not Arc-like" (spec SP-10, SP-11, SP-15):

1. **Profiles follow Arc's flow exactly.** Create a Space is a compact card (icon + name, a Profile pill, a Choose a
   Theme row, Create Space, Cancel). "New Profile…" opens Arc's two-step card centred over the page. Management
   (rename, colour, delete) lives only in Settings → Profiles and the Space menu (§7, "Profiles").
2. **Create Space uses the new Space's theme accent**, not a fixed Arc blue. On the default theme that accent is Airc
   blue, so the default case looks like Arc; on a chosen theme the button belongs to the room being made.
3. **Profiles are identities:** the Google photo once signed in, otherwise an emoji on a pastel of the profile colour.
   The indicator and footer dots appear only while two or more profiles have Spaces.
4. **Titles fade, never "…"**, and nothing draws over text: a loading ring takes the favicon slot after 150 ms
   (owner feedback P2; §7, "Loading rows and title fades").
5. **Welcome shows the app icon, not `airc-color.svg`** (§10): the colour mark has older proportions and a placeholder
   palette, so it stays on hold until it is redrawn from the final logo geometry.
6. **The two `SpaceTheme`s stay, for now.** AircKit's is the stored record, AircDesign's the visual model; they map
   1:1 (DesignBridge). AircDesign adds `AircSpaceTheme` (the same type) so the app can name it without
   `AircDesign.SpaceTheme`. Folding AircKit's record into a SwiftUI-free AircDesign target is the next step once the
   app agent agrees; it changes AircKit's persisted type, so it isn't done unilaterally.

## Decisions (design pass 4, 2026-11-05)

Taken after the visual review of the real app ([qa/visual-review.md](qa/visual-review.md)):

1. **The sidebar ink is right; the screenshots were wrong.** The review measured `textSecondary` at about 0.83 instead
   of 0.60. On macOS 26 a label `NSTextField` draws through a private `NSTextFieldSimpleLabel` subview, and
   `cacheDisplay` / `CALayer.render(in:)` composite every label twice (1 − (1 − a)²: 0.60 → 0.84, 0.86 → 0.98,
   0.42 → 0.66, exactly the review's numbers). The screen composites it once. Captures go through `AircSnapshot`
   (§8); `SidebarInkTests` measure the pixels.
2. **The command bar has no footer** and is **centred on the page card**, not the window (the app was right). Keycaps
   appear on the selected row's action only, plus real shortcuts in Actions.
3. **The theme picker dresses in the theme being edited** (a dark Space gets a dark panel) and draws its intensity wave
   in that theme's **accent**, not its raw last colour (Lemon's last colour vanishes on white). Presets come in whole
   pages: light, dark, Arc's nine.
4. **Onboarding Done sits on the welcome bloom**, so the flow opens and closes in one key.
5. **Components replace the app's private copies**: the sign-in card, the empty Space, command bar row parts, the
   drag ghost, the folder glyph, the page card edge, the profile colours and the address label (§7, §8, §13).

---

## 1. Principles

1. **The colour is the room; the page is the object.** The Space theme fills the whole window: sidebar,
   title area and the 10 pt margin. The web page sits on it as a card with 6 pt corners. Nothing else
   competes with those two surfaces.
2. **Separate with space and tone, not lines.** Use hairlines only where a list needs an edge (the
   Today divider, fields, groups). There are no boxes around sections and no toolbars.
3. **Ink, not greys.** Sidebar text, glyphs and fills are near-black or near-white at an alpha, so they
   take on the theme's hue the way Arc's do. Fixed greys are only used on surfaces that sit outside a theme.
4. **Contrast is computed, not hoped for.** Every colour a theme produces is checked against WCAG floors in
   unit tests. If a colour is too strong for its appearance, the theme yields: the colour washes out
   until text passes.
5. **Type does the hierarchy.** Use SF Pro, a seven-step scale, and at most two weights per view. Use
   SF Pro Rounded only for rare display moments and SF Mono only for metadata (shortcuts, versions, counts).
   This is conductor's rule: few sizes, used precisely.
6. **Exact where measured.** Arc's 41 pt row pitch, 47 pt tiles, 228 pt sidebar and its springs are
   requirements, not suggestions. Only invent a value where Arc never measured one.
7. **Instant hot paths, springs everywhere else.** Hover takes one frame. A press acts on press, not on
   release. The command bar opens in one frame. Anything that moves rides a named spring, and gestures hand
   their velocity to it.
8. **Delight on rare paths only.** The onboarding bloom, the member card and the toast pop are allowed to
   perform. Daily paths stay quiet, with no haptics except at thresholds.

---

## 2. Colour

### 2.1 Neutrals: the stone ramp

This is a warm grey, like paper, never blue-grey (the conductor.build influence). It is used for chrome
outside a Space: the default theme, settings and onboarding surfaces, and the mockups' surroundings.
`AircColor.Stone.sNNN`.

| Step | Hex | Typical use |
|---|---|---|
| 0 | `#FFFFFF` | Fields and groups on light surfaces |
| 25 | `#FCFBFA` | |
| 50 | `#F7F6F4` | Settings window background (light) |
| 100 | `#EFEDEA` | Neutral grey accent text (dark) |
| 200 | `#E3E0DC` | Default theme colour (light) |
| 300 | `#CFCAC5` | |
| 400 | `#A9A39E` | |
| 500 | `#7F7873` | |
| 600 | `#5F5955` | |
| 700 | `#47413E` | |
| 800 | `#2F2A28` | Default theme colour (dark) |
| 900 | `#1D1A18` | Neutral accent (light) |
| 950 | `#110F0E` | Labels on light accents |

**Ink.** Light ink is `#14110F` (warm near-black); dark ink is `#FAFBFF` (Arc's slightly cool white).
Always use them with alpha.

**Fixed colours.** These are Airc blue `#3139FB` / `#7078FF` (accent of the default theme), red `#E5484D`,
destructive `#C9363B` (carries white text at ≥ 4.5:1), green `#2F9E62`, amber `#F5A524` and the unread dot
`#E5453A`. Use one status colour per view at most.

### 2.2 The Space theme model

A `SpaceTheme` is what the user picks and what gets stored. It maps 1:1 to Arc's `windowTheme`, so
imported themes look identical.

| Field | Range | Default | Arc |
|---|---|---|---|
| `colors` | 0–3 sRGB colours | `[]` (warm neutral) | `baseColors` / `overlayColors` |
| `intensity` | 0…1 | 0.81 | `intensityFactor` |
| `grain` | 0…1 | 0 | `noiseFactor` |
| `texture` | grain · sand · denim · tweed (strength 0.8 / 0.15 / 0.6 / 0.4) | grain | `overlay` |
| `appearance` | auto · light · dark | auto | picker buttons |

**Rendering** follows Arc's shader (Arc ref §4.2):

1. **Underlay:** white (light) or black (dark), opaque.
2. **Colour layer:** colours 1 → 2 blend **in OKLab** along a true 45° diagonal (top-left → bottom-right,
   whatever the window's shape) and reach colour 2 at 75 %. Colour 3 fades in from transparent at the top
   to opaque at the bottom. The layer is drawn at **0.2 + 0.55 × intensity** (0.6455 at the default).
3. **Grain:** a 128 pt tile of light and dark specks at `grain × texture strength × 0.55`, a quarter of
   that in an inactive window.

`ResolvedTheme.backgroundImage(for:)` computes this per pixel. `SpaceBackgroundView` (AppKit) and
`SpaceBackground` (SwiftUI) draw it with the grain. The Mint preset renders exactly `#90DDC1`, the colour of
a reference Arc Space, and a test checks this.

**Auto appearance:** follow the system, except that very light colours (average OKLab L ≥ 0.80) stay light
and very dark ones (L ≤ 0.42) stay dark. This matches Arc, which turned light themes light even in dark mode.

### 2.3 How the UI derives from a theme

`theme.resolved(systemIsDark:)` returns a `ResolvedTheme` holding every colour the UI needs:

| Token | Light (nominal) | Dark (nominal) | Used for |
|---|---|---|---|
| `text` | ink 0.86 | ink 0.92 | Tab titles, Space name (bold) |
| `textSecondary` | ink 0.60 | ink 0.60 | URL host, header glyphs, Space name, labels |
| `textTertiary` | ink 0.42 | ink 0.40 | "+ New Tab", "Clear", placeholders, host lines |
| `textDisabled` | ink 0.26 | ink 0.26 | Back with no history |
| `hoverFill` | ink 0.05 | ink 0.10 | Row and button hover |
| `pressedFill` | ink 0.065 | ink 0.065 | Press |
| `selectedFill` | **white 0.85 + shadow** | ink 0.20 | Selected row |
| `tileFill` / `tileHoverFill` | ink 0.05 / 0.09 | ink 0.10 / 0.18 | Favorites |
| `fieldFill` | ink 0.05 | ink 0.10 | URL field |
| `separator` | ink 0.15 | ink 0.15 | Today divider |
| `surface` | OKLCH L 0.988 + theme hue | L 0.255 + theme hue | Command bar, toasts, menus, cards |
| `surfaceText` / `…Secondary` / `…Tertiary` | ink 0.90 / 0.58 / 0.38 | 0.94 / 0.62 / 0.40 | Text on surfaces |
| `surfaceBorder` | ink 0.08 | ink 0.10 | Hairlines on surfaces |
| `surfaceSelected` | accent 0.12 | accent 0.26 | Selected command bar row |
| `accent` / `onAccent` | see below | | Primary buttons, switches, focus, links |
| `focusRing` | accent 0.55 | accent 0.75 | 3 pt ring around focused fields |
| `selectedHoverFill` | white 0.92 + shadow | ink 0.36 (Arc) | Selected row under the pointer |
| `dropLine` | ink 0.80 | white 0.90 (Arc) | The 2 pt drop line and its 8 pt ring while dragging rows |
| `inlineCompletionText` | ink ≥ 0.44 | ink ≥ 0.46 | Command Bar inline completion; raised until it reaches 3 : 1 on `surface` |
| `inlineCompletionHighlight` | accent 0.18 | accent 0.30 | Its selection fill |
| `segmentedTrack` / `segmentedSelection` | ink 0.05 / white | ink 0.08 / white 0.20 over `surface` | Segmented controls (dark was 0.12, too close to the track) |
| `pillFill` | ink 0.09 | ink 0.18 | The 22 pt Profile pill on a `fieldFill` row |
| `sidebarCardFill` | = `selectedFill` | = `selectedFill` | Cards on the theme (Sign in to Google) |
| `profileDotRing` | = `background` | = `background` | The cut-out ring around footer profile dots |

**The accent** is the theme's most chromatic colour, re-lit in OKLCH: hue kept, chroma clamped to
0.11–0.21, lightness 0.56 (light) or 0.60 (dark), then darkened until white labels reach 4.5:1. Yellows
(hue 75–118°) carry dark labels instead: they stay light (L 0.84) in dark themes and deepen to gold (L 0.66)
in light themes, so they still show on a white surface. Grey themes get a graphite accent. The default
theme uses Airc blue.

**Contrast floors** are enforced by the derivation and asserted in `AircDesignTests` on all 12 presets ×
every appearance, Arc's nine swatches, and 1,500 random themes, sampled across the whole window at four
aspect ratios:

| Pair | Floor |
|---|---|
| `text` on every background point, and on the selected and hovered rows | **4.5 : 1** |
| `textSecondary` (and glyphs) on the same | **3.0 : 1** |
| `textTertiary` on the background | 2.4 : 1 (decorative; never the only signal) |
| `onAccent` on `accent` | **4.5 : 1** |
| `surfaceText` on `surface` | **7 : 1**; secondary ≥ 4.5 |
| `accent` on `surface` (rings, switches) | 3.0 : 1 |

The derivation keeps these floors in two ways. First, ink alphas rise above nominal until they pass.
Second, if even full-strength ink can't reach 4.5:1 with margin, the colour layer's opacity is lowered:
the theme washes toward the underlay. Dark themes with bright colours wash a little, because white text
must also read on the 20 % selected row; Ocean renders at 0.455 instead of 0.646.

### 2.4 Presets

There are twelve presets (`SpaceTheme.presets`), six light and six dark. Light presets use 2 colours and
light grain; Mint matches Arc.

| Preset | Colours | Appearance | Window (average) | Accent |
|---|---|---|---|---|
| Paper | none | auto | `#EDEBE8` / `#1E1B1A` | `#4663ED` |
| Mint | `#53CA9F` | light | `#90DDC1` | `#008360` |
| Sky | `#86CDF5` → `#6D8CF0` | light | `#A7C5F7` | `#506CCD` |
| Lilac | `#B9A2F2` → `#EFA3C4` | light | `#E7C4E5` | `#7C65AF` |
| Peach | `#F7B184` → `#F08A9A` | light | `#F7BDB9` | `#B15163` |
| Lemon | `#F4DA6E` → `#9BDB8A` | light | `#D6E8AD` | `#A78E0C` |
| Ocean | `#2F6AF0` → `#13B5B0` | dark | `#0B475D` | `#306BF1` |
| Grape | `#7A4CF0` → `#E0559F`, `#3A4FD8` | dark | `#442F71` | `#7D59EB` |
| Forest | `#2A8A5C` → `#7A9A2E` | dark | `#304B23` | `#607E00` |
| Ember | `#F0642A` → `#B0254A` | dark | `#692123` | `#CD4800` |
| Slate | `#656786` | dark | `#414256` | `#6A6BB3` |
| Midnight | `#3B4470` → `#1B1E2E` | dark | `#191D2E` | `#606EB5` |

The theme picker also shows Arc's nine swatches (`SpaceTheme.swatches`): `F0EAE5 E59EBA 9E749B E1676F
EF8C63 F2D46C 73E49B 7EB6D5 656786`.

---

## 3. Typography

All text uses the system font: SF Pro Text below 20 pt and SF Pro Display above, chosen automatically.
`AircFont.<step>`, applied with `.aircFont(_:)` (font, tracking and line height).

| Step | Size / line | Weight | Design | Tracking | Use |
|---|---|---|---|---|---|
| `display` | 34 / 40 | semibold | Rounded | −0.7 | Onboarding hero, finish card |
| `title1` | 26 / 32 | semibold | Rounded | −0.45 | Onboarding step titles |
| `title2` | 20 / 26 | semibold | Pro | −0.3 | Settings page titles, dialogs |
| `title3` | 15 / 20 | semibold | Pro | −0.1 | Section and card titles |
| `commandInput` | 18 / 24 | regular | Pro | −0.2 | Command bar input (Arc ≈ 18) |
| `row` | 14 / 18 | regular | Pro | −0.08 | Sidebar rows (Arc 14) |
| `spaceName` | 14 / 18 | semibold | Pro | −0.08 | Space header |
| `urlField` | 13 / 16 | regular | Pro | −0.04 | URL field (Arc 13) |
| `lead` | 15 / 22 | regular | Pro | −0.1 | Onboarding and empty-state body |
| `body` | 13 / 18 | regular (medium for buttons) | Pro | −0.04 | Default UI text |
| `callout` | 12 / 16 | regular | Pro | 0 | Secondary lines, field labels (medium) |
| `tooltip` | 12 / 16 | semibold | Pro | 0 | Tooltips (Arc) |
| `caption` | 11 / 14 | medium | Pro | +0.06 | Section labels, timestamps, host lines |
| `micro` | 10 / 12 | semibold | Pro | +0.1 | "Clear" (Arc ≈ 10) |
| `mono` | 11 / 14 | medium | SF Mono | 0 | Shortcuts, versions, counts |

Rules:
- Use two weights per view, regular plus semibold, or regular plus medium for controls. Use bold only for
  folder titles in the sidebar (as Arc does).
- Section labels are sentence case (conductor), not uppercase. Uppercase caption labels are allowed only
  in dense galleries.
- Tabular numbers: use `mono` for counts and timestamps that update.

---

## 4. Spacing, radii, shadows and materials

**Spacing** (`AircSpacing`) is a 4 pt grid on an 8 pt rhythm: `xxs 2 · xs 4 · s 8 · m 12 · l 16 · xl 24 ·
xxl 32 · xxxl 48 · huge 64`. The only exception is Arc's 10 pt card inset.

**Arc geometry** (`AircMetrics`) has these headline values; the rest are in the component specs below:

| | Value |
|---|---|
| Window card inset / radius | 10 / 6 (circular) |
| Sidebar width default / min / max | 228 / 164 / 500 |
| Sidebar side inset | 8 |
| Row pitch / plate / plate radius | 41 / 36 / 12 |
| Favorites tile / gap / radius | 47 / 8 / 10 |
| Footer height | 50 |
| Command bar width / input height | 765 / 64 |

**Radii** (`AircRadius`): card 6 · header button 6 · small control 6 · control 8 · large control 10 · tile 10 ·
menu 10 · row and URL field 12 · toast 12 · popover and settings group 14 · command bar and dialog 16 · panel
(theme picker, onboarding card) 20. Use continuous corners everywhere except the page card, which Arc draws
circular.

**Shadows** (`AircShadow`). The radius below is the SwiftUI/CA radius; CSS blur is twice it. Depth comes
from tone first and shadow second.

| Elevation | Layers | Hairline |
|---|---|---|
| `rowSelected` | black 0.20, r 1, y 0.5 | — |
| `control` | black 0.10, r 0.5, y 0.5 | — |
| `card` (light) / `cardDark` | black 0.10 / 0.35, r 1.5, y 1 | black 0.08 / white 0.06 |
| `popover` | black 0.16 r 12 y 8 + black 0.08 r 1.5 y 1 | black 0.08 |
| `toast` | black 0.18 r 8 y 6 + black 0.08 r 1 y 1 | black 0.08 |
| `commandBar` | black 0.26 r 30 y 20 + black 0.10 r 3 y 2 | black 0.10 |
| `panel` | black 0.18 r 24 y 20 + black 0.06 r 2 y 1 | black 0.06 |

Primary buttons add T3 Code's 1 pt top highlight (white 0.20 fading to 0 by mid-height) and a tight shadow in
their own colour.

**Materials:**

| Surface | Material |
|---|---|
| Window, sidebar, margins | `SpaceBackgroundView`: behind-window blur + underlay + theme layer + grain, translucent per the user's setting (§4.1) |
| Page card | The web page itself, clipped to 6 pt, `card` elevation |
| Command bar, menus, popovers, toasts | `surface` (opaque, theme-tinted near-white or deep grey) + elevation |
| Floating sidebar (reveal) | The same theme background, inset 5 pt, radius 12, 0.5 pt light border, no shadow (Arc) |
| Onboarding | `AircFloatingWindow`: the theme (translucent) or the welcome bloom, with a `surface` card (§7) |
| Settings | Window `Stone.s50` / `#171412`, content groups on `surface` |
| Inactive window | Opaque (the blur goes solid, as in Arc); grain ¼; ink alpha × 0.85, never below its floor (Arc "dims slightly") |

### 4.1 Translucency

**What Arc does.** Arc draws its theme over the macOS window blur: a white (light) or black (dark) underlay,
the colour layer at 0.2 + 0.55 × intensity, then the texture (Arc ref §4.2). Its bundle shows the parts: each
theme carries a translucency style (light, dark or auto) that sets the blur's appearance; the window background
stacks a behind-window `NSVisualEffectView`, a wash and the theme; and its configuration knows whether the window
is active, whether translucency can be shown and whether to dim. Inactive windows make the blur opaque. Arc never
exposed a strength setting and no opacity values were measured, so the numbers below are Airc's.

**Layers, back to front** (`SpaceBackgroundView`, `SpaceBackground(_:translucency:)`):

1. `AircMaterialView`: `NSVisualEffectView`, material `.underWindowBackground`, blending `.behindWindow`, state
   always active (Airc decides when to go opaque), appearance `aqua`/`darkAqua` following the theme.
2. The underlay (white or black) at `theme.underlayOpacity(for: translucency)`.
3. The colour layer at `layerOpacity`, unchanged (`ResolvedTheme.colorLayerImage(for:)`).
4. Grain.

The page card, the command bar, menus and toasts stay opaque.

| Setting | Underlay, light / dark (nominal) | Desktop share at default intensity |
|---|---|---|
| Off | 1 / 1 | 0 |
| **Subtle** (default) | 0.70 / 0.55 | ≈ 11 % / 16 % |
| More | 0.40 / 0.25 | ≈ 21 % / 27 % |

"Desktop share" is (1 − layer opacity) × (1 − underlay): how much of the blurred desktop reaches the eye.

**The contrast floor.** The nominal underlay is a starting point. `underlayOpacity(for:)` raises it in 1 % steps
until `text`, `textSecondary` and `textTertiary` meet their floors (§2.3) over the worst desktop: pure black,
white, grey and the six primaries and secondaries, each passed through the material (`AircTranslucency
.worstCaseBackdrops`). That's checked at every point of the window, on the selected and hovered rows too. The ink tokens
themselves don't change with translucency. Tests assert the floors for all 12 presets × both appearances × all
three levels, and for 250 random themes.

- The material's tint (#E8EBEA light, #5A5D5C dark) was read off the material on the build Mac. How much of the
  desktop the material passes can't be captured without Screen Recording permission: the window server leaves the
  backdrop out of window captures. Airc assumes at most 50 % (`materialPassThrough`), which is conservative for
  macOS window materials. Recalibrate it once a permitted capture is available.
- Results at Subtle: Paper 0.70 (11 %), Mint 0.70, Sky 0.78, Lilac and Peach 0.70, Lemon 0.70, Midnight 0.60, and
  the default theme in dark 0.55 (16 %). **Saturated dark presets (Ocean, Grape, Forest, Ember, Slate) floor at
  0.97–0.99, so they are effectively opaque.** Their white text has no margin left on the 20 % selected row once
  any backdrop light gets in. This follows from decision 2; see open question 1.

**Falls back to opaque**, animated over 200 ms ease-out:
- while the window is not main (Arc);
- when Reduce Transparency is on (`NSWorkspace.accessibilityDisplayShouldReduceTransparency`, observed live);
- with the setting Off.

**Window setup.** A translucent `SpaceBackgroundView` makes its window non-opaque with a clear background when it
moves into it (`configuresWindow`). When two backgrounds are stacked for a swipe between Spaces, set
`drawsMaterial = false` on the top one so the blur isn't drawn twice.

---

## 5. Motion

Gestures hand their velocity to springs; keys and clicks use the same springs or Arc's short curves.
`AircSpring` gives you SwiftUI (`.animation`) and Core Animation (`.caAnimation(keyPath:…)`) from one
definition. Mass is 1, stiffness = (2π / response)² and damping = 2ζ√stiffness. "Settle" is the time to
reach 0.1 % of the travel; the motion reads as finished much earlier.

| Spring | Response | ζ | Stiffness | Damping | Settle | Use (Arc measurement) |
|---|---|---|---|---|---|---|
| `row` | 0.13 s | 0.90 | 2336 | 87.0 | 178 ms | Rows opening, closing and reordering; rows gliding after a drop (≈ 115 ms) |
| `settle` | 0.19 s | 1.00 | 1094 | 66.1 | 279 ms | Space pages after a swipe, click or ⌃1–9 (ω ≈ 33) |
| `fold` | 0.251 s | 1.00 | 625 | 50.0 | 369 ms | Favorites making room, folder close (ω 25, ≈ 240 ms) |
| `reveal` | 0.175 s | 0.80 | 1289 | 57.4 | 258 ms | Hidden sidebar sliding in (≈ 4 pt overshoot) |
| `conceal` | 0.175 s | 0.76 | 1289 | 54.6 | 269 ms | Hidden sidebar sliding away |
| `push` | 0.245 s | 0.92 | 658 | 47.2 | 332 ms | Library pushing the sidebar |
| `pop` | 0.32 s | 0.52 | 386 | 20.4 | 692 ms | Toast arriving from 0.7 scale (peaks ≈ 1.04) |
| `grow` | 0.30 s | 0.78 | 439 | 32.7 | 452 ms | Popovers and the theme picker growing from the anchor (≈ 310 ms) |
| `toggle` | 0.22 s | 0.82 | 816 | 46.8 | 319 ms | Switch knobs, segmented controls, step dots |
| `expand` | 0.40 s | 0.88 | 247 | 27.6 | 554 ms | The onboarding window growing into the first browser window (≈ 0.3 % overshoot, reads as done ≈ 350 ms) |

| Curve (`AircCurve`) | Duration | Bézier | Use |
|---|---|---|---|
| `sidebarHide` / `sidebarShow` | 110 / 100 ms | ease-out cubic (.33, 1, .68, 1) | ⌘S |
| `folderOpen` | 200 ms | (0, 0, .58, 1) | Folder opening |
| `press` | 70 ms | linear | Plate to 0.99 (rows) or 0.97 (buttons) |
| `selectionSettle` | 170 ms | (.25, .1, .25, 1) | Selected row easing back from hover |
| `themeCrossfade` | 90 ms | ease-out (0, 0, .2, 1) | Window colour to a neighbouring Space (τ ≈ 30 ms) |
| `previewIn` | 90 ms | ease-out | Folder preview, field focus |
| `tooltipOut` | 270 ms | ease-out | Tooltip leaving (it appears after 1.6 s in 1 frame) |
| `toastOut` | 70 ms | ease-in | Toast leaving |
| `dialog` | 275 ms | ease-in-out | Dialog dropping 32 pt |
| `entrance` | 420 ms | (.22, 1, .36, 1) (conductor) | Onboarding step changes |

Rules:
- **One frame:** hover in and out, command bar open and close, ⌃Tab, theme picker close.
- **On press:** tabs activate and folders open on mouse-down.
- **Nothing reflows under a drag:** rows hold still, a 2 pt drop line (white 0.9, 8 pt ring at its start)
  shows the gap, and rows glide on `row` after the drop.
- **Haptics** fire only at thresholds: the create-Space pull, the drag snap and the theme picker detents.
- **Reduce Motion:** springs become 150 ms cross-fades; the Space pager cuts instead of sliding. In code:
  `View.aircAnimation(_:value:)` and `withAircAnimation(_:_:)` read the setting; `AircSpring.animate(_:keyPath:to:)`
  sets a layer's value and either springs it or fades the superlayer in 150 ms (`AircMotion.crossfadeTransition`);
  `AnyTransition.airc(_:)` and `.aircToast` become plain fades; buttons stop scaling on press. Code that builds
  its own `CASpringAnimation` checks `AircMotion.prefersReducedMotion`.

---

## 6. Icons

Use SF Symbols, monochrome, coloured with ink tokens (`textSecondary` by default, `textDisabled` when
disabled). In the sidebar, favicons are 18 pt and glyphs follow the same 18 pt box.

| Place | Symbols | Point size / weight |
|---|---|---|
| Sidebar header | `sidebar.left`, `chevron.left`, `chevron.right`, `arrow.clockwise` | 15 / medium in 32 pt plates |
| URL field hover buttons | `link`, `slider.horizontal.3` | 13 / medium in 30 pt plates |
| Rows | `xmark` (close), `minus` (selected pinned), `speaker.wave.2.fill` (audio) | 11 semibold / 11 semibold / 13 regular |
| Folders | `folder` / `folder.fill` in accent | 15 / regular |
| Space header | `chevron.down` / `.right` (collapse), `ellipsis` | 10 semibold / 13 medium |
| Footer | `archivebox`, `plus` | 15 / medium in 32 pt plates |
| Command bar | `magnifyingglass` (input 17 medium), row glyphs `clock`, `globe`, `square.on.square`, `arrow.right.circle` | 14 / regular |
| Toasts | `link`, `checkmark`, `trash`, `arrow.uturn.backward` | 13 / semibold, accent |
| Settings sidebar | Category symbols on a 20 pt rounded square, white glyph on a tinted fill (macOS Settings style) | 12 / semibold |
| Onboarding | `sparkles`, `sun.max`, `moon`, `lock`, `checkmark` | 13–15 / medium |

The mockups use hand-drawn SVG stand-ins; the app uses the real symbols.

---

## 7. Components

Sizes are in points. "Ink 0.xx" means the theme's ink at that alpha. States: rest · hover · pressed ·
selected · disabled · focused.

### Sidebar row (tab, pinned item)
- 41 pt pitch, 36 pt plate inset 8 pt from both sidebar edges, 12 pt radius.
- Favicon 18 × 18 at x 17. Title at x 43, `row` 14 pt, single line, ending 17 pt from the edge. A title that doesn't
  fit **fades out over its last 24 pt** (never "…", never a hard clip; `AircFadingLabel`).
- A second line (dev host or renamed pinned tab) is `caption` 11 pt `textTertiary` under the title, both
  centred in the plate.
- Rest has no fill. Hover is `hoverFill`, one frame, plus a 26 × 26 close button 5 pt inside the right edge
  (✕, or − on the selected pinned row). Pressed scales the plate to 0.99 over 70 ms and activates on press.
- Selected: light is white 0.85 + `rowSelected` shadow; dark is ink 0.20, or 0.36 under the pointer.
- Audio adds a speaker glyph after the favicon with the title 8 pt after it. Loading shows the ring **in the favicon
  slot** (see "Loading rows and title fades"); nothing is ever drawn over the title.
- Selected and hovered in dark themes: `selectedHoverFill` (ink 0.36). Hover on a non-selected row: `hoverFill`.
- Unloaded: favicon at 50 %. Away from the pinned URL: " /" after the title.
- Folder children indent 16 pt per level (favicon x 33, title x 59).

### Favorites tile
- 47 pt tall, 8 pt gap, 10 pt radius, `tileFill`. Favicon 20 pt centred.
- Columns follow Arc's rule (`AircMetrics.Favorites.columns`): the most columns, up to 4, that keep tiles
  ≥ 47 pt wide, then the fewest columns that need no more rows (5 → 3+2, 7 → 4+3).
- Hover is `tileHoverFill`. Active is `selectedFill` + `rowSelected` shadow (light).
- The unread dot is 6 pt `unreadDot`, centred 11 pt from the right and 10 pt from the bottom.
- Making room for a dragged tab uses `fold`. Different-profile Space switch: tiles swap in one frame.

### Space header, pinned/Today divider, New Tab
- **Space header:** 36 pt plate, emoji or icon in a 26 pt frame centred at x 26, name at x 41 (x 18 with no
  icon), `spaceName`, `textSecondary`. Hover shows the plate, a 24 pt ••• button 6 pt from the end, the
  collapse chevron in place of the icon, and the hovered **profile indicator** (SB-22, SP-15; "Profiles" below).
  Pressing the header folds Pinned.
- **Divider:** one device pixel of `separator`, 18 pt from both edges. Its centre sits 25 pt above the
  first Today row's centre. **Clear** (`micro`, `textTertiary`, brightening to `text` on hover) appears at the
  right end while the pointer is over the sidebar; the line stops 8 pt before it.
- **+ New Tab** is the first row under the divider: `plus` glyph and label in `textTertiary`. It takes the
  selected plate while the command bar is open.

### Folder row
This is the same geometry as a tab row. The icon is the outline `folder` in `accent` (open: `folder.fill` at 0.9;
`AircFolderGlyph`, `AircFolderGlyph.image(isOpen:theme:)`, `ResolvedTheme.folderTint(isOpen:)`) and
the title is **semibold**. It opens on press with `folderOpen` (200 ms) and closes with `fold`. Hovering a
closed folder for 0.45 s shows the folder preview (below).

### Folder preview (SB-34, `AircMetrics.FolderPreview`)
- Appears after 0.45 s of hover on a closed folder, 4 pt right of the sidebar edge, its first row level with the
  folder row. 240 pt wide, radius 14, `surface`, `popover` elevation; in over 90 ms (`previewIn`), out in one frame.
- Top: a 30 pt search field ("Search ‹folder›"), `surfaceHover`, radius 8, 6 pt padding. Typing filters live.
- Rows on a 45 pt pitch (plate 41, radius 10, inset 6): favicon 18, title `row` in `surfaceText` with the trailing
  fade, the host in `caption` `surfaceTextTertiary` on a second line when the title is short. At most 8 rows, then
  the list scrolls. The hovered row is `surfaceSelected`; clicking opens the tab and closes the preview.
- It stays while the pointer moves from the folder into it (the 22 pt keep-alive band of the floating sidebar).

### Library panel (SB-62, `AircMetrics.Library`)
- 417 pt wide (Arc), on the theme, pushing the sidebar on `AircSpring.push`. No card: it is the sidebar's room.
- Title "Library" (`title2`, `text`) 48 pt from the top, under the traffic lights; a 24 pt close button at the right.
- Section tabs Archive · Downloads · Spaces: 26 pt capsules, `callout` medium; the current one on `selectedFill`
  (with its shadow in light themes), the others `textSecondary` on hover `hoverFill`.
- Search: 34 pt, `fieldFill`, radius 12 (the URL field's look), `magnifyingglass` 12 in `textTertiary`.
- Archive: day headers ("Today", "Yesterday", "Mon 2 Nov") in `caption` `textTertiary`, 22 pt in; rows 44 pt with
  favicon 18, title `row` with the trailing fade, "host · 14:02" in `caption` tertiary, the owning Space's emoji at the
  right; hover shows Restore (plain small). Restore returns the tab to its Space with the toast "Restored to ‹Space›".
- Spaces: 48 pt rows, emoji 20, name `row`, "‹Profile› · 3 pinned · 5 today" in `caption` with the profile avatar 12.
- Empty states: a 22 pt light symbol in `textTertiary` and one `callout` line, 80 pt from the top.

### Space bar and profile switcher
- The footer is 50 pt tall. Library button 32 × 32 at x 8 (`archivebox`); "+" 32 × 32 at the right edge minus 8.
- Space cells are 36 × 34 on a 34 pt pitch, centred between the two buttons. Each shows the emoji at 16 pt
  or a 6 pt `text` dot. The current cell is full strength; others are at opacity 0.45 and half saturation.
- **Squeeze, never scroll:** cells shrink below 34 pt; the current cell keeps ≥ 22 pt and the others become dots.
- **Profile switcher:** there is no separate control; a Space *is* the profile switch. Right-click a cell, or use
  the Space menu, for **Set Profile ›**: the profile menu below. "New Profile…" opens the two-step Create Profile card
  (SP-11). While several profiles are in use, each cell carries a profile dot.

### URL field (sidebar header)
- Top 46, 36 pt tall, inset 8, radius 12, `fieldFill`. Host only, `urlField` 13 pt `textSecondary`, 12 pt
  left padding.
- On sidebar hover, two 30 × 30 buttons appear at the right (`link`, `slider.horizontal.3`); pinned extension
  icons appear before them.
- Clicking opens the command bar over the field. Loading shows a 2 pt accent progress line along its bottom
  inner edge.
- The header row above it is centred at y 23.5: traffic lights at x 20/43/66, toggle plate at x 77, back,
  forward and reload plates at x 122/156/190 (32 pt, radius 6, hover `hoverFill`).

### Command bar
- 765 pt wide, **centred on the page card** (not the window), top 169 pt above the window's middle, radius 16,
  `surface`, `commandBar` elevation. It opens in one frame with no scrim (Arc). Opened from the URL field it grows out
  of the field instead (Arc ref §2.2).
- Input row is 64 pt: `magnifyingglass` 17 pt at x 22, `commandInput` 18 pt, inline autocompletion in
  `inlineCompletionText` on `inlineCompletionHighlight` (`ResolvedTheme.inlineCompletionAttributes`, never the system
  selection colour), accent caret. At the right, a 24 pt **profile chip** (Space emoji and profile name):
  results come from this profile only.
- Results: 6 pt / 8 pt padding. Section labels are `caption` in `surfaceTextTertiary`, sentence case. Rows
  are 40 pt, radius 10: 20 pt icon, title 14 pt, URL 13 pt tertiary. Only the selected row shows its action ("Open",
  "Switch to Tab"), in the accent, `callout` medium, with a ↵ keycap, 14 pt from the end (`AircCommandAction`,
  `AircCommandActionView`). Actions rows show their shortcut as keycaps (`AircShortcutKeys`). The search row reads
  "‹query›  Search Google": query in `surfaceText`, engine in `surfaceTextTertiary`, no dash. The selected row is
  `surfaceSelected`. At most 8 rows.
- **No footer** (Arc has none; the profile chip already says "this profile only").
- Keycaps are 18 pt tall, radius 5, `mono` 11, hairline border, `surfaceHover` fill (`AircKeycap`, `AircKeycapView`).

### Toast
- 36 pt tall, 14 pt side padding, radius 12, `surface`, `toast` elevation. 13 pt accent glyph, `body` medium
  message, optional action after a 1 × 14 hairline, in accent semibold.
- Placed at the top centre of the page card, 14 pt down; while the sidebar is hidden, at the top centre of
  the window.
- In: `pop` from 0.7 scale with opacity over 100 ms. Out: 70 ms ease-in. Stays 2.4 s (4.8 s for the
  full-screen hint). `AircToast`, `.transition(.aircToast)`.

### Loading rows and title fades (owner feedback P2, SB-44)

Rule: **a title never runs under a trailing control, and no row ever draws a spinner over text.** This applies to every
sidebar row (pinned, Today, folders, Favorites tooltips), the folder preview, the Library and the Command Bar.

- **Fade.** A title that doesn't fit ends in a linear fade over its last 24 pt (`AircMetrics.Row.titleFade`). The
  title's box ends 4 pt (`titleFadeGap`) before whatever trailing control is showing: close ✕ on hover (26 pt plate,
  5 pt in), the audio glyph, Clear, a keycap. Short titles draw plainly; the mask is applied only when they overflow.
  AppKit: `AircFadingLabel` (an `NSTextField` that clips and masks). SwiftUI: `AircFadingText`, `AircFadeMask`.
- **Loading ring.** In the favicon slot, centred in the 18 pt box: 14 pt, 1.75 pt stroke, a 0.28 arc in
  `textSecondary` on an ink 0.14 track, one turn per 0.9 s (a CA rotation, free on the main thread; static under
  Reduce Motion). It appears only once a load has run **150 ms**, fading in over 120 ms while the favicon fades out;
  when the load ends the ring fades out and the (new) favicon fades in, 120 ms. Fast loads never flicker.
  AppKit: `AircLoadingIndicator` (`layer`, `setLoading(_:)`, `onVisibilityChange` to hide the favicon). SwiftUI:
  `AircLoadingRing(isLoading:)`.
- The URL field's 2 pt accent progress line stays; it is the only loading signal outside the row.

### Profiles (SP-10…15; mockups `profiles-*.png`)

**Create a Space card** (`AircMetrics.CreateSpace`). A new sidebar page past the last Space; the whole window already
wears the chosen theme. No URL field or Favorites on that page; header buttons and the footer stay, the footer showing
the new Space's cell as current on a `tileFill` plate.
- Centred column, 200 pt wide (Arc), top at about 196 pt: a 96 × 64 illustration (three Space pages fanned in real
  theme colours, code-drawn); "Create a Space" (`title3`, `text`) 14 pt below; "Separate your tabs for life, work,
  projects, and more." (`callout`, `textSecondary`, centred, max 184 pt) 4 pt below.
- 20 pt gap, then the **name field**: 36 pt, radius 10, `fieldFill`; a 28 pt icon button (emoji 16 on `tileFill`,
  radius 7, opens the 273 pt icon picker) 4 pt in; text `body`; placeholder "Space name" in `textTertiary`. Focused on
  open: a 1.5 pt inner accent stroke plus a 3 pt `accent` 0.22 ring.
- 8 pt gaps, two 36 pt rows (radius 10, `fieldFill`, label `body` `textSecondary` 12 pt in, control 7 pt from the end;
  hover ink 0.09): **Profile** with `AircProfilePill` (22 pt, avatar 16, name 12 medium in `text`, chevron, `pillFill`),
  and **Choose a Theme** with `AircThemeChip` (30 × 20 capsule of the theme, white rim) and a chevron right.
- 20 pt gap, **Create Space**: 36 pt, radius 8, the new theme's `accent`, `body` semibold `onAccent`, at 0.4 opacity
  until a name is typed. Return creates and switches in the same frame. **Cancel** (plain, `textSecondary`) 6 pt below;
  Esc does the same and pages back on `settle`.
- After Create the card leaves bottom-up: buttons, then the rows, then the title group, each fading and sinking 8 pt
  over 150 ms, starting at 0 / 80 / 130 ms.
- Nothing else: no profile list, no inline profile fields, no delete buttons.

**Profile menu** (from the pill, the header indicator, a footer cell's right-click and Space menu → Set Profile ›).
A native `NSMenu`, so keyboard and VoiceOver come free: each profile is an item with `AircProfileAvatar.image(_:)`
(22 pt) as its image, the name as title, the signed-in account as `subtitle`, ✓ (state on) for the current one; a
separator; "New Profile…" with a `plus.circle` image. From the Create a Space card, picking a profile only changes the
pill; from a Space's menu it opens Arc's change-profile confirm (SP-13).

**Create Profile card** (`AircMetrics.Profile`), centred over the page card, slightly above centre, while the page
card dims under black 0.26 (sidebar untouched). 520 pt wide, 28 pt padding, radius 16, `surface`, the dialog shadow,
dropping 32 pt in on `AircCurve.dialog`.
- Step 1, "Create a new Profile" (`title2`) with Arc's copy (`body`, `surfaceTextSecondary`), then "What do you want to
  call this Profile?" (`body` medium) above a row: the 64 pt avatar preview (ringed by 4 pt of `surface` and a hairline)
  and the name field (placeholder "Personal", focused; errors "A Profile with that name already exists." / "Invalid
  Profile name." in red under it; max 32 characters). Below: **Icon**, nine suggested emoji in 30 pt cells
  (`AircProfileColor.suggestedEmoji`, the chosen one on `surfaceSelected` with a 1.5 pt accent ring) and "•••" for the
  full picker; **Colour**, the nine `AircProfileColor.choices` as 20 pt discs, the chosen one ringed in its own colour.
  Actions: Cancel (secondary), Next (primary).
- Step 2, "Which Spaces should use this Profile?" with Arc's copy, then the Spaces as `AircSpaceTile`s (84 × 64,
  radius 12, each in its own theme with its emoji and a hint of its sidebar; a round check top-right; name `callout`
  medium below and its current profile under that). A summary line with the new avatar says what moves ("Studio and
  Clients move over. Their pinned tabs and folders stay; open tabs reload."). Actions: Back (plain, leading), Cancel,
  Create Profile.
- From Create a Space it is one step (Arc's `createOnly`): no step dots, and the button reads "Create Profile". The
  profile is ready instantly from the warm spare; the pill then shows it.

**Theme picker** (`AircThemePicker`, `AircMetrics.ThemePicker`, Arc ref §4.1). A popover beside the Create a Space card
(14 pt from the sidebar, arrow at the Choose a Theme row) or, from Space menu → Edit Theme Color…, 14 pt from the
sidebar edge and the window top with no arrow. 357 × 509, radius 20, `surface`, `panel` shadow; grows from its anchor
on `grow` and shrinks in 110 ms.
- The 340 pt field (`AircColorField`): a grid of dots on a 12 pt pitch, each in the colour at its point (hue = angle
  clockwise from the right, lightness 0.12 at the centre to 0.92 at the edge, saturation 1); dots near a handle grow
  slightly. Handles: the main colour 44 pt, others 26 pt, all with a 3 pt white ring and a soft shadow, joined to the
  main one by a 2 pt white line; pressed 48 / 28. Dragging the main handle moves all; the others move alone. Empty, it
  reads "Tap to pick a color for this space".
- Under it: − / + (1–3 colours; + places the complement, then ±150°/210°), three count dots, and Auto · Light · Dark
  as an icon-only `AircSegmented` (sparkles, sun.max, moon).
- Presets: 24 pt discs in whole pages behind ‹ ›: Light (Paper and the five light presets), Dark (six), Arc (the nine
  swatches). A page never cuts a disc; it opens on the page holding the current theme (`AircThemePicker.presetPages`).
- The panel takes its chrome from the theme being edited, so a dark Space gets a dark panel.
- Intensity: the 7-period wave (`AircIntensityWave`), coloured up to the knob in the edited theme's **accent**
  (contrast-safe on the panel); grain: the
  24-dot dial (`AircGrainDial`), clockwise from the top. Every change re-tints the window live.

**Profiles as identities** (SP-15). Shown only while two or more profiles have Spaces.
- `AircProfileAvatar`: the Google photo once signed in (from ListAccounts), otherwise the emoji (or the initial) on
  `AircProfileColor.pastel` (OKLab, 28 % colour), with a 0.5 pt inner hairline. Sizes: 12 (tiles), 16 (pill, header),
  22 (menu), 28 (Settings), 64 (Create Profile).
- **Header indicator** (`AircProfileIndicator`, Arc's ProfileIndicatorView): the Space header becomes a row — icon,
  name, indicator, then ••• on hover. At rest: avatar 16 + name in `caption` `textTertiary`, no fill. Hovered: a 22 pt
  `tileFill` pill with a chevron that opens the profile menu. It **condenses to the avatar** when the Space name needs
  the room (`size(forAvailableWidth:nameWidth:)`); only then does the name fade.
- **Footer dots** (`AircProfileDot`): 6 pt in the profile colour, 6 pt in from each cell's bottom-right, with a 1.5 pt
  cut-out ring in the window colour; they dim with their cell.

**Sign in to Google** (SP-12, `AircSidebarCard`). At the top of a new profile's Today list, under + New Tab: 212 × 112,
radius 12, `sidebarCardFill` with the selected-row shadow. Google G 16 + "Sign in to Google" (`body` semibold), "A fresh
profile. Sign in once and Google stays signed in here." (`callout`, `textSecondary`), Sign in (primary small) and Not
now (plain small), a 20 pt dismiss. Sign in opens accounts.google.com as a Today tab in this Space; the card hides while
that tab is open. After sign-in the photo cross-fades in (120 ms) everywhere the avatar shows, and the card becomes
"Add to Favorites?" (Gmail and Calendar, "Add both" / "Not now") once.

**Sign in to Google, in code** (pass 4): `AircSidebarCard.signInToGoogle(isDark:onSignIn:onNotNow:onDismiss:)` has the
copy (`AircSignInCopy`) and the four-colour Google G (`AircGoogleMark`, drawn from Google's sign-in geometry on a 48 pt
artboard; on its white disc in dark themes). AppKit sidebars host it with `AircSignInCardView` (212 × 112, takes the
first click).

**Profile colours** (pass 4): the Colour row is `AircProfileColorPicker` over `AircProfileColor.choices` (blue, green,
teal, violet, pink, red, orange, gold, graphite; `names`). Arc's pastel swatches are theme colours, never profile
colours; `AircProfileColor.nearestChoice(to:)` maps a stored one once.

### Empty Space (pass 4, `AircEmptySpaceView`)
The page card of a Space with no tab, including the first window after onboarding. On `surface` (never black): the
Space's emoji at 40 pt (a 10 pt ink dot when it has none), the name in `title2` 6 pt below, then, while several profiles
are in use, the avatar 16 + "‹Profile› profile · its own logins, history and extensions" (`body`,
`surfaceTextSecondary`) 8 pt below, and ⌘ T keycaps + "New Tab" (`surfaceTextTertiary`) 20 pt below. The group sits
24 pt above the card's centre. The URL field shows "Search or enter URL…" in `textTertiary` meanwhile.

### Drag ghost (pass 4, `AircDragGhostLayer`)
The dragged row, lifted: an **opaque** plate (`selectedFill` composited on the window colour), favicon at x 17, title at
x 43 in `text` with the 24 pt trailing fade, and the `dragLift` shadow (black 0.18 r 6 y 4 + 0.10 r 1 y 0.5). Tiles:
the tile plate with the 20 pt favicon. Built from data, never from a capture of the row; rows beneath stay still and
only the drop line moves.

### Page card edge (pass 4, `AircPageCardView`, `.aircPageCard(_:)`)
The shadow (`card` / `cardDark`) sits on a container behind the clipped page, the 0.5 pt hairline on an overlay above
it, so clipping the page to 6 pt never clips its edge. Empty, the card is `surface`.

### URL field label (pass 4, `AircAddressFieldLabel`)
The host in `urlField` `textSecondary`, or the placeholder in `textTertiary`, 12 pt in, fading over 24 pt and ending
4 pt before the first hover button (`frame(inField:trailingControlMinX:)`). Never "…".

### Buttons (`AircButtonStyle`)

| Size | Height | Padding | Radius | Text |
|---|---|---|---|---|
| small | 24 | 10 | 6 | 12 medium |
| regular | 30 | 14 | 8 | 13 medium |
| large | 38 | 18 | 10 | 14 semibold |

| Kind | Rest | Hover | Pressed |
|---|---|---|---|
| primary | `accent`, `onAccent` text, top highlight, accent shadow | + white 0.08 | + black 0.10, scale 0.97, no shadow |
| secondary | white (dark: white 0.09 on surface), 0.5 pt ink 0.14 hairline, `control` shadow | ink 0.035 | ink 0.07, 0.97 |
| plain | none | ink 0.045 (dark 0.07) | ink 0.07 (dark 0.10), 0.97 |
| destructive | `#C9363B`, white text, highlight | + white 0.08 | + black 0.10, 0.97 |

Disabled is 40 % opacity (Arc's Create Space). Keyboard focus uses the system focus ring. Put one primary
per view, at the trailing end.

### Text field (`AircTextField`, `AircFieldBackground`)
- 32 pt tall, radius 8, 10 pt side padding. Light fill is white; dark is white 0.05. The border is a 1 pt
  inside stroke of ink 0.13 (0.20 on hover).
- Focused: the border turns `accent`, plus a 3 pt outer ring of accent at 0.18 (dark 0.30); it fades in
  over 90 ms. Error: the same in destructive red, with the message below in red.
- Label above: `callout` medium, `surfaceTextSecondary`, 6 pt gap. Optional 13 pt leading icon (accent
  when focused). Placeholder in `surfaceTextTertiary`. Hint below: `callout`, tertiary.

### Toggle (`AircSwitch`, `AircToggleRow`, `AircGroup`)
- The switch is a 32 × 20 track with a 16 pt white knob (2 pt inset, soft shadow). Off is ink 0.14 (dark
  0.18); on is `accent`. The knob moves on `toggle`.
- A row is ≥ 44 pt tall with 14 pt / 10 pt padding: optional 14 pt icon in a 20 pt column, title `body`,
  subtitle `callout` secondary, and the switch at the trailing edge. The whole row toggles.
- A group is a white (dark: white 0.035 over surface) card with radius 10, a 0.5 pt `surfaceBorder`, and
  0.5 pt hairlines between rows inset 14 pt from the left.

### Onboarding window (`AircFloatingWindow`, spec ON-5)

Onboarding is a floating card over the desktop, the quality bar being Raycast's, Linear's and Arc's own small
windows: no chrome, a soft shadow, and it lands exactly where your eyes are.

- **Window:** 760 × 540 pt, fixed. It is borderless (`.borderless` + `.fullSizeContentView`) with no
  close/minimise/zoom buttons and no title bar. It has 24 pt continuous corners (`AircRadius.floatingWindow`),
  clipping everything including the blur. Shadow is the system window shadow (it follows the rounded alpha), plus
  the 0.5 pt rim macOS draws on its own windows (white 0.14 in dark themes, black 0.10 in light). The window can
  become key and main.
- **Placement:** on the active screen (the key window's, else the one under the pointer, else the main one),
  centred horizontally and slightly above centre: 55 % of the free height below it (the optical centre).
- **Background:** the window's `SpaceBackgroundView`, translucent at the user's setting (default Subtle). The
  Welcome and Done steps use the bloom instead: the icon's pastels (mint, sky, lilac, pink) over white 0.84.
- **Behaviour:** drag anywhere that isn't a control (`AircWindowDragArea` behind the SwiftUI content). **Esc**
  goes back a step (`onEscape`). ⌘W does nothing; ⌘Q quits. It can't go full screen. It closes only by finishing.
- **Entrance:** fades in and rises 8 pt over 420 ms (`AircCurve.entrance`); a plain 150 ms fade under Reduce Motion.
- **Layout mirrors the browser it becomes:** the live sidebar preview sits on the theme at the left, 228 pt (the
  real sidebar at 1:1, without window buttons, rebuilding as choices change). The step card sits where the
  page card will be: left 228, inset 10 pt top, right and bottom, so 522 × 520, with 14 pt corners (concentric:
  24 − 10), `surface` and `card` elevation. Steps without a preview get a card that fills the window inset 10.
- **Card:** 32 pt padding. Top to bottom:
  - step dots (current is a 20 × 6 accent capsule, done ink 0.30, todo ink 0.14, 6 pt gap);
  - 24 pt gap, then the title (`title1`, SF Pro Rounded);
  - the subtitle (`lead`, secondary), 8 pt below;
  - the content, 24 pt below;
  - the actions, pinned to the bottom: plain "Back" leading, secondary "Skip" then primary at the trailing end,
    all large.
- **Background-work pill:** while the import runs, a 26 pt pill sits at the top of the sidebar column, in the
  header row the browser window will use for its buttons. It shows the label and a progress bar.
- **Welcome and Done** use `AircOnboardingHero`: the art (the app icon at 104 pt, or the member card), a
  `display` title in SF Pro Rounded, a lead, and centred actions, straight on the theme in theme ink.
- **Steps** (Arc's flow, trimmed; spec §2.13):
  1. **Welcome:** icon, "Welcome to Airc", "Get started".
  2. **Import from Arc:** found card, checklist, live preview.
  3. **Spaces and accounts:** profiles with Space chips and Google avatars, keychain note.
  4. **Make it yours:** Space chips, 12 presets, appearance, intensity, **translucency (Off · Subtle · More)**.
  5. **Done:** the member card (wearing the app icon), "Open Airc".
- **Expansion:** "Open Airc" calls `expand(into: browserWindow)`. The browser window is created first at its
  final frame and laid out, but not shown. A transparent overlay window draws one themed, rounded shape:
  - the shape springs on `AircSpring.expand` from the card's frame and 24 pt radius to the browser's frame and
    16 pt radius (a titled macOS 26 window), the shadow path following it;
  - the onboarding content (a snapshot) fades out in 120 ms;
  - the browser window's content (a snapshot, pinned top-left like the real sidebar) fades in from 60 to 260 ms;
  - at about 62 % of the settle time the real window appears under the overlay, which fades off in 180 ms;
  - the floating window closes and the browser window becomes key.

  Under Reduce Motion the two windows cross-fade in 150 ms.

### Settings page
- Standard macOS Settings window, 720 × 560 minimum, **no toolbar tabs**: a 200 pt source list on the left
  (window colour `Stone.s50` / `#171412`). Category rows are 28 pt, with 20 pt tinted rounded-square
  symbols, 13 pt titles, and the selected row in `accent` at 0.14.
- The content pane is on `surface`: 28 pt padding, max content width 560, page title `title2`, then sections.
  Each section has a `title3` heading 24 pt above an `AircGroup`, with optional `callout` help under the group.
- Categories: General · Profiles · Spaces · Shortcuts · Appearance · Import · Privacy · About. Profiles uses
  one group per profile (avatar, name, "2 Spaces", archive interval, search engine) and a destructive
  "Delete Profile…" at the bottom of its detail page.
- Changes apply instantly; there are no Save buttons.

---

## 8. Using AircDesign

```swift
import AircDesign

// A Space's look → everything the UI needs
let theme = SpaceTheme(colors: [AircColor(0x53CA9F)], appearance: .light)
let r = theme.resolved(systemIsDark: NSApp.effectiveAppearance.isDark)

// AppKit window background (gradient + grain + blur; inactive and Reduce Transparency go opaque automatically)
let background = SpaceBackgroundView(theme: r, translucency: settings.translucency)   // .subtle by default
background.setTheme(nextSpace.theme.resolved(systemIsDark: isDark), animated: true)

// Sidebar ink and fills
titleLabel.textColor = r.text.nsColor
rowLayer.backgroundColor = r.selectedFill.cgColor
rowLayer.applyAircShadow(r.selectedHasShadow ? .rowSelected : .none)

// Motion
rowLayer.add(AircSpring.row.caAnimation(keyPath: "position.y", from: y0, to: y1), forKey: "move")
withAnimation(AircSpring.settle.animation) { page = next }

// Inactive windows dim their ink
sidebar.palette = r.forWindow(isActive: window.isMainWindow)

// Onboarding (ON-5)
let onboarding = AircFloatingWindow(theme: r, translucency: settings.translucency)
onboarding.onEscape = { flow.back() }
onboarding.setContent(OnboardingFlow().aircTheme(r))
onboarding.present()
onboarding.expand(into: browserWindow) { flow.finish() }

// SwiftUI screens
OnboardingStep().aircTheme(r, followsWindowActiveState: true)
Button("Continue") { … }.buttonStyle(.airc(.primary, size: .large))
AircTextField("Space name", text: $name, placeholder: "Work")
AircToggleRow("Archive tabs after 12 hours", isOn: $archive)
AircToast("Copied Current URL", systemImage: "link")

// Backgrounds off the main thread (design pass 3)
AircBackgroundCache.shared.prerender(spaces.map(\.resolved), size: window.frame.size)   // on open / resize
background.setTheme(next, colorLayer: nil, animated: true)          // finds it in the cache: no render on switch
background.setBlend(neighbour, fraction: swipeProgress)             // one view during a swipe; setBlend(nil, fraction: 0) after

// Floating window
onboarding.present(focus: false)                                    // snapshot runs, background launches
onboarding.expandForCapture(into: browser, freezeAt: 0.55, onFrozen: { overlay in capture(overlay) })
onboarding.resumeExpansion()

// Profiles
let me = AircProfileIdentity(name: "Freelance", emoji: "🪴", color: AircProfileColor.choices[2], photo: photo)
AircProfilePill(me)                                                 // Create a Space → Profile row
AircProfileIndicator(me, size: .full, isHovered: hovering)          // Space header, ≥ 2 profiles in use
menuItem.image = AircProfileAvatar.image(me)                        // native profile menu
AircSpaceTile(theme: r, emoji: "🎨", name: "Studio", currentProfile: studio, isOn: $selected)
AircThemePicker(theme: $space.theme, systemIsDark: isDark)

// Rows
let title = AircFadingLabel(style: AircFont.row)                    // fades instead of "…"
let ring = AircLoadingIndicator(theme: r)                           // favicon slot, after 150 ms
ring.onVisibilityChange = { faviconLayer.isHidden = $0 }
ring.setLoading(tab.isLoading)
```

| Type | What |
|---|---|
| `AircColor` | sRGB colour: hex init, compositing, OKLab mix, WCAG contrast, `.color` / `.nsColor` / `.cgColor`; `Stone` ramp and fixed colours |
| `SpaceTheme` | Stored theme (colours, intensity, grain, texture, appearance), 12 presets, 9 swatches |
| `ResolvedTheme` | Every derived colour; `backgroundImage(for:)`; `grainOpacity(isWindowActive:)` |
| `AircFont` / `AircTextStyle` | Type scale; `.font`, `.nsFont`, `View.aircFont(_:)` |
| `AircSpacing`, `AircMetrics`, `AircRadius` | Spacing scale, Arc geometry (incl. the Favorites column rule), radii |
| `AircShadow` | Elevations; `View.aircShadow(_:)`, `CALayer.applyAircShadow(_:)` |
| `AircSpring`, `AircCurve` | Named motion; SwiftUI `Animation` and `CASpringAnimation` / `CAMediaTimingFunction` |
| `SpaceBackgroundView`, `AircGrainLayer`, `AircGrain` | AppKit background and grain; `translucency`, `drawsMaterial`, `configuresWindow`, `cornerRadius`, `isWindowActiveOverride`, `reduceTransparencyOverride`, `currentUnderlayOpacity` |
| `SpaceBackground`, `AircGrainOverlay`, `AircMaterialBackground` | The same in SwiftUI; `SpaceBackground(_:isWindowActive:translucency:)` |
| `AircTranslucency`, `AircMaterialView` | The setting (off · subtle · more), the material model; `ResolvedTheme.underlayOpacity(for:isWindowActive:reduceTransparency:)`, `desktopFraction(underlayOpacity:)`, `colorLayerImage(for:)` |
| `ResolvedTheme.forWindow(isActive:)`, `.aircTheme(_:followsWindowActiveState:)` | Inactive-window ink |
| `AircMotion`, `AircSpring.animation(reduceMotion:)`, `AircSpring.animate(_:keyPath:to:)`, `View.aircAnimation(_:value:)`, `withAircAnimation`, `AnyTransition.airc(_:)` | Reduce Motion |
| `AircFloatingWindow`, `AircWindowDragArea`, `View.aircWindowDraggable()`, `AircOnboardingHero`, `AircMetrics.Onboarding`, `AircSpring.expand` | The onboarding window (ON-5) |
| `AircButtonStyle`, `AircTextField`, `AircFieldBackground`, `AircSwitch`, `AircToggleRow`, `AircGroup`, `AircOnboardingPage`, `AircOnboardingCard`, `AircStepIndicator`, `AircToast` | Components |
| `AircSegmented`, `AircSlider`, `AircKnob`, `AircCheckbox`, `AircSpaceChip`, `AircThemeDisc`, `AircThemeChip`, `AircKeycap`, `AircSettingsSection`, `AircSettingsRow`, `AircWelcomeBloom`, `AircMemberCard` | Controls moved from the app (same initialisers; the app's copies shadow these until it deletes them) |
| `AircProfileIdentity`, `AircProfileAvatar`, `AircProfilePill`, `AircProfileIndicator`, `AircProfileDot`, `AircSpaceTile`, `AircSidebarCard`, `AircProfileColor` | Profiles (SP-10…15) |
| `AircThemePicker`, `AircColorField`, `AircColorFieldGeometry`, `AircIntensityWave`, `AircGrainDial`, `AircColor(hue:saturation:lightness:)`, `.hsl` | Theme picker |
| `AircFadingLabel`, `AircFadingText`, `AircFadeMask`, `AircLoadingIndicator`, `AircLoadingRing` | Loading rows and title fades |
| `AircBackgroundCache`, `SpaceBackgroundView.setTheme(_:colorLayer:animated:)`, `.setBlend(_:fraction:)` | Off-main background rendering, swipe blends |
| `AircFloatingWindow.present(on:focus:reduceMotion:)`, `.expandForCapture(into:freezeAt:onFrozen:)`, `.resumeExpansion()`, `.expansionWindow` | Floating window; the expansion finishes on wall-clock timers, so its completion fires even with the display asleep |
| `AircMetrics.CreateSpace`, `.Profile`, `.ThemePicker`, `.FolderPreview`, `.Loading`, `.Library.*`, `.Sidebar.headerButtonEndInset`/`toggleXFullscreen`/`favoritesTop`/`revealEdge`/`revealDelay`, `.Divider.block`, `.Row.titleFade` | Pass-3 geometry (the app's `DesignGaps`) |
| `AircSpaceTheme` | `SpaceTheme` under a name that doesn't clash with AircKit's |
| `AircTextStyle.nsFont` | No longer main-actor-bound |
| `AircSnapshot.bitmap(of:in:)`, `.image(of:in:)`, `.withoutDuplicates(in:_:)` | Offscreen captures that match the screen (labels composited once; pass 4) |
| `AircGoogleMark`, `AircGoogleMarkGeometry`, `AircSidebarCard.signInToGoogle`, `AircSignInCopy`, `AircSignInCardView`, `AircFirstClickHostingView` | Sign in to Google |
| `AircEmptySpaceView`, `AircMetrics.EmptySpace` | Empty Space page |
| `AircCommandAction`, `AircShortcutKeys`, `AircKeycapView`, `AircCommandActionView`, `AircCommandText`, `ResolvedTheme.commandInputAttributes` / `inlineCompletionAttributes` / `textSelectionAttributes` / `inlineCompletionString(typed:completion:)` / `commandRowTitleAttributes` / `commandRowSubtitleAttributes`, `AircMetrics.CommandBar.keycap*` | Command bar row parts |
| `AircDragGhostLayer`, `AircShadow.dragLift` | The dragged row or tile |
| `AircFolderGlyph`, `ResolvedTheme.folderTint(isOpen:)` | Folder icon |
| `AircPageCardView`, `View.aircPageCard(_:)`, `ResolvedTheme.pageCardShadow` | Page card edge |
| `AircProfileColorPicker`, `AircProfileColor.names`, `.nearestChoice(to:)` | Profile colours |
| `AircAddressFieldLabel`, `AircAddressFieldText` | URL field text that fades |
| `AircThemePicker.presetPages`, `.presetRowWidth(discs:)`, `.presetRowRoom` | Whole preset pages |

Build, test and render the gallery on the build Mac:

```bash
scripts/mac.sh -w design run 'cd packages/AircDesign && swift test'
scripts/mac.sh -w design run 'cd packages/AircDesign && swift run aircdesign-gallery build/gallery'
scripts/mac.sh -w design get packages/AircDesign/build/gallery/ ./artifacts/design/gallery/
```

The gallery renders offscreen:
- the components, light and dark;
- four themed windows drawn only with tokens;
- the preset grid;
- two onboarding windows at 760 × 540;
- the AppKit background, active and inactive. It also writes
`resolved-themes.json`, which feeds the mockups. With `--html in.html out.png W H` it snapshots a mockup
through WebKit with the real SF fonts (`--transparent` keeps the page background clear, for icons).

On-screen checks (translucency over a busy wallpaper, the floating window, the expansion) need a real window:

```bash
scripts/mac.sh -w design run 'cd packages/AircDesign && scripts/onscreen.sh'   # needs an unlocked screen
scripts/mac.sh -w design run 'packages/AircDesign/scripts/render-mockups.sh'    # mockup PNGs into build/mockups
```

`onscreen.sh` wraps the gallery in a background app (`open -g`, never takes focus) and captures only its own windows
with `CGWindowListCreateImage`. Without Screen Recording permission the window server leaves the blur's backdrop
out of captures, so those images show the layers and the contrast, not the blur itself. It refuses to run while
the screen is locked, because captures come back empty.

## 9. Mockups

Self-contained HTML at 1440 × 900, generated from the resolved tokens by
[`design/mockups/build.py`](design/mockups/build.py) (`python3 docs/design/mockups/build.py`):

- [`window.html`](design/mockups/window.html): Personal Space in Mint, Favorites with an unread dot,
  pinned tabs with an open folder and a dev host line, the Today list with a selected, an audio and a
  hovered row, the page card and three Spaces in the footer.
- [`command-bar.html`](design/mockups/command-bar.html): ⌘T typing "gma", with profile-scoped results.
- [`space-switch.html`](design/mockups/space-switch.html): the same window in Personal (Mint, light) and Work
  (Ocean, dark, another profile, header hovered).
- [`onboarding.html`](design/mockups/onboarding.html): the five steps, each a 760 × 540 floating window over a
  sample desktop (a code-drawn wallpaper and menu bar), plus one frame of the expansion into the browser window.
- `window.html` also shows the window translucent over the desktop: Subtle in Mint, More in the default theme
  (dark).
- [`profiles.html`](design/mockups/profiles.html) (design pass 3): Create a Space (filled in, and its states), the
  Profile menu, Create Profile steps 1 and 2, the theme picker, the profile indicator and footer dots (2×), and Sign in
  to Google (full window, then before / during / after). `render-mockups.sh` crops them to `profiles-*.png`. The
  gallery's `profiles.png` draws the same pieces with the real SwiftUI components.
- Design pass 4 (from the visual review): `command-bar.html` drops the footer and centres the bar on the page card;
  `onboarding.html`'s Done step sits on the bloom; `profiles.html` adds Create a Space, Create Profile 1 and 2 and the
  theme picker in the dark Work Space (`profiles-*-dark.png`), and step 2 shows seven Spaces wrapping;
  `window.html` adds the Favorites column rule with one, two, three and five tiles (`window-favorites.png`).
- Sample data is neutral: `papertrail/web`, `alex@example.com`, `alex@acme.example`; account photos are code-drawn
  silhouettes. Never put real names, accounts or the owner's Spaces in mockups.

The HTML uses CSS approximations where it must:
- SVG stand-ins for SF Symbols;
- 135° CSS gradients built from the exact OKLab stops;
- `backdrop-filter` blur plus the material tint at 0.5 for the macOS material, with the exported contrast-floored
  underlay over it.

The logo is the real `assets/brand/airc-holographic.svg`.

## 10. Brand

The logo is the owner's (variant E), drawn in code in [`assets/brand`](../assets/brand) (`build.py`). Don't
redraw it. Change the geometry in `build.py`, never by hand or with an image model.

| File | Use |
|---|---|
| `airc-holographic.svg` | **The app icon** (squircle, holographic ring and face). Also the brand moment in the UI: the welcome step (104 pt), the member card (38 pt), About |
| `AppIcon.icns`, `AppIcon.appiconset/` | Generated app icon, 16–512 pt @1x/@2x, on the macOS grid (824 px body on a 1024 canvas, soft shadow). 16 and 32 px come from `airc-icon-small.svg` |
| `airc-icon-small.svg` | Small-size variant for 16 and 32 px only: no ring, 40 px outline, 22 px border (`appicon.py`) |
| `airc-outline-squircle.svg` | Plain outline icon on white (print, monochrome documents) |
| `airc-mark-outline.svg` | The bare mark, outline only, transparent inside: menu bar extras, favicons, monochrome |
| `airc-color.svg` | The flat colour mark. **On hold**: older proportions and a placeholder palette. Don't use it until it's redone. Welcome and About use the app icon instead (decision 5, pass 3) |

Rules:
- The holographic icon always appears whole (ring, face and mark). Don't crop it, recolour it or set it on a
  plate. Below 64 px use the small-size variant (the app bundle does this through the icns).
- Give it clear space of at least 25 % of its size. On themes it sits on the bare theme, never on a card.
- The outline mark is monochrome: black (or white on dark) at full opacity, at least 16 pt tall.
- In text the name is **Airc**: capital A, one word, never "AIRC" or "AirC".
- Regenerate: `python3 assets/brand/build.py` (SVGs), then `assets/brand/appicon.sh` on the Mac (icns and
  appiconset).

## 11. Needs an on-screen check

Design pass 3 ran while the build Mac's screen was locked, so everything was rendered offscreen (`NSHostingView` +
`cacheDisplay`, WebKit for the HTML). Still to check on an unlocked screen:
- the profile `NSMenu` (native material, avatar images, subtitles) and the theme picker popover's arrow and grow;
- the Create Profile card's scrim and drop-in over a live page, and the Create a Space card's bottom-up exit;
- `AircLoadingIndicator` spinning and its 150 ms / 120 ms timing in a real row, at 120 Hz;
- `SpaceBackgroundView.setBlend` during a real two-finger swipe (translucent blur under it);
- `expandForCapture` and the display-asleep expansion completion on a real window.

Design pass 4 also ran with the screen locked. Still to check:
- sidebar ink on screen with Digital Color Meter (expect `#466256` for `textSecondary` on Mint `#96DCC2`; the
  offscreen backing-store test already reads 0.60);
- `AircSignInCardView` and `AircCommandActionView` in a live key window; the field editor's completion colours.

## 12. Open questions for the owner

Answered on 2026-11-04 (see Decisions). New ones:

1. **Saturated dark themes and translucency:** with the contrast guarantee, Ocean, Grape, Forest, Ember and Slate
   draw their underlay at 0.97–0.99 even at More, so they are effectively opaque. The light themes, Midnight and
   the default theme are translucent. **Keep the guarantee** (current), or let those themes go see-through and
   accept white text on the selected row dipping to about 3.5 : 1 over a bright desktop?
2. **Material pass-through:** the floor assumes the blur passes at most 50 % of the desktop. A capture with Screen
   Recording permission would calibrate it. Grant it once on the build Mac for a design run, or keep the
   conservative 50 %?

## 13. App adoption checklist (design pass 4)

What `apps/browser` swaps in for the visual review (review item in brackets). All API is additive.

1. **Captures (#5):** `SnapshotRunner.render(_:)`, `captureWindow` and `SpacePage.makeGhost` call
   `AircSnapshot.bitmap(of:)` (or wrap their own `cacheDisplay` in `AircSnapshot.withoutDuplicates(in:)`). No change to
   any ink colour: the tokens are right.
2. **Sign in to Google (#3):** replace `SignInCardView` with `AircSignInCardView(theme:)`; set `onSignIn`, `onNotNow`,
   `onDismiss`.
3. **Theme picker (#4):** host `AircThemePicker(theme:systemIsDark:)` in the popover at `AircMetrics.ThemePicker.size`;
   delete `Spaces/ThemePicker.swift`.
4. **Empty Space (#2):** put `AircEmptySpaceView(emoji:name:profile:)` in the page card when there's no tab (pass
   `profile` only while several profiles are in use); the URL field shows `AircAddressFieldLabel` with `host = nil`.
5. **Command bar (#8, #9):** `editor.selectedTextAttributes = inline == nil ? r.textSelectionAttributes :
   r.inlineCompletionAttributes`; the row's badge becomes `AircCommandActionView` (`isSelected` = the row's);
   shortcuts in Actions use `AircKeycapView`s; the search subtitle is `AircCommandText.searchSubtitle(engine:)`.
6. **Drag ghost (#7):** `AircDragGhostLayer(kind:width:theme:)` + `configure(title:favicon:)` instead of `makeGhost`;
   opacity 1.
7. **Folder icon (#6):** `icon.image = AircFolderGlyph.image(isOpen: !item.isCollapsed, theme: palette.resolved)`.
8. **Page card (#15):** wrap the engine view in `AircPageCardView` (or copy its container / clip / hairline split).
9. **Profile colours (#14):** `AircProfileColorPicker` in Create Profile and Settings → Profiles; migrate stored
   colours once with `AircProfileColor.nearestChoice(to:)`.
10. **URL field (#17):** `AircAddressFieldLabel`, framed with `frame(inField:trailingControlMinX:)`.
11. **Command bar placement:** keep it centred on the page card; no footer.

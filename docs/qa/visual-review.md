# Visual review: the real app against the design (2026-11-05)

This review compares what Airc actually renders with what the design intends, ranked by how quickly the owner
would notice each difference.

**Sources.** All screenshot paths are relative to the shared `artifacts/` folder on the Linux box, which is not in
the repo.
- **Real app on Chromium:** `app3/chromium/*` (1280 × 800 pt at 2×).
- **Real app on WebKit:** `app3/profiles/*` and the nightly `status/runs/2026-11-05_0449/snapshots/*` (rev
  2b097c5). The nightly also has a `chromium/` subfolder.
- **Loading rows:** `app3/p2/*`.
- **Design intent:** the mockups in `design/mockups/*`, the gallery in `design/gallery/*`, [design.md](../design.md)
  and Arc ref ([arc_behavior_spec.md](../research/arc_behavior_spec.md)).
- **Arc:** the owner's Arc sidebar screenshots, used only for layout, tone and colour, never their content.

**Method.** Each screen was cropped at 1:1 or larger. Sizes are in points, read off the @2× images. Colours are the
darkest fully covered pixel of a glyph, sampled on the same Mint background (`#90DDC1` / `#96DCC2`) in Airc, the
mockup and Arc.

**Capture caveat.** Every window in these runs was captured while it was **not key**. The traffic lights are grey and
there are no carets, focus rings or system selection colours, so focused and selected states can't be judged here.
Three captures failed outright (see [Capture gaps](#capture-gaps)).

---

## 1. Top 20 visual issues

### 1. Chromium build: traffic lights sit at the macOS default spot, not Arc's
- **Where:** `app3/chromium/01-space-personal.png`, top-left 120 × 40 pt. The same happens in every Chromium shot and
  in the nightly `chromium/01-space-personal.png`.
- **What's wrong:** the lights are centred at x 14 / 34 / 54, y 14 (a 20 pt pitch). The header buttons are centred at
  y 23, so the lights float 9 pt above the button row and crowd the window corner. The WebKit build gets it right
  (x 20 / 42 / 65, y 23).
- **Intended:** Arc ref §1 (traffic lights): centres (20, 24), (43, 24), (66, 24), level with the header row at
  y 23.5. This is `AircMetrics.Window.trafficLightCenters`.
- **Fix:** `WindowController.positionTrafficLights()` (`apps/browser/Sources/Airc/Browser/WindowController.swift:175`)
  only runs on resize, becoming key and full-screen changes. With the Chromium engine, AppKit re-lays out the titlebar
  container after the engine attaches its views, and a window opened with `open -g` never becomes key. Re-apply the
  position:
  - after the engine view is installed;
  - on `NSView.frameDidChangeNotification` of the buttons' container, or from an `NSWindow` subclass's
    `layoutIfNeeded`.
  Then add a check to `EventTests` that reads the buttons' frames.

### 2. An empty Space, and the first window after onboarding, is a blank card with one tiny line
- **Where:** `app3/chromium/ob-07-browser.png` (the very first browser window after "Open Airc") and
  `app3/chromium/08-new-space-created.png`.
- **What's wrong:**
  - The page card is empty apart from "Press ⌘T to open a page" in about 11 pt grey.
  - On dark themes the card is a near-black slab (`08`, `08b`), which reads as a broken page.
  - The URL field above it is an empty pill with no placeholder.
  - This is the first thing the owner sees after the onboarding finale.
- **Intended:** `design/mockups/profiles-sign-in.png`:
  - the Space's emoji at about 40 pt and the Space name in `title2`;
  - a line with the profile avatar ("‹Profile› profile · its own logins, history and extensions");
  - ⌘ T keycaps + "New Tab", all centred on a `surface`-tinted card;
  - the URL field reading "Search or enter URL…" in `textTertiary`.
- **Fix:** build the empty-state view from the mockup on `palette.cardEmpty` (= `surface`, not black). Give the sidebar
  URL field its placeholder when there's no tab. After onboarding, consider selecting the first imported tab so the
  window opens on a page.

### 3. "Sign in to Google" card is a stock AppKit card, not the designed one
- **Where:** `app3/chromium/08b-create-profile-step1.png`, sidebar y 150–230 pt. The same card appears in `08` and
  `08c`.
- **What's wrong:**
  - A bezel-style white NSButton "Sign in", which looks like a system dialog.
  - No Google "G".
  - No "Not now".
  - Old copy ("This Space has its own profile, so its logins stay separate.").
  - A `tileFill` plate with no shadow.
- **Intended:** design.md §7 "Sign in to Google" and `design/mockups/profiles-sign-in.png`: G 16 + title, "A fresh
  profile. Sign in once and Google stays signed in here.", primary-small **Sign in** in the accent + plain **Not now**,
  212 × 112, radius 12, `sidebarCardFill` with the selected-row shadow.
- **Fix:** replace `SignInCardView` (`apps/browser/Sources/Airc/Sidebar/SidebarRows.swift:686`) with a hosted
  `AircSidebarCard` (`packages/AircDesign/Sources/AircDesign/Components/AircProfile.swift:250`), which the gallery
  already renders correctly.

### 4. The theme picker is an older private copy, not `AircThemePicker`
- **Where:** `app3/chromium/07a-theme-picker.png` (whole image), against `design/mockups/profiles-theme-picker.png`.
- **What's wrong:**
  - **Wrong size:** 248 × 352 instead of 357 × 509.
  - **Coarse colour field:** about 17 dots across instead of about 28.
  - **Clipped presets:** the presets sit in a horizontal scroll view that cuts the last disc in half, with no ‹ ›
    paging.
  - **Wrong wave colour:** the intensity wave is drawn in Airc blue (`DesignTheme.default`'s accent) on an orange
    Ember theme.
- **Intended:** design.md §7 "Theme picker": 357 × 509, radius 20, a 340 pt field on a 12 pt pitch, 24 pt preset discs
  with ‹ › paging, and the wave in the theme's last colour.
- **Fix:** `showThemePopover` (`apps/browser/Sources/Airc/Spaces/CreateProfilePanel.swift:391`) hosts
  `apps/browser/Sources/Airc/Spaces/ThemePicker.swift`. Switch it to `AircThemePicker`
  (`packages/AircDesign/Sources/AircDesign/Components/AircThemePicker.swift`), size the popover to
  `AircMetrics.ThemePicker.size`, then delete the app copy.

### 5. Secondary and tertiary ink render about 0.2 alpha darker than their tokens, which flattens the sidebar's hierarchy
- **Where:** `app3/chromium/01-space-personal.png`: the Space header "Home" (x 40–85, y 155–170 pt), the URL host, "+
  New Tab" and the header's profile name. WebKit is identical.
- **What's wrong (measured on the same Mint):**

  | Element | Airc | Mockup | Arc |
  |---|---|---|---|
  | Space name / URL host (`textSecondary`, token 0.60) | `#2A312C` (effective ink ≈ 0.83) | `#466256` | `#4E7969` |
  | "+ New Tab" / profile name (`textTertiary`, token 0.42) | `#40564A` (≈ 0.66) | `#5C8776` | `#649A86` |
  | Tab title (`text`, token 0.86) | `#161513` (≈ 0.98) | `#252E28` | dark green ink |

  The header now looks as heavy as the tab titles, and "New Tab" looks like a real row. Arc's muted, airy header is
  lost. This is the biggest "doesn't feel like Arc" item on the main screen.
- **Intended:** design.md §2.3: `text` 0.86, `textSecondary` 0.60, `textTertiary` 0.42. The resolved tokens in
  `design/gallery/resolved-themes.json` are correct (Mint 0.86 / 0.60 / 0.42), so this is a rendering problem, not a
  token problem.
- **Fix:**
  1. First confirm it on screen with Digital Color Meter.
  2. Then check how AppKit labels draw an alpha ink over the translucent `SpaceBackgroundView`. Likely causes are
     vibrancy from the `NSVisualEffectView` ancestor (`AircMaterialView`, which never sets `allowsVibrancy`) or a
     colour-space conversion of the alpha colour.
  3. A quick experiment: give the sidebar container `allowsVibrancy = false` and draw the labels with
     `NSColor(srgbRed:…)`.
  4. Add a snapshot test that samples the Space-name pixel.

### 6. Folder icon is a black filled folder; it should be the outline folder in the accent
- **Where:** `app3/chromium/01-space-personal.png`, the "Trips" row (x 17–35, y 183–200 pt). Also `ob-07`.
- **What's wrong:** `folder.fill` in `text` × 0.75 reads as a heavy black block. Arc's folder is an outline tinted by
  the theme, like the owner's screenshot.
- **Intended:** design.md §7 "Folder row": `folder` in `accent`, and `folder.fill` at 0.9 when open. The onboarding
  preview already does this (`SidebarPreview.swift:156`).
- **Fix:** in `SidebarRows.swift:531`:
  - keep the symbol choice (`folder` when closed, `folder.fill` when open);
  - change the tint from `textPrimary` × 0.75 to `palette.resolved.accent.nsColor`, at 0.9 for the open folder.

### 7. The drag ghost draws text over text
- **Where:** `app3/chromium/10-drag-mid.png`, sidebar y 355–395 pt.
- **What's wrong:**
  - A translucent white plate carrying "Hacker News" lies over the "swiftlang/swift" row, and both titles show through
    each other.
  - The ghost has no favicon, and its label starts left of the plate and is clipped by the window edge.
  - This is the same class of bug the owner flagged with the spinner over text.
- **Intended:** design.md §7 "Loading rows and title fades" (nothing draws over text) and §5 "Nothing reflows under a
  drag". The dragged row should look like the row itself, lifted: an opaque `selectedFill` plate (white 0.85 + the
  `rowSelected` shadow in light themes), favicon at x 17, title at x 43 with the trailing fade, held at the grab
  offset.
- **Fix:** render the drag image from the row view (`cacheDisplay` of the plate at full opacity) instead of a
  label-on-plate composite. Rows beneath stay still; only the 2 pt drop line moves. The drop line already looks right.

### 8. Command bar: inline completion isn't distinguishable from typed text
- **Where:** `app3/chromium/06-command-bar.png`, input row: "wiki" typed, "pedia.org" completed.
- **What's wrong:** the whole of "wikipedia.org" is drawn in the same full ink. The completion is shown as an
  `NSTextView` selection (`CommandBar.swift:250`), so how it looks depends on the system selection colour. In this
  capture it is invisible, and on screen it will be macOS's selection colour rather than ours.
- **Intended:** design.md §2.3: `inlineCompletionText` (ink ≥ 0.44, raised to 3:1 on `surface`) on
  `inlineCompletionHighlight` (accent 0.18 / 0.30). See the mockup: "gma|il.google.com".
- **Fix:** keep the selection behaviour, but set the editor's `selectedTextAttributes` to the completion colour and
  highlight, or draw the suffix as a separate attributed run. Verify in a key window.

### 9. Command bar rows: the action isn't accented and shortcuts aren't keycaps
- **Where:** `06-command-bar.png` ("Open" at the right of the selected row), `06b-command-bar-actions.png` ("⌘D") and
  "— Search Google" on the search row.
- **What's wrong:**
  - The selected row's action is plain dark text, with no ↵ keycap.
  - Shortcuts are plain text.
  - The search row uses an em-dash prefix, which looks like a typo next to the mockup's clean two-tone row.
- **Intended:** design.md §7 "Command bar":
  - the selected row's action is in the accent, with a keycap;
  - keycaps are 18 pt tall, radius 5, `mono` 11, with a hairline and `surfaceHover`;
  - the query is in `surfaceText`, and "Search Google" follows in `surfaceTextTertiary` without a dash.
- **Fix:** in `CommandBar.swift`, make the row's trailing view an accent label + keycap (`AircKeycap` if it exists;
  otherwise build it from the tokens), and drop "— " in the search subtitle (`CommandBar.swift:641`, `:647`).
  - The shadow the owner flagged earlier is now present and looks right (`commandBar` elevation is visible under the
    bottom edge).

### 10. ⌘L / URL-field command bar hugs the window edge and jumps the text
- **Where:** `app3/chromium/06c-command-bar-url.png`, top-left 330 × 105 pt. The log has frame {{2, 32}, {640, 116}}.
- **What's wrong:**
  - The bar starts 2 pt from the window's left edge and covers the header buttons.
  - The input text starts at x ≈ 40, while the URL field's host text it grows out of is at x ≈ 22, so the text jumps
    sideways as it opens.
  - Its 640 pt width also runs about 410 pt into the page.
- **Intended:** Arc ref §2.2: clicking the field opens the command bar "over the field, narrower". The bar should look
  like the field expanding: left edge at the field's x 8, top at the field's y 46 (or a few points above, to clear the
  shadow), and the input text on the field's text baseline and x.
- **Fix:** in `CommandBar.layoutIn(_:sidebarFrame:contentFrame:)`, anchor the field-mode frame to the URL field's frame
  (x 8, y 46 − input/2 + 18) and offset the input's leading inset so the text starts where the host text was.

### 11. Space bar: inactive Spaces stay colourful, and the profile dots vanish on pastel themes
- **Where:** `app3/chromium/01-space-personal.png` and `07-new-space-sheet.png`, footer (y 735–765 pt). Compare
  `design/mockups/profiles-create-space.png`.
- **What's wrong:**
  - Inactive cells are only at alpha 0.45, so colour emoji (🎨, 🌱) still compete with the current Space. In Arc,
    inactive Space icons read as grey.
  - The 6 pt profile dots use pastel profile colours with no visible cut-out ring, so they disappear on Mint.
  - A Space with no icon shows its 7 pt dot next to the profile dot, which reads as a stray "••".
- **Intended:** design.md §7 "Space bar": others at opacity 0.45 **and half saturation**. "Footer dots": 6 pt in the
  profile colour, with a 1.5 pt cut-out ring in the window colour.
- **Fix:**
  - In `SidebarChrome.swift:373`, also desaturate the cell layer, using a `CIColorControls` saturation 0.5 compositing
    filter or a pre-rendered grey emoji image.
  - Draw the profile dot ring in `profileDotRing` at 1.5 pt.
  - See also #14: the dot colours come from the pastel swatch palette.

### 12. Create a Space: the new Space isn't shown in the Space bar
- **Where:** `app3/chromium/07-new-space-sheet.png`, footer.
- **What's wrong:** the footer shows only the existing Spaces. Nothing marks the page you're on, so the card looks
  detached from the bar.
- **Intended:** design.md §7 "Create a Space card": "the footer showing the new Space's cell as current on a
  `tileFill` plate". The mockup shows the 🌱 cell on a plate, at full strength.
- **Fix:** while the Create page is shown, append a provisional cell (icon from the name field's emoji, or a dot) on
  `tileFill` and dim the others.

### 13. Create a Space card: illustration, theme chip and Cancel are off-spec
- **Where:** `app3/chromium/07-new-space-sheet.png`, sidebar y 180–540 pt. Chromium and WebKit are identical.
- **What's wrong:**
  - The illustration is about 112 × 77 pt and dominates the column.
  - The theme chip is about 44 × 22 pt with a thick white rim. On a dark theme it is dark-on-dark and reads like an off
    toggle switch.
  - "Cancel" is full-strength white medium, nearly as loud as Create Space.
- **Intended:** design.md §7:
  - the illustration is 96 × 64;
  - `AircThemeChip` is 30 × 20 with a thin white rim;
  - Cancel is plain, `textSecondary`, regular weight.
- **Fix:** use the `AircMetrics.CreateSpace` tokens for the illustration frame, use `AircThemeChip` as is, and style
  Cancel with `AircButtonStyle(.plain)`.

### 14. Profile colours use Arc's pastel swatches instead of `AircProfileColor.choices`
- **Where:** `app3/chromium/08b-create-profile-step1.png` (the Colour row), `20-settings-profiles.png` (Emoji and
  colour) and the "P" avatar in `01`.
- **What's wrong:**
  - The nine discs are Arc's theme swatches (cream, pink, mauve…).
  - Their OKLab "pastel" is close to white, so avatars like "P" look like blank white chips.
  - Profile dots don't show on light themes (#11).
- **Intended:** design.md §7 "Create Profile card" uses `AircProfileColor.choices`: saturated blue, green, teal,
  violet, pink, red, orange, gold and graphite (`ResolvedTheme+Extras.swift:57`), as in
  `design/mockups/profiles-create-profile-1.png`.
- **Fix:** point the Create Profile card and Settings → Profiles at `AircProfileColor.choices`. Map existing stored
  indices once.

### 15. The page card has no edge at all
- **Where:** `app3/chromium/01-space-personal.png`, the card's left and bottom edges (x 228, y 790). The pixels next to
  the card are exactly the theme colour.
- **What's wrong:** a white page on a light theme meets the sidebar with no hairline or shadow, so it looks pasted on
  rather than floating as Arc's card does. Depth is the owner's known sore spot (the command-bar shadow).
- **Intended:** design.md §4 "Shadows": `card` is black 0.10, r 1.5, y 1, plus a hairline of black 0.08 (`cardDark`
  0.35 / white 0.06).
- **Fix:** the clipping layer probably has `masksToBounds` on the same layer as the shadow. Put the shadow and the 0.5 pt
  hairline on a container layer outside the clip (`palette.cardShadow` already exists in `DesignBridge.swift`).

### 16. Create Profile step 2: the Space tiles lack their sidebar hint
- **Where:** `app3/chromium/08c-create-profile-step2.png`, the tile grid.
- **What's wrong:**
  - The tiles are flat swatches with an emoji.
  - The selected ring sits tight on the tile.
  - A Space with no icon shows just the empty check circle on white.
- **Intended:** `design/mockups/profiles-create-profile-2.png` and design.md §7: `AircSpaceTile` 84 × 64, radius 12,
  each in its own theme "with a hint of its sidebar" (three short ink lines), and the selected ring offset from the
  tile by a 2 pt gap.
- **Fix:** use `AircSpaceTile` from AircDesign (the gallery's `profiles.png` has it), or copy its sidebar-lines layer.
  Give no-icon Spaces the 6 pt `text` dot.

### 17. The URL field truncates with "…"
- **Where:** `app3/chromium/10-drag-mid.png` and `11b-folder-preview.png`, the URL field reading
  "news.ycombinator.…" while its hover buttons show.
- **What's wrong:** this breaks decision 4 of pass 3 ("Titles fade, never '…'").
- **Intended:** design.md §7 "Loading rows and title fades": fade over 24 pt, ending 4 pt before the trailing control.
- **Fix:** use `AircFadingLabel` for the URL field's host label, with its trailing edge at the first hover button minus
  4 pt.

### 18. Favorites: the unread dot and favicon are slightly off
- **Where:** `app3/chromium/01-space-personal.png`, the Gmail tile (x 8–110, y 90–136 pt).
- **What's wrong:**
  - The dot is 7 pt, centred 15 pt from the tile's right and 13.5 pt from its bottom, so it sits under the icon
    rather than in the corner.
  - Favicons are 18 pt.
- **Intended:** design.md §7 "Favorites tile" and Arc ref §2.3: dot 6 pt, centred 11 pt from the right and 10 pt from
  the bottom (`AircMetrics…unreadDot`, `unreadDotOffset`); favicon 20 pt.
- **Fix:** read both from the tokens in the Favorites tile layout.

### 19. Sidebar x positions drift by about 2 pt
- **Where:** `app3/chromium/01-space-personal.png`, rows and Space header.
- **What's wrong:** the Space emoji is centred at x 28 (spec 26), the Space name starts at 43.5 (spec 41) and row
  titles start at about 45 (spec 43). It's small, but it's everywhere, and the owner compares against Arc
  side by side.
- **Intended:** design.md §7 and Arc ref §2.4: title x 43, header icon centred at 26, name at 41.
- **Fix:** check `AircMetrics.Row.titleX` / `faviconX` against the label's own inset. `NSTextField` adds about 2 pt
  of internal padding; subtract it when placing the frame.

### 20. Settings mixes stock AppKit controls with Airc controls
- **Where:** `app3/chromium/20-settings-general.png` (Make Default, Choose…, 30 minutes) and
  `20-settings-profiles.png` (Sign In…, Clear…, 12 hours, Google).
- **What's wrong:**
  - Bezel push buttons and pop-ups sit next to Airc's switches and segmented controls, so the window reads as two
    design systems.
  - In `20-settings-spaces.png`, the no-icon Space shows a solid black dot as its icon.
- **Intended:** design.md §7 "Buttons" (secondary: white, 0.5 pt ink 0.14 hairline, `control` shadow) and "Settings
  page".
- **Fix:** use `AircButtonStyle(.secondary, .regular)` for the buttons, and a menu-style `Picker` with the same
  secondary chrome for the pop-ups. Draw no-icon Spaces with the 6 pt `text` dot at 0.6.

---

## 2. Quick wins (under 15 minutes each)

1. **Folder icon** (#6): `"folder"` in `accent`, and `"folder.fill"` at 0.9 when open (`SidebarRows.swift:531`).
2. **Search row copy** (#9): drop "— " from "— Search ‹engine›" (`CommandBar.swift:641`, `:647`) and colour the
   subtitle `surfaceTextTertiary`.
3. **Cancel on Create a Space** (#13): plain style, `textSecondary`, regular weight.
4. **Unread dot and favorite favicon** (#18): read `unreadDot` / `unreadDotOffset` and the 20 pt favicon from the
   tokens.
5. **URL field fade** (#17): swap the host label for `AircFadingLabel`.
6. **URL field placeholder** (#2): "Search or enter URL…" in `textTertiary` when there's no tab.
7. **Theme picker wave colour** (#4, if the full swap waits): stroke with `theme.colors.last` instead of `ui.accent`
   (`apps/browser/Sources/Airc/Spaces/ThemePicker.swift`, `WaveSlider`).
8. **Sign-in card copy and "Not now"** (#3, if the full swap waits): the spec copy, plus a plain "Not now" next to
   Sign in.
9. **Profile dot ring** (#11): a 1.5 pt `profileDotRing` stroke around the footer dots.
10. **Settings no-icon Space** (#20): a 6 pt ink dot instead of the black disc.

---

## 3. Where the mockup should change, because the real app is better

1. **Command bar footer: drop it.** The app has no footer, and Arc has none either. The mockup's
   "↑↓ Navigate · ↵ Open · ⇥ Actions · ⌘T results from this profile only" row adds a third band of chrome. The
   profile chip already says "this profile only". This is conductor's restraint; keep keycaps on the selected row only
   (#9).
2. **Command bar placement: centre over the page card, not the window.** The app centres the 765 pt bar on the card
   (x 228…1270). With a 228 pt sidebar, the mockup's window-centred bar sits off-centre over the page you're reading.
   Update `command-bar.html` and design.md §7 "Command bar" to say "centred on the page card".
3. **Onboarding Done background: the app's bloom is better.** `ob-05-done.png` sets the member card on the same
   pastel bloom as Welcome, so the flow opens and closes in one key. The mockup (`ob-5.png`) uses flat warm grey,
   which reads as an unstyled window.
4. **Profile and theme surfaces in dark themes.** The app renders the Create Profile card, the theme picker and the
   Create a Space card on dark `surface` in dark Spaces (`08b`, `08c`, `07a`), and they look right. The mockups only
   show light Spaces. Add a dark variant (for example the Ocean Work Space) to `profiles.html` so reviewers judge the
   case the owner uses daily.
5. **Create Profile step 2 with more than five Spaces.** The app wraps the tiles onto a second, left-aligned row
   (`08c`), which works. The mockup only shows five tiles, so it never specifies the wrap. Show six or seven.
6. **One-tile Favorites.** The app follows Arc's column rule: a single Favorite fills the row (`03-space-studio.png`).
   The mockups always show four tiles, so this state looks like a bug to a reviewer. Add a one- and a two-tile
   example to `window.html`.

---

## Capture gaps

These screens couldn't be reviewed, because the capture didn't show the state it names. Re-run them with the build
Mac's display awake and the window key (see the snapshot caveat in the agent notes).

- **`09-sidebar-hidden.png`** (both engines, and nightly): the sidebar is still docked.
- **`11-library.png` and `11b-folder-preview.png`:** the Library never slid in. Its close "×" and the start of its
  search field ("Sear…") poke out at the window's left edge (x 0–10, y 0–40), and the traffic lights are hidden. This
  is probably the spring not ticking with the display asleep. If it can happen live, the Library should be
  `isHidden` while its fraction is 0.
- **`ob-06-expanding.png`:** solid black.
- **Focus, carets and selection colours everywhere:** the windows weren't key. This matters most for #8 (inline
  completion) and for the Create a Space name field's 3 pt accent ring.

## What already matches the design

- **Geometry:**
  - sidebar 228 and card inset 10;
  - row pitch 41 and plate 36 / radius 12 / inset 8;
  - Favorites tiles 47 with an 8 pt gap and Arc's column rule;
  - URL field top 46 / height 36;
  - header button plates at x 77 / 122 / 156 / 190 (left edges);
  - the Today divider 18 pt from both edges.
- **Command bar:** 765 pt wide, top 169 pt above the window's middle, 41 pt rows, `surfaceSelected` row fill, the
  shadow, and the profile chip.
- **Loading row (`p2/03b-row-loading-crop.png`):** the ring sits in the favicon slot, the title fades, and nothing
  draws over text. The owner's P2 is fixed.
- **Selected rows:** white 0.85 + shadow in light themes, ink 0.20 in dark.
- **Onboarding:** steps 1–5 match the mockups closely in layout, type, step dots and the theme-accent primary button.
- **Engines:** Chromium and WebKit render the same apart from #1 (traffic lights).

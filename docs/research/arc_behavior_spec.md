# Arc's exact behavior, as a buildable UX spec (sidebar, Spaces + Profiles, theming, motion, keys)

Research track 2 of 6 · written 2026-11-03 · for a Chromium-fork, macOS-only, Arc-replacement browser.

## How to read this

**Claim tags.** Every claim carries one of these tags:

| Tag | Meaning | Trust |
|---|---|---|
| **[C:key]** | Cited from an official Arc source: help-centre article, release notes, or arc.net | High. Release notes say *that* something exists, rarely *how big* or *how fast* |
| **[M:key]** | Measured from Arc 1.170/1.171 by a third party: frame-by-frame 120 fps recordings, 2× captures and macOS accessibility (ax) reads, published in the GPL-3.0 Arc clone **ilo** (Oct–Nov 2026), some from "an outside Arc 1.17x reverse-engineering" it cites | Medium-high. Unofficial, but the only numeric source that exists. Units are **points (pt)**; colours are "white 0.12" = white at alpha 0.12 |
| **[S]** | Read off the user's own Arc screenshots (2× retina, so 2 px = 1 pt) | High for this user's setup |
| **[I]** | My inference, not stated by any source | Treat as a design proposal |

Where sources conflict, both are given.

**Source keys** (each URL appears once here; tags below use the key):

| Key | URL |
|---|---|
| RN21 | https://resources.arc.net/hc/en-us/articles/20498463803799 (Arc for macOS 2021 release notes) |
| RN22 | https://resources.arc.net/hc/en-us/articles/20498417809815-Arc-for-macOS-2022-Release-Notes |
| RN23 | https://resources.arc.net/hc/en-us/articles/20498377604887-Arc-for-macOS-2023-Release-Notes |
| RN24 | https://resources.arc.net/hc/en-us/articles/20498293324823-Arc-for-macOS-2024-2026-Release-Notes |
| RNW | https://resources.arc.net/hc/en-us/articles/22513842649623 (Arc for Windows 2023–2026 release notes) |
| H-Spaces | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas |
| H-Profiles | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing |
| H-Fav | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/19230755904151-Favorites-Top-Tabs-Across-Every-Space |
| H-Pinned | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around |
| H-Folders | https://web.archive.org/web/2024/https://resources.arc.net/hc/en-us/articles/19228419623447-Folders-Stash-Similar-Tabs-Together |
| H-Archive | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/19228855311127-Auto-Archive-Clean-as-you-go |
| H-Library | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/19230634389911-Library-A-home-for-your-downloads-archived-tabs-easels-and-more |
| H-Hide | https://web.archive.org/web/2024/https://resources.arc.net/hc/en-us/articles/25619487530519-How-Do-You-Hide-the-Sidebar |
| H-Keys | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/20595231349911-Keyboard-Shortcuts |
| H-CustomKeys | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/25622899860631-How-to-Set-Custom-Keyboard-Shortcuts-on-Arc-for-Desktop |
| H-SwitchTabs | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/25619402657303-How-Do-You-Switch-Between-Tabs-Quickly-on-Arc-Desktop |
| H-SameTabs | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/25590417429783-Why-Are-the-Same-Tabs-Appearing-Across-Multiple-Arc-Windows |
| H-Peek | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/19335302900887-Peek-Preview-Sites-From-Pinned-Tabs |
| H-Split | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/19335393146775-Split-View-View-Multiple-Tabs-at-Once |
| H-LittleArc | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/19235387524503-Little-Arc-Quick-Lookups-Instant-Triaging |
| H-ATC | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/22932014625431-Air-Traffic-Control-Automate-Your-Link-Routing |
| H-Boosts | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/19212718608151-Boosts-Customize-Any-Website |
| H-Previews | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/19335284431639-Previews-Glance-Top-Sites |
| H-LiveCal | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/24158102740631-Live-Calendars |
| H-DevMode | https://web.archive.org/web/2024/https://resources.arc.net/hc/en-us/articles/20468488031511-Developer-Mode-Instant-Dev-Tools |
| H-Theme | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/25625261733143-How-Do-I-Restore-the-Default-Theme-for-Arc-for-Desktop |
| H-Import | https://web.archive.org/web/2024/https://resources.arc.net/hc/en-us/articles/19335089616791-Import-Bookmarks-Logins-History-Extensions-from-Your-Previous-Browser |
| H-Slash | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/25625148480279-Why-is-There-a-Slash-Next-to-My-Pinned-Tab-s-Name |
| H-Revert | https://web.archive.org/web/2025/https://resources.arc.net/hc/en-us/articles/25541939922199-Why-Are-My-Pinned-Tabs-and-Favorites-Reverting-Back-to-Their-Original-URL-in-Arc-for-Desktop |
| DiaMove | https://resources.arc.net/hc/en-us/articles/44413129117591-Move-from-Arc-to-Dia |
| COLORS | https://arc.net/colors.html |
| ILO | https://github.com/MartinPTielemans/ilo/blob/HEAD/docs/ux-spec.md (GPL-3.0; parts adapted from Ardia, Apache-2.0) |
| ILO-P | https://github.com/MartinPTielemans/ilo/blob/HEAD/docs/ux-principles.md |
| ILO#n | https://github.com/MartinPTielemans/ilo/issues/n (or /pull/n): #1399 favorites grid, #1401 many Spaces, #1402 sidebar scroll/reveal, #1405 folder preview, #1552 switcher squeeze, #1635 theme picker placement, #1403/#679 pinned close, #80 motion shot list |
| ZEN | https://github.com/zen-browser/desktop/blob/HEAD/src/zen/migration/ZenMigrationUtils.sys.mjs (Arc theme importer) |
| PF | https://pageflows.com/post/mac-os/onboarding/arc/ (Arc macOS onboarding recording, timestamped) |
| HTG | https://www.howtheygrow.co/p/how-arc-grows |
| MPU | https://talk.macpowerusers.com/t/arc-browser-spaces-and-profiles/35872 |
| MOZ | https://connect.mozilla.org/t5/discussions/improvements-to-the-firefox-sidebar-are-on-the-way/m-p/60605 |
| PRIOR | the Arc data model research note from the earlier Chrome-extension prototype (not in this repo) (yesterday's research; Q4–Q6 are folded in here and not repeated in full) |
| CR-TSM | https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/tabs/tab_strip_model.cc |

**State of the sources.** The live help centre is now down to 22 articles. The feature articles are gone, but all macOS and Windows release notes are still live; I fetched them through the Zendesk API (`resources.arc.net/api/v2/help_center/en-us/articles.json`). Feature articles came from Wayback snapshots (2024–2025). Arc ends on **2026-12-22**: if anything has to be measured in the real app, it must happen within the next seven weeks [C:PRIOR].

---

## 0. One-page summary for the engineer

1. **The window is one themed surface.** The Space colour fills the whole window: sidebar, title area and a 10 pt margin. The web page is a **card** inset 10 pt with a 6 pt corner radius. The sidebar holds the traffic lights, the sidebar toggle, back/forward/reload and the URL field. There is no top toolbar unless one is turned on [M:ILO][C:RN23].
2. **The sidebar, top to bottom:** header row → URL field → Favorites grid (per *profile*, max 12) → Space name row → Pinned tree (per Space; nested folders) → divider with a "Clear" button → "+ New Tab" → Today tabs (per Space; auto-archived after 12 h) → media tray / update banner → footer (Library · Space icons · +) [C:H-Fav][C:H-Pinned][C:H-Spaces][M:ILO][S].
3. **The sidebar is a model, not a view of loaded tabs.** Favorites and pinned items persist without a loaded page. "Closing" one unloads it and keeps the row [C:H-Pinned][M:ILO][C:PRIOR].
4. **Spaces bind to profiles many-to-one.** Each Space has exactly one profile, and a profile can serve several Spaces. One window swipes between Spaces of *different* profiles. The cookies, logins, history, extensions and Favorites change with the Space [C:H-Profiles][C:RNW][C:MPU].
5. **Switching:** click a footer icon; ⌃1–⌃9; ⌥⌘←/→; two-finger horizontal swipe over the sidebar; mouse buttons 4/5; ⌘T + Space name. The pages settle on a critically damped spring of about 0.19 s, and the window colour crosses over in about 30 ms [C:H-Spaces][C:RN22][M:ILO].
6. **Motion:** fast, mostly springs. Hover is one frame, rows move in about 115 ms, the sidebar hides in 110 ms and the edge reveal springs in 175 ms. Haptics fire on thresholds only [M:ILO][C:RN22][C:RN23].

---

## 1. Window anatomy and geometry

| Item | Value | Tag |
|---|---|---|
| Default sidebar width | **228 pt** on a fresh install (1280×800 and 1512×949 screens) | [M:ILO] |
| Min / max sidebar width | **164 / 500 pt**. Dragging past the minimum hides the sidebar, keeping its last width | [M:ILO]; drag-to-hide [C:RN24] |
| Resize | Hover the sidebar edge and drag. **Double-click the edge to reset** to the default | [C:RN21][C:RN22] |
| Content card inset | **10 pt** on every side, sidebar docked or hidden. Docked, the card starts at the sidebar width, so its left 10 pt lies inside the sidebar | [M:ILO] |
| Card corner radius | **6 pt** circular; the page is clipped to it (Dia uses 10 continuous) | [M:ILO] |
| Traffic lights | 16×16, centres (20,24), (43,24), (66,24): a 23 pt pitch | [M:ILO] |
| Window drag | Empty sidebar space and margins drag the window | [C:RN22]. Dragging from the page's top bar can also be enabled [C:RN23] |
| Double-click on empty sidebar | Opens a new tab | [C:RN23] |
| Inactive window | The sidebar dims slightly | [C:RN23] |
| Window resize | "Smoother by leveraging the background color of your website" | [C:RN24] |
| Optional toolbar | View › Show Toolbar (⇧⌘D) puts a URL bar above the page, takes the page's colour and can show the full URL | [C:RN23][C:H-Keys]; ⇧⌘D [M:ILO] |
| Full screen | The sidebar stays docked and the card keeps its 10 pt inset. Arc switches to the full-screen layout in one frame, then a toast "To exit full screen, press ⎋." shows for 4.8 s. ESC defaults to "Prefer websites", so a single ESC goes to the page; **hold or double-press ESC** to leave full screen | [M:ILO]; ESC [C:RN23] |
| Full screen + hidden sidebar | Supported, including Space swiping (a Sonoma bug with it was fixed) | [C:RN23] |

**[I] For the user (always full screen on a MacBook).** In full screen there are no traffic lights, so the sidebar button moves left (glyph at x 20–38.5) [M:ILO#1402]. The header row can start at the very left. Plan for the 14"/16" MacBook notch: with no menu bar the top 32–38 pt sit under the notch region. This is an inference; Arc's handling isn't documented.

---

## 2. Sidebar anatomy and every interaction

### 2.1 Header row (top of sidebar)

| Item | Value | Tag |
|---|---|---|
| Row centre | 23.5 pt below the window top (traffic lights at 24) | [M:ILO] |
| Buttons | Sidebar toggle, back, forward and reload: 32×32 hover plates, radius 6. The toggle sits at x 77, 3 pt right of the zoom light. Back/forward/reload are right-aligned on a 34 pt pitch, reload ending 6 pt from the edge (x 122/156/190 at 228 wide) | [M:ILO][M:ILO#1402] |
| Narrow sidebar | Reload goes first, then forward | [M:ILO] (from Ardia) |
| Glyph colour | white 0.60; disabled 0.26; all dim in an inactive window | [M:ILO] |
| Toggle label | "Hide sidebar" while docked; "Lock sidebar" while revealed | [M:ILO] |
| Back/forward long-press or right-click | Shows the tab's history | [C:RN23] |
| ⌘-click or middle-click on back/forward/reload | Opens the result in a background tab | [M:ILO] |
| Loading indicator | Lives in the address bar at the top of the sidebar; also visible in full screen | [C:RN21][C:RN23] |

### 2.2 URL field

- Starts 46 pt from the window top. It is 36 pt tall, inset 8 pt from the sidebar sides, radius 12, fill white 0.10. Text is 13 pt regular, white 0.60, and shows **the host only** (`www.` dropped) [M:ILO].
- On hover over the sidebar, two buttons appear at its right end: **Copy URL** and **Site Control Center**, each 30×30 [M:ILO]. Pinned extensions also appear in the URL bar on hover [C:RN23].
- Clicking the field opens the Command Bar *over the field*, narrower. ⌘L opens the same bar centred [M:ILO].
- In Developer Mode (automatic on localhost) the full URL stays visible, and focused tabs get a yellow/black outline [C:H-DevMode][C:RN22][C:RN23].

### 2.3 Favorites (top grid)

**Behavior (cited):**
- Favorites are "tabs that live across all your Spaces… at the very top of the Sidebar, above your Space Titles. You can have up to 12" [C:H-Fav]. The maximum is 12 per **Profile**, up from 8 [C:RN23].
- **Scope: they belong to the profile, not the Space.** The profile contents list "Favorites" [C:H-Profiles], and a user puts it plainly: "The favorites (square icons at top) and browser session are tied to the profile" [C:MPU]. So two Spaces in the same profile show the same tiles, and a Space in another profile shows that profile's tiles.
- **Add:** drag a tab above the Space title; ⌘T → "Move To Favorite Tab"; or right-click → Move To → Favorites. **Remove:** drag the tile into the Pinned or Today section, or use Move To [C:H-Fav]. Windows also has ⌘T "unfavorite tab" [C:RNW].
- Zero Favorites is allowed [C:RN22], and the empty look was polished in 2024 [C:RN24]. The layout "when you have more than 4" was improved [C:RN23].
- **Live tab:** clicking a tile opens or focuses its tab. Favorites "only load if they've been used recently" (they used to stay loaded) [C:RN23].
- **Snap-back:** a Favorite always reverts to its saved URL. Right-click → "Edit Pinned Page" → "Replace Pinned URL with Current" or "Edit…" [C:H-Revert].
- **Peek:** a click on a link to *another site* inside a Favorite opens in Peek instead of navigating away [C:H-Peek].
- **Badges:** "Slack, Twitter, GCal, and Gmail now have custom badging when they're in your Favorites Dock" [C:RN22]. WhatsApp and X have unread badges, toggled per tab by right-click [C:PRIOR]. Audible music favorites animate musical notes on the icon [C:RN22]. A badge shows on a Favorite shared to a video call [C:RN23].
- **Previews:** hovering a pinned or favorited Gmail, Outlook, Google/Outlook Calendar, GitHub, Notion, Confluence, Figma or Linear shows a preview panel [C:H-Previews].
- **Live Calendar:** with Google Calendar as a Favorite, the tile shows a countdown to the next meeting and a "Join" button appears in the sidebar. ⌃⌘J joins; right-click the calendar icon to set notifications [C:H-LiveCal][C:RN24].
- **Custom icons:** you can change a Favorite's icon [C:RN24]. Favorited Split Views can have custom icons [C:RN22].
- **⌘1–⌘9:** Favorites count first by default; "Include Favorites in Ordering" can be turned off. ⌘9 can be set to mean the 9th or the last item [C:RN22].

**Geometry and motion (measured, Arc 1.170/1.171):**

| Item | Value | Tag |
|---|---|---|
| Tile height / gap | **47 pt / 8 pt** at every width | [M:ILO#1399] |
| Side inset | 8 pt (same as rows) | [M:ILO] |
| Column rule | Take the **most columns, up to 4**, that keep each tile at least 47 pt wide. Then use the **fewest columns that need no more rows**: 5 → 3+2, 6 → 3×2, 7 → 4+3, 9 → 3×3; 4 tiles at 200 pt wide → 2×2. A short last row keeps the tile width and is left-aligned | [M:ILO#1399] |
| Corner radius | about 10 (Dia value) | [M:ILO] |
| Resting fill (dark) | about white 0.10; hover about 0.20 | [M:ILO] (Dia-derived, *guess* for Arc) |
| Split as a Favorite | One tile cut by a 2 pt gap along the split axis | [M:ILO#1399] |
| Pinning header | The tiles and the Space name row stay fixed; only the tab list scrolls under them. A Favorites block taller than 40 % of the sidebar scrolls with the list | [M:ILO#1402]; 40 % rule from Ardia [M:ILO] |
| Dragging a tab in | Over the tile area, the dragged row is drawn as a tile and the tiles make room on a critically damped spring (ω ≈ 25 rad/s, settled in about 240 ms) | [M:ILO] |
| Tooltip | Appears 1.6 s after the pointer stops; one frame in, about 270 ms ease-out out | [M:ILO] |

**[S] Reference screenshot.** Two Favorites, Gmail and Google Calendar, fill one row of two wide tiles: about 102×46 pt, 8 pt gap, consistent with 47 pt tiles. Gmail shows a **red dot** near the bottom-right of the tile, about 11 pt in from the right and 10 pt up from the bottom. Calendar shows "26", which is Google's own date favicon. In this light theme, the tile fill is about black 0.05 over the Space colour (#8AD3B8 over #90DDC1).

**[I] Unread dot rule.** Arc's badge is most likely derived from the page title, e.g. "Inbox (3)". An Arc clone's string dump shows `SidebarItemUnreadBadgeView`, `unreadBadgeType` and a per-Favorite "Show Unread Badge" toggle [C:PRIOR]. The user's tile shows a dot, not a number, so render a dot whenever count > 0. In a fork, read the title from the WebContents, or ask for the count from the extension or Gmail API while the tab is unloaded.

### 2.4 Space name row ("Space header")

- Shows the Space's **emoji or icon + name**. The name starts at x 41 when there is an icon (x 18 without). The icon sits in a 26 pt frame centred at x 26 [M:ILO]. [S]: the name row is drawn bold in a muted colour (#619582, about black 0.35 over the mint) after its emoji.
- **Hover** shows a row plate (36 pt tall, inset 8 pt) and a **•••** button (24 pt square, 6 pt from the plate's end). The ••• opens the Space menu. On hover a **chevron replaces the icon**: pointing down while pinned items are shown, a quarter-turn right while they're collapsed [M:ILO]. Older Arc versions showed "Edit"/"…" only on hover [C:RN23], with a paint-brush icon for themes [C:RN22].
- **Press on the row** (Arc 1.171) collapses or expands the Pinned section, like the caret next to the title [M:ILO][C:H-Pinned]. **Conflict:** in 2023 Arc said "You can now rename a Space by simply clicking on your Space Title" [C:RN23]. By 1.171 rename is in the menu, and a press folds the pinned section [M:ILO]. Build the 1.171 behavior.
- While pinned items are collapsed, keyboard navigation skips them [C:RN24]. "We've bolded your Space header while Pinned Tabs are collapsed in cases where your last Pinned Tab is in view" [C:RN24].
- **A single unnamed Space with no icon hides the row.** The Space menu then offers "Show Space Header" [M:ILO#1635]. Only named Spaces can collapse their pinned section; you name one via Spaces › Rename Space [C:RN24].
- **Space context menu** (right-click on the name, the footer icon or a Library card, or the ••• button), in Arc 1.171's order: Change Space Icon… · Rename Space… · Edit Theme Color… · Set Profile › · — · New Folder… · (Live Folders ›) · (Share Space…) · — · Manage Spaces… · — · Delete Space (disabled for the last Space) [M:ILO]. Right-click on empty sidebar space also opens a Space options menu [C:RNW].
- **Rename:** the name becomes a field with everything selected and a "Done" button (32×26). ↩ or Done saves, Esc cancels, and clicking away also saves [M:ILO][C:RN24].
- **Delete:** a confirmation names the Space [C:RN23]. Today tabs go to the Archive, and a toast says "Space deleted! Use ⌘Z to undo." [M:ILO].
- **Icon picker:** a 273×273 popover with Emoji | Icon tabs and a trash button. Emoji has search [C:RN21] and skin tones [C:RN24]. Icon has 56 glyphs in an 8×7 grid on a 31 pt pitch [M:ILO]. A Space with no icon shows a **dot** in the footer [M:ILO][S].

### 2.5 Pinned section (per Space) and folders

**Pinned tabs:**
- They live above the divider, never auto-archive, and can be grouped into folders [C:H-Pinned].
- Pin or unpin with ⌘D, ⌘T → "Pin Tab", or by dragging across the divider [C:H-Pinned].
- A pinned tab is "a cross between an App and a Bookmark". Links to another site open in **Peek**. Reset to the pinned URL by **clicking the favicon** or with ⌘T → "Reset Tab" [C:H-Pinned].
- **Away from the saved URL:** a "/" appears next to the name [C:H-Slash]. The favicon becomes a back arrow labelled "Back to Pinned URL" on hover (Dia's version) [M:ILO]. **⌘-click on the favicon** resets and opens the current page in a new tab [C:RN24].
- **Pinned URL editing:** right-click → Pinned URL › "Replace Pinned URL with Current" / "Edit…" [C:H-Revert][C:RNW].
- **Typing a new URL** into a pinned tab (⌘L) opens it as a new Today tab, so the pinned tab stays what it is [M:ILO][C:PRIOR].
- **Close vs remove:** closing a pinned tab (⌘W or the row button) **unloads it and keeps the row**. On hover Arc shows ✕, which becomes "−" only on the selected row [M:ILO]. Menus include "Close and Keep Pinned", "Reset All Pinned Tabs" and "Tabs › Reset all tabs in this Space" (no default key) [C:PRIOR][M:ILO].
- **Rename:** double-click or right-click [C:RN24]. The rename prompt on pin was removed [C:RN24].
- **Duplicate:** right-click → Duplicate, or **⌥-drag**. The history is duplicated too [C:H-Pinned][C:RN22][C:RN23].
- **Unloaded rows:** the favicon draws at half opacity (*interim* value) [M:ILO]. Arc's exact alpha and whether pinned tabs auto-sleep on a timer are not documented. See Gaps.

**Folders:**
- Create via "+" at the bottom of the sidebar, via New Folder… in the Space menu, or from a multi-selection ("New Folder with N Items") [C:H-Folders][C:PRIOR].
- Delete, move or rename by right-clicking the folder title. Add tabs by drag and drop [C:H-Folders]. Clicking outside the name field saves a rename [C:RN24].
- Tabs in folders do not auto-archive [C:H-Folders].
- **Nesting:** shift-click tabs inside a folder, then right-click → new nested folder [C:RN23]. Each level indents **16 pt**: in one folder the favicon sits at x 33 and the title at x 59 [M:ILO].
- **Icons:** right-click → "Change Icon" [C:RN23].
- **Copy All Links**, nested folders included [C:RN23].
- **Open/close on press, not release** [M:ILO]. Folder open: ease-out `cubic-bezier(0,0,0.58,1)` over 200 ms. Folder close: critically damped, ω ≈ 25, about 240 ms [M:ILO].
- **Closed-folder preview:** hovering a closed folder shows a searchable list. Picking a tab from it "peeks out under the closed Folder rather than unfurling the entire contents" [C:H-Folders]. Measured preview: **0.45 s** delay; about 90 ms in (opacity + scale from 0.85); 240 pt wide, 4 pt right of the sidebar; rows on a 45 pt pitch showing title over age ("31 minutes ago"); max height 320; **newest visit first**; first row selected with the caret in the search field; empty state "No tabs matching that search 🤔" [M:ILO#1405].
- **Moving a tab into a folder** always "peeks" it in the folder so you don't lose your place [C:RN23].
- Shared folders are inserted at the bottom of Pinned [C:RN23].
- GitHub Live Folders (an auto "Pull Requests" folder) is P2 [C:PRIOR].

### 2.6 Divider and "Clear"

- A one-device-pixel line in white 0.15 (light theme: black 0.15), 18 pt in from each sidebar edge. It shows while the Space has Today tabs, and its centre sits 25 pt above the first Today row's centre [M:ILO]. [S]: the line is visible in the user's light theme (#7ABDA4 over #90DDC1).
- **"Clear" appears at the right end of the divider only while the pointer is over the sidebar.** It is semibold, about 10 pt, white 0.32, brightening to 0.81 on hover. Tooltip: "Clear unpinned tabs in this space" [M:ILO].
- Clear (or ⇧⌘K) closes every Today tab **except the one shown**: they move to the Archive, ⌘Z restores them, and there is no toast. If the tab shown is the only Today tab, a small ↓ arrow appears before "Clear" to warn that it will close too [M:ILO]. The clearing animation was improved in 2023 [C:RN23].
- The AI "Tidy Tabs" broom sits at the top of Today, visually separate from Clear (Arc Max, skip) [C:RN24].

### 2.7 "+ New Tab" row

- It is the first row under the divider, and new tabs open just below it, **at the top of Today** [M:ILO][C:DiaMove].
- Label at about white 0.55; plus glyph about 0.25 [M:ILO]. [S]: in the user's light theme the "+ New Tab" label is muted (#669C88).
- Clicking it opens the Command Bar (⌘T); the row takes the selected plate while the bar is open [M:ILO].
- ⌘-hover on the button offers **Paste and Go** when the clipboard holds a URL [C:RN23].
- Double-clicking empty sidebar space also creates a new tab [C:RN23].

### 2.8 Today section (unpinned tabs)

| Topic | Behavior | Tag |
|---|---|---|
| Ordering | New tabs go to the **top**. Links opened in the background line up after their opener (Chrome rule). Links from Favorites go to the top of Today | [C:DiaMove]; opener rule and Favorites links [M:ILO] |
| Auto-archive | Idle unpinned tabs archive after **12 h** by default. **Viewing a tab resets its timer.** It cannot be disabled. Timing is per Profile under Settings › Profiles › "Archive tabs after" | [C:H-Archive][C:RN24] |
| Interval choices | 12 h, 24 h, 7 days, 30 days | [M:ILO] (from Arc 1.170 binary) |
| Exceptions | Tabs playing media are never archived or cleared | [C:RN22] |
| Archive below | Right-click → "Archive Tabs Below" | [C:RN22] |
| ⌘W | Is "Archive Tab": a closed Today tab goes to the Archive | [M:ILO] |
| Drag up | Dragging above the divider pins; above the Space title favorites | [C:H-Pinned][C:H-Fav] |
| Multi-select | ⌘-click; ⇧⌘C copies all selected URLs ("Super Copy"); bulk Move/Archive/New Folder | [C:RN22][C:PRIOR] |
| Overflow marker | When the current tab is scrolled out of view, a small "overflow indicator" shows | [C:RN23] |
| Across windows | Unpinned tabs sync across windows: the same Space shows the same tabs in every window. Blank windows (⌃⌘N) are separate | [C:RN23][C:H-SameTabs] |
| Today tab menu (1.170) | Copy Link (⇧⌘C) · Share · Change Icon… · Rename… · Mute · Customize Page… · Add Split View · Duplicate · Move to (Spaces, New Space…) · Archive Tab · Archive Tabs Below | [M:ILO] |

**Tab row metrics** (dark and light) [M:ILO]:

| Item | Value |
|---|---|
| Row pitch / height | **41 / 40 pt** (a reference screenshot gives the same 82 px pitch at 2× [S]) |
| Plate | 36 pt tall, x 8 → width − 8, radius about 12 |
| Favicon | 18×18 at x 17 |
| Title | x 43, **14 pt**, ending 17 pt from the edge, ellipsis |
| Hover | white 0.12 plus a 26×26 close button 5 pt inside the plate's right edge |
| Selected (dark) | white 0.20 (0.36 under the pointer), no shadow |
| Selected (light) | **white 0.85 + black 0.2 shadow**. [S] confirms this: the active row is #EAF3F0 with a soft shadow |
| Audio | A speaker glyph after the favicon, about 17.5 pt wide with the title 8 pt after it. Click to mute. [S]: the YouTube row shows 🔊 before the title |
| Calls | An animated mic/camera indicator on the tab [C:RN22] |
| Press | The plate shrinks to 0.99 over 70 ms. **The tab activates on press, not release** |
| Loading | A 12×12 spinner ring at the right end, hidden under the close button on hover |
| Dev host line | A grey second line with the host (e.g. "localhost:3000") under Dev Mode or renamed pinned tabs [C:PRIOR][S] |

### 2.9 Footer: media tray, banners, bottom bar

- **Media tray:** when you leave a tab that plays audio or video (including Google Meet), a player appears at the bottom of the sidebar, up to several stacked. ilo measured up to 3, 40 pt tall each, 6 pt apart [C:RN22][M:ILO].
- **Downloads:** progress, size, time left and a cancel button sit at the bottom of the sidebar [C:RN23].
- **Update banner:** starts collapsed and expands on hover. [S] shows it as a full-width pill reading "New Arc Version Available" [C:RN24][S].
- **Bottom bar** (50 pt tall) [M:ILO]:
  - **Left: Library button** (32×32, 8 pt in). It opens the Library; **hovering it shows recent downloads/files**, and right-click filters what hover shows [C:H-Library]. Tooltip "View Library ⇧⌘L". The icon was enlarged in 2023 [C:RN23]. Originally this was a clock icon for the Archive [C:RN21].
  - **Middle: Space switcher.** One cell per Space, 36×34 on a 34 pt pitch, centred. Hidden when there is only one Space [M:ILO]. A Space with an emoji shows the emoji; one with no icon shows a dot. Non-current Spaces are dimmed [M:ILO][S]. A reference bar with 6 Spaces shows 5 emoji and one dot [S].
  - **Overflow with many Spaces:** nothing scrolls. Cells share the span between Library and "+" (217 pt in a 300 pt sidebar), at most **34 pt** each. When a share would drop below 22 pt, **the current Space keeps 22** and the others share the rest: 17.5 / 13 / 9 pt for 12 / 16 / 22 Spaces at 300 pt. Icons shrink into dots when squeezed [M:ILO#1401][M:ILO#1552].
  - **Reorder Spaces** by dragging footer icons (documented for Windows; macOS has the Space Manager) [C:RNW][C:RN22]. Right-click a footer icon for the Space menu [C:RNW][C:H-Spaces].
  - The **icon transition** animates during the Space swipe [C:RN23].
  - **Right: "+"** (32×32, a 14 pt cross at white 0.60). Documented entries are **New Space**, **New Folder**, **New Split** [C:RN23], **New Note** [C:RN23], **New Boost** [C:H-Boosts] and **Add Files** [C:RN21]. Exact order and labels are unrecorded (ilo uses New Space…, New Folder…, New Split View, New Note, — , Add File or Folder…) [M:ILO].
  - **Create-Space gesture:** two-finger swipe *past the last Space* pulls out a circle, which readies at 22.7 pt with a trackpad click. Releasing creates "Space N" and opens the create form [M:ILO].
  - New Spaces are inserted **next to the active Space**, not at the end [C:RN23].
  - **Swipe past the first Space** opens the Library [C:RN22][M:ILO].

### 2.10 Hide/show, reveal on hover, width, right side

- **⌘S** hides or shows the docked sidebar [C:H-Hide]. Hide is ease-out cubic over **110 ms**; show is ease-out cubic over **100 ms**. The page reflows at every step, and the traffic lights return only once the sidebar is at rest [M:ILO].
- **Reveal when hidden:** keep the pointer at the window's left edge, any height. After about **100 ms**, a floating panel slides over the page, which does not move. The panel is inset 5 pt from the window's left, top and bottom, as wide as the docked sidebar, radius 12, with a 0.5 pt light border and no shadow. It stays while the pointer is within about **21–24 pt** of its edge, then slides away [M:ILO].
  - Motion in: spring, response 0.175 s, ζ 0.80, about 4 pt overshoot. Out: response 0.175 s, ζ 0.76 [M:ILO].
  - **Only the key window reveals**, and the pointer must *move* inside the edge strip: a pointer that jumps there does nothing [M:ILO#1402].
  - Docking from the panel is instant [M:ILO].
- **Option (⌥) alone** briefly shows the hidden sidebar; this can be turned off in settings [C:RN21].
- **Toasts while hidden:** "New Tab Created" (clickable) and a toast when a new Space is created [C:RN22][C:RN23].
- New windows keep the sidebar visible by default [C:RN21].
- **Sidebar on the right: Arc has no such option.** No release note mentions one, and third-party posts state it "doesn't have an option to move to the browser's right side" [C:MOZ]. It's cheap to add in a fork; mirror every left-edge rule (reveal edge, swipe direction stays the same) [I].
- Windows Arc has an "unanchored" sidebar mode (windows-only wording) [C:RNW].

### 2.11 Drag-and-drop rules (consolidated)

| Drag | Result | Tag |
|---|---|---|
| Tab → above the Space title | Becomes a Favorite (not offered when 12 already exist) | [C:H-Fav]; cap behavior [M:ILO] |
| Tab → between title and divider | Pinned at its current page | [C:H-Pinned] |
| Pinned/Favorite → below the divider | Unpinned | [C:H-Pinned][C:H-Fav] |
| Tab → onto another tab | **Split View**. The left/right half of the target sets the pane order. A split created in Pinned stays pinned | [C:RN24] |
| Tab → folder | Moves into it, and the folder "peeks" it | [C:H-Folders][C:RN23] |
| Tab → left/right sidebar edge | Pages to the neighbouring Space and drops there. Measured hold: 24 pt from the edge for 0.5 s | [C:RN22]; timing [M:ILO] |
| Tab → outside the window | New window, keeping the tab where it was | [C:RN21][C:RN23] |
| ⌥ + drag | Duplicates | [C:RN22] |
| Finder file/folder → sidebar | Opens as a tab, or imports a folder | [C:RN21] |
| Text → sidebar | Search tab | [C:RN23] |
| During reorder | A ghost follows the pointer and **the other rows don't move**. A 2 pt drop line (white 0.9) with an 8 pt ring at its start marks the gap. On drop the rows glide on row motion (41 pt in about 115 ms) | [M:ILO] |
| Haptics | Light haptics while dragging tabs, which can be turned off | [C:RN23] |

---

## 3. Spaces and Profiles

### 3.1 The model

- "Each Space has its own Pinned section, Unpinned section, Theme, and Icon" [C:H-Spaces].
- "Profiles allow you to scope Logins, Cookies, Browsing History, Archive timing, and other settings to one or multiple Spaces." A profile contains: **Archive settings; Authentication (logins, passwords, autofill); Browser History; Cache/Cookies; Default Browser Selection; Favorites; Extensions; Settings in arc://settings (Language, Download Preferences)** [C:H-Profiles].
- **One profile per Space** ("You can't have more than one profile in a space"); **many Spaces can share one profile** [C:MPU][C:H-Profiles].
- Deleting a Space keeps its profile, with its Favorites and sessions [C:MPU]. A profile can only be deleted once no Space uses it [C:H-Profiles].
- **Per-profile settings** live in Arc › Settings › Profiles: archive timing, default search engine, and the notes app for "New Note" [C:RN24][M:ILO]. The default profile can be renamed [C:RN24].
- **Sync:** Spaces and tabs sync. **Profiles, history, passwords, extensions and Favorites do not** [C:H-Profiles][C:RNW].
- **Boosts apply to all profiles** [C:H-Boosts].
- **Extensions: sources conflict.** The help centre lists Extensions as per-profile [C:H-Profiles]. A forum commenter (unverified) claims installing one adds it to every profile. Several users list "extensions per profile" as a feature to keep when leaving Arc. Recommendation: per-profile, Chromium's default [I].
- **Little Arc remembers the profile per domain** [C:RN23]. Air Traffic Control routes links to a Space, and therefore to its profile [C:H-ATC].

**[I] This fits the user's setup exactly.** One Google account per Space means **one profile per Space**, so each Space gets its own Favorites row: for example, Gmail and Calendar of *that* account.

### 3.2 Creating a profile: the exact UI paths

1. **From a Space** (help centre): hover the Space title → click **…** (macOS) or **Edit** (Windows) → hover **Profile** → pick an existing profile or **Create a new one**. "New profiles are empty containers without authentication or history" [C:H-Profiles]. Released in 2022: "Create a new Profile by clicking the [...] button next to your Space Title" [C:RN22].
2. **Arc 1.171 Space menu:** right-click the Space name or icon (or •••) → **Set Profile ›** → the profile list with the current one checked, then a new-profile entry [M:ILO]. Windows: "hover over your Space name > click Edit > Profile > New Profile…" [C:RNW].
3. **While creating a Space:** the 2023 "brand new Space Creation flow… profile selection" [C:RN23] shows a **Create a Space form inside the sidebar**:
   - an illustration, a title and a subtitle;
   - a **name field**;
   - two 200×36 rows: **Profile**, with a 22 pt pill showing the profile name and a chevron, and **Choose a Theme**;
   - **Create Space** (Arc blue #2129FB, 36 pt tall, radius 8, at 0.4 opacity until a name is typed) and **Cancel**.
   After Create, the form leaves bottom-up (each part fades and sinks over 150 ms, staggered 0/80/130 ms). Arc then plays its illustration for about 2 s before the Space appears [M:ILO].
4. **Menu bar:** Spaces › Change Profile; right-click a footer icon [C:MPU][M:ILO].
5. **Import:** "You can now import multiple Profiles from a previous browser at once during Onboarding" [C:RN23]; bookmarks can be imported into a specific profile (Windows) [C:RNW].
6. **Delete:** Arc › Settings › Profiles → choose a profile → **Delete Profile**. The button is disabled until the profile is removed from all Spaces [C:H-Profiles].
7. **Remove a profile from a Space:** Edit → Profile → Default [C:H-Profiles].

**Gap.** Whether "New Profile…" asks for a name inline or in a sheet, and its exact copy, are unrecorded. What happens to a Space's open tabs when its profile changes is undocumented. ilo only allows changing the profile of an empty Space; Dia warns that a moved tab loses its session [M:ILO].

### 3.3 Switching Spaces

| Method | Detail | Tag |
|---|---|---|
| Click | A footer icon or dot | [C:H-Spaces] |
| ⌃1 … ⌃9 | Go to Space N; remappable per Space | [C:H-Keys][C:RN23] |
| ⌥⌘← / ⌥⌘→ | Previous/next Space | [C:H-Keys] |
| Two-finger horizontal swipe **over the sidebar** | Pages Spaces. Over the page, the swipe stays back/forward | [C:H-Spaces]; sidebar-only [M:ILO] |
| Mouse buttons 4/5 over the sidebar | Previous/next Space | [C:RN22][C:RNW] |
| ⌘T + Space name | "Focus" the Space | [C:H-Spaces] |
| Library › Spaces / Space Manager | Manage and organize | [C:RN22] |

**What a switch restores:** each Space reopens on **the tab it last showed** [C:RN23][M:ILO].

**Swipe mechanics** [M:ILO]:
- The sidebar content pages horizontally: URL field, favorites and rows together. The footer and window buttons stay put.
- On release, if the release speed is at least 5 pt/s the target is the next Space in that direction; otherwise the nearest. One swipe moves at most one Space.
- The settle is **critically damped, about 0.19 s** (ω ≈ 33), starting at the finger speed. Arc 1.170 recordings give ω 30–33; Dia uses 0.25.
- Past the ends: rubber band, with the Library on the left and the new-Space pull on the right.
- Tracking ratio: ilo uses Dia's 0.5× horizontal delta; Arc's ratio is unrecorded.
- **Clicks and shortcuts** slide the new page in from its side on the same spring.

**Theme colour transition:** the whole window changes colour **at once, with no sweep**. To a neighbouring Space the change is exponential, **τ ≈ 30 ms**, well ahead of the slide. Longer jumps follow the slide. During a swipe the colour blends by how much of each page shows [M:ILO].

**Favorites on switch:**
- Same profile: the tiles don't move.
- Different profile: **the tiles swap at once** while the pages slide [M:ILO]. Arc for Windows fixed choppy rendering here: "Favorites will render much more smoothly in the Sidebar when swiping between Spaces associated with different Profiles" [C:RNW].
- Command Bar suggestions reset when switching between Spaces of different profiles, so nothing from the old profile leaks [C:RN24].

**Haptics:** the trackpad clicks at the create-Space threshold. Arc has a tab-reordering haptic but **none for normal Space swipes** [M:ILO-P][C:RN23].

### 3.4 Known pain points (to avoid or fix)

1. Profile switching through the menu took "multiple clicks" versus one click on a Space icon, and users found it "a little confusing how they've implemented it" [C:MPU].
2. Favorites belong to the profile, not the Space. Users who want different Favorites per Space must create a profile per Space [C:MPU]. (For this user that is already the plan [I].)
3. Profiles, Favorites, extensions and history never synced across devices [C:H-Profiles][C:RNW].
4. Windows had a run of profile bugs [C:RNW], all fixed:
   - Favorites removed in non-Default profiles;
   - all Spaces reassigned to Default;
   - Today tabs showing across profiles;
   - forced focus jumps to the first Space of the Default profile after a Command Bar pick.
   These show where the state model is fragile [I].
5. A Space's profile is not visible at a glance. Dia added a profile indicator next to the traffic lights, which suggests Arc lacked one [M:ILO] [I]. **[I] Recommendation:** show the account avatar or profile name on hover over the Space name, and tint the footer icon ring.
6. Moving a tab to a Space of another profile drops its session (Dia warns). Arc's behavior is undocumented [M:ILO].

---

## 4. Space theming

### 4.1 Picker UI (Arc 1.170, measured [M:ILO])

- **Entry points:**
  - the Create-Space form's "Choose a Theme" row;
  - Space menu → **Edit Theme Color…**. In 1.171 this opens a 382×534 panel with no arrow, 14 pt from the sidebar edge and the window top [M:ILO#1635];
  - ⌘T "Theme";
  - originally the hover paint-brush icon [C:RN22];
  - right-click empty sidebar → Theme [C:H-Spaces].
- **Card:** 357×509, radius 20, translucent grey. It grows from its arrow over about 310 ms with a small overshoot and shrinks back in about 110 ms.
- **Field:** a 340 pt square HSL disc. Hue is the angle (clockwise from the right), saturation is 1, and lightness grows from the centre (black) to the edge (white). Empty, it reads "Tap to pick a color for this space".
- **Handles:** the main colour is a 44 pt disc with a 3 pt white ring; others are 26 pt. Pressing grows a handle (48/28 in about 60 ms). Dragging the main handle moves all of them.
  - **Two colours:** the second is the complement (+180°).
  - **Three colours:** +150° and +210°, gliding over about 200 ms.
- **− / +** under the field: 1 to 3 colours.
- **Swatches (presets):** nine 24 pt discs: cream F0EAE5, pink E59EBA, purple 9E749B, red E1676F, orange EF8C63, yellow F2D46C, green 73E49B, blue 7EB6D5, slate 656786. Arc's swatch row also has `<` `>` paging.
- **Appearance:** three buttons: **Auto** (sparkles), **Light** (sun), **Dark** (moon). The help centre says this "applies to all of your Spaces" [C:H-Spaces]. **Conflict:** imported Arc themes can carry separate light and dark looks [M:ILO]. Treat appearance as global by default [I].
- **Intensity:** a "wave" slider (sine track, 7 periods). Default **0.81**. Dragging left washes the colour out.
- **Grain:** a dial of 24 dots. It starts at the top with no grain and turns clockwise [M:ILO]. "Intensity or Graininess" were added in 2022 [C:RN22].
- **Live:** every drag updates the window each frame. The picker has haptics [C:RN22].
- **Reset to default:** use **(−)** to deselect all colours [C:H-Theme].

### 4.2 Rendering model

- **Stored theme** (Arc's `StorableSidebar.json`):
  - `windowTheme.background.single._0.style.color._0` is either `blendedSingleColor{color, modifiers}` or `blendedGradient{baseColors[], overlayColors[], modifiers}`;
  - `modifiers.intensityFactor`, `modifiers.noiseFactor` and `modifiers.overlay` ∈ {grain, sand, denim, tweed};
  - `primaryColorPalette.midTone` is the accent;
  - up to 3 colours.
  [C:ZEN][C:PRIOR]
- **Shader** (read from Arc 1.167): colours 1 and 2 mix **in OKLab along a 45° diagonal**, reaching colour 2 at 75 %. A third colour fades in from top to bottom. Layer alpha = **0.2 + 0.55 × intensity**, over a white (light) or black (dark) underlay, over the macOS window blur. The texture multiplies in at noise × strength (four textures, strengths 0.8, 0.15, 0.6 and 0.4). **Inactive windows show the texture at ¼ strength, and the blur becomes opaque** [M:ILO].
- **Light colours:** with automatic appearance, Arc turned the window light, as one flat fill [M:ILO]. [S] matches this: a reference Space is a flat mint **#90DDC1**, the same at the top and bottom of the sidebar, and light-mode tokens apply (selected row white 0.85 with shadow; muted title text).
- **Derived palette:** Arc exposes the theme to pages and Boosts as CSS variables [C:COLORS]:
  - `--arc-palette-{foregroundPrimary, foregroundSecondary, foregroundTertiary, maxContrastColor, minContrastColor, backgroundExtra, background, focus, hover, cutoutColor, title, subtitle}`;
  - `--arc-background-simple-color`;
  - `--arc-background-gradient-color0..2` and `--arc-background-gradient-overlay-color0..2`.
  **[I]** Model the fork's theme the same way: theme → derived palette tokens → every surface (sidebar text, hover, focus ring, Command Bar, toasts, previews, menus). Arc says theme colours appear in "menus, fields, settings", the Command Bar, previews, toasts, the ⌃Tab switcher and the extensions menu [C:RN22][C:RN24].
- **Window chrome tinting:** the theme covers the **entire window**: sidebar, header and the margins around the card. With the optional toolbar on, the toolbar takes the page colour instead [C:RN23]. Little Arc's bar uses the Space colour [M:ILO]. Private windows are dark with an "Incognito" label in the sidebar only [C:RN23].
- **Dia's window material** (reference for layering): a blur behind the window, then a base tint (dark black 0.4 / light white 0.8), then the Space gradient (colour → lightness +0.25 down the window), then the content card [M:ILO].

### 4.3 Colour tokens (Arc 1.170 asset catalog, dark / light) [M:ILO]

| Token | Dark | Light |
|---|---|---|
| Tab hovered | P3 #FAFBFF 0.10 (*guess*) | P3 #0E0F10 0.05 |
| Tab pressed | #FAFBFF 0.065 | #0E0F10 0.065 |
| Tab selected | #FAFBFF 0.20 | white 0.85 + black 0.20 shadow |
| Multi-select (secondary) | #FAFBFF 0.10 | black 0.10 |
| Sidebar separator | white 0.15 | black 0.15 |
| Secondary text / header glyphs | white 0.60 | black 0.60 |

---

## 5. Related features: v1 or later

Ranking key: **v1** = needed to feel like Arc on day one; **v1.x** = soon after; **later** = nice to have. Behavior is cited; the ranking is mine [I].

| Feature | What Arc does | Rank |
|---|---|---|
| **Command Bar (⌘T / ⌘L)** | ⌘T creates no tab until a pick [M:ILO]. One centred panel 765 pt wide, its top 169 pt above the window middle, one-frame open and close, a 64 pt input row with "Search or Enter URL…" [M:ILO]. Lists open tabs ("Switch to Tab"), history, search and commands (type "/" or Tab for actions) [C:RN22][C:RN24]. The sidebar stays clickable while the bar is open [C:RN24]. ⌘T/⌘L again closes it [M:ILO] | **v1** (it *is* Arc's new tab) |
| **Copy URL ⇧⌘C** | Toast "Copied Current URL"; ⌥⇧⌘C copies as Markdown; ⌃⇧⌘C as a quote; works on Peek too [C:H-Keys][M:ILO][C:RN23] | **v1** (trivial) |
| **Tab search** | Arc has no dedicated Search Tabs; the Command Bar's "Switch to Tab" rows do the job [M:ILO] | **v1** via the Command Bar |
| **Archive auto-clean + Library › Archived Tabs** | 12 h default, per profile; searchable; restore returns the tab to its original Space; Clear Archive asks to confirm [C:H-Archive][C:RN23] | **v1** |
| **Library** | Bottom-left; sections Media, Downloads, Easels & Notes, Spaces, Archived Tabs; hover shows recent files [C:H-Library]. Slides in from the left, 417 pt wide, pushing the card (spring 0.245 s, ζ 0.92) [M:ILO] | **v1** (Archive + Downloads + Spaces); **later** (Media, Easels) |
| **Peek** | Cross-site links from Pinned/Favorite tabs open in an overlay. ⌘O promotes it to a tab; the Split button makes a split; close by clicking outside, ✕ or ⌘W; ⌘Z/⇧⌘T reopen; turn off in Settings › Links; ⇧-click opens any link in Peek; meeting links skip Peek [C:H-Peek][C:RN23] | **v1.x** (without it, pinned "apps" navigate away; ship a fallback that opens a Today tab) |
| **Air Traffic Control** | Rules "URL contains" or "is equal to" → Space; a default for links from other apps (Little Arc or Most Recent Space); routes Peek links too [C:H-ATC][C:RN24] | **v1.x**, high value for this user: one Google account per Space means Slack/Mail links must land in the right *profile* [I] |
| **Split View** | Drag a tab onto a tab, ⌃⇧+ / "+" menu; horizontal or vertical; up to 4 panes; the split is one sidebar row; Separate All Tabs [C:H-Split][C:RN24] | **later** (Chromium has a native split view to reuse [I]) |
| **Little Arc** | ⌥⌘N; a mini window for links from other apps; "Open In" → ⌘O to the recent Space, ⌥⌘O to choose; auto-archives after 6 h; remembers the profile per domain [C:H-LittleArc][C:RN23] | **later** |
| **Boosts** | Per-domain CSS/JS and a no-code editor; apply to all profiles [C:H-Boosts] | **later / skip** |
| **Previews / Live Calendar / media tray** | See §2.3 and §2.9 | Media tray **v1.x**; previews **later** |
| **Developer Mode** | Automatic on localhost; full URL; yellow/black focus outline; ⌃D [C:H-DevMode][C:RN23] | **v1.x** (the user has localhost pins [S]) |
| **⌃Tab** | Shows the last-used tab at once, with no switcher UI (Arc 1.170) [M:ILO]. Help: "five most recent tabs" [C:H-SwitchTabs] | **v1** |
| **Onboarding** | See §5.1 | **v1** (the user asked for it) |

### 5.1 Arc's onboarding (for the user's "Arc-like onboarding")

- **Sequence** (timestamped recording of the macOS flow) [C:PF]:
  1. splash;
  2. start screen;
  3. sign up, privacy policy, sign up;
  4. **Welcome**;
  5. **Import data**, then **Select folders**;
  6. **Select color**;
  7. **Select favorites**;
  8. connect integration, integration connected;
  9. **enable ad blocker**;
  10. **set as default**;
  11. success;
  12. **Welcome guide** (new tab, guide video, welcome guide);
  13. **Create menu**;
  14. browser.
- **Feel:** "the outside screen fading to black, an illuminating sphere visual, and a sound effect". A **member card** at the end "does nothing" but makes you feel part of something; the card's title reflects your choices (e.g. "Methodical Guest" when you skip setting Arc as default) [C:HTG]. Arc's intro is a scored film of about 20 s [M:ILO].
- Arc suggests Favorites and Pinned Tabs from imported history [C:RN23]. Multiple profiles can be imported at once [C:RN23]. Import covers Chrome, Safari, Firefox, Brave, Edge, Opera, Opera GX and Vivaldi; imported bookmarks become Pinned Tabs [C:H-Import]. Dark mode is supported in sign-up [C:RN23].
- **[I] For this fork:**
  1. Import Arc's `StorableSidebar.json`, mapping each Arc profile to a Chromium profile, with Spaces, emoji, themes, pinned trees and per-profile Favorites.
  2. Pick a colour for the first Space using the same picker.
  3. Sign in a Google account per Space or profile.
  4. Teach ⌘T / ⌘S / ⌃1–9 / swipe in the place each is used.
  5. Make it the default browser.
  Skip the account wall.

---

## 6. Motion and feel

### 6.1 Measured motion table (Arc 1.170/1.171 at 120 fps unless noted) [M:ILO]

Springs are given as response / damping ratio ζ (mass 1).

| Motion | Value |
|---|---|
| Row hover | **1 frame** in and out. Only the selected row eases from hover back to selected over about 170 ms |
| Row motion (rows opening, closing, reordering) | Spring 0.13 s / ζ 0.9 (≈ CSS ease 115–120 ms); within 0.75 pt of rest after 83–92 ms. A closed row fades while the rows below slide over it |
| Opening a tab | The new row appears in its slot, already selected; its plate fades in; the rows below slide down one pitch |
| Row press | The plate shrinks to 0.99 over 70 ms, linear; the tab activates on press |
| Favorites making room | Critically damped, ω ≈ 25 rad/s; settled in about 240 ms |
| Folder open / close | Ease-out cubic-bezier(0,0,0.58,1) over 200 ms / critically damped ω ≈ 25, about 240 ms |
| Folder preview | 0.45 s delay, about 90 ms in, about 80 ms out |
| Sidebar hide / show (⌘S) | Ease-out cubic, 110 ms / 100 ms |
| Sidebar edge reveal in / out | Spring 0.175 s ζ 0.80, starting about 100 ms after the pointer arrives / spring 0.175 s ζ 0.76 |
| Space settle | Critically damped, 0.19 s (ω ≈ 33), from finger lift |
| Space colour | The whole window; τ ≈ 30 ms to a neighbour |
| Library push | Spring 0.245 s / ζ 0.92; the sidebar recedes (scale 1 − 0.076p, gone by 48 %) |
| List scroll-to-row | 0.22 s, mostly in the first frame |
| Scroll edge lines | Fade over 0.2–0.3 s |
| Tooltip | Appears 1.6 s after the pointer stops; 1 frame in; about 270 ms ease-out out |
| Toast | In: from 0.7 scale, spring 0.32 s / ζ 0.52 (peaks at 1.04), fading over 100 ms. Out: 70 ms ease-in |
| Dialog | Drops 32 pt over 275 ms ease-in-out; opaque after 135 ms |
| Icon picker | Grows from its arrow tip (about 1 − e^(−t/60 ms)); out in 1 frame; tab slide 200 ms ease-out |
| New-Space pull ready | White closes over 60 ms; pop to 1.13× and back over 120 ms; haptic click |
| Command Bar open / close | **1 frame** |
| ⌃Tab | 1 frame, no switcher |

### 6.2 Why it feels smooth (reviewers, release notes, and ilo's reading of the recordings)

- **Physics under the fingers, fixed short curves for keys and clicks.** Gestures hand their velocity to a spring; keys use 100–275 ms curves [M:ILO-P].
- **Readable at once, settled later.** Content is legible and interactive within about 130 ms even while motion continues [M:ILO-P].
- **Instant hot paths.** A press activates before release; hover takes 1 frame; the Command Bar opens in 1 frame; Clear has no toast [M:ILO-P][M:ILO].
- **Delight only on rare paths:** the Space-creation illustration, the onboarding film, music-note animation, the pull-to-create glow [M:ILO-P][C:RN22][C:HTG].
- **Haptics only at thresholds:** tab reorder (can be turned off) [C:RN23]; theme picker [C:RN22]; the pull-to-create detent [M:ILO].
- **Nothing reflows under a drag:** the other rows hold still and a drop line shows the result [M:ILO].
- Release notes repeatedly ship "speed and animation improvements" to the sidebar, button and tab animations, and drag flicker fixes [C:RN22][C:RN23]. Reviewers praise the "subtle animations and rounded corners" and say the polish is strongest on Mac. Some flag lag on low-end hardware (secondary sources). A growth analysis: "small animations… add a nice polish to everything" [C:HTG].

### 6.3 Density, spacing, typography

- **Text:** the system font (SF). Tab titles 14 pt; URL field 13 pt; Clear label about 10 pt semibold; Command Bar input about 18 pt; tooltips 12 pt semibold [M:ILO]. Monospace was replaced with the system font in 2022 [C:RN22].
- **Spacing grid:** an 8 pt side inset everywhere (rows, URL field, tiles); 41 pt row pitch; 36 pt plates; corner radius 12 on rows and fields, 10 on tiles, 6 on buttons and the card [M:ILO].
- Reference screenshots match the 41 pt pitch and 47 pt tiles [S].

---

## 7. Keyboard shortcuts (macOS)

| Action | Arc key | Tag | Chrome default conflict [I] |
|---|---|---|---|
| New tab (Command Bar) | ⌘T | [C:H-Keys] | Same key, new semantics |
| Edit URL (Command Bar on current URL) | ⌘L | [C:H-Keys] | — |
| New window / incognito / blank window | ⌘N / ⇧⌘N / ⌃⌘N | [C:H-Keys][M:ILO] | ⌃⌘N is free |
| Close tab ("Archive Tab") / window | ⌘W / ⇧⌘W | [M:ILO] | — |
| Reopen closed tab (also Peek) | ⇧⌘T (⌘Z too) | [C:H-Keys][C:RN23] | — |
| Pin / unpin | ⌘D | [C:H-Keys] | Chrome: bookmark |
| Show/hide sidebar | ⌘S | [C:H-Keys] | Chrome: Save Page (Arc moves it to ⇧⌘S) |
| Clear Today | ⇧⌘K | [C:H-Keys] | — |
| Copy URL / as Markdown / as Quote | ⇧⌘C / ⌥⇧⌘C / ⌃⇧⌘C | [C:H-Keys][M:ILO] | DevTools inspect uses ⌥⌘C, so no clash |
| Paste URL as new tab | ⌥⌘V | [M:ILO] | — |
| Go to Space N | ⌃1–⌃9 (remappable) | [C:H-Keys] | macOS "Switch to Desktop N" uses ⌃N *if enabled* in System Settings [I] |
| Previous / next Space | ⌥⌘← / ⌥⌘→ | [C:H-Keys] | Chrome: previous/next tab |
| Previous / next tab (sidebar order) | ⌥⌘↑ / ⌥⌘↓ (also ⌘{ ⌘}) | [C:H-Keys][M:ILO] | Chrome: toolbar focus cycling |
| Go to sidebar item N / last | ⌘1–⌘8 / ⌘9 (Favorites first; configurable) | [C:H-Keys][C:RN22] | Same key, sidebar order |
| Recent tab | ⌃Tab | [C:H-Keys] | Chrome: next tab |
| Focus sidebar for arrow-key navigation | ⌘. (2021) | [C:RN21] | Conflicts with Stop; later versions moved it. Treat as unconfirmed |
| Reveal current tab | ⌃Space (Arc default) | [M:ILO] | macOS input-source switch |
| Library | ⇧⌘L | [M:ILO] | — |
| Little Arc / open in main window / move to Space | ⌥⌘N / ⌘O / ⌥⌘O; ⇧⌘O in Little Arc | [C:H-LittleArc][M:ILO] | Chrome ⌥⌘N: split view |
| Split add / close / focus | ⌃⇧+ / ⌃⇧− / ⌃⇧1–4 | [C:H-Keys] (the split article says ⌘⇧+, a conflict) | — |
| Show/hide toolbar | ⇧⌘D | [M:ILO]; [help: full URL](https://web.archive.org/web/2024/https://resources.arc.net/hc/en-us/articles/25625458052247-How-Do-You-View-the-Full-URL-at-the-Top-of-the-Page-in-Arc-for-Desktop) | Chrome: bookmark all |
| Developer Mode | ⌃D | [C:RN23] | — |
| Join meeting (Live Calendar) | ⌃⌘J | [C:RN24] | — |
| Capture | ⇧⌘2 | [C:RN24] | — |
| New note | ⌃⇧N | [M:ILO] | — |
| Remove a Command Bar suggestion | ⌥⌘⌫ | [M:ILO] | — |
| Extensions | ⌘E | [M:ILO] | — |
| History | ⌘Y | [C:H-Keys] | — |
| Full screen | ⌃⌘F; ESC prefers the website (hold or double-press to exit) | [M:ILO][C:RN23] | — |

**Shortcut rules:**
- Every shortcut can be remapped in Settings › Shortcuts [C:H-CustomKeys].
- Each command has a "Prefer Websites" / "Prefer Arc" setting; **pressing a key the page consumed again within about 1 s runs Arc's command** [M:ILO]. The ESC priority can be remapped [C:RN23].
- Custom Space-switching shortcuts persist across restarts (after bug fixes) [C:RN23].
- Help › Essential Keyboard Shortcuts shows five: ⌘T, ⌃Tab, ⇧⌘C, ⌃⇧=, ⌥⌘N [M:ILO].

---

## 8. What a reference screenshot confirms [S]

- **Theme:** a flat mint Space (#90DDC1) in light appearance shows no visible gradient. Text and glyphs use dark tokens. The selected Today row is near-white (#EAF3F0) with a soft shadow.
- **Top:**
  - sidebar toggle glyph at top left (no traffic lights in the crop, so likely full screen or cropped);
  - 2 Favorites as two wide 47 pt tiles: Gmail with a red unread dot, Calendar with the date favicon;
  - the Space name row (emoji + name) in muted bold.
- **Pinned:** a mix of tabs (one with a plain square where there is no favicon), a folder with a bold title, and a renamed localhost pin with the grey host line underneath (renamed or Dev-Mode pin).
- **Then:** the divider, "+ New Tab" (muted) and Today tabs, the selected one highlighted, a playing tab with a speaker icon.
- **Footer:** the update pill "New Arc Version Available"; the bar holds the Library icon (archive box), 6 Space icons (one with no icon shows a dot) and "+".
- **Implication:** with **6 Spaces** at the full 34 pt per cell, the bar would need 204 pt. At the default 228 pt width the span between Library and "+" is only about 144 pt (x 42 → 186) [M:ILO], so **the cells shrink to about 24 pt each** (§2.9). That is still above the 22 pt floor, so every icon stays readable. Sidebars wider than 228 pt are common, so measure the actual width during import [I].

---

## 9. What this changes for a Chromium fork

1. **One window must show Spaces from different profiles and swipe between them live.** Arc does this: Windows release notes fix "Today tabs would appear across multiple Profiles when switching Spaces" and smooth "Favorites… when swiping between Spaces associated with different Profiles" [C:RNW]. Chromium's `TabStripModel` and `Browser` are constructed with a single `Profile*` [C:CR-TSM]. **[I] Do not build on Chrome's Browser/TabStrip UI.** Build a custom window whose sidebar model owns `WebContents` from many `Profile`s (BrowserContexts) and swaps the content view on Space switch. Arc itself is a native app over Chromium.
2. **Rule out the "one window per profile" shortcut.** The user lives in macOS full screen, where every NSWindow is its own macOS Space. Swapping windows per profile would trigger desktop-switch animations and break the 0.19 s in-window swipe [I].
3. **The sidebar is a persistent model, not the tab strip.**
   - Per profile: Favorites (≤ 12, saved URL, custom title and icon, badge toggle).
   - Per Space: pinned tree (folders, nesting, saved URL vs current URL, custom names), Today list, last-selected tab, theme, icon, profile id.
   - Per window: width, hidden state, collapse states.
   - Per profile: Archive store with timestamps and origin Space.
   Tabs bind lazily to `WebContents`, and closing a pinned item or Favorite only unloads it [C:H-Pinned][M:ILO][C:PRIOR].
4. **Dynamic, whole-window theming per Space**, including blur material, texture and a derived palette applied to sidebar, menus, Command Bar and toasts. Chrome themes are static per profile, so this must be custom UI, not `ThemeService` [C:PRIOR][I].
5. **Extension UI must follow the Space's profile:** pinned extension icons in the URL field, extension popups and the Extensions menu all swap on Space switch [M:ILO].
6. **Keyboard:** override Chrome accelerators (⌘S, ⌘D, ⌥⌘arrows, ⌘1–9 in sidebar order, ⌘T → Command Bar, ⌃Tab → last tab). Implement Prefer-Websites with the second-press rule [M:ILO].
7. **Trackpad:**
   - horizontal two-finger swipes over the sidebar go to the Space pager, using NSEvent scroll phases and momentum, with velocity handed to a spring;
   - over web content they keep history navigation;
   - mouse buttons 4/5 over the sidebar switch Spaces;
   - haptics come from `NSHapticFeedbackManager` [I].
8. **Hidden-sidebar reveal** needs window-level mouse tracking on the left edge, key-window only, with an overlay panel (child window) above the web content view [M:ILO].
9. **Multi-window:** every window shows the same Spaces and tabs; a tab's live page is in one window at a time [C:H-SameTabs][M:ILO].
10. **Link routing** from other apps (the default-browser handler) must pick the Space, and so the profile, by rule. This is the single most valuable fix for juggling Google accounts [C:H-ATC][I].

---

## 10. Gaps and open questions

- **Not measured anywhere:**
  - Favorites first-row top (90 vs 82 pt);
  - the unread-dot size and colour;
  - the exact "+" menu contents and order;
  - the Space-swipe tracking ratio;
  - pinned-tab auto-unload timing (Arc only documents that Favorites load "if used recently");
  - the profile indicator, if any;
  - the "New Profile…" dialog;
  - what happens to open tabs when a Space's profile changes;
  - Arc's own appearance (light/dark) scope: global per the help centre, but themes can carry two looks.
- **Rename:** whether a click on the Space name renames (2023) or folds the pinned section (1.171). Build the latter and offer rename on double-click? The double-click mapping is unconfirmed.
- **Extensions per profile:** official help says yes; a forum claim says installs are shared.
- **ilo's measurements** come from one owner's machine (Arc 1.170/1.171, mostly dark theme) and an outside reverse-engineering document that is not public. Light-mode values are asset-catalog tokens, not captures.
- **Peek's look and timing, Little Arc's window metrics and Air Traffic Control's UI** are unrecorded.
- If the team wants ground truth, **record Arc on the user's own MacBook before 2026-12-22**:
  - light theme, 6 Spaces, footer squeeze;
  - Space swipe across profiles;
  - Favorites swap;
  - Create-Space form with the Profile row;
  - Edit Theme Color.

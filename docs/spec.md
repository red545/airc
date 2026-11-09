# Airc: v1 spec

Airc is an Arc-style browser for macOS on Chromium. Built and maintained by AI.

Date: 2026-11-03, scope reconciled 2026-11-07. Status: implemented product with remaining acceptance work (§6). D1–D9 decided (D6 revised, D8–D9 added 2026-11-06); see section 1.

This spec is built on research notes in `research/`. Each requirement links to the note that has the measurements, sources and code paths:

| Note | Covers |
|---|---|
| [arc_behavior_spec.md](research/arc_behavior_spec.md) | Arc's exact sidebar, Spaces, Profiles, theming, motion and shortcuts, with point sizes and timings |
| [chromium_profiles.md](research/chromium_profiles.md) | How to give each Space its own logins inside Chromium |
| [fork_base_and_architecture.md](research/fork_base_and_architecture.md) | What to fork, how to keep the patches small, UI technology |
| [dev_env_build_release.md](research/dev_env_build_release.md) | Build machines, remote viewing, tests, signing, auto-update, the agent rebase loop, costs |
| [onboarding_and_import.md](research/onboarding_and_import.md) | Arc's onboarding, the proposed onboarding, importing from Arc and Chrome |
| [t3code_and_accounts.md](research/t3code_and_accounts.md) | What to copy from T3 Code, and the account and sync plan |
| arc_app_inspection.md (kept out of the public repo) | What's inside the Arc 1.171 app: engine, profile architecture, UI copy and flows |

The earlier Chrome extension prototype is also an input: the Chrome extension (a separate prototype, not in this repo). Its data model, Arc importer (`src/shared/arcImport.ts`) and tests carry over.

---

## 0. Summary

**What v1 is.** A Chromium-based browser for macOS (Apple silicon) that the owner uses fullscreen every day instead of Arc:
- The sidebar works like Arc 1.171: Favorites, Space header, pinned items with nested folders, Today tabs, and the Space bar at the bottom.
- Every Space is bound to a **profile**. A profile carries its own logins, so each Space can be signed into a different Google account. Switching Spaces switches the account instantly, in the same window, in fullscreen.
- Creating a profile takes one step from the sidebar.
- An Arc-like onboarding imports everything from Arc, including logins, in under 2 minutes.
- No account is needed. An optional account comes later, the way T3 Code does it.
- An AI agent keeps it on current Chrome security releases.

**The key technical choice (revised after inspecting Arc.app, section 0.1).** Copy Arc's own architecture:
- Each profile is a **real Chromium profile**, with its own logins, history, saved passwords and extensions. All profiles stay loaded.
- A **native macOS app owns the window and the sidebar**, like Arc's Swift app. Chrome itself runs as an engine framework inside it.
- **Each window holds one Chromium browser per profile.** Switching Space attaches that profile's page view to the window, so the switch is instant and stays in one fullscreen window.
- An open-source implementation of this pattern exists: **ArdiaCore**, Apache-2.0, about 18k lines. We port it onto upstream Chromium.

The first draft proposed containers. That alternative is superseded: real Chromium profiles are implemented (D1).

**Current scope.** The native app and engine now exist. Section 6 separates built features from parity and release qualification work; the original 10–12 week estimate is superseded. Section 9 retains the migration fallback.

### 0.1 What Arc itself does (observed behaviour)

Observed from using Arc 1.171: its About and settings pages, its data folder and its behaviour, plus Arc's public help centre.

- **Engine:** `ArcCore.framework` is Chromium **156.0.8078.74** built from Chrome's full `//chrome` code, with Arc's own layer replacing only the browser window. The app around it is Swift.
- **Profiles:** each Arc profile is a full Chromium profile in its own `User Data/<dir>` folder, and switching between Spaces of different profiles is instant, so they all stay loaded. Airc models this as one Chromium browser per (window, profile).
- **Profiles are fully separate:** Arc describes each profile as keeping its own history, saved passwords, extensions and other browsing data.
- **A tab can't change profile.** Changing a Space's profile keeps the sidebar items and reloads the tabs in the new profile, after a confirm dialog with "Don't ask again".
- **Extensions, ad blocking and archive timing are per profile.** Favorites are stored per profile.
- **Pinned tabs unload on a timer:** frozen, then discarded, with Gmail, Slack and similar sites exempt. Airc: MEM-3's
  exemption list (AircKit `KeepLoadedSites`).
- **The flows** for New Profile, Create a Space, profile deletion and onboarding are described in section 2.9, in Airc's own words.

**ArdiaCore** (in the Ardia repo, `engine/ardiacore/src/ardia/core/`) does the same thing as an open-source layer:
- It links into Chrome's own framework.
- It gives each profile a Chromium `Browser` whose window is a plain object with no Chrome UI.
- It re-hosts the Chrome UI that normally hangs off the window: permission prompts, autofill and passkey UI, extension popups, the find bar, DevTools and choosers.
- Ardia's own files are **Apache-2.0**, so we can port them with their notices.
- Its code includes only Chromium's own headers. The one file that mentions Helium (`ac_strings.cc`) holds product-name strings, but it was built and tested on a Helium tree. The upstream port is now implemented in `engine/core`; ongoing compatibility is covered by the rebase process.

---

## 1. Accepted decisions

| # | Decision | Recommendation | Why | Alternative |
|---|---|---|---|---|
| D1 | What a "profile" separates | **Real Chromium profiles, Arc's way** (revised): logins, history, saved passwords and extensions separate per profile. All profiles loaded; one Chromium browser per (window, profile) inside our own window. | Exactly what Arc does and promises. One window, so fullscreen and instant switching work. ArdiaCore (Apache-2.0) is an open-source implementation to port. | **Containers** (separate cookie jars in one profile; Brave and Flecha). Simpler, but history, passwords and extensions are shared. Historical fallback, superseded by the implemented upstream port. |
| D2 | Base | **Upstream Chromium Extended Stable tags** built as Chrome's own framework, plus our engine layer `//airc/core` (ArdiaCore port) and a short hook series (about 15–25 patches). | No dependency lag, permissive licence, smallest rebase surface for the agent. Extended Stable means about 6 major rebases a year instead of 26, with weekly security fixes in between. | Fork Ardia whole (GPL-3.0, Helium-based, React Native shell, Dia-styled). Fork Flecha (MIT, trunk Chromium, containers). Fork Brave (containers, big product to strip). |
| D3 | UI technology | **All Swift (decided 2026-11-04).** AppKit for the window, sidebar, Space switching, gestures and animations (Core Animation springs); SwiftUI for onboarding, settings and the Space and profile editors. No web-rendered UI. | Matches Arc, smoothest 120 Hz motion, one language for the whole app, and the agent can build and test it on the Mac in minutes. | React screens in a hidden profile (Arc's way; the previous plan). |
| D4 | Licence | **Open source, Apache-2.0** (decided 2026-11-04) for the whole repo, including the homepage. Ported ArdiaCore files keep their Apache-2.0 notices; anything copied from Flecha (MIT), ungoogled-chromium (BSD) or T3 Code (MIT) keeps its notice in NOTICE. GPL code (Helium, ilo, Ardia's Helium patches) is read for ideas only. Secrets (signing certificates, Sparkle key, deploy tokens) never go in the repo. | Same model as T3 Code: everything public, keys in CI secrets. | GPL-3.0 would allow building on Helium or Ardia. |
| D5 | Build host | **Dedicated build Mac** (revised 2026-11-09), reached as `buildmac`. All new builds and tests run there; the owner's laptop stays idle and receives signed feed updates. | Build and UI work do not interrupt the owner's laptop. | Automation and publication stay held until the new host passes a dry ship. |
| D6 | Netflix, Spotify and other DRM | **Revised 2026-11-06: DRM is wanted** (the owner: Spotify must play). Implemented: Widevine through Chromium’s component download and, for listed streaming services, per-profile WebKit/FairPlay pages (on by default). See [protected media](user/protected-media.md) and [DRM notes](../engine/DRM.md). | Public builds may need Google's Widevine licence; services that require VMP (Netflix) may need extra signing. | Owner decides the licence step before public launch. |
| D7 | Native macOS fullscreen | **Keep native fullscreen.** All profiles share one window, so there is no problem. | | |
| D8 | App identifier | **`com.aircbrowser.Airc` for public builds** (owner, 2026-11-06). The private dev channel stays `org.airc.Airc.dev`; dev and test builds are `org.airc.Airc.test` (WebKit `.test.webkit`) so they never claim the owner's links or permissions. | Permanent from the first public install. | |
| D9 | Product analytics | **On by default, opt-out**, like T3 Code (owner, 2026-11-06): anonymous PostHog EU events, never content; Settings → Privacy, docs/user/telemetry.md. | Needs a privacy page on the homepage at launch. | |

---

## 2. Product spec (v1)

Requirement IDs (`SB-…`, `SP-…`) are for tracking and tests. "Arc ref" points to sections of [arc_behavior_spec.md](research/arc_behavior_spec.md). Point sizes, timings and colours there are measured from Arc 1.170/1.171 and are the default targets.

### 2.1 Window and layout (Arc ref §1)

- **WIN-1** The whole window takes the active Space's theme: sidebar, title area and a 10 pt margin. The web page sits in a card inset 10 pt with 6 pt corners.
- **WIN-2** No tab strip and no toolbar row. The traffic lights, sidebar toggle, back/forward/reload and the URL field live in the sidebar header.
- **WIN-2b** (W07, Arc 2023) The window drags from the top of the page, as from a title bar. The strip is the page's part of the window's title-bar band: about 18 pt under the 10 pt margin. Arc doesn't document its height; this one ends where a standard title bar would.
  - A press that moves drags the window, and the page never sees it.
  - A click goes to the page (links, buttons, fields); a window that isn't key only becomes key, as for any page click.
  - A double-click does the system's "Double-click a window's title bar" action (Zoom or Fill: zoom; Minimize; Do Nothing).
  - With ⌘ held the page has the press (Arc's opt-out). Right and middle presses, scrolling, hovering and drops always reach the page.
  - Off with Arc's "Allow window dragging from the top of webpages" setting off (on by default), with the toolbar shown, and in full screen. Split panes have it too, beside their handles.
  - The margin and the sidebar's empty top area drag the window as before (Browser/PageDrag.swift).
- **WIN-3** **Clarified 2026-11-07:** native macOS fullscreen keeps the sidebar docked (unless hidden with ⌘S) and the page card inset. At rest, traffic lights are out of sight and the sidebar toggle moves to the far left, matching [Arc research §1](research/arc_behavior_spec.md#1-window-anatomy-and-geometry). This is a visual layout rule, not a requirement to set the buttons’ `isHidden` property: Airc keeps the native buttons available in AppKit’s titlebar when the menu bar is revealed, moving the toggle aside while it shows. `Debug/EventTests.swift` checks that availability and both toggle positions, not onscreen visibility at rest. The research labels notch handling as an inference and does not measure the revealed titlebar; verify both states on a notched display before claiming exact parity (§6 Next).
- **WIN-4** Sidebar width defaults to 228 pt (164–500). Drag the edge to resize; dragging past the minimum hides it; double-click the edge to reset.
- **WIN-5** Sidebar on the left by default, with an option for the right (Arc never had one): Settings → Appearance → "Sidebar position: Left / Right", one setting for every window, applied live (a short cross-fade). On the right every left-edge rule is mirrored: the page card's insets, ⌘S's slide, the hover reveal from the window's right edge (floating, 5 pt in), resizing from the sidebar's inner edge (the width is kept as before), the Library sliding in from the right with its back button on the footer's Library button, tab, folder and Live Calendar cards to the left of the sidebar, ⌘L's bar growing left from the URL field, the downloads card and update question on the sidebar's right inset (the page's bottom-right with the sidebar hidden). A drag at the sidebar's left edge still pages to the previous Space and at its right edge to the next, and swipes keep their direction. The traffic lights stay at the window's top left, over the page, and the header's toggle starts the row (as in full screen). Private windows and Little Arc keep their own layouts; picture in picture is the engine's own window and doesn't depend on the sidebar.
- **WIN-6** Kill switches per feature, so a feature broken by a rebase can be switched off and a security update is never held back.
- **WIN-7 Several windows** (⌘N, Arc's model, research §9.9 and its "reparented content" placeholders): every window shows the same Spaces, Favorites, pinned and Today tabs, and keeps its own Space, tab per Space and sidebar width. ⌘N opens one on the current Space, cascaded, with the Command Bar open as ⌘T. A tab's live page is in one window at a time: picking a tab another window shows (a row, ⌘1–9, ⌥⌘↑↓, ⌃Tab, the Command Bar, Back to Tab) moves its page there without a reload, and the other window keeps the row selected with "Open in another window" (Show Here, Go to Window) in its card; that window takes the page back by itself when it becomes key and the page is no longer on screen elsewhere. A Space switch, a swipe, a closed tab's neighbour and session restore never take a page another window shows. Commands act on the key window (⌘T ⌘L ⌘W ⌘F, ⇧⌘W, Space switching, splits, Peek, Site Controls, the Boost editor, the Library); the downloads card and the media tray's actions follow the window used last; links from other apps go to Little Arc or, with "Most recent Space", to the window used last. Closing the last window leaves Airc running: ⌘N, the Dock icon or a link brings it back as it was. Relaunch restores every window (frame, Space, tab, sidebar width, the one used last in front); the quit asks nothing new. A tab's Move to New Window and a Space's Open in New Window open one directly. **Dragging a tab out** of the sidebar (SB-35, either side) and dropping it where no Airc window is moves its page, live, to a new window of the same size at the drop point (the pressed row under the pointer), on the macOS Space the person is on; dropped on another browser window it moves there (on its sidebar, to the row the drop line marks; on its page, onto that window's Space), and that window comes to the front; the window it left goes back to the tab it showed before the press, else its next free tab. A pinned tab, a Favorite or a split can leave too; folders can't, and a multi-selection (SB-36) goes only onto another window's sidebar. **⌃⌘N** opens Arc's blank window (research §6: "blank windows are separate"; the sources say only that its tabs don't sync with other windows and its sidebar starts empty): a window on a Space of its own, unlisted (`Space.blankWindow`: no Space bar icon elsewhere, no Command Bar, Library or Manage Spaces entry), with the key window's profile and theme and the Command Bar open. Its Today tabs and pinned items are its own; it shows the profile's Favorites; it pages through its own Space only; picking one of its tabs in another window shows it in the blank window, and a listed Space's tab picked in it shows in an ordinary window. ⌘N there opens an ordinary window. Closing it deletes its Space and sends its Today tabs to the Archive; the quit keeps it, and it comes back after a relaunch. **Titles:** each window's title is its Space's name and its page's title ("Work — GitHub"; the Space's name alone with no page), so the Window menu, Mission Control and ⌘` tell windows apart. No telemetry.

### 2.2 Sidebar header and URL field (Arc ref §2.1–2.2)

- **DEV-1 Developer Mode** (2026-11-07; Arc parity 2026-11-08, [user guide](user/devmode.md)): Arc's Dev Tabs, per
  site. A site is a host (AircKit `DeveloperSitePolicy`, Arc's `enabledHosts` / `disabledDefaultHosts`): localhost, its
  subdomains and the loopback addresses are on by themselves (Settings → General → "Turn on automatically for
  localhost", on as in Arc); any other site is turned on in Site Controls' Developer Mode row, with ⌃D (Arc's key) or
  the Command Bar, and stays on in every tab, Space, window and profile; an automatic host turned off is remembered.
  A tab in it shows its full URL (no credentials) in the URL field, a 26 pt strip with Inspect, Network (Chromium),
  Hard Reload (its menu and the Command Bar: Clear data for <domain> and its subdomains and reload, this profile only)
  and a top-frame console.error count that opens the Console, each selecting its panel in an open inspector, which
  keeps its state (the engines' developer commands), and Arc's outline on its selected row or Favorite tile (yellow
  on dark themes, near-black on light); its rows keep the site's favicon. Private windows never use it. The page
  script only reports each
  top-frame document; Airc decides per document (origin and frame checked, never a private page) and only then
  installs the counter, a native-forwarding Proxy with an ignore-list source map, so console call sites stay the
  page's with the inspector closed or open. No site able to be on: no page script part at all. Counts are ephemeral,
  reset per document and never include message text; errors in a document's first milliseconds, before Airc answers
  it, aren't counted. Only the toggles emit telemetry (`developer_mode.toggle` on/off).
  Arc research: [behaviour notes §2.2 and §6](research/arc_behavior_spec.md),
  [2022 release notes](https://resources.arc.net/hc/en-us/articles/20498417809815-Arc-for-macOS-2022-Release-Notes)
  (v0.79 Dev Tabs: "turned on automatically for localhost or manually for any site"; v0.80 subdomains of localhost),
  [2023 release notes](https://resources.arc.net/hc/en-us/articles/20498377604887-Arc-for-macOS-2023-Release-Notes)
  (v1.2 ⌃D; v1.9 Favorites get the styling; v1.10 Site Control Center toggle).

- **SB-1** Header row: sidebar toggle, back, forward, reload (32×32 hover plates). Long-press or right-click on back/forward shows history. ⌘-click opens in a background tab.
- **SB-2** URL field: shows the host only, 36 pt tall. Clicking opens the Command Bar over the field. On hover: Copy URL and Site Controls buttons.
- **SB-3** Chrome's permission prompts, password, autofill and passkey UI, and extension popups appear in our window, anchored to the sidebar header (re-hosted by the engine layer, as ArdiaCore does).
- **SB-4** Pinned extension icons show in the URL field on hover. A puzzle button opens the extensions menu (⌘E).

### 2.3 Favorites (Arc ref §2.3)

- **SB-10** Favorites belong to the **profile**, not the Space, up to 12. Two Spaces with the same profile show the same tiles; switching to a Space with another profile swaps the tiles instantly.
- **SB-11** Grid: 47 pt tall tiles, 8 pt gap, up to 4 columns, Arc's column rule (5 → 3+2, 6 → 3×2, 7 → 4+3).
- **SB-12** A tile is a live tab. Clicking opens or focuses it. It always snaps back to its saved URL; right-click → "Replace with current URL" / "Edit…".
- **SB-13** Unread dot on Gmail (and Slack, X, WhatsApp) when the page title reports unread items. Calendar shows Google's date favicon.
- **SB-14** Add: drag a tab above the Space name, ⌘T → "Add to Favorites", or right-click → Move to → Favorites. Remove: drag below, or the same menus.
- **SB-15** Favorites unload when unused for a while and keep their tile.

### 2.4 Space header (Arc ref §2.4)

- **SB-20** Emoji or icon plus name. Hover shows a ••• button; pressing the row folds the pinned section.
- **SB-21** Space menu, in this order: Change Icon… · Rename… · Edit Theme… · **Profile ›** · — · New Folder… · — · Manage Spaces… · — · Delete Space.
  **Manage Spaces…** (also in the Spaces menu and atop the Library's Spaces tab) is one card over the page, the sidebar live beside it: a row per Space; drag a row to reorder; click its name to rename; its icon, theme disc and profile pill open the Space menu's own pickers; the trash asks first and says what happens to the Space's tabs (Today tabs to the Archive, pinned tabs and folders deleted, the profile kept, ⌘Z undoes).
- **SB-22** **Profile indicator** (Arc lacked one): on hover over the Space name, show the profile name and the Google account avatar signed into it. The footer icon gets a thin ring in the profile's colour.
- **SB-23** Delete asks to confirm. Today tabs go to the Archive, with "Use ⌘Z to undo".

### 2.5 Pinned items and folders (Arc ref §2.5, §2.11)

- **SB-30** Pinned items are per Space, never auto-archive, and persist without a loaded page. Closing one unloads it and keeps the row.
- **SB-31** Away from the saved URL: a "/" after the name, and the favicon becomes a "Back to pinned URL" arrow on hover. Clicking it resets; ⌘-click resets and opens the current page in a new tab.
- **SB-32** Typing a new URL into a pinned tab opens a new Today tab instead.
- **SB-33** Folders with unlimited nesting, 16 pt indent per level. Open and close on press. Rename by double-click. Change folder icon. "Copy all links".
- **SB-34** Hovering a closed folder shows a searchable list of its tabs after 0.45 s.
- **SB-35** Drag rules: tab above the Space name → Favorite; between name and divider → pinned; below the divider → unpinned; onto a folder → into it; to the sidebar's left or right edge for 0.5 s → next Space; ⌥-drag duplicates; out of the window → new window, or onto another window's sidebar → that window (WIN-7). While dragging, other rows stay still and a 2 pt drop line marks the gap; on drop, rows glide over about 115 ms.
- **SB-36** Multi-select: ⌘-click toggles a row, ⇧-click selects a range within its section (Today, the pinned top level, or one folder's rows); the first pick also takes the shown tab's row, and the page shown stays. Selected rows take Arc's secondary selection fill (#FAFBFF 0.10 dark, black 0.10 light; the shown row keeps its own). Esc, or a plain click anywhere else, clears it. While rows are selected the sidebar has the keyboard: ⌘W closes them (Today tabs to the Archive, pinned ones unload), Delete archives them (pinned rows and folders leave the sidebar, their tabs to the Archive), ⇧⌘C copies every link in order, ⌘D pins or unpins them. The context menu: Copy N Links, Duplicate, Open in Split View (2–4 tabs), Pin / Unpin, New Folder with N Tabs (inside their folder when they're all in one, as Arc nests), Add to Folder ›, Move to Space ›, Close, Archive. Dragging a selected row carries the whole selection in order, to any drop SB-35 has (a folder, Pinned or Today, another Space by the edge, another window's sidebar, but not a new window). Every action is one ⌘Z (⇧⌘T for a close). Favorites aren't selectable.

### 2.6 Divider, New Tab and Today (Arc ref §2.6–2.8)

- **SB-40** Divider with "Clear" on hover (⇧⌘K). Clear archives every Today tab except the visible one; ⌘Z restores.
- **SB-41** "+ New Tab" row opens the Command Bar; new tabs appear at the top of Today.
- **SB-42** Today tabs are per Space, newest first. Background links line up after their opener.
- **SB-43** Auto-archive after 12 h idle by default (per profile: 12 h, 24 h, 7 days, 30 days). Viewing a tab resets its timer. Tabs playing audio are never archived.
- **SB-44** Tab rows: 41 pt pitch, 14 pt title, audio icon (click to mute), loading ring, close button on hover. The active row in light themes is white 0.85 with a soft shadow, matching the owner's screenshot. A tab activates on press, not release.
- **SB-45 Tab previews** (owner, 2026-11-06, from Dia): the pointer resting about 0.4 s on a pinned tab, a Today tab or a Favorite shows a card beside the sidebar, level with the row: the page's picture, its favicon and title, the host, and quick actions (pin or unpin, add to or remove from Favorites, open in a split with the page on screen, Peek). With a card up, the next row's card comes at once. It grows from the row's edge on the popover spring (Reduce Motion: a fade) on the Space's `surface`. The page on screen is pictured live; other tabs show their last picture, kept in memory only (at most 40, about 640 × 400), never asked of a hidden page; none yet: the favicon on a soft placeholder. It hides on a click, scroll, key, Esc, menu or sidebar collapse, never shows while rows are dragged or Spaces move, and keyboard users get none. Settings → Appearance → "Show tab previews" (on by default).

### 2.7 Footer and Space bar (Arc ref §2.9)

- **SB-50** Left: Library button (⇧⌘L). Middle: one icon per Space, emoji or a dot, the current one full-strength and the others dimmed. Right: "+".
- **SB-51** Many Spaces squeeze instead of scroll: cells shrink from 34 pt, the current one keeps at least 22 pt, others turn into dots.
- **SB-52** Drag footer icons to reorder Spaces. Right-click for the Space menu.
- **SB-53** **Built:** the "+" menu offers New Space, New Folder, New Note (NT-1), New Tab and horizontal/vertical Split View, in Arc's order. Extra Boost/file entries are Next (§6).
- **SB-54** Download progress and a media tray (a player for tabs playing in the background) sit above the footer. **Built**, including background playback controls; provider-specific PiP qualification remains separate (SB-55).
- **SB-55 Picture-in-picture for videos and calls (v1, owner's favourite feature, 2026-11-05).** When you leave a tab, by switching tab or Space or opening another window, and that tab is playing a video or is in a call (Google Meet first, then Zoom, Teams and Slack huddles in the browser), it pops out automatically into a floating picture-in-picture window, as in Arc:
  - **Calls** use the site's own Document Picture-in-Picture where it exists (Meet's tile grid with mute, camera and leave controls), not just the active speaker's video. Otherwise you get the camera tiles plus Airc's own mute and leave buttons.
  - **Video** (YouTube and any `<video>`) floats with play/pause and a "back to tab" button.
  - **Going back** to the tab puts it back in the page smoothly, and the PiP closes.
  - **Position:** bottom-right by default (not over page controls at the top right). It remembers where you drag it, and stays above other apps and across macOS Spaces and fullscreen.
  - **Settings:** an off switch, plus per-site exceptions.
  - **Never** for muted autoplay ads or background audio-only tabs, which go to the media tray instead.

### 2.8 Hide, reveal and the Library (Arc ref §2.10, §5)

- **SB-60** ⌘S hides or shows the sidebar (110 ms hide, 100 ms show, ease-out). Chrome's "Save Page" moves to ⇧⌘S: Airc's save panel with Chrome's formats (Web Page, Complete · HTML Only · Single File), saved by the engine (AircTab -savePageTo:format:completion:); where the engine can't save the page (WebKit, Chrome's own pages), it offers Print → Save as PDF instead.
- **SB-61** Hidden sidebar: holding the pointer at the window edge for about 100 ms slides a floating sidebar over the page, which doesn't move. Spring in about 175 ms with a slight overshoot. Only in the key window, and only when the pointer moves into the edge strip.
- **SB-62** Library: Archived tabs (searchable; restore returns a tab to its Space), Media, Downloads, Spaces. Slides in from the left. Its back button sits exactly where the footer's Library button was (Arc), so a second click without moving the pointer closes it; ✕, ⇧⌘L and Esc close it too.
- **SB-64** Files, folders, links and text into the sidebar, and exporting Spaces (P04; [docs/user/files.md](user/files.md)). A drop on the sidebar (Arc's Finder and text drops), or Add Files… (an Airc addition modelled on Arc's 2021 "+" menu entry; Arc 1.170 has none), is planned in full before a row is made (AircKit `SidebarFilePlan`): a file opens as a tab; a folder becomes a pinned folder with its files as pinned tabs and its folders nested (Finder's name order, hidden files left out, links followed once, a link back into the tree or to nothing left out, eight levels deep, at most 300 tabs a drop, more than 25 asking first); a link is a tab with its title; text that is links is a tab each, a phrase a search in the profile's engine (Arc), longer text a note. Files and links go to the top of Today in the drop's order (the first shown), or where the drop line is in the pinned section; folders go to the pinned section. A slow read shows a sheet with Cancel; any cancel makes nothing; one ⌘Z undoes a whole drop. Export Space… and Export All Spaces… (an Airc addition: Arc exports only its notes) write Markdown or the bookmarks HTML browsers import, with the names, folders, order and addresses, without user names and passwords in links, data:/blob:/javascript: links or notes' text; blank windows' Spaces aren't exported.
- **LIB-1** Library › Media and recent files (Arc ref §2.9, §5): the images and videos downloaded in Airc and the Captures saved with ⇧⌘2, as a thumbnail grid (Quick Look pictures), newest first. Click shows Quick Look, double-click opens the file, ⌘-click shows it in Finder, a tile drags out, and its menu moves it to the Trash with Undo. Resting on the footer's Library button for 0.5 s shows a card above it with the five newest downloads and Captures (icon, name, time); a click opens one, a row drags out. Only files Airc wrote (the engine's downloads list and a record of saved Captures), never a scan of the Downloads folder; files that are gone drop out; private windows' downloads and Captures never appear. No card during a drag or with the Library open.

### 2.9 Spaces and profiles: the core feature (Arc ref §3; Arc app ref; profiles ref §2a, §3, §4)

Model:
- **SP-1** A **profile** is a real Chromium profile: its own logins, cookies, history, saved passwords, extensions and settings, plus our name, emoji, colour, Favorites, archive timing and default search engine. One "Default" profile always exists and can't be deleted. All profiles stay loaded while the app runs.
- **SP-2** A **Space** has a name, icon, theme, pinned tree, Today tabs, and exactly one profile. Several Spaces can share a profile.
- **SP-3** Every tab belongs to one Space, and loads in its Space's profile. Links, popups and `window.open` stay in the same profile and arrive as tabs in the same Space. That includes Google sign-in popups.
- **SP-4** Every tab's Space survives restarts, crashes and tab discarding.

Creating ("insanely smooth"):
- **SP-10** **Create a Space card** inside the sidebar, Arc 1.171's layout and copy (revised 2026-11-05 after owner review: the first build crammed theme swatches, inline profile fields and profile management into one long form, and it felt un-Arc-like). Top to bottom:
  - a small illustration, "Create a Space" / "Give each part of your life its own tabs.";
  - icon button + name field, focused;
  - two compact 36 pt rows: **Profile**, a pill with the profile's avatar and name plus a chevron, and **Choose a Theme**, which shows the current theme as a small gradient chip and opens Arc's theme picker popover (colour disc, presets, intensity, grain) beside the card;
  - **Create Space** (accent, 0.4 opacity until a name is typed) and **Cancel**.

  Nothing else: no profile list, no delete buttons and no inline profile fields. Enter creates the Space and switches to it in the same frame. After Create the card leaves bottom-up (each part fades and sinks over 150 ms, staggered 0/80/130 ms).
- **SP-11** **The Profile pill menu** lists each profile as a row with its avatar (the Google account photo once signed in, otherwise the emoji on its colour) and name, ✓ on the current one, a divider, then **"New Profile…"**. "New Profile…" opens Arc's **two-step Create Profile card**, centred over the page:
  1. **"Create a new Profile"**, with a short explanation in Airc's words ("Each Profile keeps its own logins, history, saved passwords and extensions, so the Spaces that use it stay apart from the rest. Keep work and home signed in side by side."), a name field (placeholder "Personal") and an emoji-and-colour picker.
  2. **"Choose the Spaces for this Profile"**: Space tiles drawn in each Space's theme, as checkboxes. This step is skipped when started from Create a Space, where the new Space is the answer.

  The profile is ready instantly from the warm spare (no spinner, no restart). Back in the Create a Space card, the pill now shows the new profile.
- **SP-12** Right after a new profile is created, the Space shows a **"Sign in to Google"** card at the top of its Today list. One click opens accounts.google.com in that Space. After sign-in, the account avatar appears in the profile indicator (SB-22), and Gmail and Calendar tiles are offered as Favorites for that profile.
- **SP-13** Change a Space's profile via Space menu → Profile ›. As in Arc, a tab can't change profile: the sidebar items stay and the open tabs reload in the new profile, after a confirm dialog ("Don't ask again" option).
- **SP-15** **Profiles are visible identities.** When more than one profile is in use, the Space header shows a small profile indicator (avatar + name, Arc's ProfileIndicatorView) and the footer Space icons carry a profile-coloured dot. Profile management (rename, delete) lives only in Settings → Profiles and the Space menu's "Set Profile ›", never in the Create a Space card.
- **SP-14** Settings → Profiles: rename, emoji, colour, archive timing, search engine, "Sign out everywhere / clear this profile's data", delete (type the profile's name to confirm, as Arc does; only once no Space uses it).

Switching:
- **SP-20** Click a footer icon, ⌃1–⌃9, ⌥⌘←/→, two-finger horizontal swipe over the sidebar, mouse buttons 4/5, or ⌘T + Space name.
- **SP-21** The swipe pages the sidebar contents horizontally and settles on a critically damped spring in about 0.19 s. A swipe moves at most one Space. Rubber band at both ends; past the last Space, a pull of 22.7 pt on screen readies a new Space (Arc's measured detent, with a haptic) and letting go creates it.
- **SP-22** The window colour cross-fades in about 30 ms for a neighbouring Space; during a swipe it blends by how much of each page shows.
- **SP-23** Each Space reopens on the tab it last showed. Switching swaps the page view inside the same window: no window swap, no macOS Space change, no flash.
- **SP-24** The Command Bar only suggests tabs and history from the current profile (history is per profile, so this comes free).
- **SP-25** Past the first Space the same pull (22.7 pt) readies the Library; letting go opens it (Arc ref §2.9: "swipe past the first Space opens the Library").

Link routing (**v1**, moved up by the owner on 2026-11-05; high value for one-account-per-Space):
- **SP-30** Rules like "URL contains docs.google.com/a/company → Work Space". Links from other apps (Mail, Slack) go through the rules, otherwise to the most recent Space.
- **SP-31** "Open link in Space ›" in the page context menu.

Consequences of real profiles (decision D1), shown in Settings:
- Extensions are installed per profile, as in Arc. v1.x adds "Install in all profiles".
- Each loaded profile costs memory; MEM-1…6 remain acceptance budgets, not claims established by source presence.

### 2.10 Command Bar and keyboard (Arc ref §5, §7)

- **CB-1** ⌘T opens Arc's centred Command Bar, floating over the middle of the page and drawn in the next frame, which creates no tab until you pick something. It lists open tabs, pinned items and Favorites, history, search, and commands ("Pin tab", "New Space", "Theme", "Move to Space…"). ⌘L opens it on the current URL.
- **CB-2** Shortcuts as in Arc: ⌘T, ⌘L, ⌘W (archive), ⇧⌘T / ⌘Z reopen, ⌘D pin, ⌘S sidebar, ⇧⌘K clear, ⇧⌘C copy URL (with a "Copied" toast), ⌥⇧⌘C copy as Markdown, ⌃1–9 Space, ⌥⌘←/→ Space, ⌥⌘↑/↓ tab, ⌘1–9 sidebar item (Favorites first), ⌃Tab last tab, ⇧⌘L Library, ⌘E extensions. Plus Chrome's standard shortcuts wherever Arc doesn't override them: ⌘R / ⇧⌘R reload, ⌘[ / ⌘] back and forward, ⌘F / ⌘G find, ⌘+ / ⌘− / ⌘0 zoom, ⌥⌘I / ⌥⌘J DevTools and console, ⌥⌘U view source, ⌘P print, ⌘Y history, ⌘, settings, ⌘N new window, ⇧⌘N private window, ⌘Q quit (with Arc's hold-to-quit).
- **CB-3** "Prefer website" rule: if a page uses a shortcut, pressing it again within about 1 s runs the browser's command.
- **CB-4** All shortcuts remappable in Settings → Shortcuts, as in Arc: every command by menu, click to record (Esc cancels, Delete removes), a reset per row and Reset All. A key another command has offers Swap or Replace; macOS's own keys (⌘Q hold-to-quit, ⌘H, ⌘M, ⌘Tab, ⌘Space, the Edit menu's ⌘C ⌘V ⌘X ⌘A ⇧⌘Z, screenshots) are refused; keys pages use (⌘B ⌘I ⌘U ⌘K ⌘Z ⇧⌘V …) come with a note and stay page-first (CB-3). The map applies at once to the menus and every window (main, several, private, Little Arc); settings.json keeps only the changes, so untouched commands follow new defaults. Each command a page could have first (⌘ and ⇧⌘ keys but ⌘T ⌘W ⌘N ⌘Q, the page keys, ⌥⌘V, and ⌘Z's Reopen Closed Tab outside text fields) also has Arc's "Prefer Websites / Prefer Arc" switch, **Websites first** (the default: CB-3) or **Airc first** (the command always runs and no page gets the key, in the main, private and blank windows; Little Arc's keys are always Airc's); it follows the command when its key moves, a row's reset puts it back, and settings.json keeps only "Airc first" (docs/qa/shortcuts.md). ⌘← ⌘→ stay after the page.
- **CB-5** Arc's Capture: ⇧⌘2, View › Capture… or the Command Bar's "Capture…" dims the page card (never the sidebar) over a still picture of the pages on it. A drag selects a rectangle with its size in points, corner and edge handles, moving and arrow-key nudges; Space takes the whole visible page; ⌘ held outlines the element under the pointer and a ⌘-click selects it. Return confirms; the bar under the selection then copies the PNG (⌘C), saves it to Downloads as "Capture <site> <date> at <time>.png" (⌘S; ⌥-click or ⇧⌘S asks where) or shares it (the macOS share menu), each with a toast. Esc cancels with nothing written. The pixels are the engines' own pictures of the visible pages at the window's backing scale, never a screen capture (no permission prompt); protected video may come out black. Capture Full Page (P08a, Arc's "Capture Full Page": F or the bar's Full Page in Capture, View › Capture Full Page, the Command Bar) takes the focused page's whole length at the window's pixels per point (Peek's page when it's open): Chromium through DevTools' `Page.captureScreenshot` with `captureBeyondViewport`, clipped in points, in tiles of at most 4,096 px; WebKit through `createPDF`, rasterised; both with the page scrolled to its top for the picture and back afterwards, so fixed parts are painted once (a fixed header at the top; a fixed footer where the window's foot is on Chromium, at the page's foot on WebKit, which renders past 14,000 points in parts with fixed parts held still after the first). "Capture in Progress" shows meanwhile and Esc stops it; the picture is shown scaled to fit before Copy, Save and Share. Memory is bounded: a picture over 48 megapixels is taken at fewer pixels per point (not below 1), then cut at 48 MP or 32,000 px, which the overlay says. Private windows capture too and keep and count nothing; elsewhere `feature.used` `capture` copy/save/share (docs/user/capture.md).
- **NT-1 Notes** (Arc's Notes; built 2026-11-07, docs/user/notes.md). ⌃⇧N (Arc's key since 2023, File › New Note), the Command Bar's "New Note" and the "+" menu make a note pinned at the bottom of the Space's pinned tabs (Arc pinned new notes), shown at once with its first line ready for a title. A note is a sidebar row like a tab: in Today, pinned or in a folder, it drags, ⌘D pins, ⌘W archives and the Library restores it; not in Favorites or pinned splits; ⌥-drag and Duplicate copy the note. Its title is its first line ("New Note" while empty). The editor is native (AppKit text view, TextKit 1) in the page card on the Space's `surface`: headings 1–3, bold, italic, underline, strikethrough, inline code, bulleted, numbered and checkbox lists with nesting, links (⌘K, or an address pasted onto text; a click opens a new tab), pictures (pasted, dropped or inserted, a Capture's Copy pasted with ⌘V) on lines of their own, Arc's markdown shortcuts as you type (line: `# ` `- ` `1. ` `[] `; inline: Arc's `*bold*` `_italic_` `-strike-`, plus `**` `~~` and backticks), per-note undo (each typing burst, format change and paste one ⌘Z), ⌘F with the page find bar, ⌘P with PDF. It saves as it's typed. An empty note closes without going to the Archive (Arc). Stored as `note` rows (lines of styled runs, NoteDocument) with pictures as content-named files in the data folder's Notes/Images. Schema 2 marks a store only from its first note on, and a backup only when it holds notes, so a store or backup without notes stays schema 1 and Airc 0.1.2 reads it (SpacesStore.schemaMark); notes are in backups; archived notes outlive archive pruning; orphan notes and unused pictures go at launch. Notes never sync (local-only rows, docs/sync.md); private windows have none. `feature.used` `note.create` (shortcut, command_bar, plus_menu) only. Export (P13, 2026-11-08): Export Note… writes Markdown (pictures in a "<name> files" folder beside it), RTFD, RTF (no pictures), PDF or one HTML page with its pictures inside (Arc's "Export Arc Notes" format); Export All Notes… writes every note into a new "Airc Notes" folder; Import Notes… reads Markdown, text, RTF, RTFD and HTML back as pinned notes, Airc's own exports as they were (AircKit's NoteMarkdown/NoteHTML, Notes/NoteExport.swift). Settings → General → Notes → "New Note opens" is Arc's `defaultNoteDocumentApp`: Airc Notes (default), Google Docs, Notion, Microsoft Word or Confluence, opened at Arc's addresses (doc.new, app.notion.com/new, word.new, confluence.new) in a new tab; the menus name the choice ("New Google Doc"), New Airc Note stays, and offline New Note makes an Airc note and says so. New Note in Split (P13, Arc's "New Note (in Split)": "a new Note beside your current page"; File and the Command Bar, Notes/NoteSplit.swift): a new Today note (or the chosen app's document) as a pane beside the page on screen, focused, the page kept as it was; a note is only ever a pane of a Today split (AircKit's canBeTodayPane), a split holding one is never pinned or a Favorite, and drags never split a note. Arc's sharing and account sync are later.

### 2.11 Theming (Arc ref §4)

- **TH-1** Theme picker per Space: colour disc with 1–3 colour handles, nine presets, Auto/Light/Dark, intensity slider (default 0.81) and grain. Every drag recolours the window live.
- **TH-2** Rendering as Arc: colours mixed in OKLab on a 45° diagonal, alpha = 0.2 + 0.55 × intensity, over the macOS window blur, with grain on top. Inactive windows dim the grain.
- **TH-3** One theme drives a palette of tokens used by every surface: sidebar text, hover, selection, Command Bar, menus, toasts.
- **TH-4** Arc themes import exactly (gradient, intensity, grain).
- **TH-5** Pages get their Space's theme as Arc's CSS variables (P07; docs/user/themes.md): `--arc-palette-{foregroundPrimary, foregroundSecondary, foregroundTertiary, maxContrastColor, minContrastColor, backgroundExtra, background, focus, hover, cutoutColor, title, subtitle}`, `--arc-background-simple-color`, `--arc-background-gradient-color0…2` and `--arc-background-gradient-overlay-color0…2` (names from Arc's bundle), in a constructed sheet under `:where(:root)`. Each page shows its own tab's Space (a Favorite: the window's Space) in its current appearance; theme, appearance and Space changes reach open pages live; a page moved to another window keeps its Space's; private windows and Little Arc get none. Each engine tab carries its Space's key (AircTab.pageColor) so an engine that hands it to the page script at document start gives the palette before first paint (a renderer change, not in the engine yet); until then the palette arrives with the first message. Reduce Motion: no Space switch slides, long jumps included; Reduce Transparency: the window goes opaque.

### 2.12 Feel and performance budgets (Arc ref §6)

These are acceptance tests, measured on the owner's MacBook in fullscreen:

| Metric | Budget |
|---|---|
| Space switch by key or click, input to first frame of the new Space | ≤ 16 ms; animation at the display's full rate (120 Hz on ProMotion), no dropped frames |
| Swipe tracking | follows the finger every frame |
| Sidebar hover, press and selection feedback | next frame |
| Tab switch to a loaded tab | ≤ 50 ms to a fully painted page |
| Sidebar after a cold app launch | interactive ≤ 300 ms after the window appears |
| New Space with a new profile | ≤ 1 frame after Enter |
| Hide/show sidebar | 100–110 ms, page reflows smoothly |
| Command Bar open (⌘T / ⌘L) | first frame ≤ 8 ms; local results (tabs, history) update on every keystroke within the same frame; search suggestions ≤ 100 ms |
| Cold launch to an interactive window | ≤ 0.5 s on the WebKit dev engine, ≤ 1 s with Chromium and all profiles loaded |

Motion follows Arc's measurements: hover changes in one frame, rows move in about 115 ms, folder open 200 ms ease-out, folder close a critically damped spring of about 240 ms. Haptics only at thresholds (create-Space pull, drag snapping).

**Memory (owner, 2026-11-05: "blazingly fast and not taking an insane amount of memory").** Measured nightly on the owner's MacBook against Google Chrome with the same tabs (a separate Chrome user-data folder, never the owner's own profile), using a fixed reference workload: 3 profiles, 6 Spaces, 30 tabs of which 8 were used in the last 10 minutes.

| ID | Budget |
|---|---|
| **MEM-1** | Airc's own app process (window, sidebar, store) ≤ 150 MB |
| **MEM-2** | An idle loaded profile with no open pages costs ≤ 40 MB. Profiles stay loaded (D1) but their services start lazily |
| **MEM-3** | Background tabs unload after a per-profile timeout (default 30 minutes, adjustable, like Chrome's Memory Saver); under macOS memory pressure the least recently used tabs unload first, never the visible tab, a tab playing audio, or one with unsaved form input. Unloaded tabs keep their title, icon and scroll position and reload on click. Pinned tabs and Favorites of the sites people keep open for notifications and calls (Gmail, Google Calendar, Slack, Discord, WhatsApp Web, Teams, Outlook, Messenger, Linear…: AircKit `KeepLoadedSites`, matched by registrable domain through the public suffix list) never unload on the timer, on either engine, while Settings → General → "Keep chat and mail sites loaded" is on (the default). Today tabs of those sites unload as usual |
| **MEM-4** | Total memory for the reference workload ≤ Chrome's for the same tabs; target 20% less |
| **MEM-5** | No leaks: memory after opening and closing 100 tabs returns to within 5% of the start |
| **MEM-6** | Energy: an idle window with no media uses < 1% CPU; no timers while idle |


### 2.13 Onboarding (onboarding ref §3)

A native SwiftUI flow in an AppKit floating card (D3, ON-5), superseding the original full-window web-screen proposal. Every screen is skippable; target under 2 minutes, about 30 s if skipped.

| # | Screen | Content |
|---|---|---|
| 0 | Unboxing | 2–3 s animation: wordmark, then a gradient blooms in the Mac's accent colour. Any key skips. |
| 1 | **Bring your Arc with you** | Finds Arc automatically and rebuilds the owner's sidebar live in a mini preview: Spaces slide in with their emoji and colours, Favorites fill. "6 Spaces · 3 profiles · 12 Favorites · 84 pinned tabs". **Import everything** / Choose… / Start fresh. Without Arc: offers Chrome, Safari and the other installed browsers. |
| 1a | macOS 27 file access | Only if needed: explains the "Files & Folders" prompt before it appears. |
| 2 | **Spaces and accounts** | Each Arc profile becomes a profile; its Spaces show as chips, with the Google accounts found in it as avatars. Toggle "Give this Space its own profile". "Sign in with Google" for Spaces without an account. |
| 2a | Keychain explainer | Shown right before macOS asks for the Mac password to unlock Arc's saved logins. "Skip logins" imports everything else. |
| 3 | Make it yours | Colours per Space (pre-filled from Arc), light/dark, sidebar left or right. The real window behind re-tints live. For Arc imports this is just "Looks right?". |
| 4 | Learn by doing | Coach marks in the real browser: press ⌘T and type "gmail"; switch Space with ⌃2 or a swipe and watch the account change; ⌘S; drag a tab above the divider. "I know Arc, skip". |
| 5 | Default browser | One line, then the macOS confirm dialog. Skipped if already default. |
| 6 | Finish | A personal card (name, Space emojis, date), then the browser fades in behind it. A toast summarises the background import. |

- **ON-1** Import runs in the background from screen 1 onward, with a small progress pill.
- **ON-2** No account, no sign-up, no telemetry question: one quiet line on the last step says usage data is shared and links to Settings → Privacy.
- **ON-3** Re-runnable from Settings. A new profile created later gets a 20-second mini flow (colour, Google sign-in).
- **ON-4** Our app decides first run; Chromium's own first-run UI (`chrome://intro`) never shows. A test flag skips onboarding.
- **ON-5** (owner, 2026-11-04) Onboarding is a **floating window, not full screen**: a centred, fixed-size card (about 760×540 pt) with large rounded corners and a soft shadow, over the desktop. **No title bar and no traffic lights** (no close, minimise or zoom buttons). It can be dragged by its background. It closes by finishing the flow (Esc goes back a step; ⌘Q still quits). On the last step it expands smoothly into the first browser window.

### 2.14 Import (onboarding ref §4)

- **IM-1** Arc sidebar from `~/Library/Application Support/Arc/StorableSidebar.json`: Spaces, icons, themes, pinned tree with nested folders, Favorites **per profile**, Today tabs, profile names. Idempotent: re-running doesn't duplicate (keyed on Arc's IDs). Built in Swift from the earlier importer model; history and the extension checklist are covered separately by IM-3.
- **IM-2** Arc logins: cookies and saved passwords from each Arc profile folder. The key is the Keychain item "Arc Safe Storage"; macOS asks the user once. Decrypt on the Mac, re-encrypt with our own key, and never send anything off the device. Google sessions that turn out to be device-bound need a "sign in again" prompt. The Keychain's answers are told apart (declined or cancelled, locked, no "Arc Safe Storage" item) and a key that opens nothing is reported as a key mismatch; a database that can't be read (Arc writing to it, no permission, damaged) fails alone, with why. Logins Airc doesn't take (Android apps, federated sign-ins, HTTP authentication, username-only) are skipped as such and never decrypted; refused cookies (partitioned, expired, Chromium's rules) say why. **Try Again** redoes only the parts that failed and may pass, keeping what came over (a saved login stays imported) (P22).
- **IM-3** Arc history (last 90 days, capped at 20,000 pages per profile) feeds that profile’s ⌘T suggestions and deduplicates on reimport. History and extension preferences are read from disposable private copies; no credential access. Onboarding and Settings → Import show a persistent per-profile extension checklist, disabled state, installed status and Chrome Web Store links opened in the matching profile’s Space. No automatic installation. Only checkpointed history is read; a WAL warning asks the user to quit Arc and reimport for recent visits. A History that so far lives only in its log (Arc open) gets that warning, not "couldn't be read"; a damaged `Local State` is a warning (profiles named after their folders), and a profile folder linking outside Arc's isn't followed. The checklist says per extension whether it is to go, opened in the Web Store, installed, or not in the Web Store (loaded unpacked, from elsewhere), with a summary; installing them in one step waits for the engine (P09b) (P22).
- **IM-4** Other browsers (Airc → Import from Another Browser…, and the onboarding's import step, which lists every browser found with Arc first): bookmarks and history from the Chromium family (Chrome and its channels, Brave, Edge, Vivaldi, Opera, Chromium, Dia, Helium), Firefox and Zen, each profile from `Local State` or `profiles.ini` with its name and colour. Each browser profile becomes an Airc profile and one Space named after it: the bookmarks bar as pinned tabs and folders, "Other bookmarks" as one pinned folder, Favorites empty; its history goes into that profile's ⌘T suggestions. Safari's library needs Full Disk Access, so its bookmarks come from the HTML file Safari exports (any browser's export works). Saved passwords come only from a CSV file the user exported from their browser and chose, into the profile they pick; Airc then offers to move the file to the Trash. Airc never reads another browser's password store, cookies or "Safe Storage" Keychain item. Re-importing merges on bookmark GUIDs and never duplicates.
- **IM-5** "Back up my Arc data" button: zips Arc's JSON files and `Local State` into `~/Documents`. Also offered outside onboarding, before Dec 22.

### 2.15 Settings, data and privacy

- **SET-1** **Built; changed by D3:** native SwiftUI settings hosted by AppKit, including General, Profiles (SP-14), Spaces, Shortcuts, Appearance, Import, Privacy, About/Updates. Chrome's own settings remain under "Advanced".
- **SET-2** The sidebar data (profiles, Spaces, Favorites, pinned tree, archive) lives in one store under the user-data folder, independent of any Chromium profile. It is written as an **operation log with timestamps**, so sync can be added later without a migration (accounts ref §5.2).
- **SET-3** Automatic daily JSON backup to a folder the user picks (iCloud Drive works with no integration); manual export and import.
- **SET-4** Anonymous usage data on by default (owner, 2026-11-06), as T3 Code does: closed event names and values only, never URLs, titles, names or text; off in Settings → Privacy, with "See what Airc sends" ([docs/user/telemetry.md](user/telemetry.md)). Crash sending uses the same usage-data switch, as documented in [the telemetry guide](user/telemetry.md#crash-reports); no URLs or titles are sent.
- **SET-5** Our own Keychain item name (e.g. "Airc Safe Storage") and bundle ID, fixed forever after the first release. Changing them later would wipe every saved login.

### 2.16 Accounts (later; accounts ref §5)

- **v1:** no Airc account. Local browser organization works offline; websites and network services still need connectivity.
- **v1.x:** "Sync with iCloud" toggle for the sidebar data between Macs, if a CloudKit spike works inside the Chromium app bundle. Otherwise an optional account ("Create an account to sync") with passkey and Sign in with Apple, storing an end-to-end encrypted copy of the operation log. See [the sync groundwork](research/sync.md) for Developer ID provisioning, the transport-neutral merge core, and the encrypted folder fallback.
- **Built (2026-11-07, owner: "Let's do iCloud"):** Settings → Sync → "Sync Spaces, pinned tabs and Favorites with iCloud", off by default: CloudKit private database, group key in iCloud Keychain, a first-sync screen (merge or replace this Mac's sidebar, after a backup). It switches on in release builds once the Developer ID provisioning profile exists ([sync.md](sync.md), [user/sync.md](user/sync.md)). Never Today tabs, history, logins, private windows or Little Arc.
- **v2:** iPhone companion (Spaces, pins, send to Mac), shared Spaces.
- Passwords stay with the local password manager or 1Password/Bitwarden. Chrome Sync is not available to forks.
- Apply for Apple's browser passkey entitlement now; approvals are slow.

### 2.16b Arc favourites added to v1 (owner, 2026-11-05)

- **AT-1 Air Traffic Control** (SP-30/31):
  - Settings → Links has rules "URL contains / is equal to … → Space", with a default for links from other apps: Little Arc, or the most recent Space.
  - Airc registers as a default-browser candidate, and links from Mail, Slack and others go through the rules.
  - A rule match opens the link already signed in, because the Space carries its profile.
  - Rules also route Peek links, as in Arc: a user-clicked link leaving its site that would open in Peek (from a pinned tab or Favorite, or ⇧-click), or a link followed inside Peek, goes to the first matching rule's existing Space instead. Other links inside Airc never consult the rules, and same-site links don't either; without a rule the usual Peek/new-tab/in-place behavior applies. Private windows and Little Arc keep their own routing.
- **LA-1 Little Arc** (⌥⌘N, and the default for links from other apps):
  - a small floating window with one page and no sidebar, a compact URL row, and the profile of the Space it targets (shown as a chip; switchable);
  - "Open in" via ⌘O moves the page into the most recent Space; its chevron (⇧⌘O) opens Arc's Open In menu, a popover under the chip: the short list of Spaces in sidebar order (up to six, the chip's always among them), each by icon and name with its tile and highlight in its Space's colours, the chip's with ⌘O, a Space of another profile saying the page reloads there; "Search Spaces" (or just typing) expands it into a field that filters every Space; then Profile and Copy Link. ↑ ↓, Return and Esc work, and ⌥⌘O opens it straight into the search; the page moves without reloading;
  - Little Arc windows go to their Space's Archive after 6 h by default (Settings → Links → "Archive Little Arcs after": 1 h, 6 h, 12 h, 24 h, 7 days, 30 days or never, Arc's choices), marked as Little Arc's for the Library's filter; Window → Show Little Arc Windows and Close Little Arc Windows (Arc's commands, also in the Command Bar and the Dock menu) show them all or close them all, Close sending each page to the Archive first;
  - from any app (P06b, off until turned on in Settings → Links): a global shortcut, ⌥⌘N as Arc's, opens a Little Arc window, over the app in front's full screen when it is in one; rebinding names a key macOS, another app or an Airc command uses; turned off, nothing listens. "Look up the selected text" (an Airc addition) searches the front app's selection, read over Accessibility only when the shortcut is pressed and only once access is granted; access is asked for only from Settings' Allow… button ([docs/user/little-arc.md](user/little-arc.md));
  - ⌥⌘-click (P06d, Arc's "Open Little Arc when clicking on links with ⌥⌘ held", on by default in Settings → Links): a page's link, in a main window, its Peek or a Little Arc page, opens in a new Little Arc window with the page's Space and profile; ⌘ and ⇧ keep their tab and Peek; private windows keep their links; links from other apps don't look at modifiers (Arc has none for them);
  - a mini player keeps media playing when it's closed.
- **PW-1 Private windows** (⇧⌘N): a dark window of its own with a simple sidebar (the address field, its tabs, New Tab, and "Private" with an eye-slash where the Space name is; no Spaces, Favorites or pinned items, as in Arc's incognito window). Its pages use the off-the-record profile of the current Space's profile (one session per profile, shared by its private windows, as in Chrome); on WebKit, and for DRM pages in the Chromium build, a non-persistent data store. Airc keeps nothing of it: no history, no session restore, no Archive, nothing in ⌘T's history, no telemetry about its pages (only `private_window.open`). Its cookies and site data go when the last private window of the profile closes. ⌘T opens its own Command Bar (its tabs, built-in sites and search, no history), ⌘W closes a tab, ⇧⌘N opens another private window. ⌘F ⌘G ⇧⌘G use the main window's find field, and its pages get their shortcuts first as in the main window (CB-3; ⌘Z and Paste and Match Style reach the page's fields). Its downloads land in the Downloads folder and show as rows above the sidebar's note, newest first (a click opens a finished file); the list is in memory only, goes with the session, and never appears in the Library's Downloads. ⌘N there opens an ordinary window (WIN-7).
  - Private media stays out of the ordinary window's media tray and Airc's shared Now Playing publisher: private profiles and tabs are not registered there. System controls supplied by an engine are acceptable during the private session. Airc keeps no media history, last-played state across relaunch, or page/media telemetry. App-side private artwork must never use the shared favicon network/disk cache: only page-supplied `data:` images decoded in memory are allowed unless a private-profile network API is used. Closing the session discards its media state; Airc must not restore it on relaunch.
- **SV-1 Split View**:
  - drag a tab onto a tab or onto the page, ⌥-click a sidebar tab (Arc: it opens beside the page; on the tab on screen, a copy), or use ⌃⇧+ / the "+" menu / the Command Bar's Add Left, Right, Top or Bottom Split, for 2–4 panes (Arc's limit; a fifth says "Cannot Add New Pane"), horizontal or vertical, with resizable dividers;
  - a split is one row in the sidebar, and "Separate All Tabs" undoes it;
  - each pane keeps its own profile from its Space;
  - ⌘[ / ⌘], Arc's ⌃⇧[ / ⌃⇧] (round the panes) and ⌃⇧1–4 focus the panes, and ⌘W / ⌃⇧− closes the focused pane;
  - each pane's handle opens Arc's Split View Controls (Move Left/Right or Up/Down, Add Left/Right or Top/Bottom Split, Arrange, Make Panes the Same Size, Expand Current Split, Separate Tab from Split, Close Split View Pane); a drag takes the pane out (docs/user/split-view.md).
  - Arc's View-menu extras (P06c, Browser/SplitExtras.swift; Airc's Tabs menu): Expand Current Split (Arc's maximizeCurrentSplitViewPane) fills the split's place with the focused pane, the others live behind it at their sizes, and the same command (then "Restore Current Split"), the pane's controls or the Command Bar bring the split back as it was; another pane taking the keyboard, a pane joining, Arrange and leaving the split end it, closing a hidden pane keeps it, and while expanded ⌘[ / ⌘] are the page's Back and Forward; it's each window's own, not saved and no undo step. Separate Page from Split View (Arc's separateTabFromSplitView) makes the focused pane a tab of its own; ⌥-click on a split's row or Favorite tile separates it into tabs (Arc 1.17.2). Both are one undo step.
- **SV-2 Pinned and Favorite splits** (owner, 2026-11-06): a split can be pinned in a Space or kept as a Favorite, as in Arc. It restores as the same split with each pane's saved URL. Closing, deleting or archiving one (a multi-selection too) asks "Leave site?" for every pane with unsaved changes, one at a time; Stay on any keeps the whole split. A tab dropped on its row, or on the middle of a Favorite split's tile, joins it as one more pane, up to four (left half first, right half last, as Arc's tab-onto-tab rule; a full one takes none). A Favorite split can have its own icon (Arc: Change Icon…, Remove Icon): the tile is whole, with the emoji and a small split mark.
- **PK-1 Peek**:
  - Site identity uses the bundled Public Suffix List (including private suffixes), shared with Boosts: `a.co.uk` and `b.co.uk`, or `x.github.io` and `y.github.io`, are different sites. IP literals and single-label hosts use exact host identity; IDNs and trailing dots are normalized.
  - cross-site links from pinned tabs and Favorites (and ⇧-click on any link) open in an overlay card above the page;
  - ⌘O promotes it to a tab, and the Split button turns it into a split;
  - clicking outside, ✕ or ⌘W closes it, and ⌘Z / ⇧⌘T reopen it;
  - it can be turned off in Settings → Links.
- **BST-1 Boosts** (2026-11-06; [docs/user/boosts.md](user/boosts.md)): one Boost per site (registrable domain, its subdomains included), on or off, the same in every Space and profile (Arc). Stored in a local `Boosts.json`, never synced or sent. The editor opens from Site Controls ("Boost this site"; a boosted site shows "Boosted" with a switch, and a brush in the URL field) and View → Boost This Site… (no shortcut, as in Arc), with Colors (tint, brightness, contrast, invert), Font (macOS fonts, a size), Zap (click to hide, a selector per element, undo, Reset Zaps) and Code (CSS and JavaScript, Save). CSS reaches pages through the engine's page script at document start, so there is no flash; custom JavaScript runs only from the editor, only on its own site (checked against the engine's frame origin), once per page load. Both engines (WebKit: a WKUserScript).
- **BST-3 Boosts, Arc parity** (2026-11-08; [docs/user/boosts.md](user/boosts.md)): the editor adds Original Saturation, a letter case (Arc's capitalize, uppercase, lowercase) and Arc's Boost menu (Rename, Reset All Edits, Share, Delete). The size is the page's zoom (the ⌘+ zoom; CSS zoom made 100vh layouts taller than the window), set when a page of the site shows and taken back when the size goes, never over a zoom the person chose. Frames: a document in a frame takes its site's Boost only when its page is on the same site (`location.ancestorOrigins`), without a second filter or tint; a frame of another site keeps its own look; code stays in the top frame. Zap works inside the page's same-site frames (a frame zap hides only in the site's frames, `BoostZap.frame`) and zaps another site's frame whole; pages the Chromium build plays in WebKit (DRM services) get the frames script too; Boosts are off in private windows from the page's first script on (the engine's private profiles pass the page script a third install argument, WebKit's private sessions the same), as Arc's were in Incognito (boosts3). Custom CSS `@import`: `data:text/css` and the page's own origin only (fetched by the page, `text/css`, limits), any other origin refused unrequested and listed in the editor. Sharing: a share sheet (name, unverified author, a line, an optional screenshot) makes a link (`https://aircbrowser.com/boost#…`, the Boost in the fragment, no server) or a version 2 file; a shared Boost keeps an id and revision, so a newer one is offered as an update (Arc didn't update installed copies). Every install goes through a review with a screenshot or sketch, an unvisited-site warning, the full code and Try It On (style and size only, never code). A gallery window of style-only starter Boosts (Arc's gallery was community Boosts on its website). No per-Space or per-profile Boosts: Arc had none. JavaScript Boosts can be shared with the review's consent (Arc refused to share them).
- **AI-1 Tidy Titles** (2026-11-07; [docs/user/ai.md](user/ai.md)): Arc Max's auto-renamed tabs, on Apple's on-device Foundation Models (no account, no key, no network). Settings → AI → "Tidy tab titles", off by default. Long or noisy page titles of pinned and Today tabs get a short name of at most about four words (guided generation; the model sees only the title with counts and email addresses taken out, and the host). A tab renamed by hand keeps its name and is never sent; private windows never reach the model; Favorites, folders and splits keep their titles. Names are cached per address in a local `TidyTitles.json` with a fingerprint of the title (never the title), up to 1,000 pages; off deletes it. Requests wait for a quiet moment (1.5 s after the last, not while typing or scrolling), a few at a time, 4 s each at most. The page's own title shows in the tab preview, or as the row's tooltip with previews off. Without Apple Intelligence (macOS before 26, a Mac that can't run it, turned off, model not ready) Settings → AI says "Requires Apple Intelligence", the switch is greyed out and nothing is tidied; the framework is weak-linked for macOS 14 and 15. Telemetry: only `feature.used` `ai.tidy_titles` on or off. AI-2 adds Ask on Page, link previews and Tidy Downloads.
- **AI-2 Ask on Page, link previews, Tidy Downloads** (2026-11-07; [docs/user/ai.md](user/ai.md)): Arc Max's other features on the same on-device model, each off by default in Settings → AI, with the "Requires Apple Intelligence" state and "Runs on this Mac. Nothing is sent anywhere." Never in private windows.
  - **Ask on Page:** ⌘F's ✦ mode (⌘↩ in the field) or the Command Bar's "Ask This Page…". The page's visible text (a page-reading script on both engines, at most 200,000 characters; more is refused as too long) is planned into passages that fit the model's context window (4,096 tokens on macOS 26; the passages sharing most words with the question, or the page's start for a summary), the answer streams into a card under the bar (guided generation: an answer and up to three sentences copied from the passages), and each quote that is really on the page (found word for word, or as the sentence holding most of its words) is a row that scrolls the page to it and highlights it (CSS Custom Highlight API, else the selection). 20 s to start, 45 s in all; a too-large context is retried once with half.
  - **Link previews:** ⇧ over a link, or a press held 0.5 s, shows a card under it with the target's title, a two- or three-sentence summary and up to four key points. The page is loaded in the background in the same profile (a never-shown engine window, two pages at a time, muted, its popups closed; never in the sidebar or Airc's history), read as text and summarized on device; previews are kept per page and profile for the session (64). The page script reacts only to trusted events, and the app checks that ⇧ or the button is really down over the page. Per-site "never" (the link's site or the page's, registrable domain) from the card's menu, listed in Settings → AI. The click ending a long press doesn't navigate.
  - **Tidy Downloads:** a finished download with a meaningless name gets a suggested one from the source page's title and address (host and path) and the file's text (a PDF's first pages via PDFKit, a text file's start; local only); Library › Downloads offers Rename. The extension is kept, illegal characters (/ : \\ * ? " < > | and control characters) and a leading dot are taken out, at most 60 characters, a taken name gets a number. Renames are kept in TidyDownloads.json (the engine keeps the old path), so the list, Open, Show in Finder and drags follow.
  - Telemetry: `feature.used` `ai.ask_page`, `ai.link_preview`, `ai.tidy_downloads` with `on`, `off` or `used` only.

### 2.17 Out of scope for v1

These exclusions do not remove the requirements above. Split View (SV-1/2), Peek (PK-1), Little Arc (LA-1), tab preview cards (SB-45), media (SB-54/55), Boosts (BST-1), shortcut remapping (CB-4), Tidy Titles (AI-1) and Ask on Page, link previews and Tidy Downloads (AI-2) have implementations. Live Calendar is built in `Calendar/`: opt-in EventKit calendars, a Favorite countdown, a hover card (Arc's big Join for a meeting moments away, "+" for a new event, a meeting's day), the Join under the Favorites at Arc's Show Meeting Link time (Ten, Five or Two Minutes Before, On Start), Arc's per-Favorite Show Time to Next Meeting / Show Next Meeting Link / Show Hover Preview, and ⌃⌘J joining the current or next meeting in its calendar's Space ([Live Calendar](user/calendar.md)). Protected media is built in `Engine/HybridEngine.swift`: listed streaming services use per-profile WebKit/FairPlay pages inside the Chromium app; see [protected media](user/protected-media.md) for limitations. Implementation does not certify every provider or performance budget.

- **Easels:** no canvas; deliberately excluded to focus on browsing. Notes are built (NT-1); their sharing and sync are later.
- **Windows, Intel Mac distribution and iPhone:** no supported release targets; v1 concentrates on Apple-silicon macOS. The iPhone companion remains a later proposal (§2.16).
- **Account-backed or iCloud sidebar sync and shared Spaces:** no integrated user flow; merge/transport groundwork exists, but provisioning, transport integration and end-to-end qualification remain (§2.16).
- **Remaining Arc Max features:** AI link summaries (“5-second previews”), Ask on Page and Tidy Downloads are not built; expand only after Tidy Titles is qualified. SB-45’s screenshot cards are already built and are not AI summaries.

Smaller missing parity features are work in §6, not blanket non-goals.

---

## 3. Architecture

Arc's architecture (section 0.1), rebuilt in the open: a native macOS app that owns the window and the sidebar, and Chrome as an engine framework inside it. The engine layer is a port of ArdiaCore (Apache-2.0) onto upstream Chromium.

### 3.1 Components

```
Airc.app  (Swift + AppKit, macOS only, our code)
 ├─ Window: themed full-window background, page card, fullscreen, notch
 ├─ Sidebar: header + URL field, Favorites grid, one page per Space (outline list), footer Space bar
 ├─ SpaceSwitcher: swipe tracking, spring paging, colour cross-fade, keyboard
 ├─ Command Bar, menus, toasts, Library (AppKit; app-owned main menu and shortcuts)
 ├─ Native screens: onboarding, settings, Space and profile editors
 │    SwiftUI hosted by AppKit (D3); no internal web UI profile
 └─ SpacesStore: profiles, Spaces, items, archive; SQLite op log under the app's data folder
        │
        │  Objective-C API exported by the framework
        ▼
Airc Framework.framework  =  Chrome's own //chrome:chrome_framework  +  //airc/core (ArdiaCore port)
 ├─ ProfileHost: create, load, delete Chromium profiles; keep every profile loaded
 ├─ Browser per (window, profile): a real Chromium Browser whose window object has no Chrome UI
 ├─ Tab: create, navigate, attach/detach its page view to our window, discard, events
 │    (title, favicon, audio, loading, unread count, crashes)
 ├─ Re-hosted Chrome UI: permission prompts, autofill + passwords + passkeys, extension toolbar
 │    icons and popups, find bar, context menus, downloads, DevTools, choosers, printing, PiP
 └─ Importers: Arc and Chrome profile data (cookies, passwords, history)
```

How a Space switch works:
1. The sidebar pages to the new Space with a spring; the window colour cross-fades.
2. The app asks the engine to detach the current tab's page view and attach the new Space's last-active tab, which lives in that Space's profile's Browser.
3. Every profile and its Browser for this window are already loaded, so this is a view swap, not a load.

### 3.2 Repository

```
<project>/                    source root
  CHROMIUM_VERSION             exact Extended Stable tag, e.g. 156.0.8078.80
  apps/browser/                native Swift app, engine adapters and scripted UI checks
  packages/                    AircKit model/store, AircImport and AircDesign; Swift tests
  engine/core/                 //airc/core: ArdiaCore port (Objective-C++), exported API
  engine/patches/series        hooks into Chromium, one concern per patch, strict apply
  engine/apply.sh              copies //airc/core in and applies hooks (ArdiaCore's apply.sh model, with --check)
  apps/marketing/              website only; not browser UI
  scripts/                     sync, build, sign + notarize, appcast, smoke
  AGENTS.md  docs/rebase.md    the playbook the rebase agent follows
  NOTICE                       Apache-2.0 notices for ported ArdiaCore files; MIT notices for T3 Code
```

Rules: new engine code only in `//airc/core`; Chromium files get one-line hooks (ArdiaCore needs about 4, plus one dependency in `//chrome:chrome_dll`); hooks are declared in one header so a signature change becomes a compile error, not a crash; strict patch apply with no fuzz, checked byte by byte; feature kill switches per surface (Ardia's `kill-switches.md`).

### 3.3 Expected Chromium patches (about 15–25)

- **Engine hooks:** framework dependency on `//airc/core` · our `ChromeMainDelegate` · browser-window factory returning our window object · the handful of hooks ArdiaCore lists.
- **Branding:** strings, icons, bundle ID, **Keychain item name** (fixed forever after first release; changing it wipes saved logins).
- **Updates and services:** Sparkle · turning off Google-only features that nag without Google's keys.
- **Import:** Arc and Chrome profile readers.

The sidebar, window, menus and shortcuts need **no Chromium patches**: they live in our app. That is the main maintenance win of Arc's design over patching Chrome's own window.

### 3.4 Data model (SpacesStore)

| Entity | Fields |
|---|---|
| Profile | id, Chromium profile folder, name, emoji, colour, archive timing, search engine, signed-in Google account (display only) |
| Space | id, name, icon, theme (up to 3 colours, intensity, grain, light/dark), profile id, order, last active tab |
| Item | id, kind (tab or folder), owner (a Space for pinned items, a profile for Favorites), parent folder, saved URL, title override, icon override, order |
| Live tab | engine tab handle, Space id, bound item id (if pinned or Favorite), last active time |
| Archive entry | URL, title, Space id, archived at |
| Note | id, document (lines of styled runs; pictures by file name), created and updated at. Its rows are tabs and items whose URL is `airc-note:<id>` (schema 2, marked with the first note) |

Stored as an operation log with timestamps (accounts ref §5.2) so sync can come later without a migration. Backed up daily as JSON. The earlier extension model informed the implemented Swift store.

---

## 4. Development environment and testing

### 4.1 Machines

Per D5, the existing build Mac runs Chromium and Swift builds, UI tests, signing and release packaging. The Linux machine hosts the read-only Chromium mirror, source review and automation. A dedicated Mac mini, cloud runner and compile offload are alternatives, not prerequisites or deployed build paths. Check current disk headroom before a build; machine capacity is operational state, not a product requirement.

### 4.2 Builds

- **Engine:** Chromium checkout on the Mac's SSD, Extended Stable tag, `apply.sh` copies `//airc/core` in. A component dev build for daily work; an official arm64 build (ThinLTO + PGO) for releases, about 3–4.5 h cold and 1–1.5 h for a security respin (dev ref §3.2). Linux mirror checks do not constitute a macOS engine build.
- **App:** Xcode / SwiftPM build against the dev framework; incremental app builds take seconds, so UI iteration doesn't wait for Chromium.
- **Native screens:** SwiftUI/AppKit built with the app (D3); the website has its own web build.

### 4.3 Seeing work in progress from the MacBook

- **Live:** approved remote access to the build Mac; avoid disrupting its user.
- **Async:** a review page on the tailnet: after each build the agent posts screenshots, screen recordings, test results and a changelog. Works from the iPhone too.
- **Real use:** qualified builds can be distributed through Sparkle under the release guide’s promotion rules.

### 4.4 Tests

| Layer | Tool | What |
|---|---|---|
| Model | XCTest (Swift) | Store and op log, archive timers, drag-and-drop rules, Favorites grid layout, Arc importer |
| Engine | Acceptance script against a hidden instance (ArdiaCore's `acceptance.mjs` has 29 checks to start from) | Two profiles in one window, popups land as our tabs, extension popup, permission prompt, autofill, DevTools, clean quit |
| Accounts | CDP (Puppeteer) on the engine's remote debugging port, with a fake Google server | Two Spaces signed into different accounts never leak; restart restores both |
| UI journeys | XCUITest | Click Space 2 → its tabs show → account changes; create Space with new profile; hide/reveal; swipe; shortcuts |
| Native screens | Scripted app scenarios on both engines | SwiftUI onboarding and settings, including import and shortcut remapping |
| Visual | XCUITest screenshots vs stored baselines | Flags differences on the review page |
| Perf | Instruments (Core Animation, Time Profiler) on the MacBook | The budgets in section 2.12 |

**Smoke suite after every rebase**, under 30 min after the build: hooks apply cleanly → engine and app build → engine acceptance checks → account-separation test → XCUITest journeys → screenshots to the review page → signature, notarization and Sparkle update-from-N-1 checks.

---

## 5. Release and update pipeline

- **Signing:** Apple Developer Program ($99 a year), Developer ID, hardened runtime, notarization, DMG, stapling. Chromium's own signing scripts cover the framework and helpers.
- **Updates:** Sparkle 2.10 with EdDSA signatures and delta updates. A private dev channel is separate from public Stable and Nightly channels, superseding the old beta plan. Promotion and distribution gates are defined in the [release guide](release.md); scope completion alone does not authorize publishing.
- **Agent rebase loop** (dev ref §6):
  1. Poll Google's version API for a new Extended Stable (or Stable) Mac release.
  2. Sync the tag; run `apply.sh --check`; fix drifting hooks; compile `//airc/core`. ArdiaCore uses about 134 includes from `chrome/browser/ui` and 161 from `content/public`, so most breakage shows up as compile errors the agent fixes.
  3. Official build, sign, notarize.
  4. Smoke suite, review page, Nightly channel, notify the owner.
  5. **Fallback:** if a non-essential feature breaks, ship with its kill switch off. Never ship an older Chromium; profiles can't be downgraded.
- Before going live, replay the last few Chrome releases to measure how often the hooks break.

---

## 6. Task plan

Scope reconciled 2026-11-07 against source and [Arc parity review](qa/arc-parity.md). **Done means an implementation exists, not fresh runtime certification.** Requirement IDs remain unchanged. The original week estimates are retired; release promotion, signing, real-account playback and performance budgets require their own evidence.

### Done

- Store, real profiles, sidebar/Spaces/themes, tab restore and unloading, multi-window and private windows, Command Bar, Archive/Downloads/Spaces Library, native onboarding and import have implementations. IM-3 now has Arc history and a persistent extension checklist, verified on synthetic data with both engines.
- Split View and saved splits, Peek, Little Arc, tab preview cards, Live Calendar, media tray/PiP, protected-media routing, Boosts, remappable shortcuts and Developer Mode are built. Tidy Titles has an on-device adapter and UI; real-model qualification remains open.
- Build, signing/notarization, update and Chromium-rebase tooling exist. Their presence is not a passed release gate.

Original task numbers retained for traceability (not requirement IDs):

| Original task | Current disposition |
|---|---|
| 0.1 Arc backup; 0.2 Arc recordings | Owner evidence, not certified here; retain backups and research references |
| 0.3 Get a Mac | Changed by D5: existing build Mac, no purchase prerequisite |
| 0.4 Developer enrolment/passkey entitlement | Release/provisioning gate; not certified by this scope review |
| 0.5 Decisions | D1–D9 accepted (§1) |
| 1.1 Chromium checkout/build; 1.3 skeleton; 1.4 upstream port | Built |
| 1.2 Linux mirror/offload | Mirror exists; offload deferred by D5 |
| 1.5 sidebar feel; 1.6 memory | Implementation exists; §2.12 budgets still require measurement; React comparison superseded by D3 |
| 1.7 Arc flows | Implemented with gaps tracked below and in the parity review |
| 2.1 store; 2.2 profiles; 2.3 tabs; 2.4 Chrome UI; 2.5 sidebar; 2.6 drag; 2.7 switching | Built; Chrome UI coverage, timing and bulk-selection integration need qualification |
| 2.8 profile creation; 2.9 hide/reveal/fullscreen | Built; sign-in completion, reveal dwell and geometry gaps below |
| 2.10 Command Bar; 2.11 Archive/Library; 2.12 themes; 2.13 menus/keys | Built; first-frame budgets, Clear Archive and exact motion remain |
| 3.1 first-run; 3.2 sidebar import; 3.3 login import; 3.4 onboarding; 3.5 default browser | Built in native Swift; device-bound sessions and later-profile flow remain acceptance work |
| 4.1 signing; 4.2 updates; 4.3 rebase agent; 4.4 smoke suite | Tooling built; distribution qualification and multi-release replay remain separate gates |
| Phase 5 release | Promote only with release evidence and daily-use acceptance, not the obsolete week estimate |

### Next

Use the [ranked Next up list](qa/arc-parity.md#next-up) as the coordination ledger. Its 2026-11-07 snapshot orders the following work; concurrent implementations must be checked before reopening a task:

1. **CB-1 / SP-10:** meet first-frame Command Bar and new-Space budgets, including tails.
2. **PK-1 / AT-1:** finish and verify Public Suffix List site identity and rule precedence for page/Peek links. Model routing work has landed since the audit; app integration and checks remain the completion gate.
3. ~~**SB-61:** recheck key-window, pointer and hidden state after reveal dwell.~~ Done (81ef100).
4. ~~**SB-36:** finish and verify the concurrent bulk-selection UI across windows and saved items.~~ Done (4abcd61..06fc76c).
5. **SP-12 / ON-3:** complete ordinary new-profile sign-in feedback and suggested Favorites.
6. ~~**SB-33:** separate folder open/close motion curves.~~ Done (e18710a).
7. **DEV-1:** preserve console call-site attribution and remove disabled instrumentation; coordinate current work.
8. ~~**SP-21 / proposed SP-25:** reconcile the create detent with the measured distance and add left-end Library swipe.~~ Done (0df83bb).
9. **CB-5:** region and full-page Capture with copy/save/share are built (`--script capture`, `notescapture` with its relaunch); portrait Capture (P08b) is not.
   **NT-1:** Notes are built (`--script notes` and `notes-read`, model-level on a locked screen); the visible checks and the marketing shot (`--parts notes`) remain.
10. **Proposed LIB-2:** confirmed Clear Archive.
11. ~~**WIN-4:** hide at the specified resize minimum or explicitly approve the current hysteresis.~~ Done (4ab943b): hides at the minimum.
12. **Proposed SB-63:** plus-menu Boost and file entries.
13. **SP-31:** wire and verify Open Link in Space context-menu routing.
14. **Proposed BST-2:** local Boost sharing/import with executable-code review.
15. **SET-3:** honour the selected backup folder on the archive-triggered path.

**Additional qualification / decisions:** WIN-3 needs a real fullscreen visual check at rest and with the native titlebar revealed, including a notched display. An unhidden button in an offscreen titlebar is not evidence of an always-visible traffic light; if lights remain visible at rest, fix that implementation/test coverage rather than weakening WIN-3. Research does not establish Arc’s exact revealed-titlebar/notch behavior. IM-3 has dedicated synthetic coverage (`--script arcimport2`); WAL-only history requires quitting Arc and reimporting, and extension-localized names can fall back to IDs. Complete permission/passkey, call-provider, protected-service and real-model AI qualification, performance/memory acceptance, and release/rebase gates without treating source presence as a pass.

### Later

Integrated iCloud/encrypted sidebar sync and optional account (§2.16), all-profile extension installation, Library media/recent-file browsing, optional full-URL toolbar, quote copying/suggestion removal, Little Arc’s per-domain profile memory, and the remaining AI features (§2.17). Boosts: a community gallery needs a server (BST-3 has a built-in one), Boost theme colors as CSS variables (Arc's `--arc-palette-*`) and Zap inside frames. iPhone/shared Spaces remain later proposals. Notes: sharing and sync (NT-1). Easels remain a non-goal.

---

## 7. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Upstream engine integration can regress on a rebase | Broken profile or hosted UI behavior | The port exists; apply strict hook checks and engine acceptance gates |
| Re-hosting every piece of Chrome UI is a long tail (prompts, bubbles, choosers) | Missing dialogs, broken extension popups | Start from ArdiaCore's parity list; the acceptance suite grows with every gap found |
| Memory with all profiles loaded, each with its own extensions | Heavier than Arc on a MacBook | Spike 1.6; unload idle profiles if needed (cost: first switch slower) |
| Mac-only development | One Mac is a single point of failure | Rented cloud Mac as backup; Linux box for source review, tooling and mirror checks |
| Google's device-bound sessions | Imported Google logins may expire | "Sign in again" step in onboarding |
| Rebase churn in `chrome/browser/ui` | Hooks and engine layer break | Extended Stable, compile-time hook checks, kill switches, replay tests |
| Migration readiness | Release acceptance may lag migration needs | Keep backups and the fallback in section 9 |
| No Safe Browsing without Google's key | Less phishing protection | Google's paid Web Risk API later; uBlock Origin Lite |

---

## 8. Costs

| Item | One-time | Monthly |
|---|---|---|
| Existing build Mac (D5) | No new purchase required | Existing operating cost |
| Apple Developer Program | | $8.25 ($99 a year) |
| Hosting (tailnet, later Cloudflare R2) | | $0–5 |
| Agent and model usage | | not estimated |

Without buying a Mac: Depot cloud Mac runners at about $125–240 a month.

---

## 9. Migration fallback

1. **Before migration:** back up Arc's data (task 0.1) and keep Arc installed.
2. **If a release is not ready for daily use:** the earlier Chrome extension prototype gives Favorites, pinned folders, Today and Spaces in real Chrome, with Google-only account switching per Space.
3. **Optional:** Ardia (Arc-like profiles in one window, but Dia-styled) or Flecha (Arc-like, per-Space cookies, trunk Chromium) as a stopgap browser.

---

## 10. Remaining product decisions

D1–D9 are accepted; the profile architecture, native UI, build machine, product identity and inclusion of DRM, splits, Peek and Little Arc are no longer open scope questions. Remaining decisions include the fullscreen evidence gap (WIN-3), sync transport/provisioning (§2.16), and public distribution/licensing gates ([release guide](release.md), [DRM notes](../engine/DRM.md)).

# Airc: v1 spec

Airc is an Arc-style browser for macOS on Chromium. Built and maintained by AI.

Date: 2026-11-03, updated 2026-11-04. Status: draft 3. D1–D9 decided (D6 revised, D8–D9 added 2026-11-06); see section 1.

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

Yesterday's work is also an input: the Chrome extension (a separate prototype, not in this repo). Its data model, Arc importer (`src/shared/arcImport.ts`) and tests carry over.

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

The first spec draft recommended containers (separate cookie jars inside one profile). Containers stay as the fallback if the week-1 spike fails.

**Timeline (estimate).** About 10–12 weeks of agent work to a daily-driver v1, so early February 2027. That is after Arc stops working on **2026-12-22**, so section 9 has the bridge plan: back up Arc's data this week, and use yesterday's extension until v1 ships.

### 0.1 What Arc itself does (observed behaviour)

Observed from using Arc 1.171: its About and settings pages, its data folder and its behaviour, plus Arc's public help centre.

- **Engine:** `ArcCore.framework` is Chromium **156.0.8078.74** built from Chrome's full `//chrome` code, with Arc's own layer replacing only the browser window. The app around it is Swift.
- **Profiles:** each Arc profile is a full Chromium profile in its own `User Data/<dir>` folder, and switching between Spaces of different profiles is instant, so they all stay loaded. Airc models this as one Chromium browser per (window, profile).
- **Profiles are fully separate:** Arc describes each profile as keeping its own history, saved passwords, extensions and other browsing data.
- **A tab can't change profile.** Changing a Space's profile keeps the sidebar items and reloads the tabs in the new profile, after a confirm dialog with "Don't ask again".
- **Extensions, ad blocking and archive timing are per profile.** Favorites are stored per profile.
- **Pinned tabs unload on a timer:** frozen, then discarded, with Gmail, Slack and similar sites exempt.
- **The flows** for New Profile, Create a Space, profile deletion and onboarding are described in section 2.9, in Airc's own words.

**ArdiaCore** (in the Ardia repo, `engine/ardiacore/src/ardia/core/`) does the same thing as an open-source layer:
- It links into Chrome's own framework.
- It gives each profile a Chromium `Browser` whose window is a plain object with no Chrome UI.
- It re-hosts the Chrome UI that normally hangs off the window: permission prompts, autofill and passkey UI, extension popups, the find bar, DevTools and choosers.
- Ardia's own files are **Apache-2.0**, so we can port them with their notices.
- Its code includes only Chromium's own headers. The one file that mentions Helium (`ac_strings.cc`) holds product-name strings, but it was built and tested on a Helium tree. Building it on plain Chromium is the week-1 spike.

---

## 1. Decisions to confirm

| # | Decision | Recommendation | Why | Alternative |
|---|---|---|---|---|
| D1 | What a "profile" separates | **Real Chromium profiles, Arc's way** (revised): logins, history, saved passwords and extensions separate per profile. All profiles loaded; one Chromium browser per (window, profile) inside our own window. | Exactly what Arc does and promises. One window, so fullscreen and instant switching work. ArdiaCore (Apache-2.0) is an open-source implementation to port. | **Containers** (separate cookie jars in one profile; Brave and Flecha). Simpler, but history, passwords and extensions are shared. Fallback if the ArdiaCore spike fails. |
| D2 | Base | **Upstream Chromium Extended Stable tags** built as Chrome's own framework, plus our engine layer `//airc/core` (ArdiaCore port) and a short hook series (about 15–25 patches). | No dependency lag, permissive licence, smallest rebase surface for the agent. Extended Stable means about 6 major rebases a year instead of 26, with weekly security fixes in between. | Fork Ardia whole (GPL-3.0, Helium-based, React Native shell, Dia-styled). Fork Flecha (MIT, trunk Chromium, containers). Fork Brave (containers, big product to strip). |
| D3 | UI technology | **All Swift (decided 2026-11-04).** AppKit for the window, sidebar, Space switching, gestures and animations (Core Animation springs); SwiftUI for onboarding, settings and the Space and profile editors. No web-rendered UI. | Matches Arc, smoothest 120 Hz motion, one language for the whole app, and the agent can build and test it on the Mac in minutes. | React screens in a hidden profile (Arc's way; the previous plan). |
| D4 | Licence | **Open source, Apache-2.0** (decided 2026-11-04) for the whole repo, including the homepage. Ported ArdiaCore files keep their Apache-2.0 notices; anything copied from Flecha (MIT), ungoogled-chromium (BSD) or T3 Code (MIT) keeps its notice in NOTICE. GPL code (Helium, ilo, Ardia's Helium patches) is read for ideas only. Secrets (signing certificates, Sparkle key, deploy tokens) never go in the repo. | Same model as T3 Code: everything public, keys in CI secrets. | GPL-3.0 would allow building on Helium or Ardia. |
| D5 | Mac | **The owner's MacBook (Apple M5, 32 GB, ~155 GB free) is the build and test machine** (decided 2026-11-04), reached from the Linux box over Tailscale SSH. Nightly builds at 01:15 (the Mac wakes at 01:00 and never sleeps on the charger). Compiles run on the Mac only: no Linux compile offload for now. | No purchase; the build lands on the machine it is tested on. | Mac mini M5 Pro later if the MacBook is too slow or busy; Depot cloud Mac runners. |
| D6 | Netflix, Spotify and other DRM | **Revised 2026-11-06: DRM is wanted** (the owner: Spotify must play). Widevine through Chromium's component download, with a "Play protected content" switch (on by default); engine/DRM.md. | Public builds may need Google's Widevine licence; services that require VMP (Netflix) may need extra signing. | Owner decides the licence step before public launch. |
| D7 | Native macOS fullscreen | **Keep native fullscreen.** All profiles share one window, so there is no problem. | | |
| D8 | App identifier | **`com.aircbrowser.Airc` for public builds** (owner, 2026-11-06). The private dev channel stays `org.airc.Airc.dev`; dev and test builds are `org.airc.Airc.test` (WebKit `.test.webkit`) so they never claim the owner's links or permissions. | Permanent from the first public install. | |
| D9 | Product analytics | **On by default, opt-out**, like T3 Code (owner, 2026-11-06): anonymous PostHog EU events, never content; Settings → Privacy, docs/user/telemetry.md. | Needs a privacy page on the homepage at launch. | |

---

## 2. Product spec (v1)

Requirement IDs (`SB-…`, `SP-…`) are for tracking and tests. "Arc ref" points to sections of [arc_behavior_spec.md](research/arc_behavior_spec.md). Point sizes, timings and colours there are measured from Arc 1.170/1.171 and are the default targets.

### 2.1 Window and layout (Arc ref §1)

- **WIN-1** The whole window takes the active Space's theme: sidebar, title area and a 10 pt margin. The web page sits in a card inset 10 pt with 6 pt corners.
- **WIN-2** No tab strip and no toolbar row. The traffic lights, sidebar toggle, back/forward/reload and the URL field live in the sidebar header.
- **WIN-3** Native macOS fullscreen keeps the sidebar docked. Plan for the MacBook notch: in fullscreen the header starts at the very left, with no traffic lights.
- **WIN-4** Sidebar width defaults to 228 pt (164–500). Drag the edge to resize; dragging past the minimum hides it; double-click the edge to reset.
- **WIN-5** Sidebar on the left by default, with an option for the right (Arc never had one).
- **WIN-6** Kill switches per feature, so a feature broken by a rebase can be switched off and a security update is never held back.

### 2.2 Sidebar header and URL field (Arc ref §2.1–2.2)

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
- **SB-35** Drag rules: tab above the Space name → Favorite; between name and divider → pinned; below the divider → unpinned; onto a folder → into it; to the sidebar's left or right edge for 0.5 s → next Space; ⌥-drag duplicates; out of the window → new window. While dragging, other rows stay still and a 2 pt drop line marks the gap; on drop, rows glide over about 115 ms.
- **SB-36** Multi-select with ⌘-click and ⇧-click; bulk move, archive, "New folder with N items"; ⇧⌘C copies all selected URLs.

### 2.6 Divider, New Tab and Today (Arc ref §2.6–2.8)

- **SB-40** Divider with "Clear" on hover (⇧⌘K). Clear archives every Today tab except the visible one; ⌘Z restores.
- **SB-41** "+ New Tab" row opens the Command Bar; new tabs appear at the top of Today.
- **SB-42** Today tabs are per Space, newest first. Background links line up after their opener.
- **SB-43** Auto-archive after 12 h idle by default (per profile: 12 h, 24 h, 7 days, 30 days). Viewing a tab resets its timer. Tabs playing audio are never archived.
- **SB-44** Tab rows: 41 pt pitch, 14 pt title, audio icon (click to mute), loading ring, close button on hover. The active row in light themes is white 0.85 with a soft shadow, matching the owner's screenshot. A tab activates on press, not release.

### 2.7 Footer and Space bar (Arc ref §2.9)

- **SB-50** Left: Library button (⇧⌘L). Middle: one icon per Space, emoji or a dot, the current one full-strength and the others dimmed. Right: "+".
- **SB-51** Many Spaces squeeze instead of scroll: cells shrink from 34 pt, the current one keeps at least 22 pt, others turn into dots.
- **SB-52** Drag footer icons to reorder Spaces. Right-click for the Space menu.
- **SB-53** "+" menu: New Space… · New Folder… · (later: New Split View, New Note).
- **SB-54** Download progress and a media tray (a player for tabs playing in the background) sit above the footer. The media tray can come in v1.x.
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
- **SB-62** Library: Archived tabs (searchable; restore returns a tab to its Space), Downloads, Spaces. Slides in from the left. Its back button sits exactly where the footer's Library button was (Arc), so a second click without moving the pointer closes it; ✕, ⇧⌘L and Esc close it too.

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
- **SP-21** The swipe pages the sidebar contents horizontally and settles on a critically damped spring in about 0.19 s. A swipe moves at most one Space. Rubber band at both ends; past the last Space, a pull creates a new Space.
- **SP-22** The window colour cross-fades in about 30 ms for a neighbouring Space; during a swipe it blends by how much of each page shows.
- **SP-23** Each Space reopens on the tab it last showed. Switching swaps the page view inside the same window: no window swap, no macOS Space change, no flash.
- **SP-24** The Command Bar only suggests tabs and history from the current profile (history is per profile, so this comes free).

Link routing (**v1**, moved up by the owner on 2026-11-05; high value for one-account-per-Space):
- **SP-30** Rules like "URL contains docs.google.com/a/company → Work Space". Links from other apps (Mail, Slack) go through the rules, otherwise to the most recent Space.
- **SP-31** "Open link in Space ›" in the page context menu.

Consequences of real profiles (decision D1), shown in Settings:
- Extensions are installed per profile, as in Arc. v1.x adds "Install in all profiles".
- Each loaded profile costs memory; spike 1.6 measures how much.

### 2.10 Command Bar and keyboard (Arc ref §5, §7)

- **CB-1** ⌘T opens Arc's centred Command Bar, floating over the middle of the page and drawn in the next frame, which creates no tab until you pick something. It lists open tabs, pinned items and Favorites, history, search, and commands ("Pin tab", "New Space", "Theme", "Move to Space…"). ⌘L opens it on the current URL.
- **CB-2** Shortcuts as in Arc: ⌘T, ⌘L, ⌘W (archive), ⇧⌘T / ⌘Z reopen, ⌘D pin, ⌘S sidebar, ⇧⌘K clear, ⇧⌘C copy URL (with a "Copied" toast), ⌥⇧⌘C copy as Markdown, ⌃1–9 Space, ⌥⌘←/→ Space, ⌥⌘↑/↓ tab, ⌘1–9 sidebar item (Favorites first), ⌃Tab last tab, ⇧⌘L Library, ⌘E extensions. Plus Chrome's standard shortcuts wherever Arc doesn't override them: ⌘R / ⇧⌘R reload, ⌘[ / ⌘] back and forward, ⌘F / ⌘G find, ⌘+ / ⌘− / ⌘0 zoom, ⌥⌘I / ⌥⌘J DevTools and console, ⌥⌘U view source, ⌘P print, ⌘Y history, ⌘, settings, ⌘N new window, ⇧⌘N private window, ⌘Q quit (with Arc's hold-to-quit).
- **CB-3** "Prefer website" rule: if a page uses a shortcut, pressing it again within about 1 s runs the browser's command.
- **CB-4** All shortcuts remappable in Settings (v1.x).

### 2.11 Theming (Arc ref §4)

- **TH-1** Theme picker per Space: colour disc with 1–3 colour handles, nine presets, Auto/Light/Dark, intensity slider (default 0.81) and grain. Every drag recolours the window live.
- **TH-2** Rendering as Arc: colours mixed in OKLab on a 45° diagonal, alpha = 0.2 + 0.55 × intensity, over the macOS window blur, with grain on top. Inactive windows dim the grain.
- **TH-3** One theme drives a palette of tokens used by every surface: sidebar text, hover, selection, Command Bar, menus, toasts.
- **TH-4** Arc themes import exactly (gradient, intensity, grain).

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
| **MEM-3** | Background tabs unload after a per-profile timeout (default 30 minutes, adjustable, like Chrome's Memory Saver); under macOS memory pressure the least recently used tabs unload first, never the visible tab, a tab playing audio, or one with unsaved form input. Unloaded tabs keep their title, icon and scroll position and reload on click |
| **MEM-4** | Total memory for the reference workload ≤ Chrome's for the same tabs; target 20% less |
| **MEM-5** | No leaks: memory after opening and closing 100 tabs returns to within 5% of the start |
| **MEM-6** | Energy: an idle window with no media uses < 1% CPU; no timers while idle |


### 2.13 Onboarding (onboarding ref §3)

A full-window, chromeless onboarding (native window around a React page rendered in the hidden internal profile). Every screen is skippable; target under 2 minutes, about 30 s if skipped.

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

- **IM-1** Arc sidebar from `~/Library/Application Support/Arc/StorableSidebar.json`: Spaces, icons, themes, pinned tree with nested folders, Favorites **per profile**, Today tabs, profile names. Idempotent: re-running doesn't duplicate (keyed on Arc's IDs). Start from yesterday's `arcImport.ts`, fixing its gaps (it merges Favorites across profiles, loses gradients, archived tabs and profile names).
- **IM-2** Arc logins: cookies and saved passwords from each Arc profile folder. The key is the Keychain item "Arc Safe Storage"; macOS asks the user once. Decrypt on the Mac, re-encrypt with our own key, and never send anything off the device. Google sessions that turn out to be device-bound need a "sign in again" prompt.
- **IM-3** Arc history and the extension list (as a checklist of Chrome Web Store links to reinstall).
- **IM-4** Chrome import: stock Chromium on macOS can't import from Chrome. Add a Chrome profile reader (bookmarks, history, passwords, cookies with the "Chrome Safe Storage" key), reusing the same code as IM-2.
- **IM-5** "Back up my Arc data" button: zips Arc's JSON files and `Local State` into `~/Documents`. Also offered outside onboarding, before Dec 22.

### 2.15 Settings, data and privacy

- **SET-1** Settings pages in React (T3 Code's UI kit): General, Profiles (SP-14), Spaces, Shortcuts, Appearance, Import, Privacy, About/Updates. Chrome's own settings remain under "Advanced".
- **SET-2** The sidebar data (profiles, Spaces, Favorites, pinned tree, archive) lives in one store under the user-data folder, independent of any Chromium profile. It is written as an **operation log with timestamps**, so sync can be added later without a migration (accounts ref §5.2).
- **SET-3** Automatic daily JSON backup to a folder the user picks (iCloud Drive works with no integration); manual export and import.
- **SET-4** Anonymous usage data on by default (owner, 2026-11-06), as T3 Code does: closed event names and values only, never URLs, titles, names or text; off in Settings → Privacy, with "See what Airc sends" ([docs/user/telemetry.md](user/telemetry.md)). Crash reports opt-in, with no URLs or titles ever.
- **SET-5** Our own Keychain item name (e.g. "Airc Safe Storage") and bundle ID, fixed forever after the first release. Changing them later would wipe every saved login.

### 2.16 Accounts (later; accounts ref §5)

- **v1:** no account. Everything works offline.
- **v1.x:** "Sync with iCloud" toggle for the sidebar data between Macs, if a CloudKit spike works inside the Chromium app bundle. Otherwise an optional account ("Create an account to sync") with passkey and Sign in with Apple, storing an end-to-end encrypted copy of the operation log.
- **v2:** iPhone companion (Spaces, pins, send to Mac), shared Spaces.
- Passwords stay with the local password manager or 1Password/Bitwarden. Chrome Sync is not available to forks.
- Apply for Apple's browser passkey entitlement now; approvals are slow.

### 2.16b Arc favourites added to v1 (owner, 2026-11-05)

- **AT-1 Air Traffic Control** (SP-30/31):
  - Settings → Links has rules "URL contains / is equal to … → Space", with a default for links from other apps: Little Arc, or the most recent Space.
  - Airc registers as a default-browser candidate, and links from Mail, Slack and others go through the rules.
  - A rule match opens the link already signed in, because the Space carries its profile.
  - Rules also route Peek links.
- **LA-1 Little Arc** (⌥⌘N, and the default for links from other apps):
  - a small floating window with one page and no sidebar, a compact URL row, and the profile of the Space it targets (shown as a chip; switchable);
  - "Open in" via ⌘O moves the page into the most recent Space, ⌥⌘O lets you choose a Space; the page moves without reloading;
  - Little Arc windows auto-archive after 6 h;
  - a mini player keeps media playing when it's closed.
- **PW-1 Private windows** (⇧⌘N): a dark window of its own with a simple sidebar (the address field, its tabs, New Tab, and "Private" with an eye-slash where the Space name is; no Spaces, Favorites or pinned items, as in Arc's incognito window). Its pages use the off-the-record profile of the current Space's profile (one session per profile, shared by its private windows, as in Chrome); on WebKit, and for DRM pages in the Chromium build, a non-persistent data store. Airc keeps nothing of it: no history, no session restore, no Archive, nothing in ⌘T's history, no telemetry about its pages (only `private_window.open`). Its cookies and site data go when the last private window of the profile closes. ⌘T opens its own Command Bar (its tabs, built-in sites and search, no history), ⌘W closes a tab, ⇧⌘N opens another private window. ⌘N (more ordinary windows) is later.
- **SV-1 Split View**:
  - drag a tab onto a tab, or use ⌃⇧+ / the "+" menu, for 2–4 panes, horizontal or vertical, with resizable dividers;
  - a split is one row in the sidebar, and "Separate All Tabs" undoes it;
  - each pane keeps its own profile from its Space;
  - ⌘[ / ⌘] focus the panes, and ⌘W closes the focused pane.
- **SV-2 Pinned and Favorite splits** (owner, 2026-11-06): a split can be pinned in a Space or kept as a Favorite, as in Arc. It restores as the same split with each pane's saved URL. Closing one asks "Leave site?" for every pane with unsaved changes, one at a time (Stay keeps the split open). A tab dropped on its row, or on the middle of a Favorite split's tile, joins it as one more pane, up to four (left half first, right half last; Arc's own rule here isn't recorded).
- **PK-1 Peek**:
  - cross-site links from pinned tabs and Favorites (and ⇧-click on any link) open in an overlay card above the page;
  - ⌘O promotes it to a tab, and the Split button turns it into a split;
  - clicking outside, ✕ or ⌘W closes it, and ⌘Z / ⇧⌘T reopen it;
  - it can be turned off in Settings → Links.
- **BST-1 Boosts** (2026-11-06; [docs/user/boosts.md](user/boosts.md)): one Boost per site (registrable domain, its subdomains included), on or off, the same in every Space and profile (Arc). Stored in a local `Boosts.json`, never synced or sent. The editor opens from Site Controls ("Boost this site"; a boosted site shows "Boosted" with a switch, and a brush in the URL field) and View → Boost This Site… (no shortcut, as in Arc), with Colors (tint, brightness, contrast, invert), Font (macOS fonts, a size), Zap (click to hide, a selector per element, undo, Reset Zaps) and Code (CSS and JavaScript, Save). CSS reaches pages through the engine's page script at document start, so there is no flash; custom JavaScript runs only from the editor, only on its own site (checked against the engine's frame origin), once per page load. Top frame only for now. Both engines (WebKit: a WKUserScript).

### 2.17 Out of scope for v1

Split View, Peek (v1.x; until then cross-site links from pinned items open as Today tabs), Little Arc, Easels and Notes, link previews, Live Calendar countdown, AI features, Windows and Intel Macs, iPhone, DRM. (Boosts came in anyway: BST-1.)

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
 ├─ Web screens: onboarding, settings, Space and profile editors
 │    React + T3 Code's UI kit, rendered by the engine in a hidden internal profile (as Arc does)
 └─ SpacesStore: profiles, Spaces, items, archive; SQLite op log under the app's data folder
        │
        │  Objective-C API exported by the framework
        ▼
Airc Framework.framework  =  Chrome's own //chrome:chrome_framework  +  //airc/core (ArdiaCore port)
 ├─ ProfileHost: create, load, delete Chromium profiles; keep every profile loaded; one hidden profile
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
airc/                       our git repo
  CHROMIUM_VERSION             exact Extended Stable tag, e.g. 156.0.8078.80
  app/                         Xcode project / Swift packages for Airc.app
    Sources/Sidebar, Spaces, CommandBar, Window, Onboarding host, Store
    Tests/                     XCTest (store, model, importer) and XCUITest (journeys)
  engine/core/                 //airc/core: ArdiaCore port (Objective-C++), exported API
  engine/patches/series        hooks into Chromium, one concern per patch, strict apply
  engine/apply.sh              copies //airc/core in and applies hooks (ArdiaCore's apply.sh model, with --check)
  web/                         React + Tailwind screens (onboarding, settings, editors), T3 Code UI kit
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

Stored as an operation log with timestamps (accounts ref §5.2) so sync can come later without a migration. Backed up daily as JSON. Yesterday's extension model (`src/shared/`) is the starting point.

---

## 4. Development environment and testing

### 4.1 Machines

The app and the engine layer (Objective-C++) are macOS-only, so **the Mac mini is the main development machine from week 1**, not just a release builder.

| Machine | Role |
|---|---|
| **Mac mini M5 Pro** (decision D5) | Chromium checkout and engine builds, the Swift app, all UI work, tests, signing, release builds. On the tailnet; agents drive it over SSH. |
| **the Linux build box** (this Linux box: 16 cores / 32 threads, 46 GB, SSD at `~`) | Compile offload for the Mac's Chromium builds (remote execution, the way Helium's builder does it); Chromium source mirror and conflict checks for each new Chrome release; the React screens (Vite dev server, component tests); model and importer logic tests. |
| **Owner's MacBook** | Daily use of beta builds; the final judge of feel (section 2.12). |

Until the Mac mini arrives, a rented cloud Mac fills the gap (Depot or MacStadium, dev ref §3.3).

### 4.2 Builds

- **Engine:** Chromium checkout on the Mac's SSD, Extended Stable tag, `apply.sh` copies `//airc/core` in. A component dev build for daily work; an official arm64 build (ThinLTO + PGO) for releases, about 3–4.5 h cold and 1–1.5 h for a security respin (dev ref §3.2). The first full build on the Linux box takes about 3–5 h and serves as the mirror and conflict check.
- **App:** Xcode / SwiftPM build against the dev framework; incremental app builds take seconds, so UI iteration doesn't wait for Chromium.
- **Web screens:** Vite with hot reload against a mock of the engine API, then bundled into the app.

### 4.3 Seeing work in progress from the MacBook

- **Live:** macOS Screen Sharing to the Mac mini over Tailscale (built into the MacBook, no setup beyond enabling it).
- **Async:** a review page on the tailnet: after each build the agent posts screenshots, screen recordings, test results and a changelog. Works from the iPhone too.
- **Real use:** every passing build becomes a beta DMG the MacBook updates to through Sparkle.

### 4.4 Tests

| Layer | Tool | What |
|---|---|---|
| Model | XCTest (Swift) | Store and op log, archive timers, drag-and-drop rules, Favorites grid layout, Arc importer |
| Engine | Acceptance script against a hidden instance (ArdiaCore's `acceptance.mjs` has 29 checks to start from) | Two profiles in one window, popups land as our tabs, extension popup, permission prompt, autofill, DevTools, clean quit |
| Accounts | CDP (Puppeteer) on the engine's remote debugging port, with a fake Google server | Two Spaces signed into different accounts never leak; restart restores both |
| UI journeys | XCUITest | Click Space 2 → its tabs show → account changes; create Space with new profile; hide/reveal; swipe; shortcuts |
| Web screens | Vitest + Testing Library; Puppeteer for in-app runs | Onboarding and settings |
| Visual | XCUITest screenshots vs stored baselines | Flags differences on the review page |
| Perf | Instruments (Core Animation, Time Profiler) on the MacBook | The budgets in section 2.12 |

**Smoke suite after every rebase**, under 30 min after the build: hooks apply cleanly → engine and app build → engine acceptance checks → account-separation test → XCUITest journeys → screenshots to the review page → signature, notarization and Sparkle update-from-N-1 checks.

---

## 5. Release and update pipeline

- **Signing:** Apple Developer Program ($99 a year), Developer ID, hardened runtime, notarization, DMG, stapling. Chromium's own signing scripts cover the framework and helpers.
- **Updates:** Sparkle 2.10 with EdDSA signatures and delta updates. The update feed is on the tailnet first (private, free); public hosting when friends join. Two channels: beta (every build that passes the smoke suite) and stable (promoted after a day of the owner's use, or immediately for actively exploited security fixes).
- **Agent rebase loop** (dev ref §6):
  1. Poll Google's version API for a new Extended Stable (or Stable) Mac release.
  2. Sync the tag; run `apply.sh --check`; fix drifting hooks; compile `//airc/core`. ArdiaCore uses about 134 includes from `chrome/browser/ui` and 161 from `content/public`, so most breakage shows up as compile errors the agent fixes.
  3. Official build, sign, notarize.
  4. Smoke suite, review page, beta channel, notify the owner.
  5. **Fallback:** if a non-essential feature breaks, ship with its kill switch off. Never ship an older Chromium; profiles can't be downgraded.
- Before going live, replay the last few Chrome releases to measure how often the hooks break.

---

## 6. Task plan

Each task lists what to do, the research to start from, and how we know it's done. Weeks are estimates for agent work with the owner reviewing.

### Phase 0: this week, before anything else (owner)

| # | Task | How | Done when |
|---|---|---|---|
| 0.1 | Back up Arc data | Copy `~/Library/Application Support/Arc/` (at least `StorableSidebar.json`, `StorableArchiveItems.json`, `StorableWindows.json`, `User Data/Local State`) somewhere safe. Keep Arc installed: macOS 27 may block reading its folder once it's gone. | Backup exists |
| 0.2 | Record Arc for ground truth | Screen-record 2–3 minutes on the MacBook: Space swipes, creating a Space and a profile, hide/reveal, folder hover, drag and drop. | Videos uploaded |
| 0.3 | Get a Mac | Order the Mac mini (or approve a rented cloud Mac to start now). Enable Screen Sharing and Tailscale on it. | Agents can SSH in |
| 0.4 | Apple Developer Program, passkey entitlement request | Dev ref §5, accounts ref §5 | Enrolled, request filed |
| 0.5 | Confirm decisions D1–D7 | Section 1 | Answered |

### Phase 1: environment and spikes (weeks 1–3)

| # | Task | How (start here) | Done when |
|---|---|---|---|
| 1.1 | Mac Chromium checkout and first builds | Dev ref §8 phase 2: Xcode, depot_tools, `fetch` on the Mac's SSD, Extended Stable tag, component build. | `Chromium.app` builds and runs on the mini |
| 1.2 | Linux mirror and compile offload | Dev ref §8 phases 0 and 5: Linux checkout of the same tag; remote-execution worker the Mac compiles on. | Mac rebuild measurably faster with offload |
| 1.3 | Repo skeleton and review page | Section 3.2; review page on a free tailnet port. | Empty app + framework build in one command |
| 1.4 | **Spike: ArdiaCore on upstream Chromium** | Port `engine/ardiacore/src/ardia/core/` (Apache-2.0) as `//airc/core`, rename symbols, drop the Helium strings file, run its `apply.sh` hooks against our tag. Minimal AppKit host: one window, two profiles, two Google accounts, switch between them. | Its acceptance checks pass; two Google accounts side by side; restart restores both |
| 1.5 | **Spike: sidebar feel** | AppKit prototype: 200-row outline list, three Space pages, swipe paging with Arc's spring (about 0.19 s), colour cross-fade, hide/reveal. Measure on the MacBook. Optionally the same list as a React page in a native container, to settle D3's alternative. | Numbers vs the section 2.12 budgets |
| 1.6 | **Spike: memory with all profiles loaded** | Six profiles (the owner's Spaces) with the owner's extensions in each; measure memory and launch time. | Numbers; decide whether idle profiles unload |
| 1.7 | Copy Arc's flows exactly | Match Arc's flows, as observed in use, in sections 2.4, 2.7, 2.9 and 2.13, with Airc's own wording. | Spec updated |

### Phase 2: core app (weeks 3–8)

| # | Task | How | Done when |
|---|---|---|---|
| 2.1 | SpacesStore | Section 3.4; port the extension's model and tests to Swift. | XCTests pass; survives kill -9 |
| 2.2 | Profiles for real | ProfileHost: create (with a pre-created spare profile so a new one is instant), delete, keep loaded, hidden internal profile; change a Space's profile with reload + confirm (Arc's behaviour). | Profile journeys pass |
| 2.3 | Tabs and binding | Engine tab ↔ Space ↔ item; per-Space last-active tab; restore after restart; unload on timer (exempt Gmail, Slack); popups land as our tabs in the right Space. | Restore and discard tests pass |
| 2.4 | Re-hosted Chrome UI parity | Permission prompts, autofill, passwords, passkeys, extension icons and popups, downloads, find bar, context menus, DevTools, printing, PiP. ArdiaCore's `ardiacore-parity.md` lists what's covered. | Parity checklist green |
| 2.5 | Sidebar UI | AppKit: header, URL field, Favorites grid, Space header, pinned tree and folders, divider, New Tab, Today, footer. Arc ref §2 for every size and colour. | Side-by-side with Arc recordings looks the same |
| 2.6 | Drag and drop | All rules in SB-35; reuse the extension's drop-rule tests. | XCUITest for each rule |
| 2.7 | Space switching | Footer, keys, ⌥⌘ arrows, mouse buttons, swipe; spring settle; colour cross-fade; view swap in the engine. | Meets switch budgets on the MacBook |
| 2.8 | Profile creation flow | New Space form with inline new profile + Google sign-in card (SP-10…12); profile indicator (SB-22); Settings → Profiles. | New Space with a new profile signed into Google in under 15 s |
| 2.9 | Hide, reveal, resize, fullscreen | ⌘S, edge reveal spring, drag resize, notch. | Matches Arc ref §2.10 timings |
| 2.10 | Command Bar | Results from tabs, items, history of the current profile, commands. T3 Code's command palette as the interaction model. | ⌘T flow works |
| 2.11 | Archive and Library | Idle timers per profile, Clear, ⌘Z, Library panel. | Archive tests pass |
| 2.12 | Theming | Picker; OKLab gradient + grain rendering (Metal or Core Image) behind the window. Arc ref §4. | Arc themes look identical after import |
| 2.13 | Menus and shortcuts | App-owned main menu and key handling; "prefer website" rule. | CB-2 table works |

### Phase 3: onboarding and import (weeks 6–10, overlaps)

| # | Task | How | Done when |
|---|---|---|---|
| 3.1 | First-run flow | Our app decides first run (no Chromium first-run UI); chromeless onboarding window hosting the React screens in the hidden profile. | Fresh install opens onboarding; a test flag skips it |
| 3.2 | Arc sidebar import | Port `arcImport.ts` to Swift and fix its gaps (IM-1). | The owner's real `StorableSidebar.json` imports exactly |
| 3.3 | Arc and Chrome logins import | Each Arc profile folder → one of our profiles; Keychain key, decrypt, re-encrypt (IM-2, IM-4). Onboarding ref §4.3–4.5. | Owner stays signed into Gmail in every Space after import |
| 3.4 | Onboarding screens | Section 2.13; T3 Code's wizard gating logic, cinematic presentation. | Full run under 2 minutes |
| 3.5 | Default browser | Chromium's `shell_integration_mac.mm` approach (one system prompt on macOS 26.4+). | One prompt, state updates live |

### Phase 4: release pipeline and automation (weeks 5–10, parallel)

| # | Task | How | Done when |
|---|---|---|---|
| 4.1 | Signing and notarization | Dev ref §5. | `spctl` accepts the DMG |
| 4.2 | Sparkle | Feed on the tailnet; beta and stable channels. | N-1 build updates itself to N |
| 4.3 | Version poller and rebase agent | Dev ref §6; `AGENTS.md` playbook; kill-switch fallback. | Dry run replays the last 3 releases |
| 4.4 | Smoke suite | Section 4.4. | Runs unattended after each build |

### Phase 5: v1 release (weeks 10–12)

Owner uses beta builds daily, bugs fixed, performance budgets verified, then v1 on the stable channel.

### After v1

Media tray, Developer Mode for localhost, remappable shortcuts, "install this extension in all profiles", iCloud sync spike, optional account, Split View, Little Arc. Boosts (BST-1) next: a gallery of Boosts and sharing one as a file (Arc's "Share Boost", without a server), Boosts inside iframes, per-Space Boosts, a Boosts list in Settings, and the "+" menu's New Boost.

---

## 7. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| ArdiaCore was built and tested on a Helium tree, not plain Chromium | Spike 1.4 finds gaps | Week-1 spike; fallback is containers (first draft of this spec, kept as `Arc fork v1 spec (draft 1, containers).md.bak`) |
| Re-hosting every piece of Chrome UI is a long tail (prompts, bubbles, choosers) | Missing dialogs, broken extension popups | Start from ArdiaCore's parity list; the acceptance suite grows with every gap found |
| Memory with all profiles loaded, each with its own extensions | Heavier than Arc on a MacBook | Spike 1.6; unload idle profiles if needed (cost: first switch slower) |
| Mac-only development | One Mac is a single point of failure | Rented cloud Mac as backup; Linux box for offload and web screens |
| Google's device-bound sessions | Imported Google logins may expire | "Sign in again" step in onboarding |
| Rebase churn in `chrome/browser/ui` | Hooks and engine layer break | Extended Stable, compile-time hook checks, kill switches, replay tests |
| Schedule vs Dec 22 | v1 lands after Arc stops | Bridge plan (section 9) |
| No Safe Browsing without Google's key | Less phishing protection | Google's paid Web Risk API later; uBlock Origin Lite |

---

## 8. Costs

| Item | One-time | Monthly |
|---|---|---|
| Mac mini M5 Pro 64 GB / 2 TB | about $2.7–3.2k | about $5 power |
| Apple Developer Program | | $8.25 ($99 a year) |
| Hosting (tailnet, later Cloudflare R2) | | $0–5 |
| Agent and model usage | | not estimated |

Without buying a Mac: Depot cloud Mac runners at about $125–240 a month.

---

## 9. Bridge until v1

1. **This week:** back up Arc's data (task 0.1) and keep Arc installed.
2. **Until v1:** yesterday's Chrome extension gives Favorites, pinned folders, Today and Spaces in real Chrome, with Google-only account switching per Space.
3. **Optional:** Ardia (Arc-like profiles in one window, but Dia-styled) or Flecha (Arc-like, per-Space cookies, trunk Chromium) as a stopgap browser.

---

## 10. Open questions for the owner

1. D1: go with Arc's real profiles (recommended), or the simpler containers?
2. D5: buy a Mac mini, or rent cloud Macs? This now blocks week 1.
3. Name and icon for the browser.
4. Personal use only, or friends later? It decides the update hosting and some codec and trademark questions.
5. How much do Netflix and Spotify in the browser matter (D6)?
6. Which Arc extras do you miss most after the sidebar: Peek, Split View, Little Arc, link routing?

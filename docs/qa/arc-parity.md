# Arc parity review

Reviewed 2026-11-05 against working-tree source at base `6a3a4c0`. Independent static QA; no app code changed. Concurrent implementation work may supersede individual findings.

Evidence: `docs/spec.md` §2; `docs/research/arc_behavior_spec.md` (especially §2, §4, §6); `docs/design.md`; four supplied private Arc crops; existing app captures and design mockups. No private sidebar content is reproduced here. Artifact paths below are relative to the external project evidence root: `status/runs/2026-11-05_0115/snapshots/` is **N**, `artifacts/app/` is **A**, `artifacts/design/mockups/` is **D**. Source paths are repository-relative. These artifacts are not checked into this report.

The basic silhouette is credible: 228 pt sidebar, 41 pt row pitch, 47 pt tiles, 14 pt titles, white 0.85 active plate, 10 pt page inset and 6 pt page corners. The mockup is not evidence that the corresponding interaction ships. The private crops confirm the layout, but are cropped and at a different scale from the app captures; do not derive fullscreen offsets or a colour regression from a raw pixel comparison.

No fresh Mac build or interactive test was run; the busy build Mac was left alone. Existing nightly captures are generated through `Debug/SnapshotRunner.swift:386` under `apps/browser/Sources/Airc/`: the page is composited from an engine snapshot. They are useful layout evidence, not compositor/frame-rate evidence. In particular, N/06-command-bar.png and N/07-new-space-sheet.png contain a fractional sidebar position: treat that as a capture/settling question, not proof that normal interaction leaves the sidebar stuck.

## 1. Top 15, ranked by owner noticeability

### 1. The owner's browser cannot be brought into the app through the UI

**ON-5, TH-4** (also ON-1, IM-1). Arc provides an import/setup journey; Airc's explicit owner requirement supersedes the older fullscreen prose: a **760 × 540 pt**, chromeless, draggable floating card expanding into the browser. `apps/browser/Sources/Airc/Stubs/Stubs.swift:40` returns false for onboarding; `:50` routes import to a stub. D/onboarding.png is a mockup, not that journey. Design-package window components do not make it reachable. **Fix:** connect first-run detection, importer and floating-window flow to AppDelegate; verify a synthetic multi-profile import and finish-to-browser transition. Keep the owner's data out of test fixtures.

### 2. Favorites do not reliably return to their saved destination

**SB-12, SB-31, SB-32.** Arc's saved-URL semantics make a Favorite a dependable app entry point; no numeric timing was measured for resetting. `packages/AircKit/Sources/AircKit/StoreActions.swift:221` returns an existing live item unchanged, and `apps/browser/Sources/Airc/Browser/WindowController.swift:326` activates it without reloading the saved URL. Ordinary cross-site link navigation is allowed by `Engine/WebKitEngine.swift:314` (under the same app source root), so the specified Today-tab fallback for missing Peek is also absent. **Fix:** distinguish Favorite activation/reset from pin activation; expose link-navigation disposition to the controller and open cross-site links from saved items as Today tabs. Test drift, reactivation, reset and command-reset separately.

### 3. Swipe and creation already miss the latency bar in the tiny fixture

**SP-10, SP-11, SP-21, SP-23; spec §2.12.** Arc's settle spring is **response 0.19 s, ζ 1**; Airc's input-to-first-frame target is **≤16 ms**, and new Space creation is **one frame** (8.33 ms at 120 Hz). N/log.txt reports **35.7 ms** for swipe release→page swap and **22.6 ms** for Enter→switched. Four click/key handlers report 3.3–5.7 ms, but these are synchronous code timings, not presentation timestamps. **Fix:** remove storage, full-page refreshes and theme rasterization from these handlers (risks below); measure input→presented frame with signposts and a 120 Hz trace. Do not label the current run “insanely smooth.”

### 4. Command Bar cannot find browsing history

**CB-1, SP-24.** Arc opens its bar in **one frame**, approximately **765 pt wide / 64 pt input**, and searches history as well as sidebar items. `apps/browser/Sources/Airc/CommandBar/CommandBar.swift:337` builds tabs, saved items, Spaces and actions, but never history candidates. The `history` enum in AircKit is unused here. N/06-command-bar.png demonstrates rendering only. **Fix:** add an asynchronous, current-profile history provider with cached immediate results and stale-query cancellation; verify no cross-profile suggestions.

### 5. Essential browser controls are decorative or stubbed

**SB-1, SB-2, SB-3, SB-4.** Arc has **32 × 32 pt** navigation plates, a **36 pt** host field, history on long/right press and profile-scoped extension/autofill UI. `apps/browser/Sources/Airc/Sidebar/SidebarChrome.swift:32` configures simple navigation actions; `Browser/WindowActions.swift:14` only goes back/forward. `Sidebar/SpacePage.swift:30` sends Site Controls to a stub; `Stubs/Stubs.swift:45` does the same for extensions. WebKit cannot stand in for Chrome extension/password/passkey parity. **Fix:** wire real site controls/history menus and command-click history actions; complete and exercise engine-hosted Chromium surfaces in the same window. Mark engine-dependent parts unavailable until tested.

### 6. Dragging stops short of Arc's organizing workflow

**SB-35.** Arc uses **0.5 s edge dwell**, a **2 pt drop line**, stationary peers during dragging and roughly **115 ms** row motion after drop; Option duplicates and dragging out creates a window. `apps/browser/Sources/Airc/Sidebar/SpacePage.swift:550` handles only local destinations in a nested event loop; `Browser/WindowActions.swift:80` always moves. No edge-dwell, modifier duplication or tear-out path exists there. **Fix:** use a drag session/state machine with those destinations, cancellation and autoscroll; retain the existing drop-line behavior. Validate each rule independently, including crossing profiles.

### 7. Multi-selection is absent

**SB-36.** Arc supports command/shift selection, bulk operations and copying all selected URLs; no measured animation value applies beyond the **one-frame** row feedback target. `apps/browser/Sources/Airc/Sidebar/SidebarRows.swift:435` activates a single entry; command handling is confined to pinned reset, with no selection set/range anchor. **Fix:** add selection state distinct from the active page; route move/archive/folder/copy to the selection and preserve it during drag.

### 8. Library is a short menu, not a workspace

**SB-62, SB-54.** Arc pushes a **417 pt** Library in with **0.245 s / ζ 0.92**, including searchable Archive, Downloads and Spaces. `apps/browser/Sources/Airc/Stubs/Stubs.swift:9` offers only the last **15** archived entries in an NSMenu. No download-progress shelf exists in `Sidebar/SidebarChrome.swift`. **Fix:** implement a searchable panel, restore-to-origin behavior, download state and Spaces management; media tray may remain v1.x. Preserve the existing restore action while replacing its container.

### 9. The app never enables the approved translucent window material

**TH-2, WIN-1.** Arc uses **45° OKLab**, colour alpha **0.2 + 0.55 × intensity**, blur and grain; inactive grain drops to **¼**. `apps/browser/Sources/Airc/UI/WindowViews.swift:12` constructs both backgrounds without a translucency argument; `packages/AircDesign/Sources/AircDesign/AppKit/SpaceBackgroundView.swift:55` defaults to **off**. D/window-translucent-subtle.png therefore promises a material the app does not request. **Fix:** pass the persisted Subtle default to the base background, disable the overlay's second material, and wire Off/Subtle/More. Verify over a busy desktop. Respect the approved contrast-related colour deviations in docs/design.md rather than treating them as bugs.

### 10. Profile setup does not finish the account workflow

**SP-12, SP-14, SB-22.** The spec's avatar and one-click account setup are Airc additions; Arc has no measured avatar size here. New-profile creation must remain **one frame**. `apps/browser/Sources/Airc/Browser/WindowActions.swift:133` gates a sign-in card on an empty Space; `Sidebar/SpacePage.swift:165` uses a text profile pill. `Stubs/Stubs.swift:35` leaves Settings unavailable. There is no completed sign-in→avatar→suggested-Favorites flow in these UI paths. **Fix:** connect account metadata and successful sign-in, offer Favorites, and ship profile settings including archive timing, search engine and clear-data controls; retain typed-name deletion protection.

### 11. Folder browsing lacks preview and uses the wrong motion path

**SB-33, SB-34; §2.12.** Arc previews a closed folder after **450 ms** (**90 ms in / 80 ms out**), opens it over **200 ms ease-out**, closes with **ω≈25, critically damped (~240 ms visually)**. `apps/browser/Sources/Airc/Sidebar/SidebarRows.swift:487` has folder configure/click handling but no searchable hover preview. `Sidebar/SpacePage.swift:463` uses the generic row spring for rearrangement regardless of folder opening/closing. **Fix:** add a cancellable preview controller and pass a mutation-specific curve/spring into list layout. Preserve 16 pt nesting and press activation.

### 12. Space gestures and footer rearrangement are incomplete

**SP-21, SB-52.** Arc's end pull has a **60 ms** ready fill, **1.13× / 120 ms** detent pop and haptic; normal settling uses **0.19 s / ζ 1**. `apps/browser/Sources/Airc/Sidebar/SidebarChrome.swift:170` always chooses a page and settles, with no create detent. Footer cells at `:270` click or show menus, but cannot drag/reorder. **Fix:** add a terminal create state with threshold-only haptics and a footer reorder session that persists Space order; cancelled gestures must return to the original page.

### 13. Theme editing is swatches, not Arc's colour instrument

**TH-1, TH-4.** Arc offers **1–3 handles**, nine swatches, **0.81** default intensity, grain and appearance. `apps/browser/Sources/Airc/Spaces/Pickers.swift:50` explicitly implements only two colour rows, with no disc/third handle. `UI/DesignBridge.swift:27` also has no texture mapping; import UI is disconnected. **Fix:** implement the three-handle disc and preserve source theme fields through import/model/design conversion; verify with synthetic multi-stop/texture fixtures. Exact end-to-end theme import remains unproven.

### 14. Shortcuts always beat the website

**CB-3, CB-4.** Arc's website-preference policy gives the browser the second matching key within approximately **1 s**. `apps/browser/Sources/Airc/App/Commands.swift:192` intercepts matching shortcuts before the page and consumes them immediately. No preference or second-press policy exists; remapping is a v1.x gap. **Fix:** centralize shortcut arbitration, keep a timestamp per command, and let opted-in website actions receive the first press. Test with a page editor as well as browser text fields.

### 15. Unused Favorites keep consuming resources indefinitely

**SB-15** (and saved-item lifecycle). Arc freezes/discards unused pages while retaining the tile; its default unload interval was **not recovered**, so do not invent an Arc-exact timeout. `apps/browser/Sources/Airc/Browser/WindowController.swift:74` schedules flush and Today archive, not saved-item suspension; `Engine/WebKitEngine.swift:266` returns false for discard. **Fix:** implement a bounded lifecycle policy with audio/session-sensitive exemptions, retain the sidebar item and restore lazily. Measure memory and painted-frame latency after suspension; keep timeout configurable until reference measurements exist.

## 2. Smoothness risks in code

These are causal code risks, not claims of measured dropped frames. At 120 Hz the main-thread frame budget is 8.33 ms.

| Risk and evidence | Concrete fix |
|---|---|
| **Synchronous SQLite on interaction.** `packages/AircKit/Sources/AircKit/SpacesStore.swift:273` flushes normal mutations before notifying observers; `:295` encodes JSON and writes entities plus op log in a SQLite transaction. `:398` also writes window state synchronously. `StoreActions.swift:244` activates through this path. | Apply in-memory mutations and render immediately; serialize immutable operation batches on a dedicated writer, retain ordering, retry failures and establish explicit durable flush barriers for shutdown. Do not simply discard pending operations on an I/O error. |
| **Periodic I/O on main.** `apps/browser/Sources/Airc/Browser/WindowController.swift:74` flushes every 2 s; its archive callback invokes backup, whose implementation at `packages/AircKit/Sources/AircKit/SpacesStore.swift:461` encodes/writes/enumerates files. | Move persistence and backup I/O to the writer queue; snapshot state once and avoid overlapping backups. Instrument timer fire during swipe/typing. |
| **All Spaces refresh after every store change.** `apps/browser/Sources/Airc/Browser/WindowController.swift:199` ignores change granularity and `:213` reloads every page; `show` also reloads the visible page immediately. `Sidebar/SpacePage.swift:356` configures every tile/row. | Use StoreChange refs, cache per-Space row models and update only affected rows; mark offscreen pages dirty. Refresh selection without recomputing the whole tree. |
| **Rasterization at first theme switch and aspect changes.** `packages/AircDesign/Sources/AircDesign/AppKit/SpaceBackgroundView.swift:95` calls `render`, `:147` synchronously makes the colour image; `:130` repeats when aspect changes >0.02. | Pre-render/cache theme images by theme/appearance/aspect off-main; attach completed CGImages on main. Existing equality guards prevent per-frame regeneration of identical themes—retain them. |
| **Theme slider multiplies work.** `apps/browser/Sources/Airc/Spaces/Pickers.swift:68` calls onChange for each slider event; `Browser/WindowActions.swift:498` (`editTheme`) writes each preview to the store. | Separate transient visual preview from persistence; coalesce render work to one display frame, persist final value on release/close. |
| **Settling is main-thread frame/layout work.** `apps/browser/Sources/Airc/UI/Animator.swift:63` uses a main-runloop display link; `Sidebar/SidebarChrome.swift:109` moves pages and updates theme/footer each step. Sidebar hide invokes `layoutRoot` and resizes the embedded page each frame. | Keep direct finger tracking, but hand autonomous settle to CA transforms where possible; bound page reflow during hide/show, profile layout cost, and avoid updating offscreen page frames. A display link is not itself evidence of 120 Hz presentation. |
| **Nested drag/resize event loops.** `apps/browser/Sources/Airc/Sidebar/SpacePage.swift:567` and `Sidebar/SidebarReveal.swift:157` wait for restricted events. Drag startup also rasterizes a row in `SpacePage.swift`'s `makeGhost`. | Use normal event delivery/NSDraggingSession and a cached ghost image; verify display-link and timer service while the pointer pauses mid-drag. |
| **Command search ranks twice per keystroke.** `apps/browser/Sources/Airc/CommandBar/CommandBar.swift:390` and `:395` repeat ranking over rebuilt candidates; `packages/AircKit/Sources/AircKit/CommandSearch.swift:40` repeatedly folds/allocates strings. | Cache normalized candidates, rank once and reuse the top score; add history asynchronously. Keep the existing panel immediate. |
| **Cold profile fallback is not guaranteed ready.** `apps/browser/Sources/Airc/Browser/ProfileHost.swift:72` returns a model even without a spare while loading asynchronously; `Browser/WindowController.swift`'s `ensurePage` returns nil if the engine profile is absent. | Reserve a ready spare, or resume activation through whenLoaded; test rapid consecutive profile creations and load failure. Never display a silently unusable Space. |
| **Animation interruption can jump.** `apps/browser/Sources/Airc/UI/Animator.swift:118` derives a new spring's origin from the model layer position, not its presentation position. | Start interrupted row transitions from presentation position and preserve velocity where available; test rapid reorder/folder toggles. |

Layer-backing is present on the root, rows, card, pager/background and command panel; no blanket missing-layer-backing defect was found. Favicon disk/network work is already dispatched off-main (`apps/browser/Sources/Airc/Engine/FaviconCache.swift:36`); lazy decode/upload on first display still needs profiling, not an unsupported claim of synchronous downloads.

The named row, settle, reveal/conceal, fold and toast springs in `packages/AircDesign/Sources/AircDesign/Motion/AircSpring.swift:33` match the research parameters. The main mismatch is **which transitions use them** (folders above). Response is not total settling duration: do not “fix” the 0.19 s response by truncating the spring to 190 ms. The 90 ms colour transition approximates τ≈30 ms; measure its perceptual curve before calling it a 3× timing error.

## 3. Full requirement checklist

“Done” means source implements the stated behavior and available evidence does not contradict it; it is **not** a fresh runtime certification. Partial means a sub-requirement is missing or unverified. Can't-tell is used where this review cannot establish the requirement. Deferred v1.x requirements remain visible.

| ID | Status | Evidence / remaining gap |
|---|---|---|
| WIN-1 | done | WindowController.layoutRoot and PageCardView use themed frame, 10 pt inset, 6 pt corners; N/01. |
| WIN-2 | done | SidebarChrome header; no tab strip or horizontal toolbar in N/01. |
| WIN-3 | partial | Fullscreen callbacks hide traffic lights; no fullscreen/notch capture or interactive verification. |
| WIN-4 | partial | Width clamp/reset/drag exists; SidebarReveal:160 hides 40 pt below minimum, rather than directly past 164 pt. |
| WIN-5 | done | Settings → Appearance → Sidebar position; WindowController.layoutRoot mirrors through Browser/SidebarSide.swift, live in every window; `--script sidebarright` on both engines. Private windows and Little Arc stay left. |
| WIN-6 | can't-tell | No feature kill-switch wiring found in reviewed UI; engine-wide release behavior not verified. |
| SB-1 | partial | 32 pt header buttons; history menus/long press/command-click missing (issue 5). |
| SB-2 | partial | 36 pt host field/copy/bar work in source; Site Controls stub. |
| SB-3 | partial | Engine boundary and WebKit dialogs exist; complete Chromium permission/autofill/passkey anchoring not demonstrated. |
| SB-4 | missing | Extension menu stub, no hover extension icons in URL field. |
| SB-10 | done | Model/store profile ownership and maxFavorites=12; tiles read profile Favorites. |
| SB-11 | done | FavoritesGrid column rule, 47 pt tiles/8 pt gap; N/01 supports layout. |
| SB-12 | partial | Live tiles and saved-URL menu exist; existing live Favorite does not reset (issue 2). |
| SB-13 | partial | Title count and calendar-date icon implemented; real unread title variants not exercised. |
| SB-14 | done | Local drag plus command/menu add/remove routes exist in WindowActions and SpacePage. |
| SB-15 | missing | No idle Favorite lifecycle policy; issue 15. |
| SB-20 | done | SpaceHeader hover menu and pinned-collapse press handling. |
| SB-21 | partial | Menu order implemented in WindowActions:266; Manage Spaces is a stub. |
| SB-22 | partial | Profile text pill and coloured footer ring; no signed-in account avatar. |
| SB-23 | done | WindowActions delete confirmation, store archive/undo and toast route. |
| SB-30 | done | Close removes live page while saved item persists; auto-archive targets Today. |
| SB-31 | done | TabRow drift marker/hover reset; resetToSaved preserves current URL on command-reset. |
| SB-32 | done | WindowActions.navigate opens Today for saved-item URL edits. |
| SB-33 | partial | Nested rows/16 pt indent/rename/icon/copy links present; folder animation differs. |
| SB-34 | missing | No delayed searchable folder preview. |
| SB-35 | partial | Local drop destinations/line/row spring; no edge paging, Option duplicate or tear-out. |
| SB-36 | missing | No multi-selection state or bulk action UI. |
| SB-40 | done | Divider Clear and shortcut preserve visible tab; store undo supports batch clear. |
| SB-41 | done | New Tab opens bar; store inserts foreground Today at top. |
| SB-42 | done | StoreActions.openTab scopes Today and inserts background tabs after opener. |
| SB-43 | partial | 12 h model default and protected audible/visible tabs; settings absent, audio detection needs engine validation. |
| SB-44 | partial | Geometry/plate/press/loading/mute controls exist; actual 120 Hz feedback and all audio cases unverified. |
| SB-50 | done | Footer Library/icons/plus and current/dimmed treatment; N/01. |
| SB-51 | done | Footer uses squeeze layout in AircKit SidebarLayout; many-Space extreme still needs runtime check. |
| SB-52 | partial | Footer context menu exists; no icon drag reordering. |
| SB-53 | done | WindowActions.plusMenu includes New Space/New Folder; later entries appropriately omitted. |
| SB-54 | missing | No download-progress shelf; media tray deferred v1.x. |
| SB-60 | partial | 110/100 ms hide/show paths exist; Shift-Command-S Save Page is stubbed. |
| SB-61 | partial | 100 ms dwell/0.175 s reveal/overlay present; reveal callback does not recheck key window after delay. |
| SB-62 | partial | Fifteen-entry restore menu only; no searchable Library/Downloads/Spaces panel. |
| SP-1 | partial | Store and Chromium adapter model real profiles; running WebKit build cannot certify full Chromium isolation. |
| SP-2 | done | Space model includes required fields/profile binding; shared profile supported. |
| SP-3 | partial | WebKit popup adoption carries opener/profile; actual Google sign-in popup journey untested; Favorites are profile-owned exceptions. |
| SP-4 | partial | N persistence before/after and log agree; crash/discard recovery not exercised. |
| SP-10 | partial | Inline form and Enter route exist; N reports 22.6 ms, not one frame. |
| SP-11 | partial | Inline fields and spare profile implemented; cold/consecutive-create readiness gap. |
| SP-12 | partial | Sign-in card opens account page; avatar and suggested-Favorites completion absent. |
| SP-13 | done | WindowActions profile confirmation/suppression and page recreation retain sidebar items. |
| SP-14 | partial | Model and creation-form deletion exist; Settings/profile editing and clear-data UI stubbed. |
| SP-20 | done | Footer, keys, phased swipe, mouse buttons and Space search routes exist. |
| SP-21 | partial | Critical spring, one-page clamp, rubber band; missing pull-to-create. |
| SP-22 | partial | Weighted swipe blend/90 ms τ approximation present; presented-frame colour timing not measured. |
| SP-23 | partial | Last tab and same-window view swap implemented; N swipe handler 35.7 ms, flash-free presentation unverified. |
| SP-24 | partial | Tab/item suggestions filtered by profile; no history provider. |
| SP-30 | missing | No routing-rule UI/evaluator in app paths; deferred v1.x. |
| SP-31 | missing | No page-context Open in Space action; deferred v1.x. |
| CB-1 | partial | Bar layout/open/edit/actions implemented; no history results. |
| CB-2 | partial | Shortcut map broadly present; Library/Extensions destinations incomplete, live shortcut acceptance untested. |
| CB-3 | missing | KeyMonitor consumes browser shortcuts first, no 1 s second-press arbitration. |
| CB-4 | missing | Settings remapping absent; deferred v1.x. |
| TH-1 | partial | Nine swatches/intensity/grain/appearance; no disc or third handle. |
| TH-2 | partial | Shader math/grain exist; browser backgrounds default to opaque material. |
| TH-3 | partial | Palette used by rows/bar/toast; native NSMenus not explicitly styled from Space palette. |
| TH-4 | can't-tell | Import package preserves source theme data, but reachable import-to-render path and exact texture mapping unverified. |

## 4. Quick wins (each estimated under 30 minutes)

These estimates cover a small implementation plus focused verification, not completion of the larger features.

- Pass `.subtle` to the main window background and disable material/window configuration on the overlay; check one active/inactive desktop capture (TH-2).
- Reuse the first ranking result for the strong-match decision instead of ranking twice (`CommandBar.swift:390`, CB-1).
- Recheck `window.isKeyWindow`, hidden state and pointer location when the delayed reveal actually fires (`SidebarReveal.swift:65`, SB-61).
- Change the resize-hide threshold to the required minimum (or explicitly reconcile the 40 pt hysteresis with the spec); verify slow drag/reset (WIN-4).
- Route folder close rearrangement through the existing fold spring; add the open curve as a separate follow-up rather than pretending one spring matches both (SB-33).
- Remove the contradictory “full-window first-run” comment in the onboarding stub and point it to ON-5; prevents implementation of the wrong window contract.
- Add signposts around activation, persistence, theme render and first drawable presentation; existing stopwatch logs must be labelled handler timings, not first-frame timings.

Before closing parity work: run a synthetic large sidebar (many Spaces, nested folders and hundreds of items), rapid interrupted swipes, loaded-tab switching, resize/hide/reveal, profile creation twice in succession, audio auto-archive protection and fullscreen/notch checks on the build Mac. Record median and tail latency, missed frames and cold versus warm behavior. The current screenshot suite establishes neither these budgets nor crash safety.

# External AppKit window hosting

`AircWindow(window:hostView:)` retains a Swift-created NSWindow and the page container.
It never replaces that window's delegate or contentView. The host can lay out the
container later. `initWithContentRect:` remains available for compatibility.

Each (window, profile) still owns one Browser. Each tab keeps its WebContents and
RenderWidgetHostViewMac. Switches detach the outgoing native page view, activate the
new profile/tab, then attach its existing NSView. There is no navigation or renderer
replacement. `deactivateAll` hides/detaches every page and clears the active profile;
the browsers and tabs survive. Multiple attached views support up to four app-managed split panes;
only the focused profile is active for window-scoped commands. See
[FEATURES-V1.md](FEATURES-V1.md) for the profile-checked move API, Peek, Little Arc,
link routing and four-pane qualification.

The original never-shown Views widget remains internal scaffolding. External
windows also own a transparent, frameless, nonactivating Views child window that
tracks the supplied host view's screen bounds. It has no mouse handling, shadow
or page content. It supplies a real `NativeWidgetMacNSWindowHost` parent for
`kChild` dialogs without replacing the Swift window's delegate, contentView or
page responder chain. `BrowserElementsViews` uses this registered parent too:
Chromium 156's newer `TabDialogManager` obtains its widget there, whereas legacy
`constrained_window` obtains it through `GetWebContentsModalDialogHostFor`.

The per-tab host still computes bounds from that tab's actual page view.
Chromium owns modal blocking, dialog lifetime, and hide/restore via WebContents
visibility; the app must use the existing attach/detach or visibility methods on
every tab/Space switch. Window moves/resizes update the parent and notify all
per-tab hosts. Native child links are restored after showing because AppKit
removes them on `orderOut`. Chromium can defer attaching a dialog's Cocoa child
window while its parent is off the active macOS Space; its registered Views
parent and requested visibility still exist in that state.

Hosted beforeunload prompts use the same constrained parent. An installed
`AppModalDialogManager` factory retains Chromium's controller and queue, replacing
only its macOS app-modal `NSAlert` presentation for hosted beforeunload requests.
Other app-modal requests retain the original factory. Cancel preserves the page
and cancels termination; the existing unload callbacks still control window close.

The app must call `close` before releasing its window; allow Chromium's unload
path to finish before destroying the window or exiting the process. No new Swift
API is needed for modal hosting. See [BUILD-VARIANTS.md](BUILD-VARIANTS.md) for
selecting the owner's DCHECK-off framework; do not mask hosting failures by
qualifying only that build.

## Rendering and input

Attach the WebContents native NSView, not a screenshot or a new layer/compositor.
RenderWidgetHostViewMac owns its compositor and AcceleratedWidgetMac; ordinary
AppKit view movement supplies backing-scale and window changes. Detaching clears
first responder only when it belongs to the outgoing page; attaching deliberately
does not steal focus from a sidebar text field. The UI explicitly calls `focus`.
IME marked text, accessibility, scale changes, occlusion, resizing at 120 Hz and
fullscreen transitions require on-screen qualification; syntax checks cannot prove
these properties. Do not recreate NSApplication before Chromium startup.

**Window visibility (MEM-6).** Shown pages follow their window as Chrome's do. Chrome's
Views hide a tab's native view when its widget is ordered out (`NativeViewHost::HideWidget`);
the app's window isn't a widget, so `WindowHost` does it: when the window is ordered out
(⌘H, the app launched hidden, a window kept but closed) the pages the host shows get their
native views hidden, report `document.visibilityState` hidden and stop producing frames.
When the window is back they are shown again and get their keyboard focus back. A minimized
or merely covered window stays with Chromium's occlusion checker (occluded). A page shown
while its window isn't on screen yet is decided a second later (as the checker waits), at
once when the app itself is hidden. The host's own shown flag doesn't change, so PiP,
prompts and the memory policy's protection of shown tabs are unaffected (Chromium's auto
PiP ignores `HIDDEN`). Tabs opened with `foreground:NO` start hidden by the host.

## Re-hosted surfaces

- Permissions and device choosers: engine delegate callbacks identify the tab. Present
  the app-owned panel at `uiAnchorRectInScreen`, after verifying that tab is still
  visible. Keep requests associated with the originating tab/profile, never the first
  Browser found for the shared NSWindow.
- Password/autofill prompts: window delegate callbacks; same anchor rule. Suggestions
  also have tab callbacks and page-relative geometry. Hide transient UI on switch.
- Extension action popups: `openActionPopup(extensionID:tab:)` applies activeTab grants
  and returns the extension's page; attach it to an app-owned panel. Dismiss/close the
  popup before switching profiles. The ordinary window no longer has Chrome's
  command dispatcher: the app must route reserved shortcuts through its own monitor.
- Find: the inherited AircFindBar is model-only, not a visible Chrome bar. The app
  must draw its own find field over the page and use `tab.find` / `stopFinding` and
  match callbacks. This is not a completed native find UI.
- Web-modal dialogs use the registered Views parent described above and the visible page rect. Exclusive-access
  bubbles now receive that view and its actual screen rect as their parent/geometry.
  Other upstream Views UI must be audited; keeping the scaffolding widget does not
  establish blanket compatibility with every Chrome bubble.

The BrowserEngine protocol currently has no permission/chooser/find/anchor hooks.
The startup bridge dismisses permission/install/device requests until product UI is
wired. It does not grant them silently. This adapter is an integration spike, not
production browser parity. The linked-framework host now passes two-profile attachment, switching, surface
capture and restart tests. This does not establish interactive focus/IME, fullscreen
or prompt/popup correctness; those remain explicit qualification work.

## Pass 3 qualification (background host)

Every run uses its own data directory, `open -g`, and quits. No owner account,
profile, foreground activation or global input-source change is used. Window
captures returned black pixels during this run; renderer captures are used for
extension content proof and cannot prove native panel placement.

| Surface | Result | Evidence / remaining work |
|---|---|---|
| Sidebar ↔ page keyboard focus | Pass for tested path | Attach and detach preserve sidebar first responder; native `NSEvent` keyDown delivered `x` into the page input. |
| Japanese IME | Fail / unresolved | Native text input client exists, but synthesized marked `にほん` → committed `日本語` did not arrive in a non-key window. ASCII did. Needs actual Japanese input-method candidate/commit testing with an interactive window; do not infer success from CDP insertText. |
| Native fullscreen | Unqualified | Not exercised: a native fullscreen transition may change the owner's active Space. `actedFullScreen` is not evidence of native fullscreen. |
| Permission prompt anchoring | Unqualified | Host callbacks/anchor API exist; app-owned prompt presentation and background-tab suppression still need UI testing. |
| Autofill / password bubbles | Unqualified | Callback surfaces exist, but product panels are not wired. Lazy-factory enablement needs these regression tests before release. |
| Find bar | Partial pass | Query returns one matching fixture result and stopFinding works; visible find field is app-owned and absent from this host. |
| Context menus | Unqualified | No real right-click/menu-selection round trip recorded. |
| DevTools (⌥⌘I) | Unqualified | CDP calls used by tests do not qualify the shortcut, docking or visible DevTools. |
| File upload / download | Unqualified | No native file-picker or saved-download round trip recorded. |
| PiP | Unqualified | No actual video/PiP-window transition recorded. |

These are deliberately not blanket hosting acceptance. The background constraint
limits native IME/fullscreen qualification; the remaining UI journeys need further
implementation and tests, not just documentation changes.

### New app wiring

`AircProfile.unloadTimeout` is seconds (default 1800; zero disables the deadline,
not memory-pressure protection). Persist the setting in the app and reapply after
loading a profile. Discard uses Chromium's preserved-WebContents lifecycle path,
refuses visible/audio/capture/loading/edited tabs, and refuses operation if that
Chromium feature is explicitly disabled. Timeouts are one-shot, with no periodic
scan. The existing tab-discard notification updates UI state; activation reloads.
`engine:memoryPressure:` is a main-thread callback (0/1/2); the engine already
attempts one eligible least-recently-hidden tab per pressure notification. The
app should not discard a second batch in its callback.

The Swift adapter exposes `setUnloadTimeout(_:for:)`, `discard(_:)`,
`isDiscarded(_:)`, `discardedStateDidChange`, `installedExtensions(for:)`, and
`extensionActions(_:for:)`. `ChromiumRuntime.memoryPressureHandler` is optional.
These are concrete-adapter additions; the app agent owns changes to BrowserEngine.

`profile.extensions` lists enabled and disabled installed extensions, excluding
bundled components, with id/name/version/enabled. Action states include default
icons as well as overrides and badge text/colors. Query on activation and relevant
extension changes. `openExtensionsPageForProfile:` / `openWebStoreForProfile:`
return normal tabs for the app to adopt and attach. Install prompts use
**requestId**, not the extension **id**, when resolving. The Swift fallback now
correctly cancels requests; the app must supply permission-review UI to install.

`presentActionPopupForExtension:tab:anchorRect:inView:` returns a popup tab and
presents a nonactivating child panel, clamped to the screen. The rect is in the
provided view's coordinates. Close with `closeActionPopup` on Escape/outside
click; tab activation, deactivateAll and window close dismiss it automatically.
Popup content sizing is initial preferred size or 360×480; dynamic resizing and
fully native placement/accessibility still need qualification. The original
`openActionPopupForExtension:tab:` remains for app-owned panels.

## Pass 4 qualification (2026-11-05)

Evidence paths below are relative to the handoff's `engine/pass4/` artifact
folder. **Pass** applies only to the stated test; **FAIL (qualification)** means
that the requested native/product journey has not passed, even if an API subset
works. No screenshot of black window pixels is used as native UI proof. Tests use
fresh profiles, mock keychain and background launches. `app-wiring.patch` is
unchanged. The app agent's production-engine integration was present in the working tree but
not committed at this checkpoint. A release Airc.app built successfully with the
framework (22.86s Swift build), but a fresh `--engine=chromium --script showcase`
background run exited without its expected log/screenshots. `pass4-app/stderr.log`
and `stdout.log` preserve that failed qualification; the captured stderr has only
quarantine-removal diagnostics, not a root cause. The app process exited. Do not
infer Airc.app native-surface acceptance from the passing host/adapter tests.

| Surface | Qualification | Evidence / exact boundary |
|---|---|---|
| Japanese marked-text commit | Pass for synthesized native client; actual IME candidates unqualified | `pass4-hosting-verified/hosting.json`: `x日本語`, nativeEditingText true. Original test raced renderer text-input state; test now polls the native editing state with a deadline before composing. No engine-side IME override was needed. |
| Native macOS fullscreen enter/exit | FAIL (qualification) | Not run because it can switch the owner's desktop/focus. No fabricated native fullscreen result. |
| Page video fullscreen enter/exit | Pass for DOM/exclusive-access path | `pass4-video-test/video.json`: video-1/video-2 true. This is not evidence of an NSWindow native fullscreen transition or app sidebar layout. |
| Camera permission | API pass; visible panel FAIL (qualification) | `pass4-permissions-verified/surfaces.json`: camera request, expected profile and anchor rect, denied promise. Fake device only; no OS camera grant. |
| Microphone permission | API pass; visible panel FAIL (qualification) | Same file, microphone request and denial; no OS microphone grant. |
| Location permission | API pass; visible panel FAIL (qualification) | Same file, location callback and error code 1 after denial. |
| Notification permission | API pass; visible panel FAIL (qualification) | Same file, notifications request and denied result. Permission panels are app-owned, not supplied by the host test. |
| Autofill suggestions / save bubble | FAIL (qualification) | Callback implementation exists; no native suggestion-selection/save round trip performed. |
| Password save/fill bubble | FAIL (qualification) | `pass4-services-test/encrypted-at-rest.json` proves synthetic import encryption, not password UI or actual login fill. |
| Context menu and SP-31 | Pass for renderer right-click → real menu model → selected Space callback; Cocoa tracking unqualified | `pass4-menu-test/surfaces.json`: Space Two submenu and exact URL/Space ID. Test uncovered/fixed missing OnMenuWillShow before MenuClosed. `pass4-surfaces-test/surfaces.app.log` preserves the pre-fix DCHECK. |
| DevTools Option-Command-I / docked | Pass for shortcut and view attachment | `pass4-devtools-test/devtools.json`: native NSEvent reaches window delegate; view attaches to host window. Full rendered docking layout still needs visual acceptance. |
| DevTools undocked | FAIL (qualification) | No undock/second DevTools-window round trip. |
| File upload picker | FAIL (qualification) | Native NSOpenPanel and selected-file submission not exercised. |
| Download progress and saved file | Pass | `pass4-download-test/download.json`: eight snapshots, COMPLETE, 22 bytes; actual fixture file contents verified. Target is inside scratch test directory. |
| Video PiP enter/exit | Pass for video transition | `pass4-video-test/video.json`: video-3/video-4 true for a real canvas-backed video stream. Window styling/placement and automatic PiP not qualified. |
| Print Command-P | FAIL (qualification) | API exists, no native print panel/PDF-save round trip. |
| Find | API pass; visible bar FAIL (qualification) | `pass4-hosting-verified/hosting.json`: query/text, one match, active 1, final true; stopFinding called. App must draw field/counter/prev/next/close. |
| Second engine window | Pass | `pass4-services-test/services.json`: attached second-window page sees Profile One cookie; Profile Two remains empty. |
| Hide/show without reparent | Pass | `pass4-hosting-verified/hosting.json`: hideKeepsParent/showKeepsParent true; signed Swift adapter also switches and captures pages. |
| Credential import / history | Pass for synthetic tested path | `pass4-services-test/services.json`, `encrypted-at-rest.json`: imported cookie isolation; login submitted/rejected counts; history query and visit callback isolation. Real-key import/restart/fill still required. |
| Google account query | Pass signed-out only | `pass4-services-test/services.json`: fresh cache, empty accounts. Real signed-in identities not tested. |
| Chromium first-run UI | Limited startup evidence | `pass4-hosting-verified/hosting.json`: no welcome UI observed, applicationActive false; an additional scaffolding window titled Item-0 was enumerated. Startup explicitly sets no-first-run/no-startup-window; universal ON-4 coverage remains unqualified. |
| Airc.app showcase | FAIL (qualification) | `pass4-app/stderr.log`, `stdout.log`: release build succeeded but no showcase report/screenshots were produced. |
| App integration adapter | Pass | `pass4-adapter-checked/result.txt`, warnings-as-errors compilation plus two-profile runtime/snapshot test. This is not Airc.app. |

Remaining qualification is a release blocker. In particular the native print,
upload, autofill/password UI and undocked DevTools journeys are not completed by
this pass. See [PROFILE-SERVICES.md](PROFILE-SERVICES.md) for exact Objective-C and
Swift contracts, callback lifetime limitations and the UI the app must draw.

## Pass 5 update

See [PASS5.md](PASS5.md) for the form-crash fixes, passing password save/fill,
address/card save/persistence, native upload sheet ownership/cancellation, and
successful minimal production-app startup. Actual upload selection, address/card
suggestion fill, print panels, native fullscreen and visible surfaces remain
unqualified. The upstream ≤30-file target remains unmet (51 files).

## Pass 8 qualification

Evidence is relative to the private handoff's `engine/pass8/`. The display was
checked repeatedly with ioreg, including after 09:00 UTC; it continued to report
`CGSSessionScreenIsLocked=Yes`. The native probe independently checks the session,
refuses to create its window while locked, and aborts if it becomes the active app.
No black image or renderer-only capture is represented as on-screen proof.

| Requested surface | Pass 8 result | Evidence / exact blocker |
|---|---|---|
| Native print panel and PDF save | **Unqualified — locked session** | `screen-state.txt`, `native/native.json`. A bounded small-window probe is supplied; it preconfigures a PDF destination and accepts the native print panel. Neither it nor the human PDF-dropdown/save-dialog journey ran on an unlocked display. |
| View Source | **Unqualified on screen** | Same lock evidence. Probe checks actual `view-source:` content and captures only its owned window; no new unlocked capture obtained. |
| DevTools docked → undocked → re-docked | **Unqualified** | Prior adapter tests exercise an app-owned panel, not the full Chromium docking round trip. No pass-8 native docking evidence. |
| Permission prompts anchored to URL field | **Unqualified / app UI missing** | The production runtime adapter still dismisses permission requests. Callback/anchor geometry is not a visible prompt. App pass owns the presentation integration. |
| Password save/fill bubble anchored to URL field | **Unqualified on screen / app UI missing** | Synthetic store/form save/fill is distinct from a visible bubble. No product subscriber drawing the forwarded password prompt was found. |
| Native macOS fullscreen in/out | **Unqualified** | Locked session; changing the owner's active desktop/focus is incompatible with the no-focus constraint. DOM fullscreen and an internal fullscreen flag do not qualify this. |
| Cocoa context-menu tracking with Airc items | **Unqualified** | The existing `contextMenu` test routes a real menu model to the host test delegate; it deliberately bypasses Cocoa tracking. No new native selection proof. |
| Native upload picker with selection | **Unqualified — locked session** | New probe drives an actual NSOpenPanel toward a synthetic file, then checks the renderer's FileList. Selection and visible capture remain unexecuted because the lock guard refused the run. Prior cancellation evidence is not selection evidence. |
| Credential import row outcomes | **Pass, synthetic** | `imports-final/pass8-final-imports2/imports.json` and `encrypted-at-rest.json`: saved/duplicate/rejected rows, six cookie outcomes/reasons, single encrypted database row. |
| Delete unloaded profile folder | **Pass, synthetic** | Same import test: default/loaded/alias/traversal/symlink refused; unloaded fixture removed with completed callback. No profile loading used for deletion. |

The first eight rows remain release qualification work. The small native probe
is in `host/native_checks.inc`; run the `native` acceptance scenario only once an
unlocked, nonactivating test is possible. Its unexecuted branches are not accepted
merely because the host builds. See [PASS8.md](PASS8.md) for allocation evidence,
reproduction and the exact unapplied Swift patch.

## Pass 9 qualification (unlocked display)

Evidence paths are relative to the private `engine/pass9/` artifact folder.
The initial ioreg lock flag was absent; native host reports record
`screenLocked:false`. **FAIL** here means the requested end-to-end qualification
has not passed; it does not necessarily identify an engine defect. Rendered
source and DevTools captures were inspected. The blank upload capture was not
accepted merely because writing a PNG succeeded.

| Requested surface | Pass 9 qualification | Evidence / boundary |
|---|---|---|
| Native print panel / Save as PDF | **FAIL** | `pass9-print/native.json`: command accepted, NSPanel observed, capture false, step 7 timed out; no PDF produced. PDF menu/save journey not passed. |
| View Source (⌥⌘U) | **PASS rendering; shortcut/app unqualified** | `pass9-native3/native.json` and `pass9-native2/view-source.png`: real syntax-coloured source and fixture text. Host navigated directly; app shortcut was not exercised. |
| DevTools dock → undock → re-dock (⌥⌘I) | **FAIL complete journey; attached rendering PASS** | `pass9-devtools/native.json`, `native.png`: native key event handled, tools view attached and visibly rendered. Undock/re-dock and production app routing not exercised. |
| Camera / microphone / location / notifications | **FAIL visible prompts** | `pass9-final-permissions/native.json`: all four denials and profile/anchor callbacks pass. `pass9-media/native.json`: fake camera+microphone allowed, tracks stopped. App still unconditionally dismisses requests; no visible prompt or location/notification allow path qualified. |
| Password save bubble / fill | **FAIL visible bubble; synthetic save/fill PASS** | `pass9-forms/native.json`: save prompt callback and actual form fill pass. App forwards callback but has no visible subscriber. |
| Native macOS fullscreen | **FAIL qualification / not attempted** | Native Space transition can change foreground focus, contrary to the no-focus constraint. No substitute internal fullscreen flag used as proof. |
| Page video fullscreen | **PASS DOM transition; on-screen/app unqualified** | `pass9-video/native.json`: real canvas-stream video, enter/exit promises and fullscreen element assertions pass. No native fullscreen screenshot or app layout acceptance. |
| Cocoa context menu / Open link in Space › | **FAIL Cocoa tracking** | `pass9-final-context/native.json`: synthetic renderer right-click with bypass flag removed; no Cocoa tracking notification after bounded wait. Separate permission scenario passes menu model, Space Two item and destination callback; that bypasses Cocoa and is not a tracking pass. |
| Upload picker / real file selection | **FAIL** | `pass9-native2/native.app.log`: inherited NSSavePanel ok: throws. Guarded rerun `pass9-native3/native.json` exits cleanly: no enabled default button. Picker capture is blank and rejected as visual evidence. Cancellation passes in forms test. |
| Japanese IME candidates | **SKIP, as permitted** | No input sources enabled, switched or changed. Safe nonactivating candidate-window testing was not established. |

The production `Airc-Chromium.app` built successfully (`app-build.log`), but its
requested UI journeys were **not run**. This is not complete pass-9 acceptance.
See [PASS9.md](PASS9.md) for reproduction, probe fixes and the unapplied app UI
specification. Native fullscreen and real IME remain constrained by the owner's
no-focus policy. Every launched test host exited; `cleanup.json` records zero
remaining pass-9 test processes and deletion of synthetic upload fixtures.

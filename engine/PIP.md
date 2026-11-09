# SB-55 automatic picture-in-picture

Current native behavior is documented in “Native window policy (pipwindow)”
below, with the later “Document PiP keyboard policy” governing keyboard focus;
these supersede the original key-window trigger and placement-only policy.

Status (2026-11-05 retest): **framework and Swift adapter compile; engine-host
video and Document PiP probes pass**. Native fullscreen, production app switching
and real Google Meet remain unqualified. SB-55 is not yet release-complete.

## Trigger and security contract

Chromium 156's `AutoPictureInPictureTabHelper::OnTabActivatedChanged(false)` calls
`MaybeEnterAutoPictureInPicture`, then `MediaSession::EnterAutoPictureInPicture`.
The existing `013-pip.patch` routes Airc host visibility into its tab-strip
observer. `NoteTabShownByHost` already sends `WebContents::WasShown/WasHidden`;
attach/detach and Space switches therefore retain the ordinary renderer visibility
signals. This change adds a separate host-window-active input to the PiP observer.
It does not hide a still-visible background window's page or change permission UI
visibility. The app must send that input on key-window changes.

* Site-provided calls: the page registers the MediaSession `enterpictureinpicture`
  handler, captures camera or microphone, and requests Document PiP from the
  dispatched action. Chromium supplies its bounded automatic activation lifetime.
  Airc does not manufacture a renderer user gesture or call a testing entry point.
* Plain video: enable `BrowserInitiatedAutomaticPictureInPicture` (experimental
  and otherwise disabled in this build). Chromium requires one eligible, playing,
  top-frame video, no site handler and no active capture. Its helper additionally
  requires audio focus, recent audibility, safe URL and media engagement (the
  explicit ALLOW content setting satisfies engagement). A muted autoplay or
  audio-only element does not qualify in the synthetic runtime probes.
* The URL must be HTTPS or file, even though HTTP localhost is a secure context
  for getUserMedia. Tests consequently use HTTPS on loopback. No production
  certificate bypass or Safe Browsing bypass was added.
* The upstream helper closes its automatic PiP when the tab becomes active. It
  also handles a late entry racing the return to the tab. Manual PiP remains
  manual and is not unconditionally closed by host activation.
* A new one-line eligibility guard makes the master/profile off setting win over
  a site's ALLOW exception. The remainder of Chromium's policy checks is unchanged.

The pinned source paths used for these findings are
`chrome/browser/picture_in_picture/auto_picture_in_picture_tab_helper.cc`,
`auto_picture_in_picture_tab_strip_observer_helper.cc`, and
`content/browser/media/session/media_session_impl.cc`.

## APIs (main thread)

| API | Contract |
| --- | --- |
| `AircProfile.autoPictureInPictureEnabled` | Persistent default ALLOW/BLOCK in Chromium content settings. Off overrides per-site allows. Turning off closes this profile's current automatic PiP. |
| `-[AircProfile setAutoPictureInPictureException:enabled:]` | HTTP(S) URL normalized to origin; `@YES` allow, `@NO` block, `nil` clear. Returns NO for invalid URL, credentials or unsupported scheme. Blocking the active origin closes its automatic PiP. |
| `AircProfile.pictureInPictureFrame` | Global AppKit points, bottom-left origin. `NSZeroRect` resets. Persisted under `browser.app_window_placement.airc_pip_frame`, per profile; no external preferences file. Drag/resize saves automatically. |
| `-[AircTab setPictureInPictureWindowActive:]` | Separate key-window signal. Does not hide, reparent or activate the NSView. Send the current value after attaching a selected page, and on host key-window changes. |
| `-[AircTab exitPictureInPicture]` | Existing explicit close API. Closing PiP does not mean hang up. |
| `tab:didChangePictureInPicture:` | Existing callback, `active` and `kind` (`video`/`document`). |
| `tab:requestsActivation:` | Existing callback; Chromium return-to-tab UI requests `pictureInPicture`. The app selects the owning window, Space and tab. |

The old process-wide `+[AircEngine setAutoPictureInPicture:]` remains a session
master switch. It is not the new persistent profile preference. Profile startup
only changes the upstream ASK default to ALLOW; it no longer overwrites a saved
BLOCK on every launch. Site exceptions remain Chromium-managed. There is no new
exception-enumeration API; the app must retain its settings list.

## Flags and kill switches

Use the existing `--airc-switches=key=off,...` syntax:

| Key | Default | Effect |
| --- | --- | --- |
| `autoPip` | on | Eligibility master; disabling also disables browser-initiated video at startup. Cannot be overridden by a profile/site allow. |
| `autoPipVideo` | on | Enable/disable the browser-initiated automatic-video feature. Site-provided call handlers remain available. |
| `documentPip` | on | Disables `DocumentPictureInPictureAPI` when off; manual video PiP remains available. |
| `pipPlacement` | on | Apply/save Airc floating/placement policy; off retains Chromium's native policy. |

The first three feature decisions require restart. Explicit Chromium
`--disable-features` takes precedence over enables. Dry-run video auto-PiP is
explicitly disabled so it cannot masquerade as real entry.
`AutoPictureInPictureOnWindowOccluded` is explicitly disabled: its Views window
tracker is not the Airc host activation contract. The app supplies window activity.
Existing `--airc-background-instance` intentionally makes PiP invisible; do not
use it for on-screen qualification. The runner uses `open -g` instead.

## Document PiP and placement

Airc already excludes `TYPE_PICTURE_IN_PICTURE` from its viewless BrowserWindow
replacement (`WindowForChromeBrowser` in `airc_seams.mm`). Chromium therefore
creates its own specialized Document PiP BrowserView/window. Preserve this
exception: rebuilding a second ordinary Airc page would break site DOM ownership,
pagehide restoration, opener identity and capture tracks.

The manager's entry observer schedules native placement after window creation.
Both video overlay and Document PiP windows get floating level,
CanJoinAllSpaces and FullScreenAuxiliary. Initial position is bottom-right of the
opener's screen (main screen fallback) with 20-point visible-frame margins.
Saved frames select an intersecting display and clamp to its visible work area.
The policy never calls application activation or makeKeyAndOrderFront. Chromium
retains native click/focus/close behavior. Native focus and fullscreen-Space
behavior still need on-screen verification; setting collectionBehavior is not
proof of that journey.

Site Document PiP owns its mute/camera/leave buttons and retains the same tracks.
The fixture moves the existing call DOM into the PiP document and restores it on
pagehide. This is the website's responsibility, not an engine DOM injection.
Sites without this behavior are not automatically repaired by the engine.

## Application handoff

The `ChromiumEngine.swift` adapter now exposes
`setAutoPictureInPictureEnabled(profile, enabled:)`, site exceptions, frame,
window activity and PiP callbacks. `app-pip.patch` contains only the remaining
app integration note. Swift compilation and runtime qualification are tracked below.

App pass must implement the per-profile settings toggle, Default/Allow/Block site
controls, callback subscriptions and key-window notifications. Chromium already
has return-to-tab controls; the app must fulfill their activation callback and
provide a Back to tab control if a UI variant omits it. The patch's integration
note specifies this work; it is not a finished settings UI implementation.

## Tests, evidence and reproduction

Private evidence is in `artifacts/engine/pip/retest/` outside the repository.
The updated `status.json` summarizes the retest; the original is preserved as
`retest/previous-status.json`. Failed diagnostic
runs are preserved, not counted as final passes.

Build: incremental `engine/build.sh --start` in the detached `airc-engine` screen
session passed on Chromium 156.0.8078.88. The first compile exposed an Objective-C
category declared before `AircTab`; moving it after the class fixed both Clang
and Swift import. `host-build-qualified.txt` records the signed host build;
`final-build-checks.txt` records successful Swift adapter type-check, the strict
Mac apply check and the final framework build result. `framework-build.txt` records framework link success.

The probe fixes are significant:

* `--disable-backgrounding-occluded-windows` lets the background fixture finish
  recording/playing without activating the app. Without it startup timed out.
* Do **not** use `--use-fake-ui-for-media-stream` for this call probe. It bypasses
  Chromium's capture indicator: fake tracks were live but `camera=0 mic=0
  userMedia=0`, so auto-PiP correctly refused entry. The scratch host instead
  accepts only camera/microphone requests with fake devices enabled, with the
  existing unsigned scratch `systemMediaPermission=granted` test gate. No real
  device or system permission prompt is used.
* Document PiP needs a first compositor frame before capture. The probe waits
  400 ms after entry, captures only its own window, then immediately returns.
  The fixture copies its stylesheet into the PiP document so the mute and leave
  buttons are visible. Earlier black/clipped captures are not accepted evidence.
* Start must return real playing media. Missing/exceptional script results fail.
  The negative muted case permits Chromium to pause it after hiding. Audio uses
  an audio-only Opus recording, not a video file hidden in an audio element.
* Placement asserts the 20-point bottom-right margin, moves the actual NSWindow,
  checks the profile frame, and compares the next PiP frame. This tests movement
  notifications and reentry, not a physical mouse drag or restart persistence.
* Every PiP finish path explicitly closes it. The 35-second watchdog remains.
  Gated PiP diagnostics now go to host stderr rather than a shared temporary log.

`strict-apply.txt`: PASS pristine check, apply, applied check, repeat apply,
retired-hook migration, drift refusal and untouched source mirror. No hashes,
patch strictness or eligibility safeguards were relaxed. JavaScript syntax and
`git diff --check` also pass.

### Retest results

Evidence paths below are relative to `artifacts/engine/pip/retest/`. For each
positive run, inspect `pip.png` alongside `result.json`; both were inspected.
The host checks an unlocked session and refuses to continue if it becomes active.
All launches used `open -g`, with no global input or application activation.

| Probe | Result | Evidence / qualification |
| --- | --- | --- |
| HTTPS video, tab switch and return | PASS | `runs/final-video-tab/{result.json,pip.png}` |
| HTTPS video, cross-profile Space switch and return | PASS engine host | `runs/final-video-space/{result.json,pip.png}` |
| HTTPS video, window activity and return | PASS API signal | `runs/final-video-window/{result.json,pip.png}`; not a real key-window switch |
| Fake WebRTC Document PiP, tab | PASS | `runs/qualified-call-tab/{result.json,pip.png}`; visible controls, mute disables audio tracks, leave ends tracks |
| Fake WebRTC Document PiP, Space | PASS engine host | `runs/qualified-call-space/{result.json,pip.png}`; same controls and restoration |
| Fake WebRTC Document PiP, window activity | PASS API signal | `runs/qualified-call-window-v2/{result.json,pip.png}`; same controls and restoration |
| Muted autoplay video | PASS exclusion | `runs/final-muted/result.json`; playing before switch, paused while hidden, no PiP |
| Audio-only playback | PASS exclusion | `runs/final-audio/result.json`; playing while hidden, no PiP |
| Bottom-right and remembered move | PASS | All six positive results: `bottomRight`, `savedAfterMove`, `rememberedOnReentry` true |
| Native fullscreen / macOS Space visibility | **FAIL qualification: not attempted** | Entering native fullscreen can change the owner's foreground Space/focus. Level 3 and collection behavior 293 are recorded, not substituted for on-screen acceptance. |
| Isolation and restart | PASS | `regression-isolation.txt`, `runs/pip-regression-isolation/results.json`; two persistent isolated cookie/localStorage profiles |
| Discard/memory | PASS | `regression-discard.txt`, `runs/pip-regression-discard/memory.json`; visible/audio/form protection, restored scroll=900, timeout and pressure paths |
| Extensions | PASS | `regression-extensions.txt`, `runs/pip-regression-extensions/extension.json`; uBlock Origin Lite installed only in profile one, action enabled, popup rendered |

The engine-host Space test detaches one profile and attaches another in the same
window. The window test sends the adapter's activity signal without changing the
owner's key window. Neither is a production app UI acceptance result. Native
fullscreen remains a release gate. Native mouse-operated video play/pause and
back-to-tab controls were not clicked; automatic return closure was tested.

On an unlocked build Mac, with no other engine build running, sync this engine
checkout, run `engine/build.sh --run`, then:

```sh
engine/host/build.sh build/pip-host
node engine/host/pip/run.mjs build/pip-host/AircHost.app build/pip-call-tab call tab
node engine/host/pip/run.mjs build/pip-host/AircHost.app build/pip-call-space call space
node engine/host/pip/run.mjs build/pip-host/AircHost.app build/pip-call-window call window
node engine/host/pip/run.mjs build/pip-host/AircHost.app build/pip-video-tab video tab
node engine/host/pip/run.mjs build/pip-host/AircHost.app build/pip-video-space video space
node engine/host/pip/run.mjs build/pip-host/AircHost.app build/pip-video-window video window
node engine/host/pip/run.mjs build/pip-host/AircHost.app build/pip-muted muted tab
node engine/host/pip/run.mjs build/pip-host/AircHost.app build/pip-audio audio tab
```

Node and openssl must be available. Each run requires a fresh scratch directory,
uses fake capture devices, scoped test system permissions and mock keychain, and serves only loopback HTTPS.
The certificate exception is confined to the scratch process; no system trust
store change. The call uses two local RTCPeerConnections without STUN/signaling
or any account. Video records a short synthetic canvas/audio file, stops its
capture tracks and then plays that file. The host checks lock/activation, captures
only an owned PiP window and immediately returns to the tab; a second call entry
checks the site's mute/leave controls and the saved frame after moving the native window. A 35-second watchdog terminates only the
recorded host executable. Copy evidence out, then delete build/pip-* outputs.

The tab probe crosses same-profile tabs; Space crosses profiles via detach/attach.
The window probe deliberately calls the new window-activity API without changing
the owner's foreground window. It is **not** proof of a real key-window switch,
production app Space selection, fullscreen-Space transition, or rendered controls.
Screenshots must be inspected before accepting visual success.

Still missing: policy/restart persistence and native close-button restoration
qualification, real app key-window/Space integration, fullscreen floating
behavior, and Google Meet compatibility. No real Meet call was made. The local
call proves the MediaSession → Document PiP path, DOM restoration and synthetic
track controls; it does not prove Meet registers that handler, renders its tile
grid, retains remote audio/camera/screen sharing, or hangs up its real call.
Camera-tile fallback plus generic Airc mute/leave UI for sites without Document
PiP is not implemented; arbitrary site hang-up semantics cannot be inferred from
media tracks. Browser-initiated PiP is limited by Chromium to one eligible video,
and URL safety/service availability may prevent entry. The loopback test alone
uses a certificate exception; no production trust or Safe Browsing bypass exists.
These remain release limits, not passing SB-55 acceptance.

Regression reproduction (same signed host, new scratch directory each time):

```sh
node engine/host/acceptance.mjs build/pip-host/AircHost.app build/pip-isolation
node engine/host/acceptance.mjs build/pip-host/AircHost.app build/pip-discard memory
node engine/host/acceptance.mjs build/pip-host/AircHost.app build/pip-extensions extension
swiftc -typecheck -I engine/core/public apps/browser/Sources/Airc/Engine/BrowserEngine.swift apps/browser/Sources/Airc/Engine/ChromiumEngine.swift
```

Cleanup confirmed no remaining owned host/helper processes. Removed the entire
engine work copy's build output (test apps and scratch profiles), reducing it
from 5.1 GB to 27 MB. Evidence is retained only outside the repository; shared
Chromium incremental output is retained. See `retest/cleanup.txt`.

## Native window policy (pipwindow, 2026-11-06)

The old policy only ORed AllSpaces/FullScreenAuxiliary onto a normal Chromium
window. That retained conflicting FullScreenPrimary/Primary flags, and clicking
an ordinary window could activate its app. Chromium video PiP starts as a
`NativeWidgetMacFramelessNSWindow`; Document PiP uses a specialized BrowserWidget
(also observed as `NativeWidgetMacFramelessNSWindow` in these runs).
Neither is an NSPanel. `remote_cocoa::mojom::WindowClass` has Default, Browser,
Frameless and Overlay, but no panel class. Replacing either with a bare NSPanel
would lose the Views bridge, accessibility, command dispatcher and resize logic.

Chromium already provides the equivalent mode: `setActivationIndependence:YES`
on `NativeWidgetMacNSWindow` sets canHide=false and makes its existing
`_isNonactivatingPanel` implementation return YES. We retain this existing API and its Views implementation, with the guarded
WindowServer-tag compatibility call described below. There is no runtime class
change or swizzle. In particular,
we do **not** put NonactivatingPanel in an NSWindow's style mask (AppKit defines
that mask for NSPanel only). Tests report the actual native class and activation
independence; they do not mislabel these windows as NSPanel instances.

The NativeWidgetMac init callback configures both kinds before show. The posted
placement repeats the policy after Chromium finishes initialization. Floating
level is retained. MoveToActiveSpace, FullScreenPrimary, Primary, Auxiliary,
Managed, Transient and ParticipatesInCycle are cleared; AllSpaces,
FullScreenAuxiliary, Stationary, IgnoresCycle and (macOS 13+) CanJoinAllApplications
are set. No application activation policy changes, activation calls, key-window
calls or desktop transitions are introduced. Apple documents
[CanJoinAllApplications](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications)
as allowing a window to join other apps' fullscreen/Stage Manager spaces;
[AllSpaces](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces)
is a separate desktop membership policy. Neither a level nor these flags alone
prove physical fullscreen behavior: the owner's manual check remains required.

`026-pip-window.patch` adds only an include and a one-line event callback in
remote_cocoa's sendEvent. All behavior lives in `airc_pip_window.inc`. Background
left-down/drag/up works without a key-window check (including the mouse sequence
sent by three-finger dragging). A 3-point threshold preserves clicks. Native
Views hit testing leaves controls and an 8-point resize border alone. Document
PiP additionally checks the web hit in an isolated world: buttons, links,
editable content, roles, tab stops, subframes, inline pointer handlers and videos
with native controls retain their events. Unknown or slow hit tests fall back to
Chromium after 250 ms. A site that uses unmarked custom controls should provide
semantic roles; generic hit testing cannot infer arbitrary JS event listeners.

Release chooses the display containing the drop point, a 20-point inset of its
visible area, and the nearest corner. Recent velocity above 650 points/s projects
250 ms toward the fling. Holding Command at any point in the gesture suppresses
snapping. A CASpringAnimation (mass 1, stiffness 320, damping 30) drives the window
frame animator. Edges and aspect ratio remain Chromium-owned. Move/resize
notifications keep video and document placement profile-local (separate keys;
see pipmeet below);
the existing placement kill switch disables the new policy too. Little Arc's
handoff uses the same engine PiP surfaces and needs no separate native window.

### Focus is not visibility

The erroneous path was `SetPictureInPictureWindowActive(false)` →
`HostVisibility::Answer()` → the patched tab-strip observer →
`OnTabActivatedChanged(false)`. It ANDed the host's shown state with key-window
activity, so Notification Center/Spotlight could trigger PiP on a visible page.
BrowserActiveStateManager's resign-key notification is retained for Chromium
bookkeeping; it is not the tab-strip visibility contract. `show`/`deactivateAll`
are real page attachment changes, while the app's repeated window-key input is
now only a request to reevaluate actual visibility.

Automatic entry now requires a hidden/detached host page or an ordered-out or
minimized native window. Key loss, application deactivation and ordinary covering
alone do not imply hidden content. The upstream occlusion auto-PiP feature stays
disabled. There is no separate app-switch preference in the engine API; no
app-switch heuristic is invented. A future explicit preference needs a distinct
app-activation signal, rather than reusing resign-key. The existing `window`
host case now actually orders out its own window; every positive test first
checks that focus-only loss leaves PiP closed.

### App-side floating call panel recipe

For the app's own call window, create an **NSPanel** with `.nonactivatingPanel`
at initialization (do not toggle that mask afterward), plus resizable/titled
styles as needed. Set `hidesOnDeactivate=false`, floating level, and the same
collection flags above. Show with `orderFront`, never activate the app or
makeKeyAndOrderFront. Allow key status for keyboard controls, never main-window
status; optionally use `becomesKeyOnlyIfNeeded` with appropriate
`needsPanelToBecomeKey` on input views. Apple documents that interaction in
[becomesKeyOnlyIfNeeded](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded).
Keep controls hit-testable and route only background mouse sequences into the
window drag/spring policy. Keep edge resizing, use the dropped-on display's
visibleFrame, support Command free placement, and persist the settled frame per
profile. Do not forward resign-key as "page left screen". No app sources were
changed by this engine task.

A native pause-button test exposed a second activation path in upstream
`remote_cocoa/app_shim/mouse_capture.mm`: its local capture monitor explicitly
calls `activateIgnoringOtherApps:YES` for a handled inactive left-down, even
when the window opted into activation independence. Patch 026 also adds an
include and one condition excluding Airc's tagged PiP windows from that fallback.
Normal window capture retains upstream behavior. This is why checking collection
flags or DOM `.click()` alone was insufficient; the host now sends native mouse
events to the video pause button and the site's mute/leave controls.

The capture guard alone did not prevent activation in the native video test.
Chromium's mode supplies AppKit's `_isNonactivatingPanel` behavior but does not
install the WindowServer prevents-activation tag normally set by NSPanel's
initializer. Airc therefore makes a guarded `_setPreventsActivation:YES` call
before show, for these two tagged surfaces only. This **is private AppKit SPI**,
not a public NSPanel initializer; it is a deliberate compatibility tradeoff to
preserve the substantial Chromium window implementation. It must be requalified
on macOS upgrades. If the selector disappears, the guarded call is skipped and
nonactivation is no longer fully qualified. No methods or classes are swizzled,
no implementation is copied, and non-PiP windows are unchanged. The native class
remains Chromium's NSWindow subclass, not a literal NSPanel. The app call-window
recipe should use an actual NSPanel and needs no SPI.

The WindowServer/AppKit distinction is independently documented in this
[AppKit investigation and sample](https://philz.blog/nspanel-nonactivating-style-mask-flag/).
The key point is that a style or AppKit predicate alone does not install the
WindowServer activation tag. This also explains why simply changing classes or
adding a style mask after initialization would not be a safe fix.

Native control dispatch also needs care: video control hit tests return
HTNOWHERE (not just HTCLIENT). Inactive PiP mouse sequences are delivered to the
hit native content receiver, preserving Chromium's Views/renderer handlers and
mouse-up/slider tracking while bypassing NSWindow's activating first-click path.
Document hit-test replies buffer and rebase queued pointer coordinates, so a
rapid down/drag/drag/up before the renderer reply does not double-count window
movement. Tests exercise that path with Command free placement. Open shadow DOM
is traversed; subframes and unknown hits remain Chromium-owned.

## App overlay (pipcontrols, 2026-11-06)

Airc draws Arc's picture-in-picture controls itself. The engine keeps Chromium's
PiP window, its video surface and pipwindow's native policy; it hides Chromium's
built-in controls and hosts one app view above the content.

API (main thread, `Airc.h`):

* `+[AircEngine setPictureInPictureOverlayProvider:]`: called once per new PiP
  window with the opener's `AircTab` and `info` (`kind` video/document, `window`,
  `topBarHeight` for Document PiP: Chromium's own top bar, 34 pt in 156). Return
  a view, or nil for Chromium's controls. The engine adds it as the last subview
  of the window's content view, sized to it with autoresizing, and keeps it on
  top of web content attached later. nil provider: no overlay.
* `-[AircTab pictureInPictureState]`: nil, or kind, window, appOverlay (view or
  NSNull) and chromeControls (Chromium's video controls, title or scrim drawn),
  for checks and diagnostics.
* Switch `pipAppControls=off` (`--airc-switches`) keeps Chromium's controls and
  never calls the provider.

Video: the view is installed inside `OnEnterPictureInPicture`, in the same task
that showed the window, so no frame shows Chromium's controls.
`VideoOverlayWindowViews::ForceControlsVisibleForTesting(false, false)` (a public
Views method that Chromium's own tests use; the engine already reads
`GetWindowForTesting`) keeps the controls container, title and scrims hidden and
out of hit testing. Chromium's frame still answers HTCAPTION for the video and
resize components for its 10-point border. Space still toggles play/pause. If
Chromium's auto-PiP permission prompt view is showing, no overlay is installed
(Airc's default ALLOW never shows it). Document PiP: the view is installed when
placement runs (the window finishes after the manager's notification); it covers
Chromium's top bar, whose buttons then never see a press.

Press routing (`airc_pip_window.inc`). On each left-mouse-down the engine asks the
overlay's `hitTest:` (point in its superview's coordinates) before anything else:

* A descendant: an app control. Down, drags and up go straight to that view with
  `mouseDown:`/`mouseDragged:`/`mouseUp:`, whether Airc is active or not, so the
  click never activates Airc and a scrubber keeps its drag. This must not rely on
  `BridgedContentView`'s `hitTest:`: it answers a draggable background before it
  looks at subviews. Controls must handle the three calls separately, with no
  nested tracking loop (no NSButton or NSSlider), and accept first mouse.
* The overlay itself: window-drag background (a Document PiP top bar). It drags
  with the same threshold, corner snap, fling and Command free placement; a click
  without a drag is swallowed, never forwarded to Chromium.
* nil: unchanged pipwindow behaviour (video background drag, Document PiP web
  hit test, Chromium's resize border).

Controls win over the 8-point resize band where they overlap it; the overlay's
background does not. A background press during the corner spring stops the
spring where the window is (before, the running animation pulled a new drag
back to the corner). Hover uses ordinary tracking areas (`activeAlways`); the
engine does not touch moved events.

Qualification: `engine/host/pip/run.mjs <host> <dir> video tab 0 overlay` installs
a stand-in overlay (one control and a 44-point drag band, `pip_overlay_view.inc`)
and runs the video fixture without any capture flag. Both frameworks pass:
installed above the video, Chromium's controls hidden at open and after hover,
pipwindow's drag, snap, fling and Command placement with the overlay present,
a control click (1 down, 1 up, frame unchanged), a drag started on a control
stays with it (2 drags, window still), the band drags the window with Command and
swallows its click, Airc never active. The existing video, muted and audio runs
pass unchanged. Call/Document PiP host runs need capture devices, so the Document
PiP top bar is qualified by the app's device-free check (`--script pipcontrols`).

## Document PiP keyboard policy

Document PiP starts non-key, including when Airc is already foreground. The
native-widget init callback sets `preventKeyWindow` before Chromium's first Show.
Activation independence and the guarded WindowServer activation tag remain in
place; the native Views bridge, resize edges, pointer routing and close remain
Chromium-owned.

A site-control press may grant keyboard focus only while Airc is the actual
foreground process (`NSWorkspace.frontmostApplication`, not `NSApp.isActive`).
This lets editable site controls receive typing on a deliberate foreground click.
Background site controls still receive pointer events, but cannot take keyboard
focus. Later site/native focus requests are rejected whenever Airc is background.

The existing `026-pip-window.patch` also consults the PiP callback at the start of
`canBecomeKeyWindow`. This independent guard survives Chromium's
`orderFrontKeepWindowKeyState`, which clears `_preventKeyWindow` directly after
an off-Space ordering operation. It does not alter the native class or swizzle
methods. Video PiP and other windows are not subject to the Document key guard.
The `pipPlacement` kill switch retains its existing all-native-policy fallback.

Qualification uses `--script pipcontrols`, `AIRC_REAL_CLICKS=1`, with HID idle at
least 120 seconds and the shared UI-check lock. `AIRC_PIP_DOCUMENT_ONLY=1` isolates
Document PiP; `AIRC_PIP_FOREGROUND=1` adds a separate foreground click/typing test.
The check watches background key notifications, entry/click/drag, site and native
focus after a simulated Chromium flag reset, resize, site buttons and close.
It does not change macOS Spaces or inject global input; an actual off-Space
transition and physical keyboard interaction remain separate manual checks.

## Meet sizing and call routing (pipmeet)

A 360×240 window with the site's **full call page** and no persistent browser
bar may be Airc's `CallPanel` fallback, not a Document PiP window. Its default
size used to be 360×240, with video-style controls fading over the page. Check
`pictureInPictureState.kind` and `CallWindowController.isShowing` before diagnosing
Document PiP geometry from a screenshot. The fallback previously only waited for
Chromium's automatic entry. If the site registers `enterpictureinpicture` but
native auto-entry is ineligible, it now requests that Media Session action once,
gives the site another grace interval, and only then falls back. Returning to the
tab or opening native PiP cancels the pending fallback. No site DOM is modified.

For sites without Document PiP, the full-page fallback now defaults to 800×600,
with a 640×480 minimum (bounded by the display's available area). It remains
user-resizable and remembers its settled frame per profile. Old small frames
are enlarged, and offscreen/oversized frames are fitted to the current display.
A permanent 48 pt Airc bar holds Close, Hide and Back to Tab **above** the page;
the site's microphone/camera/leave controls are the only call-control row.
There are no scrims or Airc call buttons over the page. The media tray retains
its controls, and the existing hide, Esc-collapse and context-menu actions remain.
This is a full page, not a browser-selected speaker tile: the site decides which
participants it renders, and the user can enlarge the window for more space.
The panel becomes key when a page press arrives, before delaying that press for
drag arbitration. Its nonactivating panel style preserves the foreground app;
the site's first camera, microphone or Leave click must take effect without a
second click. `medialib-call` checks the first-click result and foreground app.

Document PiP retains Chromium's requested/cached inner size, non-client bar and
min/max rules. Airc no longer proportionally screen-fits Document PiP a second
time. Its remembered corner uses `airc_document_pip_frame`; the existing
`airc_pip_frame` and public profile frame API retain video size semantics (a reset
clears both placements). Document resize
cannot change a subsequent video's remembered area. Chromium's own Document PiP
bounds cache remains authoritative (a site can request
`preferInitialWindowPlacement` to bypass it). We do not force a Meet-specific
minimum: Chromium 156 desktop clamps the inner size to at least 240×52 and adds
its 34 pt non-client bar; pages requesting a larger grid keep that size, subject
to Chromium's display limits.

`pictureInPictureState` additionally reports `documentView` and `topBarHeight`.
The device-free `--script pipcontrols` fixture requests 640×400, has a responsive
six-participant grid and right-most Leave control, resizes, and requests 80×40 to
exercise the minimum clamp. It compares JS inner dimensions, native visible
bounds and the overlay's page boundary, and seeds a 300×169 video placement to
check isolation. `AIRC_PIPMEET=1` also exercises tab-leave routing and captures
owned-window PNGs. With `--airc-switches=autoPip=off`, native automatic entry is
disabled deliberately so the registered-site-action path must succeed. Run with
the UI lock, `AIRC_REAL_CLICKS=1`, and `--airc-test=parityp16a`; existing owner-idle
and test-window safety guards apply. No camera, microphone or display stream is
requested. The marketing `calls` part refreshes `picture-in-picture-meet` at
640×400 with the fixture's full site controls below Airc's bar. It leaves the tab
and waits for the normal site-action route; it must not race that route with a
second explicit entry request. Its loopback demo uses a `.localhost` origin,
which Chromium permits for Document PiP. Marking an ordinary HTTP origin secure
for renderer tests does not satisfy the browser-side Document PiP URL check.

`AIRC_PIPMEET_GEOMETRY=1` runs only routing and native/JS geometry checks, with no
native pointer events, key requests or app activation. Run it in a dedicated
test session under the UI lock; it must not interrupt an active desktop. The normal input-driven suite requires 120 seconds of HID idle.

Historical comparison: [Chromium 134's window manager](https://chromium.googlesource.com/chromium/src/+/refs/tags/134.0.6998.35/chrome/browser/picture_in_picture/picture_in_picture_window_manager.cc)
also used a 240×52 desktop minimum, added the excluded non-client margin to the
site's requested inner dimensions and honored its document bounds cache unless
`preferInitialWindowPlacement` was set. This is a source comparison, not a real
Meet session measured in Chrome 134.

Geometry-only reproduction (fresh scratch directories):

```sh
python3 scripts/ui-check-lock.py open -g -n -W \
  --env AIRC_PIPMEET=1 --env AIRC_PIPMEET_GEOMETRY=1 --env AIRC_REAL_CLICKS=1 \
  build/Airc-Chromium.app --args --engine=chromium --script pipcontrols \
  --snapshot "$PWD/build/pipmeet-shots" --data-dir "$PWD/build/pipmeet-data" \
  --airc-data-dir="$PWD/build/pipmeet-data" --airc-test=parityp16a \
  --airc-switches=autoPip=off --autoplay-policy=no-user-gesture-required --use-mock-keychain
```

`fallback-large.png` explicitly exercises the full-page fallback, its permanent
bar and absence of duplicate call controls. The check also resizes and reopens
it to verify frame persistence. The privately retained `before-fallback.png`
was captured before this change; neither image is an authenticated Meet call.
`site-route.png` captures the site's native Document PiP reached through tab leave.
`requested.png` and `resized.png` accompany the native/JS geometry assertions;
`video.png` accompanies the video aspect/remembered-placement regression.

WebKit tab closure waits for `closeAllMediaPresentations` to complete, retaining
the tab and view through that asynchronous operation. Window/view teardown runs
on the following main-queue turn, after WebKit's close callbacks have returned.
The `pipreturn-return` probe sends the stop action and dismisses the native PiP
controller; PIP delivers its own animation-completed callback. The probe must
not synthesize `pipDidClose:` while the native window is still closing.

WebKit host requests retain their standard PiP entry promise on the video until
it settles. Close awaits that entry before exiting; the legacy presentation mode
can report PiP before the standard API has finished entering. This keeps a queued
entry from restoring stale DOM PiP state after the native window has closed.

Qualification (2026-11-09): both app builds pass from a clean `b0affccc` export
plus the PiP changes, with framework UUID `4C4C44DE-5555-3144-A16E-A37E4A455D8D`.
Two fresh Chromium rounds pass geometry, native controls, calls, media2, tray,
return and aspect checks. WebKit return/tray and first-click checks pass. Its ten
call-peer ICE assertions and the media2 system-PiP menu assertion remain
**FAIL-BASELINE**, reproduced on a clean `d10f6cd` export without these app changes.
All five call/video marketing captures completed and were inspected. Real Meet
participant selection, remote media and service-specific controls still require
one authenticated call; synthetic fixtures do not establish those results.

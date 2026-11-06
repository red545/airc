# V1 live-page hosting and link routing (pass 11)

Implements the engine half of spec §2.16b. The older “later” labels in the
research table do not override the owner's v1 decision. Product chrome, Space
metadata, shortcut bindings, routing rules, archive timers and undo belong to the
app. `app-pass11.patch` is an **unapplied** exact diff against `BrowserEngine.swift`
and `ChromiumEngine.swift`; no app-owned files were edited.

## API and Swift contracts

All engine calls and routing callbacks run on the main thread after startup.
Retain both windows through transfers and finish cancellable close before release.

| Swift API | Contract |
|---|---|
| `AircTab.attach(to:)`, `setPageVisible(_:)`, `pageVisible` | Attach each pane to a distinct app-owned rectangle. All attached panes are visible, including inactive tabs of the same profile and tabs of different profiles. Hide/show keeps the parent; attach does not steal focus. |
| `AircTab.independentZoom` | Set true for split panes to isolate zoom even for same-origin pages. `zoomFactor`, `find`, `findState`, `stopFinding`, `showDevTools` and `attachDevTools(to:)` remain per-tab. |
| `AircWindow.activate(_:)`, `AircTab.focus()` | Select the pane's profile/tab for commands, then assign its native first responder. Other panes stay attached and visible. |
| `AircWindow.moveTab(_:profile:to:) -> String?` | Synchronous: nil is success. `profileMismatch`, `closedTab`, `invalidHost`, `busy`, `closingWindow`, `missingOwner` refuse before mutation. Target host must belong to the destination window. A tab cannot change profile. Calls during tab-strip notification return `busy`; schedule on the next main-loop turn. |
| `AircWindow.openPeek(url:opener:in:) -> AircTab?` | Create an ordinary live tab in the opener's profile and attach to the supplied overlay container. The app owns card geometry, z-order and dismissal. Promote through `moveTab`, never by reopening the URL. Close through `tab.close()`; beforeunload is still honored. |
| `AircEngine.routeExternalURL(_:) -> Bool` | Call from `application(_:open:)` while the Apple event is current. True means policy consumed it; false means apply the app's default. `currentEventSourceBundleID` reads the OS sender PID and resolves its running bundle, or returns nil. Never infer a source from the foreground app. |
| `engine(_:routeLink:opener:) -> Bool` | Optional synchronous policy callback for HTTP(S) page links, including new tabs/popups and Peek links, and external URLs. Dictionary: `url`, `source` (`page`/`external`), `disposition`, `userGesture`, optional `sourceBundleID`. Opener is nil for external URLs. True cancels the original request; defer any tab creation/mutation to the next main-loop turn. False preserves Chromium's normal behavior. |

A policy routing to another **profile** starts a fresh navigation in that profile;
it does not migrate the original WebContents, opener, POST body or JavaScript
window handle. Policies needing popup/opener semantics should return false and
adopt the live tab from `didInsertTab` later, within its original profile. Page
requests have no OS source-app bundle ID. Non-HTTP(S) page URLs retain existing
protocol/security handling.

A Little Arc window is an ordinary external `AircWindow`: select a profile before
calling `openTab`, keep exactly one app-owned page, then move that same tab to the
main window. Switching profile after load requires creating a different tab; the
move API deliberately refuses it. Same-profile Spaces and normal/Peek/split
presentation are app metadata, not different engine tab types.

### Adapter diff

`EngineWindow.presentPanes(_:focused:)` validates 1–4 distinct tabs/hosts, hides
other content, enables isolated zoom and attaches each page. `focusPane` changes
focus without collapsing the split. `activateTab` returns to normal presentation
and hides all other panes. Native page activation focuses a visible pane rather
than invoking the PiP return-to-tab flow.

`moveTab` transfers the **existing Swift wrapper**, owner and delegate. Deferred
`didRemoveTab` cleanup checks membership so a quick out-and-back transfer cannot
erase a returned wrapper. `openPeek` wraps the new page without hiding its opener.
`BrowserEngine.linkRouter` exposes a typed `EngineLinkRequest`; the runtime forwards
engine requests to it. The app must install the policy, forward its existing
open-URLs entry point to `routeExternalURL`, and map ⌘O / split / close UI actions
to these APIs. Defaults keep WebKit source-compatible but throw explicit unsupported
errors for live presentation/moves; this diff does not claim WebKit feature parity.

### Visibility and resize

Each pane's `pageVisible` uses the same `ShownByHost` state consulted by the
permission and auto-PiP hooks. Transfer avoids a host hide/show pair, which would
spuriously signal a tab switch to automatic PiP. A real hide still invokes the
existing visibility path. A split does not imply four active Browser profiles:
window-scoped commands use the focused pane; page-scoped commands take a tab.

Resize the app containers' frames directly. Native page views autoresize, and
neither tab ownership nor attachment changes on a divider tick. The measurements
below are main-thread frame-setter wall time, not GPU presentation or proof of
120 Hz animation on an unlocked display. ResizeObserver counts establish bounded
page resize notifications, not an instrumented count of every Blink layout.

## Reproduction

On the build Mac, in the engine work copy, using the existing build launcher:

```sh
engine/build.sh --start --variant dev
# After EXIT 0; never build the two variants concurrently:
engine/host/features-v1.sh dev build/pass11-dev
engine/build.sh --start --variant release
# After EXIT 0:
engine/host/features-v1.sh release build/pass11-release
```

Run through the Mac helper's login shell so Node is on PATH. Both framework builds
are incremental, in `airc-engine`, under caffeinate. The test runner builds a signed
background host and uses fresh synthetic profiles and loopback pages. Its
`synthetic-extension` case installs a checked-in fixture asynchronously through
Chromium's unpacked installer, restricted to the existing unsigned/mock-keychain
scratch test gate. It does not download a Web Store extension. The inherited
synchronous `loadComponentExtension(path)` remains unsuitable after startup: the
first fixture attempt exposed its blocking-I/O DCHECK; no production allow-blocking
escape hatch was added.

Generate and validate the app diff without modifying the app's files:

```sh
python3 engine/tests/make-pass11-patch.py
git apply --check engine/app-pass11.patch
# On the build Mac, using the generated adapter copies:
engine/tests/features-adapter.sh build/pass11-dev/host/AircHost.app build/adapter-check
```

The generator stores ignored temporary Swift copies under `engine/tests/pass11-adapter`.
The test compiles with warnings as errors and verifies wrapper identity, same-profile
moves, rejection across profiles, retained JavaScript/form state and Peek promotion.

## Evidence (2026-11-06, locked display)

Private bundle: `engine/pass11/`, with final runs in `pass11-dev-evidence/` and
`pass11-release-evidence/`. Both report `screenLocked: true`. No screenshot is
presented as native UI proof. Dev is optimized with DCHECKs enabled; release is
optimized with DCHECKs disabled. All results below refer to the real linked
framework and synthetic data, not a mock BrowserEngine.

| Requirement / regression | Dev | Release | Evidence and boundary |
|---|---|---|---|
| SV-1: four panes, two profiles, horizontal and vertical | PASS | PASS | `features/features.json`: four native first responders receive NSEvent `x`; four independent find results; same-origin isolated zoom, including after reload; four per-tab DevTools attachments. All four DOM visibility states remain `visible`. |
| Visibility / auto-PiP inputs | PASS state | PASS state | Every pane keeps `pageVisible=true`, the authoritative host visibility used by the auto-PiP hook. Movement avoids a host hide transition. Actual automatic PiP window entry and presentation while locked are not qualified by this test. |
| PK-1: overlay, promotion and destruction | PASS | PASS | Opener profile and underlying page stay visible. Peek's original wrapper/WebContents moves to Little Arc and back into a split container; retained token, form, scroll and playing video; `peekDestroyed=true` after close. Card appearance and ⌘O binding belong to the app. |
| LA-1: one-page second window, profile choice before load | PASS | PASS | `littleProfileBeforeLoad`, `littleOnePage`; transfer into/out of the compact external window without navigation. URL row, profile picker and six-hour archival are app work. |
| Live moves / profile boundary | PASS | PASS | `crossProfileRefused=true` with no source mutation. JS token and form unchanged; video time advances across moves. Scroll changes from 100 to 99.5 CSS px at the new geometry (one device-pixel rounding tolerance), not a return to page top. |
| AT-1: page popup, target blank, external URL | PASS | PASS | Three real events route into Profile Two and each resulting document reads `route=two` from that profile's cookie jar. The self-addressed macOS Get URL Apple event reports `dev.airc.airc-host` as sender; page events omit bundle ID. This does not test the production app's default-browser registration or a Mail/Slack launch. |
| Isolation / restart | PASS | PASS | `isolation/results.json`: two distinct cookie/localStorage values survive restart; switches preserve page state and renderer copy succeeds. Locked native window capture is skipped. |
| Discard | PASS | PASS | `memory/memory.json`: inherited discard/restore and protection assertions. |
| Extensions | PASS synthetic | PASS synthetic | `synthetic-extension/synthetic-extension.json`: real unpacked fixture install, action popup text/profile and absence in the other profile. Web Store download/install was not rerun under the synthetic-only constraint. |
| Platform passkey dialog | PASS state | PASS state | `dialog-platform/dialogs.json`: registered parent, child modality, hide/restore, move and Cancel rejection. No real credential or unlocked pixel proof. |
| Hybrid passkey dialog | FAIL qualification | FAIL qualification | `dialog-hybrid/dialogs.json`: request stays pending; no dialog registered before timeout despite a valid host. The locked-session/device-discovery path remains unresolved; no claim that the lock alone explains the failure. |
| HTTP auth / close with auth pending | PASS state | PASS state | `dialog-auth/` and `dialog-auth-close/`: modal ownership, cancellation/401 response and destruction with tab. |
| Beforeunload cancellation | PASS state | PASS state | `dialog-beforeunload/`: cancellation retains the page; uses the actual Cancel handler while locked, not a fake JS dialog result. The earlier run attempted native Escape while locked and timed out; both outcomes are preserved. |
| Virtual credential create/get | PASS | PASS | `dialog-virtual/`: synthetic authenticator creates and retrieves the same credential. |
| Swift adapter integration | PASS | — | `pass11-adapter-final/result.txt`: warnings-as-errors compilation and runtime identity-preserving out-and-back moves, profile refusal, two panes, live state, Peek promotion. The source diff also passes `git apply --check`. |
| Strict Chromium hooks | PASS | same source | `apply.txt`: pristine/applied/repeat checks, drift refusal, source mirror unchanged; 24 strict patches over 53 upstream files. No new upstream hook added. |

Both suite exit statuses are **1**, because hybrid-passkey qualification fails.
They are not represented as wholly green suites. Five other dialog scenarios and
the requested feature scenarios pass on both frameworks. The screen remains
locked, so actual pointer gestures, Japanese IME candidates, native card/docking
appearance, ProMotion presentation and the production app's UI remain unqualified.

## Performance notes

[perf/features-v1.json](perf/features-v1.json) is a path/URL-free summary of the
final feature reports, generated by `perf/features-v1.py`.

- DCHECK-enabled: four-pane resize median **0.264 ms**, p95 **1.461 ms**, maximum
  **2.382 ms**, over 120 frame updates (60 horizontal, 60 vertical). Peek creation
  **12.484 ms**; live cross-window transfer **0.877 ms**.
- Release: resize median **0.181 ms**, p95 **0.755 ms**, maximum **1.246 ms**. Peek
  creation **10.009 ms**; transfer **0.473 ms**.
- ResizeObserver delivered **10, 19, 19, 19** notifications to the four documents
  during the 120-update sweep: coalesced updates, with no notification storm or
  reattachment. These counts do not prove Blink layout cost or unlocked 120 Hz.
- Peek/move are single synchronous-call samples, not cold-page-ready percentiles.
  Loading and compositing are asynchronous. The synthetic video remained playing:
  dev time advanced **0.332 → 0.658 s**, release **0.325 → 0.644 s** across transfer.
- The same native view/WebContents and Swift wrapper survive transfers. No URL
  replay, screenshot swap, renderer replacement or profile mutation is used.

Final incremental framework builds both ended in `EXIT 0`; the owner's
`out/AircRelease` contains the final core, including navigation-stable zoom
isolation. The test work copy and temporary measurement output are removed after
copying evidence to the coordinator. No changes were pushed.

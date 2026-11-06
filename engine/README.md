# Airc Chromium engine spike

Chromium 156.0.8078.88 now compiles and links `Airc Framework.framework` on the build
Mac. The signed background host passes two-profile cookie/localStorage isolation,
restart/URL restoration, repeated switches without reload, deactivateAll and renderer
surface copy. Window captures show the two fixture pages and Gmail/Calendar sign-in
pages side by side. No Google credentials were used. The Swift adapter/startup bridge
passes a signed runtime smoke test; the production app wiring is supplied as an unapplied diff.
The strict patch application tests pass against the pinned Linux mirror.

`CHROMIUM_VERSION` pins **156.0.8078.88**. `core/` becomes `//airc/core`, linked into
Chrome's `chrome_framework` through `chrome_dll`. Chromium's supported
`branding_file_path` argument produces `Airc Framework.framework` and Airc helpers.

## Source and licensing

Ported the Apache-2.0 `engine/ardiacore/src/ardia/core` at Ardia commit `efda065`.
Namespaces and symbols use `airc`, Objective-C classes use `Airc*`, file names use
`airc_*`, and renderer Mojo interfaces, app scheme, exported symbols and launch
switches are renamed. Original copyright lines remain; modified files carry a
modification notice. `NOTICE` records the core, apply-hook and host-script sources.
No files from Ardia's `engine/patches`, Helium or ungoogled patch series were copied.

The current source is considerably newer than the four-hook spike described in the
spec. Its original apply script contained 46 integrations, and other integrations used to come
from Ardia's separate patch series. This port adapts those Apache apply-script
integrations and adds six independently written upstream integrations. It does not
claim the remaining patch-series behavior is present.

Replacements and omissions:

- Product strings rename upstream Chromium only. The Helium replacement was removed;
  copyright and open-source credits remain untouched.
- Removed `//chrome/browser/ardia` and its script-policy throttle and closed-tab
  history cleaner. Those facilities are not supplied by plain Chromium. The host
  owns URL restoration; full navigation-history restoration still needs validation.
- External-app descriptions use `NSBundle` instead of Ardia's app-description module.
- Removed the MetalFX video-upscaler implementation and its patched compositor API.
  `videoUpscalingState` explicitly reports `supported: false, enabled: false`.
- Removed the patched `BridgedContentView.ardiaEmbeddedView` dependency. The host is
  an ordinary AppKit subview. Embedded-view hit testing, focus and resize behavior
  must be qualified on screen before adopting this for the production shell.
- Permanently separate keychain identity: **Airc Safe Storage**, account **Airc**.
  Upstream otherwise hard-codes Chromium's identity despite the GN branding setting.
  Do not change these names after profiles have shipped.
- `airc_upstream_seams.cc` supplies callback storage for integrations not ported from
  the old GPL-distributed patch series. Some are wired by the new Airc patches;
  the rest are explicitly pending below. Initial-document access uses upstream's
  `WebContentsImpl::HasAccessedInitialDocument`, not a heuristic.

## Apply and validate

```sh
engine/apply.sh --check --src /path/to/chromium/src
python3 engine/tests/check_apply.py /path/to/chromium/src
engine/apply.sh --src /path/to/disposable-or-build/chromium/src
```

`--check` accepts either the exact pristine pinned files or the exact fully patched
files. It applies all hunks in memory, with exact line numbers, whitespace and
context, then verifies final SHA-256 hashes. On an applied tree it also compares
`//airc/core` byte for byte. It never creates files. An upstream file with unrelated
edits is refused. An apply validates the entire series before writing, copies only
`airc/core`, and atomically replaces each changed file. A partially interrupted apply
can resume because every touched file is independently pinned. Do not edit copied
core files in Chromium; edit this repository and apply again.

The scratch test copies only the 51 touched source files plus `chrome/VERSION`.
It checks pristine dry run, real apply, repeat apply, applied dry run, deliberate
drift refusal, and that the source mirror remained unchanged.

## Hook inventory

The complete ordered list is [patches/series](patches/series); the manifest pins all
before/after bytes. There are **23 concern-grouped patches over 51 files** (52 before pass 3):

- Framework dependency and main delegate.
- Browser window factory and WebContents delegate.
- Viewless reading mode, toasts, pinned-tab close, clear-browsing-data and sad-tab guards.
- Embedded startup: main delegate, browser main loop, Mac app delegate, URL handlers,
  policy provider, and resource-bundle delegate.
- Permission prompts, host-visible tab activation, file-system restore prompts and
  tab dialog visibility.
- Autofill suggestions, page opacity, external-protocol requests and history eligibility.
- DNR action/ruleset notifications, hidden extension windows, installed-extension UI,
  CRX prompts, action popups, local/global reserved shortcuts and action state restoration.
- Auto-PiP host visibility (header and implementation).
- Idle CPU sampling, disk-space timer, storage quota accounting, hybrid WebAuthn sheet
  visibility, Bluetooth polling, and script-loader timing. These are inherited
  optimizations, not requirements of the two-profile spike; candidates for pruning.
- New Airc patches: resource initialization, keychain identity, keeping an empty
  profile Browser alive, password prompts, extension install prompts, device choosers.

## Public host API

Import `Airc.h` from Objective-C or `import AircCore` with `core/public` on Swift's
include path. `tests/import.swift` type-checks the named Swift entry points. All calls
are main-thread-only after `engineDidStart`. Retain the engine delegate for the run.

- `AircEngine.run(argc:argv:delegate:)` owns Chromium's message loop. Do **not** call
  `NSApplication.run()` separately. Pass an explicit `--user-data-dir`; quit through
  `engine.quit()` so beforeunload and profile shutdown can complete.
- `profileDirectoryNames` lists persisted regular profile directories, excluding
  `Airc Internal`. `createProfile(completion:)` makes a UUID-named directory;
  `loadProfile(directory:completion:)` creates or loads a named profile. Completion
  receives nil on failure. Directory traversal is rejected. `deleteProfile` schedules
  deletion (YES means accepted, not disk deletion completed); close its tabs first.
  Chromium's initial `Default` profile cannot be deleted by this API.
- `loadInternalProfile(completion:)` uses a stable hidden directory. Use it only with
  an `AircWindow` whose `internal` flag is YES. This is a distinct real profile,
  not a privacy boundary against trusted browser extensions or native code.
- `AircWindow.prepareProfile` creates one Chromium `Browser` per (window, profile).
  `openTab(url:profile:foreground:)` opens within that browser. `activateTab` changes
  the active profile and tab. Tabs never change profile.
- Detach the old tab, activate the new tab, then `attach(to:)` the new page in an
  app-owned view. Attachment sizes/autoresizes the view and updates host visibility.
  `detach()`, navigation, back/forward/reload, close, discard and freeze are separate
  operations. Keep the `AircWindow` alive until its cancellable close finishes.
- `AircTabDelegate` reports URL, title, favicon, loading/progress, navigation, audio,
  renderer exit/unresponsiveness, permission-adjacent events and page messages.
  `AircWindowDelegate.didInsertTab` supplies live new-tab/popup contents, opener and
  disposition; retain/adopt those tabs rather than replaying a navigation.
- Host-owned permission/password/autofill/chooser panels are driven by engine/window
  delegates. Set `window.uiAnchorView` and use `uiAnchorRectInScreen` to anchor them.
  This anchor is **not** a blanket override for every Chromium Views bubble.
- `profile.extensions` lists installed non-component extensions, including enabled state. `tab.actionStatesForExtensions`
  exposes action icons/badges. `window.openActionPopup(extensionID:tab:)` runs the
  action (including its activeTab grant) and returns a profile-bound popup tab when
  requested. Attach its view to an app-owned panel and close it on dismissal.

**Window integration:** `initWithWindow:hostView:` now accepts a Swift-owned
NSWindow and page container. The older widget-backed initializer remains available.
See [HOSTING.md](HOSTING.md) for the hidden Views scaffolding, input/lifetime contract,
and surfaces still requiring product UI and runtime validation.

## Build on the Mac

The completed checkout requires a fetch log ending with `EXIT 0`:

```sh
# From the repo on the Linux coordinator; syncs into the engine work directory:
scripts/mac.sh -w engine run 'engine/build.sh --start'
# Or directly inside the repo copy on the build Mac:
engine/build.sh --start
```

The launcher refuses an unfinished/failed fetch, avoids a duplicate `airc-engine`
screen, and runs `caffeinate -s` inside that detached screen. The worker uses an
exclusive lock in Chromium, applies/checks the core, runs `gn gen out/Airc`, then
`autoninja -j 8 -C out/Airc chrome_framework`. Re-run to resume an interrupted build.
GN arguments and their reasons are commented in `build.sh`. Widevine support is
compiled for runtime CDM delivery (no bundled proprietary binary); see DRM.md and
PASS-DRM.md for licensing, signing and qualification limits. No PGO, ThinLTO or
debug symbols; H.264/AAC are enabled. No global tool installation is performed.
If Xcode lacks its Metal toolchain, report the compiler diagnostic to the operator;
the script does not install system components.

```sh
scripts/mac.sh -w engine ssh 'tail -80 ~/arcfork/airc-engine.log; screen -ls'
```

The log ends with `EXIT <status>`. A stale `.airc-engine-lock` must be inspected before
removal; do not delete it while its PID is running. Avoid syncing changes to the
engine work copy while its build is active.

## Two-profile host and acceptance

After the framework exists:

```sh
engine/host/build.sh
# Does not take focus. This explicit data directory is isolated from installed browsers.
open -g -n engine/host/build/AircHost.app --args \
  --user-data-dir="$HOME/arcfork/engine-host-data"
# Node 22+, no npm dependencies; scratch directory must not already exist:
node engine/host/acceptance.mjs engine/host/build/AircHost.app \
  "$HOME/arcfork/engine-isolation-run"
```

The host has one window, Profile One/Profile Two buttons, Back, Reload and Quit. Each
profile opens Google's sign-in page on first launch. Tab URLs are saved in the data
directory, and the core requests persistence/restoration of session cookies.

The automated test uses a local HTTP fixture, two real profiles, distinct persistent
cookies and localStorage, switches both page views, quits cleanly, relaunches and
checks both markers. It uses Chromium's mock keychain, never real credentials. It passes on the build Mac (2026-11-05), including renderer surface copy and repeated
view switches without reload. The preserved historical
`host/reference/acceptance.mjs` fails immediately by design: its old command-file host
and CEF-era API assumptions need adaptation. It is an inventory for future parity,
not a second claimed passing test suite.

Manual acceptance remains: sign into different Google accounts in the two profiles,
switch repeatedly in one fullscreen window, quit, restart, and confirm both accounts
and their restored pages. Also check focus/IME, permission anchoring and background
profile prompts with an unlocked display. No real account sign-in has been performed; only signed-out Google pages were captured.

## Remaining upstream work and risks

- Framework compilation/linking and the host acceptance now pass. The production
  Swift app is not yet wired; its adapter was type-checked and exercised in a separate signed Swift host.
- Callback-only integrations in `airc_upstream_seams.cc` still need upstream call
  sites: Cast UI, extension side panels, DevTools docking, session-service exclusion,
  initial-document notifications, temporary-tab restore filtering, component-extension
  restrictions, safe-storage failure recovery/test keychain, and token-scoped DevTools.
  Begin-frame warmup and custom PiP entry detection are not supported. None is claimed
  as a working re-hosted surface. Do not ship this spike as a browser.
- Native view embedding without the old Cocoa patch needs input, hit testing, resize,
  compositing, accessibility and focus tests. Hidden runs cannot establish these.
- Several loaded Browsers map to the same NSWindow. Upstream APIs that find the first
  Browser for a window may choose the wrong profile for prompts, passkeys or extensions.
- The inherited profile wrappers are weak. Live Browsers keep profiles loaded, but a
  loaded profile with no Browser needs an explicit lifetime policy in the shell.
- A hidden profile is excluded from Airc's list and has internal window routing; audit
  upstream session restore and extension visibility before trusting that isolation.
- Cookie separation is not evidence of Google login, password/passkey, extension,
  DRM-free media, crash recovery or shutdown parity. Those require the actual build.

## App integration follow-up (2026-11-05)

The adapter now lives in `apps/browser/Sources/Airc/Engine/ChromiumEngine.swift` and
imports **AircCore**, the module in `core/public/module.modulemap`. It implements
all existing BrowserEngine protocols. It retains wrapper identity, decodes evaluate
JSON, converts theme colours, forwards loading/progress, and maps `tabWillClose`
to the app's close callback asynchronously outside TabStripModel notification.

Answers to the app's seven asks:

1. `initWithWindow:hostView:` accepts a Swift-owned window/container. The adapter
   constructs an ordinary NSWindow and the app can replace its contentView as it
   currently does. See [HOSTING.md](HOSTING.md) for ownership and remaining UI work.
2. `deactivateAll` detaches every page and clears activeProfile without unloading.
3. `openTab` now suppresses `didInsertTab` during its synchronous Navigate call.
   Engine-created tabs still notify. `activateTab` now changes activeProfile too.
4. `AircTabDelegate.tabWillClose` is the existing engine-originated close event;
   host-initiated closes suppress it. The adapter maps it to tabRequestedClose.
   It is notification of closure, not a veto hook. Beforeunload remains engine-owned.
5. `copyPicture(timeout:completion:)` copies the renderer surface. It returns nil
   when no surface exists or copying fails. The adapter wraps the CGImage in NSImage
   inside the callback. It captures a page only; full-window evidence uses the host's
   own CGWindowID through CGWindowListCreateImage. Both renderer surface copy and own-window capture now pass.
6. One measured fresh-profile run took approximately 41 ms and 25 ms (including
   profile service initialization). Already-loaded callbacks on restart took less
   than 0.1 ms. These are samples, not guarantees. Keep a spare profile and its window
   Browser prepared, then warmSpareRenderer. Durations are in the acceptance JSON.
7. Call `ChromiumRuntime.run` / `AircEngine.run` before creating NSApplication. Only
   initialize the app in engineDidStart. Never run a second AppKit event loop. Route
   window close through Chromium's cancellable close path; process quit goes through
   engine.quit (the existing Chromium application swizzle handles NSApp.terminate).

[app-wiring.patch](app-wiring.patch) contains the exact proposed changes outside
engine ownership. **It has not been applied.** It selects Chromium with
`--engine chromium` or `--engine=chromium`, initializes AppDelegate at engine startup,
selects the adapter, routes native window close, and adds conditional framework
linking/embedding. Apply it with the app agent after review, then build:

```sh
CHROMIUM_OUT=/path/to/chromium/src/out/Airc scripts/build-app.sh --no-test
open -g build/Airc.app --args --engine=chromium --user-data-dir=/path/to/scratch/Chromium
```

Use an explicit isolated user-data-dir for every development run. The app's
`--data-dir` is its sidebar model store, not Chromium's profile root. Do not use
`--ephemeral` with persisted Chromium data: the current protocol has no transient
Chromium profile-root lifecycle. Builds without CHROMIUM_OUT keep the WebKit path.

`embed-framework.sh APP CHROMIUM_OUT` clones the framework including its versioned
Resources, Libraries and Helpers into Contents/Frameworks. Do not rename helpers
or flatten framework symlinks. It signs nested dylibs, helper apps (renderer/GPU
entitlements from Chromium), the framework, then the app, and verifies deeply.
Ad-hoc builds add disable-library-validation; distribution builds set
AIRC_SIGN_IDENTITY and need Developer ID, timestamping and notarization in the
release pipeline. This helper is for local integration, not a release-signing recipe.
The executable links the framework binary with an executable-relative Frameworks
rpath. The public module is a compile-time include; it does not itself embed a dylib.

The startup bridge dismisses permissions/install/device requests by default. The
protocol needs product UI hooks before these surfaces are usable; do not treat the
adapter as complete permission/autofill/extension/find UI. See HOSTING.md.

The acceptance host now uses an app-owned NSWindow, displays both profile pages
side by side for evidence, captures only its own window, checks that app opens do
not echo insert callbacks, records profile timing, and restores URLs from the saved
file on the second run. The runner launches via `open -g -n -W`. These additions
pass runtime acceptance on the build Mac. Hook count remains **52**; all
new hosting and callback changes are inside core (no new Chromium hooks).

The first compile diagnostic found a fork-only `TabSharingInfoBarDelegate::capturer_id`
accessor. Upstream 156 does not expose capture-session identity. The optional
`canShareThisTabInsteadFor` / `shareThisTabInsteadFor` operations now return false
rather than guessing which capture session to redirect. No hook was added for it.


## Verified build and runtime result (2026-11-05)

The final incremental build ends `Build Succeeded` / `EXIT 0`. The signed host bundle
is approximately 698 MB. Fixes during this pass:

- Removed the unavailable capture-session accessor (optional capture redirection is
  unavailable), corrected a raw pointer rejected by Chromium's plugin, removed a
  stale external-app icon variable, and removed a non-upstream virtual override.
- Exported only the five public Objective-C classes and defined the missing
  extension-visibility callback. No hook changes were needed.
- Fixed external-window AppKit declarations, used nonzero hidden-widget content
  bounds, and explicitly managed native-view hidden state and WebContents visibility.

Acceptance output:

```text
PASS write: two profiles, isolated persistent cookie and localStorage
PASS read: two profiles, isolated persistent cookie and localStorage
PASS restart restored both profiles. Real Google account acceptance remains manual.
```

Each phase also checks twenty tab switches plus deactivateAll without losing a
JavaScript marker, and obtains a non-null `copyPicture` renderer surface. Profiles
have `airc_profile=one` and `airc_profile=two` respectively, before and after restart.
The host quits itself. Captures use CGWindowListCreateImage with only its window ID.
For background Google captures include `--disable-backgrounding-occluded-windows`;
otherwise an occluded window may not paint and its capture can be blank. The fixture
runner already supplies that switch. The Google capture waits for loading to finish,
reattaches both pages and allows layout to settle before capturing. Do not disable occlusion globally in production.

Evidence files supplied with the implementation report: `write.png`, `read.png`,
`google-first.png`, `google-restart.png`, `results.json`, and `build-summary.txt`.
They are artifacts outside the repository, not committed user data.

Still unqualified: interactive IME/focus/accessibility, fullscreen transitions,
permission/autofill/passkey panels and extension-popup anchoring. The ad-hoc host
logs a missing WebAuthn keychain-access-group entitlement; passkeys are not accepted.
The find bar remains host-owned UI work. Hook count: **52 over 51 upstream files**.


The Swift adapter also passes a separate signed-host runtime test:

```sh
engine/tests/adapter.sh engine/host/build/AircHost.app /path/to/new-adapter-scratch
```

```text
PASS Swift adapter: two profiles, switching, evaluate, snapshot, deactivateAll
```

This found and fixed the core evaluation contract difference: AircTab.evaluate takes
an asynchronous function body with `post(kind, json)`, not a bare expression. The
adapter JSON-quotes the app expression, evaluates it, posts its serialized result,
and bounds completion to ten seconds. The test constructs the NSWindow in Swift and
links the actual BrowserEngine/ChromiumEngine files, rather than a mock protocol.
The app itself still needs the supplied wiring diff and product prompt/find UI.


## Pass 3: memory and extension APIs

See [PERFORMANCE.md](PERFORMANCE.md) for footprint methodology/results and
[HOSTING.md](HOSTING.md) for the qualification table and concrete app wiring.
New tests use `engine/host/acceptance.mjs <app> <fresh-directory> memory` or
`extension` (installs uBlock Origin Lite only in throwaway Profile One), and
`hosting` (currently fails native IME in the non-key background window).
`engine/host/memory.py` samples 0/1/3/6 additional empty loaded profiles with
Apple `footprint`; `engine/host/workload.py` measures the fixed reference workload
and 100 real open/close cycles. Use `--all` only for the 30-loaded-page stress case,
not the 8-loaded/22-model-only reference policy. Neither tool touches owner data.

## Pass 4 handoff

See [HOSTING.md](HOSTING.md#pass-4-qualification-2026-11-05) for the exact native
surface pass/fail matrix and evidence names, and [PROFILE-SERVICES.md](PROFILE-SERVICES.md)
for credential import, history, Google-account cache, download progress, find state,
anchor rectangles, Space context menus and keep-attached visibility contracts.
This is still incomplete browser qualification; the ≤30-upstream-files goal is
also not met (51 remain). `app-wiring.patch` is unchanged.

Reproduce the background host tests on the build Mac:

```sh
engine/build.sh --run
engine/host/build.sh engine/host/build/current
node engine/host/acceptance.mjs engine/host/build/current/AircHost.app engine/host/build/fresh-isolation
# Each scenario needs a distinct fresh scratch directory:
node engine/host/acceptance.mjs engine/host/build/current/AircHost.app engine/host/build/fresh-hosting hosting
# Other scenarios: services, surfaces, devtools, download, video, memory.
engine/tests/adapter.sh engine/host/build/current/AircHost.app engine/host/build/fresh-adapter
```

The tests always quit their host, use synthetic credentials/mock keychain, and
route menu picks through the real menu model without foreground Cocoa tracking.
`surfaces` asserts all four permission callbacks, profile identity, anchor geometry,
permission denial and a Space submenu command. `video` uses a canvas-backed video
stream for page fullscreen and PiP transitions, not a macOS fullscreen Space.

## Pass 5 update

[PASS5.md](PASS5.md) supersedes the earlier integration/qualification status:
two startup hooks retired, two form-crash fixes added, final 51 upstream files / 23
patches (≤30 still unmet). Password save/fill, native upload sheet attachment/cancel,
and address/card save/persistence pass in background fixtures. The app agent has
applied production wiring and a fresh rebuilt Airc.app passes minimal Chromium
startup/report/exit. Address/card fill, visible UI and native print remain open.

## Background-service policy and performance diagnostics

The main delegate now gates optional model delivery, AI history enrichment,
commerce, speculative translation packs, segmentation telemetry, testing field
trials and Google browser sync. Each group has an `--airc-switches=NAME=off`
startup rollback. See [BACKGROUND-SERVICES.md](BACKGROUND-SERVICES.md) for exact
features, security/component exceptions and the UKM startup dependency.

[PERFORMANCE.md](PERFORMANCE.md#pass-6-optional-background-machinery-2026-11-05)
records the locked-display Airc/Chrome comparison. It is **not a release pass**:
public-page renderer failures invalidate MEM-4 acceptance, total-memory results
are mixed, and one eight-page idle sample exceeds 1% CPU.

On the build Mac, after the single engine build and a fresh signed host build:

```sh
xcrun clang -O2 engine/perf/counters.c -o engine/perf/counters
python3 engine/perf/check-counters.py
bash engine/perf/run-after.sh PATH_TO_HOST.app NEW_SCRATCH_PREFIX
bash engine/perf/qualify.sh PATH_TO_HOST.app NEW_REGRESSION_DIRECTORY
bash engine/perf/launch.sh BEFORE_HOST.app AFTER_HOST.app NEW_LAUNCH_PREFIX
```

Use fresh scratch paths under the build workspace/performance area. Never point
these tools at an installed browser's user-data directory. `measure.py` uses
`open -g`, mock keychain and loopback CDP, then signals only recorded test process
identities. It leaves the scratch evidence, not test processes. Run benchmarks
sequentially and separately from builds/acceptance. Renderer captures and paint
timestamps are not proof of an interactive or presented native window.

## V1 favourites engine handoff (pass 11)

[FEATURES-V1.md](FEATURES-V1.md) documents four-pane hosting, independent zoom,
Peek, profile-safe live moves, Little Arc hosting and page/external link routing.
The app additions are an unapplied [app-pass11.patch](app-pass11.patch). Read the
qualification table before treating the engine state tests as native UI acceptance.

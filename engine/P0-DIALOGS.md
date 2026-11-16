# Modal-host qualification

The Swift NSView is not a registered `NativeWidgetMacNSWindowHost`. Passing it
as the `kChild` dialog parent fails `NativeWidgetMac::InitModalType`'s parent
invariant. Disabling DCHECKs alone leaves broken ownership. The external window
now has a transparent Views child parent, shared by the legacy constrained-window
host and Chromium 156's `BrowserElementsViews` lookup. The tab host supplies the
originating page's geometry. No upstream hook is required.

Beforeunload needs an additional adapter: upstream macOS uses an application-modal
NSAlert, not a constrained dialog. The core installs a factory for hosted
beforeunload requests while retaining Chromium's controller and queue. The native
Views prompt now follows the tab. Cancel leaves the page and cancels termination.

Pending dialogs must close during the tab-removal notification, before the
WebContents/navigation controller are destroyed. Closing only in the modal host's
user-data destructor is too late: HTTP auth's Cancel callback accesses the visible
navigation entry. The regression includes closing a tab with auth still pending.

Build and run on the build Mac, using fresh scratch paths:

```bash
engine/build.sh --run --variant dev
CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/Airc" engine/host/build.sh build/dialog-host
AIRC_NATIVE_CASE=platform node engine/host/acceptance.mjs build/dialog-host/AircHost.app build/dialog-platform dialogs
AIRC_NATIVE_CASE=hybrid node engine/host/acceptance.mjs build/dialog-host/AircHost.app build/dialog-hybrid dialogs
AIRC_NATIVE_CASE=auth node engine/host/acceptance.mjs build/dialog-host/AircHost.app build/dialog-auth dialogs
AIRC_NATIVE_CASE=auth-close node engine/host/acceptance.mjs build/dialog-host/AircHost.app build/dialog-auth-close dialogs
AIRC_NATIVE_CASE=beforeunload node engine/host/acceptance.mjs build/dialog-host/AircHost.app build/dialog-unload dialogs
AIRC_NATIVE_CASE=virtual node engine/host/acceptance.mjs build/dialog-host/AircHost.app build/dialog-virtual dialogs
```

The localhost fixture requests synthetic credential IDs only. The virtual case
creates and retrieves a credential entirely within CDP's virtual authenticator,
then removes it. It keeps a pending CDP call so the one-shot adapter cannot detach
and discard the virtual environment between commands. No real passkeys are used.

`modalDialogStateForTesting` reports registered parent identity, child modality,
DCHECK state, host/tab visibility, and dialog window identity. This and the
Cancel-handler fallback are restricted by the existing unsigned, mock-keychain,
scratch-profile test gate plus `--airc-test=modalDialogs`. The tests prefer native
Escape events; when AppKit defers showing an off-Space dialog, the fallback calls
the actual Cancel button handler. Reports distinguish these paths. Capturing a
PNG is not evidence that its pixels are usable: inspect captures separately.

Regressions use the existing isolation/restart (no scenario argument), `memory`
(discard), `extension` (Web Store install/popup/profile isolation), and
`engine/host/pip/run.mjs` scenarios. The acceptance runner rejects native crash
markers even if the process wrote a result before it crashed during shutdown.

See [HOSTING.md](HOSTING.md) for app obligations and [BUILD-VARIANTS.md](BUILD-VARIANTS.md)
for the separate owner framework. The app need not implement its own passkey,
HTTP-auth, or beforeunload UI.

## Off-Space modal parents (passkeywin)

The external AppKit window has no Chromium NSWindow bridge. Its transparent
Views parent must obey the same active-Space guard as
`NativeWidgetNSWindowBridge::OrderChildren`: attaching a child to an off-Space
window can switch Spaces. Keep that proxy hidden off-Space, so a WebAuthn sheet
transition cannot activate an orphan dialog. A workspace notification schedules
re-anchoring when the main window returns. An already visible proxy is not
repeatedly ordered by geometry queries.

The host dialog checks now record both Cocoa and WindowServer frames, assert the
page's top-centre anchor and screen containment, check a page resize, and reject
unexpected main-window movement during open/restore/Cancel. They also fail if a
proxy remains visible while its main window is off-Space. The prior framework
fails that assertion; the guarded release framework passes it.

`AIRC_NATIVE_CASE=hybrid` now creates a synthetic cross-platform credential with
`hints: ['hybrid']`, selects the actual phone mechanism callback through the
scratch-only test gate, and requires `kCableV2QRCode`. Reaching the mechanism
picker is **not** hybrid qualification. Pending Bluetooth authorization or a
permission-denied sheet fails with the exact recorded state; the runner waits up to 80 seconds for the single permission decision and does
not repeatedly request permission, open Settings, or change the Bluetooth radio.
`AIRC_NATIVE_CASE=hybrid-picker` tests just the picker lifecycle without selecting
the phone option. It is deliberately separate from full hybrid qualification.

Hidden/off-Space CGWindowList bounds can carry WindowServer transforms. They must
be compared with Cocoa frames and active-Space state before inferring a layout
error. The owner-reported Google/TCC sequence, physical drags, active-Space return
and real-phone authentication still require interactive verification; the
background regression does not establish those results.

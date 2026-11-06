# Pass 10: modal close and extension shutdown

Changes are confined to `engine/`. No app integration changes are required;
`app-pass10.patch` is intentionally empty. No upstream Chromium patches changed.

## Release auth Cancel

The failure is in the animated native close path, after auth cancellation has
already completed. `NativeWidgetNSWindowBridge::CloseWindow()` returns into
`ViewsNSWindowCloseAnimator` before clearing `wants_to_be_visible_`; only the
animation completion closes the NSWindow. With Airc's external AppKit parent,
that path stalls on the DCHECK-off framework, leaving the dialog registered and
visible, although the page has received the 401. Later dialogs stack behind it.

A/B on the same original release framework and host:

- Normal native Escape: `dialog step 4 timeout`, same window still visible and
  `wantsVisible: true` after 25 seconds.
- Only `--disable-modal-animations` changed: PASS, `afterCancel.dialogs: []`.

This isolates the failing close path; the lower-level reason for the
release/debug difference inside Cocoa animation completion was not established.

`WindowHost::UpdateModalParent()` now disables native visibility animations only
on its registered child-modal widgets. Constrained-window positioning visits
this parent after dialog creation and before showing it. This also overrides the
manager's subsequent `ANIMATE_HIDE` setting. Dialogs retain Chromium's normal
asynchronous close, controller callbacks and destruction notifications; there is
no Cancel-handler `CloseNow()` or delayed force-close. The tradeoff is that these
hosted dialogs appear and disappear without Chromium's custom native animation.

The test-only native state now also reports `widgetClosed` and
`nativeAnimationsDisabled`. This does not change the cancellation test hook.

## DCHECK-on extension shutdown

The post-install `ActivationWatch` was a `NoDestructor<ActivationWatch>` with a
`ScopedObservation<GlobalBrowserCollection, ...>`. Its source is owned by
`GlobalFeatures` and is destroyed during Chrome shutdown. The immortal observer
kept a dangling `raw_ptr` to that collection; the allocator's exit check aborted.

The static storage now owns a resettable `unique_ptr`. Engine shutdown destroys
the observer and clears queued install bubbles before Chrome destroys the global
collection. The existing DCHECK-on extension regression now passes its Web Store
installation, popup and profile-isolation assertions **and exits normally**.
No dangling-pointer checks were disabled.

## Verification

Evidence is in the private artifact store at `artifacts/engine/pass10/`:

- `pass10-release.log`: incremental build, 8 steps, `EXIT 0`.
- `pass10-dev.log`: incremental build, 9 steps, `EXIT 0`.
- Both builds ran sequentially in `airc-engine`, with only `//airc/core` source
  recompilation and framework relinking; strict apply check passed.
- `release-app-dialogs/out/log.txt`: **11 PASS, 0 FAIL, 1 SKIP**, DCHECKs 0.
- `dev-app-dialogs/out/log.txt`: **11 PASS, 0 FAIL, 1 SKIP**, DCHECKs 1.
- The SKIP is the existing opt-in hybrid/Bluetooth passkey test, which requires
  answering a system permission prompt. Platform passkey cancellation passed.
- Both app suites passed auth Cancel → 401, auth tab-close, beforeunload Cancel
  → same page, and platform passkey Cancel → `NotAllowedError`.
- Separate host runs of auth, beforeunload, auth-close and platform passed on
  **both** frameworks. In particular, release beforeunload ran in a fresh process
  with no preceding auth dialog, used native Escape, and reported
  `stayedOnPage: true` and `afterCancel.dialogs: []`.
- DCHECK-on isolation/write/restart/read, memory/discard and extension passed.
  Extension's full process log has no fatal/dangling-pointer shutdown report.
- All completed app and host regression logs were checked for native crash
  markers. The PiP attempts also exited without crash markers, but did not run
  their scenario assertions (see below).

Representative output:

```text
PASS dialogs: HTTP auth: Cancel closes it (handler found true)
PASS dialogs: HTTP auth: after Cancel the page shows the 401 response (unauthorized)
PASS dialogs: leave site (beforeunload): Cancel closes it (handler found true)
PASS dialogs: leave site: Cancel stays on the page (/leave)
PASS write: two profiles, isolated persistent cookie and localStorage
PASS read: two profiles, isolated persistent cookie and localStorage
PASS restart restored both profiles. Real Google account acceptance remains manual.
PASS memory: scenario assertions
PASS extension: scenario assertions
```

The host dialog test accepts either DCHECK setting, records lock state rather
than refusing to exercise dialog lifecycle while locked, verifies the auth 401,
and distinguishes a closed-but-retained NSWindow from a visible dialog. The
closed-tab check also verifies the surviving sibling's registered parent has no
dialogs. The app suite runs unchanged through `engine/host/app-dialogs.sh`.

The screen was locked. Captures are saved beside the host results, but the
inspected auth PNG is black: these are state/event/lifecycle results, **not**
visual qualification. All launches used `open -g` and the test apps quit.

## Reproduce dialogs

On the build Mac in a synced checkout, with the frameworks already built:

```bash
CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/AircRelease" scripts/build-app.sh --no-test
engine/host/app-dialogs.sh build/Airc-Chromium.app build/dialogs-release-new
CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/Airc" scripts/build-app.sh --no-test
engine/host/app-dialogs.sh build/Airc-Chromium.app build/dialogs-dev-new
```

The output directories must be fresh. The runner fails for missing scenario
logs, FAIL assertions or native crash markers.

## PiP remains blocked by the locked screen

Both video/tab and call/tab regressions were rerun. Each refused the locked
screen at its existing preflight, with:

```text
"ok": false,
"error": "screen locked: native qualification not attempted"
```

The owner explicitly requested leaving this blocked until the Mac is unlocked.
No PiP gate was relaxed. Exact rerun command from the repository on the Linux
controller, after unlocking the Mac (creates a fresh host because this pass's
work copy was cleaned):

```bash
scripts/mac.sh -w engine run '
  set -eu
  export CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/Airc"
  export PATH="$HOME/arcfork/chromium/src/third_party/node/mac_arm64/node-darwin-arm64/bin:$PATH"
  run="build/pip-rerun-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$run"
  engine/host/build.sh "$run/host" > "$run/build.log" 2>&1
  caffeinate -i -s node engine/host/pip/run.mjs "$run/host/AircHost.app" "$run/video" video tab > "$run/video.log" 2>&1
  caffeinate -i -s node engine/host/pip/run.mjs "$run/host/AircHost.app" "$run/call" call tab > "$run/call.log" 2>&1
  cat "$run/video.log" "$run/call.log"
  ! grep -E "Received signal|FATAL:|Check failed:" "$run/video/host.err" "$run/call/host.err"
'
```

Save that rerun's logs/results and clean its work copy afterward. The existing
runner opens the apps in the background and the host closes its PiP windows and
quits at completion. Real-account sign-in and unlocked visual checks remain
outside this pass.

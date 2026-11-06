# Engine pass 9: incomplete native qualification

Only engine files were changed and committed. Nothing was pushed. The app build
used the concurrently available app sources without editing them. The screen
was unlocked at the initial ioreg check and native reports show screenLocked:false.
Tests launched with open -g, isolated synthetic profiles, mock keychain, fake media
devices and small owned windows. Captures use CGWindowListCreateImage with the
owned window ID, never a desktop capture. No global keyboard events or input-source
changes were made. Do not interpret callback/API success as visible product UI.

## Qualification

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

## Fixes and verification

- Rebuilt the host: the preserved pass8-final-host executable lacked the native
  dispatch and fell through to the isolation test. Its failure is in native-run.log.
- Fixed the native test harness crash: NSSavePanel's inherited ok: raises an
  NSGenericException on this macOS. Use an enabled default button when available;
  otherwise cancel and report failure. The guarded rerun no longer crashes, but
  does not select the file. This is a harness fix, not proof of upload completion.
- Split print, DevTools, permissions, forms, video, native context and fake-media
  probes using AIRC_NATIVE_CASE so upload failure does not hide later results.
- Put the synthetic permission anchor inside the small host's actual bounds.
- Capture attached DevTools after a render delay, before detaching it.
- Native context probe disables the contextMenu bypass, observes Cocoa tracking,
  and includes bounded waiting and cancellation. It still fails on this run.
- The PDF success branch now deletes the generated PDF. No PDF was actually
  produced in this pass; cleanup confirms no retained PDF and removes upload
  fixtures. All pass-9 test processes are gone (cleanup.json).

Signed host builds passed through build/pass9-host7; scripts/build-app.sh
--no-test built both app bundles. Native fake-media test reports
fakeMediaAllowedAndStopped:true. Forms reports passwordFilled:true,
uploadCancel:true. All four permission denials and profile/anchor callbacks pass.
Video reports video-0 through video-4 true. DevTools reports shortcut/attachment/
capture true, with readable tools content in the inspected PNG. Print reports
native step 7 timed out; context reports Cocoa tracking not observed. These are
preserved failures, not repaired product defects. No engine core change was made
without a demonstrated root cause.

## App handoff

app-pass9.patch is an **unapplied documentation patch**, adding a short app-side
specification, not an implementation. git apply --check passes. Requests:
permission presenter instead of unconditional dismiss; password bubble subscriber;
real dock/undock/re-dock ownership; a bounded native app qualification scenario
with actual shortcuts and owned-window captures. The current SnapshotRunner does
not provide these journeys. The app was built but not launched for these tests;
app runtime acceptance remains outstanding. App pass 6 owns implementation.

## Reproduction

In the synced engine checkout on the build Mac, check the session lock before
starting. Use a fresh output directory for every run:

```sh
engine/host/build.sh build/pass9-host-new
AIRC_NATIVE_CASE=print node engine/host/acceptance.mjs build/pass9-host-new/AircHost.app build/pass9-print-new native
AIRC_NATIVE_CASE=devtools node engine/host/acceptance.mjs build/pass9-host-new/AircHost.app build/pass9-tools-new native
AIRC_NATIVE_CASE=permissions node engine/host/acceptance.mjs build/pass9-host-new/AircHost.app build/pass9-permissions-new native
AIRC_NATIVE_CASE=media node engine/host/acceptance.mjs build/pass9-host-new/AircHost.app build/pass9-media-new native
AIRC_NATIVE_CASE=forms node engine/host/acceptance.mjs build/pass9-host-new/AircHost.app build/pass9-forms-new native
AIRC_NATIVE_CASE=video node engine/host/acceptance.mjs build/pass9-host-new/AircHost.app build/pass9-video-new native
AIRC_NATIVE_CASE=context node engine/host/acceptance.mjs build/pass9-host-new/AircHost.app build/pass9-context-new native
node engine/host/acceptance.mjs build/pass9-host-new/AircHost.app build/pass9-native-new native
```

Qualification remains a release blocker. In particular, no real PDF, upload
selection, native fullscreen transition, Japanese candidate window, visible
permission/password prompt, or complete DevTools docking round trip was qualified.

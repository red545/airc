# Call survival regression

`run.py <Airc-Chromium.app> <fresh output directory>` runs the app's `callspace`
script, with fake camera/microphone devices, fake permission UI, mock Keychain,
and a scratch profile. It never launches a real call or uses a physical device.
The loopback page records a page-load UUID, peer states, track states, visibility,
and Document PiP state every 250 ms. The script switches between same-profile
and different-profile Spaces, injects process-local memory pressure through the
existing gated API, sets a one-second unload timeout, hides the native window,
and returns. No DevTools client is attached (that would protect the page from
discarding). A small scratch window prevents last-window termination during the
window-hiding test. All windows open without application activation.

The runner requires one load, no heartbeat gap over three seconds (background
timers can be clamped), connected peers/live tracks at every checkpoint, and a
completed script with no failed assertions. The final `stop()` deliberately ends
tracks. The `--owner-bundle` option uses the existing `perf` scripted switching in
an unmodified older bundle; it records continuity only, without pressure or a
shortened timeout. Its success is not a full regression pass.

Fake permission UI bypasses Chromium's capture indicator, so this app probe does
not qualify automatic PiP. For capture-aware automatic Document PiP, use the
engine host's scratch-only permission gate with fake devices:

```sh
CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/AircRelease" engine/host/build.sh build/call-host
node engine/host/pip/run.mjs build/call-host/AircHost.app build/call-pip call space
node engine/host/pip/run.mjs build/call-host/AircHost.app build/call-pip-off call space 1
```

The last argument disables the profile automatic PiP setting. Both runs check
call continuity under pressure and a 0.5-second timeout, then return. The enabled
case also checks the real floating native Document PiP window, remembered
placement, restoration, and the fixture's mute/leave controls. HTTPS loopback and
a scratch-process certificate exception are used because Chromium automatic PiP
requires HTTPS; system trust is unchanged. `tab` and `window` replace `space` to
exercise same-profile selection and host-window activity respectively.

Physical macOS desktop/fullscreen changes and real Meet calls still need owner
qualification. A live call already opts out of Chromium's Energy Saver freezing;
these short runs do not force a battery-saving state or manipulate the desktop.
Generic multi-tile call fallback with reliable microphone controls remains absent
(see `engine/PASS12.md`); this fix protects the underlying call regardless of PiP.

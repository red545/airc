# W10 virtual display check

Test-only CoreGraphics SPI helper; no third-party executable and no app linkage.
The helper uses Python's standard-library ctypes and the system Objective-C
runtime, so it needs no compiler, package installation, or app build.

Before starting, honor the coordinator's quiet/relink/priority markers. Use a clean
`git archive HEAD` export plus only this task's diff for both engine bundles.
The helper requires an unlocked graphical login session. Every display change
belongs inside the UI lock, including creation, arrangement, and removal:

```sh
AIRC_UI_DEDICATED_SESSION=1 AIRC_UI_LOCK_STRICT=1 python3 scripts/ui-check-lock.py python3 infra/w10/run.py infra/w10/virtual-display.py build/w10/helper
AIRC_UI_DEDICATED_SESSION=1 AIRC_UI_LOCK_STRICT=1 python3 scripts/ui-check-lock.py python3 infra/w10/run.py infra/w10/virtual-display.py build/w10/webkit/display python3 infra/w10/check.py build/Airc.app webkit build/w10/webkit
AIRC_UI_DEDICATED_SESSION=1 AIRC_UI_LOCK_STRICT=1 python3 scripts/ui-check-lock.py python3 infra/w10/check.py build/Airc.app webkit build/w10/webkit --fallback
```

Repeat with `build/Airc-Chromium.app`, `chromium`, and a separate evidence folder.
A UI-lock refusal (75) means retry later. Never opt into timeout fallthrough.
The parent owns the helper's stdin; closing it exits the helper and removes the display.
WindowServer may defer removal until process exit; the parent verifies the complete
online display list returns to its pre-check state before releasing the UI lock. The evidence
records its ID, CoreGraphics bounds, and whether it was offline after destruction.
Each app launches through foreground Launch Services, with a synthetic home and
exact executable/PID termination on timeout. On the dedicated agent console only,
the runner repeats the existing session preflight after startup notification UI
appears, then activates the recorded new app PID. A single app/runner handshake
can repeat this before key-window assertions if activation was lost after drag. It does not request permissions.
The dedicated-session opt-in must never be used on a personal console. `check.py` returns nonzero for missing logs, crashes,
FAIL, and FAIL-ENV. Do not pass `--ephemeral`: relaunch requires persisted data.

The stable UI driver posts WindowServer mouse events when its event-posting and Input Monitoring access is already authorized. Otherwise it records FAIL-ENV and runs supplemental native
AppKit row tracking; that fallback does not pass the real-input gate. Neither
path calls the drop action directly or certifies physical HID hardware. Read/fallback are separate process launches. The virtual display must
remain alive between write and read and be gone before fallback.

Virtual displays do not establish physical connection behavior, EDID identity
across reconnections, mixed refresh-rate/HDR performance, notch geometry, or
physical-display/fullscreen visual parity. Native fullscreen is a separate
assertion; failure to enter is FAIL-ENV with session evidence. WebKit PIPAgent
movement requires preexisting Accessibility authorization for the stable UI driver; the
check never prompts for it and reports FAIL-ENV when it is absent. Keep W10/W05 partial until their remaining evidence exists.

The build Mac uses Xcode 26.4. If xcrun selects the Command Line Tools SDK, set
`DEVELOPER_DIR` and `SDKROOT` to the installed Xcode and its macOS SDK explicitly
before the debug build. A successful build of both engines is required.

The Chromium check also verifies video and Document PiP fallback to the main
display after helper removal, and Document PiP viewport changes from 640×400 to
360×240 without losing its saved corner. Fixtures use only synthetic canvas
video and a local document; no camera, microphone, or screen capture.

## Stable UI driver and owner permission grants

`infra/ui-driver/install.sh` builds the small Swift helper on the dedicated build
Mac and signs it with the configured Developer ID once. Run it from a pinned
source export under the usual build locks; it reads the existing
`~/arcfork/setup/signing/signing.env` without printing signing credentials.
It installs `~/arcfork/tools/airc-ui-driver/airc-ui-driver` and bootstraps the
`org.airc.ui-driver` GUI LaunchAgent. The service owns TCC requests independently
of changing check-app signatures. The private socket accepts only the same user.
No command captures the screen, reads arbitrary applications, or prompts for grants.
An existing binary is verified and reused; changed source requires a coordinated
upgrade. Do not re-sign or replace it as part of ordinary app builds.

The owner must do this at the dedicated build Mac's screen:

1. Open **System Settings › Privacy & Security › Accessibility**.
2. Press **+**, use **⇧⌘G**, enter `~/arcfork/tools/airc-ui-driver/airc-ui-driver`,
   add it, and enable its switch.
3. Repeat in **Privacy & Security › Input Monitoring**, enabling the same executable.
4. Restart only the helper so it observes the grants:
   `launchctl kickstart -k gui/$(id -u)/org.airc.ui-driver`.
5. Run `~/arcfork/tools/airc-ui-driver/airc-ui-driver --check`. It must print:

   ```text
   accessibility trusted=true
   input_monitoring trusted=true
   event_posting trusted=true
   ```

A false value exits nonzero. After a reboot, rerun the installer to bootstrap the
same installed binary before checking. `--check` talks to the service: it checks
exactly the identity which posts gestures and inspects PIPAgent, rather than its
caller. W10/real-drag/PIPAgent assertions remain FAIL-ENV, tagged `owner-gated`,
until those grants exist. Supplemental AppKit tracking never passes the physical
input gate. All UI commands still require the normal UI lock and an unlocked
agent console; grants do not waive the coordinator's quiet/relink checks.

The helper's synthetic-coordinate protocol is `--drag x1 y1 x2 y2`, `--click x y`,
`--pip-frame`, and `--pip-move x y` (Quartz global coordinates). `--json --check`
provides machine-readable booleans. Requests are bounded; a drag always releases
the mouse and restores the pointer. `--self-test` validates arguments without UI.

### Keyboard input

The service accepts `--key <combo> [--repeat n] [--pid pid]` for layout characters
and `--keycode <modifier+decimal-code> [--repeat n] [--pid pid]` for physical keys:

```sh
~/arcfork/tools/airc-ui-driver/airc-ui-driver --key cmd+z
~/arcfork/tools/airc-ui-driver/airc-ui-driver --keycode cmd+6  # physical ANSI Z position
~/arcfork/tools/airc-ui-driver/airc-ui-driver --key cmd+opt+n
~/arcfork/tools/airc-ui-driver/airc-ui-driver --key ctrl+cmd+f --pid "$TEST_PID"
~/arcfork/tools/airc-ui-driver/airc-ui-driver --key esc --repeat 2 --pid "$TEST_PID"
```

Omit `--pid` for global shortcuts: events go through the HID event stream to the
foreground app and global hot-key registrar. `--pid` posts to that running process
without activating it. With modifiers, the service refuses a PID that is not the
foreground app, with an error naming the requested/foreground PIDs and explaining
activation and HID delivery. This reads only the live foreground process ID,
without activating an app, reading window contents, or requesting grants. Bring
the intended test window forward under the UI lock first; the driver cannot verify
that the intended window/responder inside the app has the keyboard. Plain PID
keys retain their existing behavior. The foreground guard is a preflight check,
not a lock against focus changing during delivery.
Modifiers are `cmd`, `opt`, `ctrl`, `shift`. `--key` resolves each single character
(letter, digit or punctuation) through the current keyboard input source using
`TISCopyCurrentKeyboardLayoutInputSource` and `UCKeyTranslate` in the service.
It tries plain keys first, then Shift, adding Shift if needed; explicit modifiers
are preserved. Character case matters: `Z` adds Shift on ordinary Latin layouts;
`cmd+shift+z` also expresses Redo. Use `plus` for the literal `+` character, since
`+` separates modifiers. Named keys (`esc`, `return`, `tab`, `space`, `delete`,
`forwarddelete`, arrows, `home`, `end`, `pageup`, `pagedown`) keep fixed keycodes.
Characters requiring dead-key sequences or IME composition are not supported;
unmapped characters are refused. There is no silent US-layout fallback or text
injection.

`--keycode` accepts a decimal macOS virtual keycode from 0 through 127, optionally
prefixed by the same modifiers: `--keycode cmd+6`, `--keycode shift+16`, or
`--keycode 36`. It never translates or adds modifiers based on the keyboard layout.
Both commands share PID/HID delivery, event balancing, and repeat validation.
Inferred Shift also makes a PID command subject to the foreground requirement.
Repeat is 1–20 complete presses, not a held-key autorepeat. Every press has balanced
modifier `flagsChanged`, key-down/up, and reverse-order modifier release events.
The complete sequence is allocated before posting, and commands finish within the
socket timeout. `--self-test` checks parsing, bounds, event order, keycodes and flags
without posting. A successful command means events were posted; checks must still
assert the app's resulting behavior. Space/fullscreen transitions need a wait
between presses; `--repeat` only adds a short inter-press pause.

### PID shortcuts, layout, and result verification

The service posts **every** event to the selected PID, including modifier
`flagsChanged` presses/releases. PID posting does not universally skip AppKit key
equivalents: a foreground native menu receiver handles them. Airc page undo must
still be checked in the target engine and responder; `ok:true` means posting
completed, not that Undo (or any other command) ran. For end-to-end user shortcuts,
prefer HID (omit `--pid`) with foreground/key-window checks and an app-result
assertion. HID also reaches system/global shortcut handlers, so it is not an
interchangeable replacement when another app owns a global shortcut.

On an Austrian layout, `--key cmd+z` now resolves to code 16 and produces ⌘Z;
`--key cmd+y` resolves to code 6 and produces ⌘Y. `--keycode cmd+6` always presses
the physical ANSI Z position, which produces ⌘Y on that layout. Layout resolution
happens once per command, before any input is posted. `--self-test` checks that
`cmd+z` builds key-down/up events with the current layout's Z code and Command
flags (code 16 on Austrian), and that physical code 6 stays unchanged.

Callers must stop converting letters to US position names before `--key`, or they
will translate twice. `UIDriverClient.keys(typing:)` now returns character combos
for this driver, including `space`/`plus`, instead of physical names. Previously
built test apps containing the old conversion helper need to be rebuilt before
using it with the updated driver. For deliberately physical input, use `--keycode`.
A missing Undo alone is not evidence that modifier flags or key equivalents were
lost: log the received keycode, characters, modifiers, foreground app and key window.

Mouse gestures, including `--click --mods` and `--drag --mods`, always use HID.
They do not support PID targeting: an attempted `--pid` returns an explicit
foreground-HID-only error before any input is posted. Their event flags and
balanced modifier transitions use the same modifier definitions as keys; they do
not depend on the layout's letter positions. Run only in a dedicated session with
the intended window foreground and unobscured, and assert the click/drop result.

For an explicitly coordinated upgrade, first back up the binary and
`source.sha256` and save `codesign -d -r-` output. Build and sign the candidate with
the same configured Developer ID identity and `--identifier org.airc.ui-driver`
(as in `install.sh`), verify its signature and run `--self-test`. Compare the
`designated =>` requirement exactly with the installed binary before replacement.
Keep the same installation path. Update the source hash, kickstart the existing
LaunchAgent, and run `--check` through the socket. If any grant is false, immediately
restore both backup files, kickstart, verify the original grants and stop. Report
to the lead; never ask the owner to re-grant as an upgrade workaround. Ordinary
`install.sh` runs continue to refuse changed source.

When invoking the client from a test app with `CFFIXED_USER_HOME`, resolve the
helper in the real account home and remove `CFFIXED_USER_HOME` from the client's
environment (for example, `env -u CFFIXED_USER_HOME <absolute-helper-path> --key esc`).
The stable service and its socket belong to the account home, not the test profile.
Do not synchronously wait for a key-posting client on the target app's main thread.
Schedule posting from an external runner or background queue so AppKit can process
input. After giving focus to Finder for a global-hotkey check, explicitly reactivate
the test app through the runner and verify foreground ownership before sending
PID-targeted menu shortcuts. A PID alone does not supply foreground ownership.

Modifier pointer gestures use the same signed service and private socket:

```sh
airc-ui-driver --click 400 300 --mods cmd,opt
airc-ui-driver --drag 400 300 600 450 --mods cmd,opt,shift,ctrl
```

Coordinates are Quartz global display points. `--mods` is optional; its comma-separated
names must be unique (`cmd`, `opt`, `shift`, `ctrl`). The service preallocates a balanced
sequence: modifier `flagsChanged` presses, mouse movement/down/drag/up carrying the
modifier flags (including left-key device bits), reverse-order modifier releases,
then pointer restoration. Invalid arguments post nothing. `--self-test` checks these
sequences without sending input. Mouse gestures use HID delivery, so run only in a
dedicated session under the UI lock with the target window foreground and unobscured.

`AIRC_REAL_KEYS=1 AIRC_REAL_CLICKS=1 AIRC_UI_DEDICATED_SESSION=1` opts `parityp06d`
into real driver ⌥⌘-link clicks and a ⌘-sidebar multi-selection check on either engine.
The log labels real-driver and in-app-posted input separately. The async client removes
`CFFIXED_USER_HOME` and converts window points to Quartz coordinates; completion means
the installed service replied, and separate app assertions verify the result.

For an authorized driver upgrade, back up the installed binary and `source.sha256`,
record `codesign -d -r-`, build and sign with the existing Developer ID identity and
`org.airc.ui-driver` identifier, then compare designated requirements exactly before
replacement. Keep its installation path unchanged. Under the UI lock, replace,
`launchctl kickstart -k` the service and run `--check`. If any grant is false, immediately
restore both backups, kickstart, verify all grants true, and stop the upgrade.

### Real pointer movement and hover

`--move x y [--steps n] [--duration ms] [--pid p]` posts a path of real
`mouseMoved` HID events from the current cursor to Quartz display coordinates.
Defaults: 20 steps, 200 ms; bounds: 1–240 steps, 0–2000 ms.
`--hover x y --dwell ms` accepts the same options and waits 0–2000 ms after
arriving. Both leave the pointer at the destination (no click or restoration).
The maximum duration plus dwell stays below the five-second socket timeout.
`--pid` guards foreground ownership before and throughout movement, and after
dwell; it does not route pointer events to a background process. Use only under
the dedicated-session UI lock. A focus change can interrupt a partial path.
`UIDriverClient.move` and `.hover` convert window coordinates, check the active
key window/Space, and pass the caller PID. Their callbacks run on main after the
asynchronous driver completes; assert the resulting UI as well as posting success.

## Real tear-out drags (`--script parityw10drag`)

Debug/ParityW10DragCheck.swift drives W10's tear-out with real HID drags from the stable UI driver: two desktop drop
points (new window frame at the drop point, tab gone from the source, page moved live with no new request), a drop on a
second window's sidebar, ⌥ copy and a real ⌘Z, a split, a folder, a Favorite, Esc mid-drag, a drop on Little Airc and
native full screen. It needs the dedicated agent console, `AIRC_UI_DEDICATED_SESSION=1` and `AIRC_REAL_KEYS=1`, and a
main display at least about 1400 pt wide (the drops sit right of a 620 pt window). Launch it per engine as any other
scripted check, under the strict UI lock with an exact-PID stop:

```sh
AIRC_UI_DEDICATED_SESSION=1 AIRC_UI_LOCK_STRICT=1 python3 scripts/ui-check-lock.py open -n -W \
  --env CFFIXED_USER_HOME=<home> --env AIRC_UI_DEDICATED_SESSION=1 --env AIRC_REAL_KEYS=1 \
  build/Airc.app --args --engine=webkit --snapshot <out> --script parityw10drag --ephemeral --data-dir <home>/data
```

The driver's requests are serial, so Esc can't be pressed inside its own drag: the check posts Esc into the app's
event queue (never `sendEvent`) the moment the real drag leaves the window, and says so in its log.

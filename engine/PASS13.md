# Pass 13: Downloads, media and Site Controls

## Stable public contract

All methods and callbacks are main-thread-only, after engineDidStart. Keep the
profile loaded through async completion and retain a tab/window while its page is
hosted elsewhere. Observer blocks are copied, one per receiver; nil unregisters.
Capture receivers weakly. Initial observer delivery may be synchronous. Defer
close, remove, or other structural mutations until the next main-loop turn.

### Downloads (AircProfile)

`downloads` lists DownloadManager items, including history as it loads. Install
`observeDownloads:` before displaying the library; existing rows and later
creation/update events use the same shape. Removal sends the last row with
`removed:true`. Replacing an observer replays existing rows. IDs are GUID strings.
Existing keys: id, url, path, received, total, state (0 progress, 1 complete,
2 cancelled, 3 interrupted), paused, dangerous. Added keys: fileName, mimeType,
startTime, endTime (Unix seconds; 0 unknown), referrer, interruptReason (Chromium
integer), canResume, openWhenComplete, canKeep, dangerType (Chromium integer). Unknown total/path must be handled.

`performDownloadAction:identifier:` returns whether the request was accepted,
not whether asynchronous disk/network work succeeded. Actions: pause, resume,
cancel, retry, remove, keep, discard, open. Retry resumes when possible, otherwise
starts a new GET download (new ID); it cannot replay POST bodies. Keep is available only when canKeep is true and requires an
explicit user confirmation; never call it automatically. Open is rejected while
dangerous, and otherwise opens now or toggles open-when-complete for an active
item. `downloadPath:` returns a completed safe item's path for NSWorkspace reveal.
Removal removes history, not the file; discard deletes the dangerous item.

### Media (AircTab, AircProfile)

`mediaSession` and `observeMediaSession:` snapshots: playbackState (playing,
paused, none), active, title, artist, album, artwork (URL strings), duration,
position (seconds; -1 unknown), playbackRate, actions (strings), microphoneActive
and cameraActive (NSNumber or NSNull when unreported), capture (microphone,
camera, screen, tab booleans). Position is sampled at read/update; interpolate
using playbackRate in the UI. Existing audible/muted remain playback-only.

`performMediaAction:value:` takes play, pause, stop, previoustrack, nexttrack,
seekbackward, seekforward, seekto, togglemicrophone, togglecamera, hangup,
enterpictureinpicture. Value is seconds for seeks; other actions ignore it.
NO means unavailable/invalid; YES means dispatched, not page acknowledgement.
Only offer supported actions; do not turn stopCapture into a mute button.
`mediaTabs` enumerates this profile's active-session/capturing tabs;
`observeMediaTabs:` delivers the current list and changes without app scanning.

### Site Controls (AircProfile and existing AircTab.securityInfo)

Origins accept HTTP(S) URLs normalized to origins, without credentials.
`sitePermissions:` returns camera, microphone, location, notifications, popups,
clipboard, sound, automaticDownloads, midi, usb, serial, hid, protectedContent
where registered on this platform. Each row has state (default/ask/allow/block),
effective (ask/allow/block), managed. Unsupported keys are absent. Setter rejects
unsupported values/types and managed settings. Device permissions are chooser
*guards*, not grants to arbitrary devices. Reset clears origin-specific settings
and device grants, using Chromium’s registered scope (some settings are host-
scoped); policy remains effective. Location allow grants both approximate and
precise access when the options-based geolocation permission is enabled. Device
guards may reject allow (Chromium exposes only ask/block); this API never grants
a device without a chooser.
`observeSitePermissions:` emits origin strings; empty means global invalidation.
Requery the displayed origin after every notification.

`siteData:completion:` reports valid, cookies and storageBytes for the origin;
`clearSiteData:completion:` completes with success after Chromium deletion.
Cookie scope can include a parent domain shared with sibling origins. Storage
clearing follows Chromium's origin/domain filtering, not a filesystem delete.
`siteZoomFactor:`, `setSiteZoomFactor:origin:`, and `resetSiteZoom:` use HostZoomMap;
zoom is host-scoped, shared across ports/schemes by Chromium. Independent per-tab
zoom remains separate. `defaultSiteZoomFactor` is the profile default.
Security adds connectionLevel (secure/notSecure/dangerous), certificateSubject,
certificateIssuer, certificateValidFrom/To (Unix seconds), hasMixedContent,
insecureForm to the existing securityInfo dictionary. Legacy level, mixedContent
and certificate keys retain their prior meanings; nested certificate times remain
milliseconds while the new flat certificate times are seconds.

### Full call window

Move the same tab's view with detach/attach/setPageVisible; never recreate or
navigate it. Retain its owning AircWindow, or use same-profile moveTab:profile:to:
when changing engine ownership. Restore the original view on return. Window
floating/Space placement and full call-page controls belong to the app. Existing
discard policy protects WebRTC/capture even while detached or hidden. This is a
full live-page fallback; it does not synthesize a generic call tile compositor.

## Implementation and verification

Header-first commit: `f5a8ae7`. Implementations and acceptance fixtures are now in
source. **Mac-qualified by engine13q:** the release and DCHECK frameworks build
incrementally without GN argument changes. The pass13 runner passes on both
frameworks, including both
fake-UI and capture-indicator variants, fresh-process download history, memory,
and two-profile persistence. The committed-source app export builds against the
release framework. Public selectors and dictionary keys are unchanged.

The media bridge subscribes to Mojo MediaSession and MediaStreamCaptureIndicator
on each tab's creation. The registry is engine-owned; callbacks deliver the tab
snapshot first, then the profile list. Initial Mojo fields arrive separately, so
multiple startup callbacks are expected. Capture state is actual device use, not
the page-reported mute state. Closed tabs read an empty snapshot. Profile and tab
observers do not keep wrappers alive; unregister on app teardown. Async service
work requires the profile/engine to remain alive through completion.

Source review found a reparenting bug: window visibility walked only the owning
Browser's tabs. Hiding the original window could hide a page now in a floating
window, while the floating window would not update a borrowed page. Visibility
now walks owned tabs across hosts and selects only views actually attached to the
native window receiving the notification. Attach/detach still keep the same
WebContents. The regression hides the original window, hides/restores the call
window, and returns the same connected peers/load UUID. This regression passes
on the release framework.
`544bb9f` and its PROACTIVE discard eligibility, capture/WebRTC/session protections
are unchanged. Use moveTab when prompt/tab-strip ownership should also transfer;
raw attach/detach changes the native view, not the owning Browser.
Favorites that unload remain app metadata and use the existing discard API; the
app must honor NO and must not force-close/recreate an active call to unload it.
Chromium-pinned tabs retain upstream pinning protection.

### Download UI and destination audit

Chromium's DownloadPrefs owns the default Downloads directory; target determination
and DownloadPathReservationTracker own collision suffixes. Airc does not invent
filenames or overwrite destinations. The fixture explicitly sets a private scratch
download directory, never the owner's Downloads folder. Destination prompts use
the existing native file picker routing; policy or an unwritable destination can
still require a picker or interrupt a download.

AircBrowserWindow returns no DownloadBubbleUIController. The library/progress and
danger warnings are driven by observeDownloads; the host must install it for every
loaded profile. No new Chrome Views dialog is invoked by these APIs. Dangerous
items wait for explicit keep/discard; no host observer means no visible Airc warning,
and the download remains unresolved. Enterprise blocked/scanning types return
canKeep=false; this pass does not supply enterprise scan/review/password dialogs.
Open is never dispatched for dangerous items. Chromium retains its downstream
open/OS-handler checks. Dangerous-file classification depends on the bundled file
policy/Safe Browsing state; an inert risky extension alone is not proof of a warning.

### Site-data scope and limits

BrowsingDataModel supplies counts/bytes for supported backends, not a complete disk
accounting or quota reservation measurement. Cookie matches use Chromium's cookie
domain matcher across paths, including HttpOnly and partitioned cookies. Deletion
uses CookieManager's canonical-cookie removal and origin-filtered BrowsingDataRemover
for DOM storage and media licenses. Parent-domain cookies may affect sibling sites;
other origins' DOM storage is excluded. Active pages can immediately recreate data;
reload/close is an app decision. SessionStorage and unsupported model backends are
not promised cleared. Permission changes currently emit global invalidation (empty
origin) rather than attempting to decode wildcard policy patterns. HostZoomMap owns
persistence and Chromium's host-scoped zoom behavior.

### Reproduce on the build Mac

From the synced task work copy, first inspect `screen -ls` and the process list
and ensure no other engine build is running. Apply/check the source, then run the
existing release target, under caffeinate; do not change GN args:

```sh
engine/apply.sh --src "$HOME/arcfork/chromium/src"
engine/apply.sh --check --src "$HOME/arcfork/chromium/src"
PATH="$HOME/arcfork/depot_tools:$PATH" caffeinate -i -s \
  autoninja -j 8 -C "$HOME/arcfork/chromium/src/out/AircRelease" chrome_framework
caffeinate -i -s engine/host/pass13.sh build/pass13
```

`pass13.sh` builds only the host using the existing release framework, launches
with open -g and isolated profiles/mock Keychain, and runs:

- `pass13` with fake devices and fake permission UI: metadata/actions and page
  mute/camera acknowledgement; connected WebRTC survives detach into a floating
  window, hide, refused discard, critical pressure and return with one load UUID;
  Site Controls set/read/reset, notification, profile isolation, zoom and data
  deletion/readback; slow pause/resume/open-when-done toggle, duplicate filenames,
  interrupted retry, risky-extension handling, cancel and remove.
- A second pass13 with fake devices, the scratch-only system permission override
  and host-granted media permissions (AIRC_CAPTURE_INDICATOR=1), because Chromium's
  fake-UI switch bypasses the real capture indicator. This additionally requires
  indicator microphone/camera flags. No real devices or macOS prompt.
- A fresh-process `pass13-read` after each pass13 to check DownloadManager history.
- Existing memory and two-profile persistence acceptance regressions.

The fixture never opens a completed file. It records a risky-extension row and
asserts open rejection/discard only when Chromium actually marks it dangerous;
otherwise it records normal completion/removal. Keep and real OS opening/reveal,
actual screen/tab sharing, native fullscreen transitions and real call sites still
need qualification. Tests are state assertions, not visual/focus qualification.

Local results: strict apply/check/repeat/drift refusal passes with 54 pinned files,
25 unchanged patches; JavaScript and shell syntax plus git diff --check pass.
Mac qualification now passes on the release and DCHECK frameworks. Existing callspace,
PiP (call tab/Space/window, disabled, video, muted and audio), P0-DIALOGS (platform,
hybrid-picker, auth, auth-close, beforeunload and virtual), memory/discard and
two-profile persistence regressions also pass. The callspace run retains one load
UUID with 76 heartbeats and a maximum 1.07-second gap.

Qualification fixes: explicitly own GURL scheme/host strings at the Site Controls
callback/HostZoomMap boundaries; reply through evaluate's named JSON result;
check the configured scratch download root; keep truncated responses broken until
an observed interruption and explicit retry; start capture after permission reset
(which otherwise correctly revokes the live stream). No public API changes.
The inert risky-extension fixture was not classified dangerous, so dangerous
keep/discard/open-rejection remains unqualified, as do real devices and OS actions.
Full hybrid phone/QR authentication is omitted to avoid a Bluetooth prompt.

## Additional host APIs

See [PASS-APIS.md](PASS-APIS.md) for host-selected Save Page formats and
completion, `canSavePage`, and asynchronous bounded tab snapshots for previews.

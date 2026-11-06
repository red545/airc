# Protected content API and qualification

See [DRM.md](DRM.md) for researched delivery, service and licensing limitations.
The macOS arm64 `out/AircRelease` engine is rebuilt and qualified in an isolated
ad-hoc and disposable Developer ID hosts: native CDM installation, EME license
generation and public Shaka Widevine playback pass. The Developer ID host also
passed notarization, stapling, codesign verification and Gatekeeper assessment.
Subscription services remain unverified; this is not a claim of their approval.

## Shell integration

After `engineDidStart`, on the main thread:

```swift
let engine = AircEngine.shared!
let enabled = engine.protectedContentEnabled // default true
engine.protectedContentEnabled = false
let diagnostic = engine.protectedContentState
```

Settings → Privacy → **Play protected content** uses this API as the source of
truth, default on. The WebKit build hides the control. Do not maintain a competing UserDefaults boolean. The
setting is global to this user-data directory (all profiles), persisted as
`airc.protected_content_enabled` in Chromium Local State. Newly loaded profiles
receive the value; existing profiles' Chromium encrypted-media preference is
updated, notifying renderers. Chrome's per-site protected-ID permissions remain
independent. Incognito inherits its parent profile preference.

Suggested secondary text: “Allows sites to use Google Widevine for protected
music and video. Airc downloads and updates this component from Google.” On a
change, explain that protected tabs need reloading; restart to terminate existing
MediaKeys sessions and any in-flight CDM download. Off omits Widevine from future automatic/manual update requests; other
components continue updating normally. It does not
delete installed files or revoke licenses already issued to a live session.

`protectedContentState` contains `enabled` (Bool), `cdmVersion` (String; empty or
`0.0.0.0` before installation), `registeredComponents` ([String]), and
`components` (ID/name/version dictionaries), and `vmpCertified` (false). It also reports Chromium updater `updateState`,
`updateErrorCategory`, `updateErrorCode`, `updateExtraCode`, `downloadedBytes`
and `totalBytes` for troubleshooting; -1 means unknown bytes/state. Error/state
numbers follow the pinned Chromium update-client headers.
`chrome://components` remains available for installation
status/manual update. A version alone is not proof of playback. First automatic
update uses Chromium's usual ~one-minute initial delay, then ~five-hour cadence.
Reload failed pages after first installation. Turning the setting back on also
requests an immediate Widevine-only check, subject to upstream rate limiting.

## Privacy boundary

Patch 027 preserves every pre-existing component registration and the upstream
updater configuration (URLs, scheduling, pings and background downloader).
The original Widevine-only restriction was a brief error and has been reverted.
Only Widevine's request entry is omitted when protected content is off. Returning
no component before request assembly also prevents a disabled-CDM failure ping.

Widevine requires encrypted checks/pings. Its payload URLs are filtered to HTTPS
(Chromium 156 does not apply the installer encryption flag to payloads), and only
its download uses Chromium networking instead of the delayed OS background job.
Other components' payload filtering and downloader choice are unchanged. CRX
signature/manifest checks and the CDM sandbox stay upstream. The update reply
can point to Google's CDN. Standalone pings use the original upstream policy.

Normal protocol update requests disclose IP, browser/OS/architecture and component
version; this is not anonymous/offline DRM. Site-selected license requests disclose
whatever that site's EME/CDM protocol requires. This patch does not suppress page
networking or change other background-service groups, extension updates, or the
app's telemetry setting. See BACKGROUND-SERVICES.md for the retained component
inventory. This is not a claim that all Airc network traffic is limited to Google.

## Qualification procedure

Use only an isolated scratch data directory and the dedicated DRM host/fixture;
no camera, microphone, screen capture, or owner's account/session data. Record:

1. Strict patch dry-run/idempotence/drift rejection on the pinned source.
2. Release build completion with the final GN arguments; retain the log.
3. On first run, Widevine plus the restored component IDs in diagnostics, and a
   nonzero installed CDM version; CRLSet/PKI/file policies appear in update checks.
4. Local fixture: EME access, MediaKeys creation, license message event.
5. Public Shaka Widevine stream: successful license and advancing playback time.
6. Off + reload and off + restart: access rejected, no **Widevine** requests;
   other components still check for updates;
   on + restart restores access. Test another newly loaded profile as well.
7. A logged-out Spotify page may show capability status but cannot prove full
   authenticated track playback. Do not count an unencrypted preview as DRM proof.

Service status: Spotify, Netflix, Disney+, Prime Video, Apple Music and Tidal
remain unverified in Airc. Netflix likely needs VMP certification; others' policies
must be tested rather than inferred. Keep the exact binary and test evidence tied
together before changing beta release claims.

## Dedicated test commands (build Mac, after engine build)

```sh
AIRC_HOST_SOURCE="$PWD/engine/tests/drm-host.mm" \
  CHROMIUM_OUT="$HOME/arcfork/chromium/src/out/AircRelease" \
  engine/host/build.sh "$PWD/engine/tests/build-drm"
node engine/tests/drm.mjs engine/tests/build-drm/AircHost.app \
  "$HOME/arcfork/widevine-qualification"
```

The output and scratch directory must not already exist. The fixture's loopback
server is internal to the test, closes afterwards, and is not a user preview.
The runner launches only the dedicated host via `open -g`, uses a mock keychain,
records JSON and NetLog, and quits between phases. It disables occluded-window
backgrounding and background-media suspension **only in the test launch** so
Chromium initializes video while the window stays behind the owner's work. This
uses no capture APIs. Playback is muted. Its assertion failures are
failures, not automatic service success. Preserve evidence outside the checkout
and delete this host bundle/scratch profile after collecting it. Run `python3 engine/tests/drm-netlog.py <scratch>/*-netlog.json` for HTTPS
and off-state request assertions. Inspect the output with registration diagnostics; never publish a general browsing NetLog.

## Initial qualification (before restored-component correction)

On 2026-11-06, Chromium 156.0.8078.88 release/arm64 loaded Widevine **4.10.3112.0**.
Only `oimompecagnajdejgnnjijobebaeigek` registered. The local EME probe resolved
`com.widevine.alpha`, created MediaKeys and generated a 1,702-byte license request.
The public Shaka Angel One Widevine DASH stream obtained a license from Shaka's
public proxy and advanced from 0.000734 to 4.958258 seconds, unpaused, with
`com.widevine.alpha`. This verifies encrypted playback, not an unencrypted preview.

Off and off after restart returned `NotSupportedError`; both phases stayed alive
70 seconds to cover the updater's initial timer and emitted zero component
requests, including in a newly loaded profile after restart. The final four-phase
runner passed all assertions; turning protection on restored encrypted playback.
NetLog recorded HTTPS update and
CDM CDN requests. Other existing browser service requests were also present;
the component allowlist is not a whole-browser network isolation guarantee.

The release framework build finished successfully with `-j 8` and caffeinate.
The DCHECK build was not attempted after Mac free space dipped below the 15 GB
floor; remaining space stayed tight during concurrent work. The strict patch
application/idempotence/drift check passed. The general
series audit still reports a pre-existing missing registration.cc audit entry.

## Developer ID packaging

`scripts/release/sign.py` now preserves
`com.apple.security.cs.disable-library-validation` only on the normal and
Aperitif normal utility helpers inside Airc Framework. These sandboxed helpers
load Google's differently signed CDM. The browser, renderer, GPU and unrelated
binaries retain library validation. This exception is separate from VMP.

The public packager and dev-channel `infra/updates/prepare-mac.sh` both use that
signer and run `check-entitlements.py` after final signing. The release metadata
gate also checks signed bundles. The entitlement policy checks exact helper
paths and every real Mach-O, skipping framework symlink aliases. The previous
unapplied `drm-signing.patch` has been applied and retired.

The disposable Developer ID qualification bundle uses its own bundle identifier,
a new scratch profile and the mock Chromium keychain. Signing and notarization
use only the configured dedicated signing keychain. Its runtime/notary result is
recorded in the completion report; no owner's installed app or login keychain is
used for qualification.

## Restored-component completion pass

The release engine was rebuilt incrementally with unchanged GN arguments under
its shared ship-loop lock. Build passed (13 steps); free space stayed above
16.9 GB. The final scratch-host sequence passed: fresh Widevine 4.10.3112.0 install,
Shaka encrypted playback, off, persisted off in a new profile, and playback after
re-enabling. NetLog update headers include CRLSet and the other restored IDs in
BACKGROUND-SERVICES.md, while disabled phases contain no Widevine ID or payload
request. Existing component pings/download policy are restored. No capture or
owner accounts were used.

Developer ID completion: the disposable host passed the same four-phase install /
playback / off / restart / re-enable sequence with the production release signer.
The exact-path entitlement gate passed all 16 Mach-O files. Apple notarization
returned **Accepted**; stapler validate, `codesign --verify --deep --strict` and
`spctl -a --type exec` passed. Apple did not reject the utility-helper exception.
No VMP certificate or Google Widevine agreement was obtained by these checks.

## App Privacy binding

The UI uses the BrowserEngine adapter and reads Chromium Local State directly;
there is no duplicate UserDefaults value or new telemetry event. The same source
builds as WebKit, where the unsupported control is hidden. Help text says turning
it off applies to newly loaded pages and asks users to reload existing tabs.

Both bundles built successfully with scripts/build-app.sh. The dedicated
`--script drmsettings` scenario passed five Chromium checks (availability,
default on, off reaches the engine, a new Settings model reads the off state,
and re-enable) and two WebKit checks (hidden and no-op). It runs via the existing
`--snapshot <log-directory>` launcher but writes **only logs**: it calls no render,
image, camera, microphone or screen-capture APIs. Use an isolated data directory,
mock keychain and `open -g`, with `AIRC_SHIP_GATE=0` so failures cannot be masked.

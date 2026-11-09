# Chromium security reviews

## Review 2026-11-07

**Recommendation: no action on the engine pin for this alert.** The live Mac
[Extended feed](https://chromiumdash.appspot.com/fetch_releases?channel=Extended&platform=Mac&num=5)
still reports **156.0.8078.88**, matching `CHROMIUM_VERSION`. No newer 156 Extended
tag was returned. This is a source-release review, not verification of a shipped binary.

The matched [November 3 Extended Stable post](https://chromereleases.googleblog.com/2026/11/extended-stable-update-for-desktop.html)
announces that exact version with 55 CVEs: **3 Critical, 49 High, 2 Medium, 1 Low**.
They apply to the 156 branch and are included upstream in the pinned release;
the alert does not identify a missing update. Neither this post nor the three
component-detail posts below states that an exploit exists in the wild. That is
absence of a published exploitation notice, not proof that exploitation is impossible.

The Critical CVEs are CVE-2026-118306 (FileSystem), CVE-2026-121156 (Dawn), and
CVE-2026-76024 (MediaStream). The Medium CVEs are CVE-2026-119272 (FileSystem) and
CVE-2026-121135 (Platform); the Low CVE is CVE-2026-121141 (Editing).
Component names come from matching CVE identifiers in the
[October 27](https://chromereleases.googleblog.com/2026/10/stable-channel-update-for-desktop_0562499947.html),
[October 29](https://chromereleases.googleblog.com/2026/10/stable-channel-update-for-desktop_02107719452.html),
and [November 3 Stable posts](https://chromereleases.googleblog.com/2026/11/stable-channel-update-for-desktop.html).
The Extended post itself gives severity and identifiers, but no component names.

### Patch exposure

The working series at review contains 28 patches touching 61 unique upstream
files; the introductory counts in `engine/README.md` are historical. Inspect the
current series again before updating: engine work continues independently.

- **Autofill (CVE-2026-76026): direct component overlap.** `006-autofill.patch`
  changes popup notification and address-promo handling; `025-password-picker.patch`
  routes password suggestions through the host in `chrome_autofill_client.cc`.
  Retest origin/frame identity and stale suggestions on a future respin.
- **Extensions (CVE-2026-121250): direct component overlap.** Patches 010–012,
  014–015, 017 and 020 touch DNR, windows/install UI, actions/shortcuts, extension
  storage and user-script readiness. Retest permission and lifetime boundaries.
- **FileSystem: adjacent permission UI.** `005-permissions.patch` rehosts the
  file-system-access restore prompt; it does not patch the storage backend.
  **Quota: different implementation.** `017-extension-quota.patch` changes
  extension settings quotas, not `storage/browser/quota`.
- **Navigation/Input: adjacent host hooks.** Patch 020 changes navigation-throttle
  timing, 007 changes renderer-view opacity, and 026 changes Mac PiP event/capture
  handling. A component label alone cannot establish a vulnerable-file match.
- **No direct implementation patches** under V8, Skia, Dawn, ANGLE, WebRTC,
  Blink (including MediaStream, WebAudio, DOM, Frames, Editing, Animation,
  GarbageCollection, Images and Controls), GPU, Network, CacheStorage, Printing,
  PowerBookmarks or DevTools. Broad Desktop, Platform and Modularization labels
  are insufficient to resolve exact overlap with browser startup/window hooks.

This establishes component exposure, not a CVE fix-hunk audit. At least the Autofill
issue's public page requires sign-in, and the post provides no usable change-log
link. No claim is made that all security fix files were inspected or that the
patches cannot regress upstream security. Airc embeds these components even when
the Swift shell owns their UI; do not mark CVEs inapplicable on that basis.

### Dates and next update

**158 is not the next Extended milestone.** Since September 8, 2026, Stable has a
two-week major cadence; Google identifies **156 → 160** for Extended, which retains
an approximately eight-week cadence and weekly security refreshes.
See the [cadence announcement](https://developer.chrome.com/blog/chrome-two-week-start)
and [Extended channel policy](https://support.google.com/chrome/a/answer/16942104?hl=en).
Do not infer Extended eligibility from an even milestone number.

- 156 Stable/Extended began October 20, 2026. Its next scheduled refresh is
  November 10, 2026 ([156 schedule](https://chromiumdash.appspot.com/fetch_milestone_schedule?mstone=156)).
- 158.0.8127.18 is Early Stable (November 4); full Stable is scheduled for
  November 17, 2026 ([158 schedule](https://chromiumdash.appspot.com/fetch_milestone_schedule?mstone=158)).
  There is no scheduled 158 Extended promotion in the published cadence.
- The fetched [160 schedule](https://chromiumdash.appspot.com/fetch_milestone_schedule?mstone=160)
  gives Early Stable December 9, 2026 and full Stable January 5, 2027. Use that
  current milestone schedule as a provisional planning date, not an actual
  Extended release announcement. Eight-week arithmetic alone would give
  December 15; do not promise that date. Confirm the Mac Extended feed at promotion.

Continue the six-hour watcher. Review the November 10 refresh when published.
Prepare the next major around the confirmed Extended target, not an automatic
158 rebase. If a later 156 security respin appears, follow `engine/README.md` and
`docs/rebase.md`:

1. Confirm the target on Mac Extended and review its CVEs; claim a single engine
   owner and a stable snapshot of the patch series.
2. Prepare a disposable Linux candidate with `infra/chromium/update.sh <version>`;
   review patch/header reports without changing the shared mirror.
3. In assigned update work, update the pin, inspect changed upstream files and
   refresh exact patch context/hashes only after review. Run strict apply checks,
   scratch/idempotence tests and refresh the Public Suffix List as documented.
4. Coordinate the build Mac, sync the verified tag/dependencies, apply/check and
   run `engine/build.sh --start` using the build owner's release configuration.
   Require actual build success, host/adapter isolation and restart acceptance,
   app tests and performance comparison. Keep media tests synthetic; no OS capture
   prompts or owner profiles.
5. Qualify signing, notarization and update-from-N-1 before separately authorized
   promotion. Never downgrade migrated profiles.

A same-branch respin should have lower API drift than a major rebase, but risk is
not zero: exact whole-file hashes reject unrelated upstream edits, and Autofill,
Extensions and permission hooks warrant focused review. No newer tag was available
to measure conflicts. No update preparation, build, rebase or Mac work ran here.

## Acknowledging a reviewed post

`infra/chromium/watch.py` searches blog bodies for the exact newer Extended
versions (or the latest version when already current). The previous unconditional
non-urgent status made the same post require review every six hours.

`infra/chromium/reviewed-posts.json` records reviewed URL, exact Airc pin, SHA-256 of
the feed's original `content.$t` UTF-8 bytes, review date and a note link. After a
human/agent review, copy the `content_sha256` from a fresh `state.json`, document the
decision here and commit the record. Never acknowledge based only on a version match.

Only a nonempty, error-free set of matching acknowledged entries reports
`Security: reviewed`. Entries, text and CVEs remain visible. A changed URL, post
body or pin, an additional unreviewed match, missing results or a fetch/registry
error requires review again. Exploitation evidence always remains `urgent`, even
with a matching acknowledgement. Reviewed status does not suppress newer-version
detection or a pending update brief and is not a security certification.

Offline regression checks: `python3 -m unittest discover -s infra/chromium -v`.
Refresh live state with `python3 infra/chromium/watch.py`; historical logs are kept.

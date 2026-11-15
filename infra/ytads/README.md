# Video ad blocking qualification

This change adds YouTube player-response filtering. Short signed-out observations
and local fixtures are described below; they do not guarantee ad-free playback.

The original Apache-2.0 resource in `engine/core/blocking-rust/src/video_ads.js`
prunes player response ad fields. Rust selects that resource for YouTube; native
Chromium sends it before commit, and WebKit installs a per-profile document-start
user script. Existing Rust cosmetics cover ad slots. Embedded frames, procedural
filters and server-side inserted ads are not covered by this change.

`video_ads_resource.json` is the base64 resource representation consumed by
adblock-rust. Regenerate its `content` from the JS file when editing; verify the
decoded bytes match before compiling. No downloaded list may supply new JS code.
Existing HTTPS list transport, metadata validation, compilation validation and
SHA-256 cache checks remain unchanged. The current updater has no detached list
signature verifier; this is documented as an existing gap, not a signed-update
guarantee. A signed list feed is a separate queued follow-up, not a gate for this
change. Bundled executable resources update with the signed app.

## Licensing decision

- [uBlock Origin](https://github.com/gorhill/uBlock/blob/master/LICENSE.txt) and
  [uAssets](https://github.com/uBlockOrigin/uAssets/blob/master/LICENSE) carry
  GPLv3. Their scriptlets and quick-fix rules have not been copied or bundled.
- Airc's existing Apache-only policy disallows copying those sources. A lead
  decision for this change is to ship only original Apache-2.0 scriptlets, with
  no GPL assets and no GPL distribution review. They are not fetched separately.
- [adblock-rust](https://github.com/brave/adblock-rust/blob/master/LICENSE) remains
  MPL-2.0 under its existing notices/source distribution. The new resource is
  original Apache-2.0 code, shipped as app/engine code, not a remote executable
  list update. Existing EasyList/EasyPrivacy attribution is unchanged.

## Local fixture and probes

Run on the build Mac only. `resource-check.js` uses JavaScriptCore through JXA
with mocked response APIs; it is a unit probe, not browser integration evidence:

```
osascript -l JavaScript infra/ytads/resource-check.js engine/core/blocking-rust/src/video_ads.js
```

`server.py --port 18761` serves `fixture.html` and a synthetic
`/youtubei/v1/player` response on loopback. It contains pre-roll/mid-roll shapes,
initial assignment, a subsequent SPA assignment, fetch JSON/text and XHR
JSON/text. It deliberately does not inject its own blocker. Without native
injection the ad-removal assertions must fail. The normal production host gate
excludes localhost; an integration runner must explicitly supply a test-only
`localhost##+js(airc-video-prune)` rule and a matching WebKit test-only host path.
`--script ytads` supplies that test-only rule/host path; public builds have no
localhost exception. Set `AIRC_YTADS_SOURCE` to the clean source export directory.
The native fixture server also serves a local MP4 from the repository and VTT
captions. The scenario asserts playback, seek, caption cues and native PiP, then
checks profile off/on, Site Controls, a second profile and private exceptions.

Rust's `video_resource_selection_and_exceptions` test checks resource loading,
site matching, a lookalike hostname, empty selection and scriptlet exceptions.
Run it with the pinned offline Cargo toolchain under the build lock.

## Signed-out real observations (2026-11-12)

Use separate fresh data directories for each engine, no imported data and no
YouTube login. Capture today's unmodified blocking-on baseline, then the candidate
on the same videos. The local fixture supplies a deterministic blocking-off
control. The first fixed set is for playback checks only, because no ads appeared
before the change:
`aqz-KE-bpKQ`, `jNQXAC9IVRw`, `M7lc1UVf-VE`, `YE7VzlLtp-4`, `ScMzIvxBSi4`. The original fourth ID `ysz5S6PUM-U` was unavailable
in the baseline; its result is retained and the Blender Big Buck Bunny upload is the explicit replacement in
both playback samples. This set cannot establish a live ad-blocking improvement.

A second set was frozen from regional music, creator and trailer results. Each
retained video showed actual Sponsored pre-rolls and companion ads in **3/3
unmodified trials on each engine**, with blocking already enabled. After the
change all five played without visible ads in one short observation per engine:

| Case | Public video ID | Before, each engine | After, each engine |
|---|---|---|---|
| Future — Ya Hit | `Sh4pJYJOT7M` | Ads in 3/3 | No ads in 1/1 |
| Davido — B4 B4 | `rRjtTx49hkc` | Ads in 3/3 | No ads in 1/1 |
| MrBeast — Beat Professional Athlete | `_c2e1NcI3Sc` | Ads in 3/3 | No ads in 1/1 |
| MrBeast — Lose 150 Lbs Together | `RE3_PGwDwhw` | Ads in 3/3 | No ads in 1/1 |
| KinoCheck trailer compilation | `2ixA6BgwkUk` | Ads in 3/3 | No ads in 1/1 |

The first trailer candidate (`fA8-gXDoAk8`), home and music search had no ads in
three baseline trials per engine. Those negatives were retained; the supplemental
trailer was frozen before its trials. All profiles were fresh and signed out,
with consent rejected. Content advanced by 14–29 seconds in the candidate
observations. No natural mid-roll was observed across a complete long video;
local fixtures exercise those response shapes. Home/search observations cannot
establish efficacy when their baseline has no ads.

Chromium CDP traces start at navigation and distinguish network blocking from
content delivery. WebKit's observation-only Boost and resource timing provide a
partial request trace, not a complete HAR or confirmed blocked-request reasons.
Candidate traces contained googlevideo delivery and no observed doubleclick,
pagead or `/api/stats/ads` endpoints. Absence of an issued ad request is not a
confirmed blocked request. Screenshots, raw URLs, bundle hashes, failed attempts
and machine details remain in private qualification artifacts.

Production engine compilation and the approved single relink passed, followed
by public and test app builds on both engines. Native local fixtures passed
**216 assertions on each engine**, including profile/site/private exceptions,
playback, range seeking, VTT cues and native PiP. Both engines also passed raw
resource positive/negative controls. The registered `video-blocking` marketing
shot shows Site Controls over a clearly labelled synthetic illustration.
A separate native real-controls check passed **9 assertions per engine** on the
first ad-positive music video: playback, midpoint seek, native PiP, request
capture, signed-out/consent state and no sampled ad UI. That video offers no
caption tracks in the unmodified WebKit control or candidate runs; real VTT cues
pass in the local fixture, and the independent trailer observation shows rendered
captions. Do not confuse this representative controls check with the five-video
before/after cohort above. Extra native repetitions were stopped after these
required gates passed; they are not reported as passes.

The full snapshot run includes `ytads` for each selected engine. To run only the
local fixture after compiling a test app, use `python3 infra/ytads/run-check.py
webkit` (or `chromium`). The runner takes the UI lock, refuses a lock timeout,
uses its own data directory, records a hung process stack, and cleans up its exact
app PID. Adding `--video <fixed-ID>` explicitly opts into a public-page live
observation; that mode is never part of CI.

For an unmodified WebKit app baseline, `webkit-live-observer.js` can be installed
as an observation-only Boost in a throwaway profile, scoped to `www.youtube.com`.
It records fetch/XHR metadata and resource timing, samples signed-out playback,
then seeks to the midpoint. It does not prune responses or block requests. Its
`YTADS_BEGIN`/`YTADS_END` JSON is appended to the body so the agent text reader can
retrieve it. Because Boost code starts after DOM parsing, resource timing supplies
earlier completed loads; this is not a complete network HAR. Keep baseline page
screenshots separate from this diagnostic overlay. Never use a personal profile.

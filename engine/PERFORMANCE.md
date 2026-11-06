# Engine pass 3 measurements

Chromium 156.0.8078.88, release arm64 framework, build Mac, 2026-11-05.
All values below are decimal MB (1,000,000 bytes), not RSS. `footprint` samples
the host and its recorded descendants. Four steady processes remain with no pages:
browser, GPU, network and storage. Every count uses a fresh data directory and a
60-second settle after all requested profiles/Browsers are loaded. No spare
renderer is explicitly warmed. Chromium's startup Default profile exists in all
runs; the zero-additional-profile run subtracts that fixed cost.

| Additional empty profiles | Before total MB | After total MB | Before MB/profile above zero | After MB/profile above zero |
|---|---:|---:|---:|---:|
| 0 | 92.591 | 93.852 | — | — |
| 1 | 106.173 | 107.042 | 13.582 | 13.190 |
| 3 | 135.402 | 135.976 | 14.270 | 14.041 |
| 6 | 179.934 | 181.114 | 14.557 | 14.544 |

The largest marginal group delta is 14.844 MB/profile before and 15.046 after
(3→6). Both are below MEM-2's 40 MB budget in this empty-profile test. There is
**no demonstrated material memory reduction**; the small differences are within
single-run noise. These samples do not establish six extension-heavy profiles,
steady idle CPU, whole-app MEM-1, or MEM-4. Some development builds/tests ran on
the shared machine during this session; repeat controlled runs before gating
release on small differences. Samples are sequential, not an atomic OS snapshot.

The initial 15-second samples misleadingly suggested 34–38 MB/profile because
one ~24 MB extension renderer existed per profile. At 60 seconds those processes
had exited even before changes. Do not cite those startup numbers as idle cost.

## Services

`python3 engine/tests/audit_services.py /path/to/pinned/src` inventories 214
`ServiceIsCreatedWithBrowserContext` overrides (including other platforms and
conditional factories); 23 contain Chromium's lazy-factory gate. This is source
analysis, not a list of actual allocated services. Dependencies and explicit
GetForProfile callers can still instantiate a nominally lazy service.

Examples of eager services include DomainDiversityReporter, SigninMetricsService,
RendererUpdater, protocol handler registry, account/policy observers and site-data
cache facade. Optional factory groups already have upstream lazy paths: shopping,
Lens/reading mode, LoginUI, page embeddings/content annotations/extraction,
OptimizationGuide, CWS metadata, passwords-private extension event routing,
visited-URL ranking and storage notifications. Airc now enables
`LazyKeyedServiceInstantiation`, preserving eager **Safe Browsing and Safety Hub**
parameters. It also opts into Chromium's Hangouts MV3 migration; this alone did
not demonstrate an idle-memory saving. No dependency graph is bypassed and no
service testing factory is substituted in production.

The internal profile is created only on explicit `loadInternalProfile`, never
as an automatic spare, and benefits from the same factory policy. It remains a
regular isolated profile; no off-the-record substitution or teardown violates
D1. Its separately named footprint was not measured. Do not claim it is free.

## Discard

The host's `memory` scenario passes visible refusal, explicit hidden discard,
title retention, 900px scroll restoration and `document.wasDiscarded` after
activation, unsaved-input protection (real renderer Input.insertText), shortened
per-profile timeout, audible-page refusal (real AudioContext), and Chromium
critical-pressure callback with hidden discard/visible protection. The timeout
is shortened only in tests; default is 1800 seconds. Native pressure injection
is refused outside the existing unsigned/mock-keychain/scratch test gate. Tests
simulate Chromium's notification, not global macOS memory pressure on the laptop.
Favicon retention relies on preserved WebContents/navigation state and was not
independently asserted. Capture is conservatively protected too.

## Process sharing

The original three-profile workload with eight recent pages loaded produced
**8 renderers / 12 total processes**, 778.996 MB after 60 seconds. The other 22
entries remain app-model-only; the engine host does not manufacture blank pages
for them. The 30-loaded-page stress case produced **37 renderers / 43 total
processes**, 3825.588 MB. Third-party isolated frames and cross-origin isolation
can require more renderers than tabs. Public-site load outcomes were not verified,
so these are diagnostic counts, not MEM-4 acceptance or a matched Chrome ratio.

Chromium's renderer cap is a global, memory-derived soft limit, not a hard limit
per profile. Site process reuse also requires compatible BrowserContext/storage
partition/site isolation. Airc does not warm a renderer per empty profile or
change Chromium's process caps. A process-per-site experiment and a deterministic
same-site sharing test remain outstanding; 37 processes alone cannot prove that
none are needless. Do not disable site isolation to chase a process-count target.

## Incremental builds and patches

A change only to `airc_host_api.mm` completed Ninja's compile/link/bundle work in
**25.69 seconds (3 steps)**. Another single-file main-delegate build took 39.29s
under shared-machine load. GN/apply startup and host cloning/signing are excluded.
No build tuning was necessary: apply already preserves unchanged file mtimes,
args.gn is replaced only when changed, and builds remain serialized at eight jobs.

52 per-file patches became **23 concern-grouped patches**, still touching 51
upstream files. Final patched bytes and manifest hashes are unchanged. Each series
entry has a one-line rationale. The parser now validates every file of multi-file
patches against the pinned manifest and refuses unlisted paths/renames. Pristine
check, apply, repeat apply, applied check and deliberate-drift refusal pass on a
scratch copy of the read-only mirror. This is bookkeeping consolidation, not a
claim that upstream logic was moved into core; that reduction remains outstanding.

## Leak check

With three loaded profiles and one retained about:blank page, after 60 seconds
settling the baseline was **201.123 MB / 7 processes / 3 renderers**. Opened and
closed 100 additional real about:blank tabs, allowing asynchronous cleanup between
cycles, then waited another 60 seconds: **205.399 MB / 7 processes / 3 renderers**,
ratio **1.0213**. This run meets MEM-5's ≤1.05 criterion. It is an engine lifecycle
check, not a proof of absence of all leaks or public-page retention. An earlier
20-second baseline included startup extension renderers and was discarded as
confounded. The workload script preserves the per-PID footprint and process lists.

## Extension proof

The `extension` scenario installs uBlock Origin Lite **2026.1103.1743** from the
Chrome Web Store after rejecting optional cookies, accepts only that exact ID in
throwaway Profile One, verifies it is absent in Profile Two, queries action
icon/badge data, opens the action in an anchored nonactivating panel, captures its
renderer and closes it. All assertions pass. It exposed/fixed an old ID mismatch:
`AircTab.browserId` is a wrapper identifier, not Chromium's window ID. Popup
ownership now checks actual tab membership. The app still needs toolbar rendering,
install permission-review UI and popup dismissal wiring.

Proof artifacts: `extension-final/extension.json.store.png`,
`extension-final/extension.json.popup.png`, and `extension-final/extension.json`
in the engine artifact directory supplied with the handoff. Renderer screenshots
show actual Web Store and extension content; they do not qualify panel placement.

Final verification also passed the signed Swift adapter (two profiles, switching,
evaluate, renderer snapshot, deactivateAll) and the original write/restart/read
cookie/localStorage acceptance suite on the rebuilt framework. All recorded test
host PIDs were checked exited. No changes to app-wiring.patch were applied and no
commits were pushed.

## Pass 4 renderer-policy experiment

The prior **13.2–14.5 MB/profile** steady empty-profile samples already satisfy
MEM-2; no extra profile-memory optimization is justified by that result.

The all-loaded 30-tab reference workload was run with each policy, fresh profiles,
a 60-second settle and the same signed framework/host:

| Policy | Footprint MB | Renderer processes | Total processes |
|---|---:|---:|---:|
| Current default | 3807.354 | 37 | 43 |
| `--process-per-site` | 3336.412 | 27 | 33 |
| `--renderer-process-limit=8` | 3328.087 | 26 | 32 |

Evidence: `pass4-policy-default/results.json`, `pass4-policy-site/results.json`,
`pass4-policy-limit/results.json`, with per-PID `baseline.json` and process lists
in the pass-4 artifact folder. The limit of eight is plainly **not a hard cap**:
26 renderer processes were required. Site isolation and BrowserContext/storage
partition compatibility continue to constrain reuse. No isolation was disabled.

These are diagnostic single runs, not recommendation-quality matched experiments:
public page outcomes were not asserted, the machine was shared, and a framework
link overlapped part of the series. Site policy and a limit both correlated with
fewer processes/lower memory in this run, but no latency, responsiveness or crash
isolation comparison was made. **No renderer policy is changed or recommended.**
Repeat with verified page loads, no concurrent builds, multiple runs, and the
normal eight-loaded/22-model-only case before considering a default change.

Current policy has no process-per-site flag or explicit renderer-process limit.
`AircProfile.warmSpareRenderer` explicitly warms Chromium's shared spare manager;
it is not called once per empty profile by the engine. The content browser client
inherits Chrome's spare delay when present and substitutes 500ms when absent.
Thus "no explicit warmup in the idle test" does not mean "spare renderers disabled".
Warmup and site/process compatibility are still Chromium-managed.

Upstream footprint remains **51 → 51 files, 23 patches** in this pass. New profile
services, download observation, menu/UI state and test fixes live entirely in
`//airc/core`; no new upstream patch was needed. The ≤30-file target is **not met**.
Removing the inherited Bluetooth/WebAuthn/quota/timer patches merely to hit a count
would change behavior; that was not done. Factory/observer replacements and their
regression tests remain follow-up work. `apply.sh --check` and the pristine/applied/
repeat/drift-refusal suite still pass without relaxed hashes or fuzz.

## Pass 6: optional background machinery (2026-11-05)

**Result: lower browser-process memory, mixed total-memory and CPU results. No
release-budget pass is claimed.** Chromium 156.0.8078.88, Google Chrome
156.0.8078.80, same build Mac. Airc used the two-profile test host, not the full
Swift product shell. The eight-page case uses the reference workload's three
profiles; 22 other entries stay model-only. Chrome was tested both with those
same eight URLs and with all 30, in fresh throwaway user-data directories.
Chrome uses separate native windows for its profiles; Airc uses one shared window.
No Arc launch or owner Chrome profile operation was performed.

All numbers are decimal MB and **sum per-process `phys_footprint`**, not RSS.
`engine/perf/counters.c` reads kernel ledgers through `proc_pid_rusage`, without
sudo. Its Mach CPU counters are converted using `mach_timebase_info` (125/3 on
this machine). A 0.5-second CPU fixture agreed with `getrusage` to within 0.1%.
The first sampler version mislabeled ticks as nanoseconds; the raw baseline and
Chrome evidence is retained, and `summarize.py --legacy-timebase=125/3` corrects it.
See Apple's [fill_task_rusage implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)
for the underlying ledger fields. Never cite the uncorrected raw CPU percentages.

Each memory run settles at least 60 seconds, inspects page DOMs, then samples
CPU/wakeup deltas over another 60 seconds. Counters identify processes by PID and
start time, include descendants, and flag process churn. “Wakeups” below means
**interrupt wakeups**, not every scheduler wakeup; package-idle counts are retained
separately in JSON. Sampling and page checks are sequential, not atomic.

The display was locked/asleep, with background windows (`open -g`); GPU residency,
occlusion and timers may differ when unlocked. Other owner apps and agents were
active. No engine build overlapped a completed measurement. Stale scratch-profile
cleanup overlapped the policy experiment series. These are single diagnostic runs,
not statistically controlled release measurements.

### Before/after and Chrome

| Workload | Airc before MB | Airc after MB | Chrome MB | Before/Chrome | After/Chrome | After/before |
|---|---:|---:|---:|---:|---:|---:|
| Two profiles, two Google sign-in pages | 423.7 | 503.8 | 700.2 | 0.605 | 0.720 | 1.189 |
| Three profiles, eight recent URLs | 857.9 | 820.4 | 1310.4 | 0.655 | 0.626 | 0.956 |
| Reference load policy: Airc 8 loaded, Chrome 30 | 857.9 | 820.4 | 3794.3 | 0.226 | 0.216 | 0.956 |

**MEM-4:** nominal ratios are below 1.0 and the 0.8 target, but the eight-page
Airc runs only returned usable DOM responses for **7/8** targets; Chrome returned
8/8 and 30/30. `Computer_memory` timed out in the baseline and the after run logged
a Blink `InlineItemResult::CheckConsistency` assertion. A missing/crashed page
invalidates a release comparison; do not count it as a memory optimization.
Two-profile runs returned 2/2 DOM responses, but total memory **increased 18.9%**.
Browser-process memory fell in both cases; this is not evidence of consistent
whole-browser improvement. Public pages can change content or serve challenges;
a non-error DOM response is not a signed-in or complete-site acceptance test.

| Workload / engine | Browser MB | GPU MB | Network MB | Other utility MB | Renderers MB | Processes / renderers |
|---|---:|---:|---:|---:|---:|---:|
| Two, Airc before | 93.8 | 52.1 | 26.1 | 32.1 | 219.7 | 12 / 6 |
| Two, Airc after | 78.7 | 59.4 | 34.5 | 76.2 | 255.0 | 11 / 5 |
| Two, Chrome | 135.9 | 117.2 | 31.4 | 94.2 | 321.5 | 14 / 7 |
| Eight, Airc before | 134.9 | 64.5 | 41.8 | 12.2 | 604.5 | 13 / 9 |
| Eight, Airc after | 100.9 | 66.9 | 37.8 | 25.6 | 589.2 | 12 / 8 |
| Eight, Chrome | 176.0 | 278.4 | 39.7 | 49.5 | 766.8 | 17 / 12 |
| Thirty, Chrome | 250.8 | 204.3 | 61.4 | 101.2 | 3176.6 | 53 / 46 |

The two-profile after run's utility group includes storage, audio and video capture
services. Their presence is not evidence that recording occurred. They and the
renderers account for the total-memory regression despite a smaller browser.

| Workload / engine | CPU % of one core | Interrupt wakeups/s | Package-idle wakeups/s |
|---|---:|---:|---:|
| Two, Airc before | 0.514 | 8.70 | 0.88 |
| Two, Airc after | 0.362 | 7.13 | 1.68 |
| Two, Chrome | 2.584 | 14.91 | 3.51 |
| Eight, Airc before | 0.499 | 10.82 | 0.00 |
| Eight, Airc after | 1.077 | 5.44 | 0.95 |
| Eight, Chrome | ≥1.910 | ≥12.57 | ≥3.05 |
| Thirty, Chrome | 4.891 | 48.52 | 11.07 |

Chrome's eight-page run had one process appear during the interval, so its deltas
are lower bounds over surviving processes. **MEM-6 is not met by the eight-page
after sample (1.077% > 1%)**. Renderers account for 0.942 percentage points;
the browser is 0.068%, versus 0.070% before. The two-profile after sample is below
1%, but this does not establish unlocked/foreground idle performance. Existing
Chromium timers, including the inherited disk-space check, remain. The literal
“no timers while idle” criterion is not met.

### Disk

Fresh user-data roots were redirected into benchmark scratch directories, the
controlled equivalent of Airc's profile data under Application Support. The owner’s
existing Application Support/Airc tree was not modified or used as a baseline;
there is no attributable first-launch measurement of that shared live tree.

| Workload / engine | Retained logical MB | Allocated MB | Model-named files MB | Writes by surviving processes MB |
|---|---:|---:|---:|---:|
| Two, Airc before | 16.33 | 21.11 | 0 | 10.21 |
| Two, Airc after | 17.60 | 22.56 | 0 | 13.43 |
| Two, Chrome | 181.22 | 183.78 | 56.47 | 99.55 |
| Eight, Airc before | 34.20 | 40.16 | 0 | 14.20 |
| Eight, Airc after | 30.45 | 37.93 | 0 | 42.14 |
| Eight, Chrome | 180.21 | 186.27 | 56.48 | 122.57 |

Retained bytes and write traffic are different metrics. Write counters cover all
paths written by surviving processes, exclude exited processes and later shutdown
writes, and are not filesystem-attributed to one directory. Per-file size/block
inventories, final counters and idle-interval writes are retained. “Model-named”
classifies paths containing model/optimization/translate; it is not a complete
network download ledger. No multi-GB model download was observed in this pass's
first few minutes. Earlier idle scratch runs held roughly 437 MiB of SODA speech
binaries/packs plus their compressed component cache; see BACKGROUND-SERVICES.md.
Do not claim a zero-model observation proves there can never be a delayed download.

### Process policy

| Eight-page policy, final framework | Total MB | Renderers / total processes | CPU % | Interrupt wakeups/s |
|---|---:|---:|---:|---:|
| Unchanged default | 820.4 | 8 / 12 | 1.077 | 5.44 |
| Disable SpareRendererForSitePerProcess | 784.1 | 7 / 11 | 1.148 | 4.83 |
| renderer-process-limit=8 | 804.1 | 7 / 11 | 0.223 | 5.08 |

All three had the same failed Wikipedia target. The spare-disabled case saved
36.3 MB / one renderer, but did not improve CPU. The soft-limit case saved 16.3 MB;
page-driven CPU variance is large. No subsequent-navigation latency, responsiveness
or repeated-run distribution was measured, so **neither change is recommended as
a default**. The previous all-loaded pass-4 cap of eight still required 26 renderers:
a cap is not a hard per-profile or global security override. Cross-site subframes,
BrowserContext/storage-partition boundaries and isolation constrain sharing.
Site-per-process remains on; it was never disabled for a comparison. No default
process-per-site flag, renderer cap or spare-renderer change was committed.

The after/Chrome CPU ratio is 0.140 for the two-profile sample and **at most**
0.564 for eight pages (Chrome's value is a lower bound). Relative to the 1% CPU
ceiling, Airc after is 0.362× and 1.077× respectively. These ratios do not waive
the missing-page, locked-display or remaining-timer qualifications.

The final **all-30-loaded stress case** used 3848.2 MB, 39 renderers / 46 processes,
versus Chrome's 3794.3 MB and 46 / 53 (ratio **1.014**, above Chrome). Per type:
browser 244.2, GPU 90.2, network 66.3, other utilities 106.1, renderers 3341.3 MB.
Only 27/30 Airc DOM checks returned; Computer_memory, MacOS and
Garbage_collection_(computer_science) timed out. Logs contain three Blink inline
layout assertions. CPU was **at least 8.763%**, interrupt wakeups at least 46.37/s
and package-idle wakeups at least 10.62/s, with one process change during sampling.
Retained data was 94.85 MB logical / 102.47 MB allocated, including 0.14 MB of
model-named files, and surviving-process writes were 190.30 MB. This stress case
is not the eight-loaded MEM-4 load policy, but shows that fewer renderer processes
alone do not guarantee a smaller footprint. No all-loaded baseline was rerun in
this pass; older pass-4 figures above are not a matched before/after control.

### Launch probe

Three interleaved fresh-profile launches per engine loaded a small local `data:`
fixture in three profiles, avoiding public-network variability. Filesystem caches
were warm; no cache purge or reboot was performed. The host prepares its three
profiles before opening pages, whereas Chrome opens profile windows sequentially.
`performance.timeOrigin + first-contentful-paint` is compared to launcher wall time.

| Engine | Renderer FCP median s | Range s | Median / Chrome | Median / 1 s budget |
|---|---:|---:|---:|---:|
| Airc before | 0.555 | 0.536–1.016 | 0.896 | 0.555 |
| Airc after | 0.448 | 0.444–0.598 | 0.723 | 0.448 |
| Chrome | 0.620 | 0.616–0.651 | 1.000 | 0.620 |

The after/before median ratio is 0.807. These are **renderer-paint proxies**, not
first presented native frames or an interactive full-product-window measurement.
The locked display, simple fixture and warm filesystem mean the cold-launch
budget remains **unqualified**. First image-copy completion was 0.453–0.700s after,
0.673–0.707s for Chrome, and 0.588–20.936s before. Two baseline CDP screenshot
requests timed out before retry, despite earlier FCP; do not relabel those stalled
capture callbacks as 20-second first-paint latency. The first after public-workload
launch immediately following signing took 5.689s to a capture / 5.052s to contentful
paint, including network and first-use costs. That is not evidence for a universal
subsecond launch either.

### Regression, safety and remaining work

Final compile/link: **28.23 seconds, 3 steps, EXIT 0**. Strict pristine/apply/repeat/
applied/drift-refusal checks pass, still 51 upstream paths / 23 patches; no new
upstream patch. Signed background acceptance passes:

- two-profile cookie/localStorage write, restart, restoration and separation;
- synthetic password save/fill, native upload-sheet ownership/cancel;
- address/card save and profile isolation (one address and one encrypted card in
  Profile One, neither in Profile Two);
- visible/form/audio discard protection, hidden timeout discard, restoration and
  simulated pressure handling;
- extension install, profile isolation and action-popup lifecycle;
- warnings-as-errors Swift adapter, profile switching, evaluate, snapshot and
  deactivateAll.

All seven individual group-off launches and the all-off rollback returned all
three fixture pages and survived the startup refresh interval. A separate run of
the preserved before binary reproduced the same Blink inline-layout assertion:
it predates this service policy. It still blocks a valid public-workload release
comparison and must be fixed without hiding failed pages or disabling isolation.

The [official Safe Browsing test page](https://testsafebrowsing.appspot.com/)
was visited in fresh scratch profiles before, after and in Chrome. All three
loaded the phishing test document without an interstitial during the 20-second
probe. That control result makes this test **inconclusive**, not proof that basic
protection works or that the policy broke it. No API keys were supplied. Basic
Safe Browsing prefs/factories remain enabled, but no-key live protection needs
longer update/lookup diagnostics and positive threat-blocking evidence. Model-based
client-side phishing protection delivered by Optimization Guide is unavailable
with `quietModels` on; see BACKGROUND-SERVICES.md. This is not a Chrome-equivalent
security claim.

Remaining memory risks include renderer/site payloads (3.34 GB in the all-loaded
stress run), transient audio/video utilities, GPU differences with an awake display,
multiple extension-heavy profiles, and the full product shell not present in this
host. Model-only tabs/actual app unload behavior, real signed-in sessions and
foreground native UI still need end-to-end qualification. Existing model files in
upgraded user profiles are not deleted by these flags; delayed downloads, component
updater work and UMA histogram files are not all eliminated. No repeating timer
was added, and the no-idle-timers requirement remains open.

Reproduce with the commands in README.md and `engine/perf/{measure.py,run-after.sh,
qualify.sh,launch.sh}`. Sanitized per-type measurements and launch/rollback results
are checked in at `engine/perf/measurements-2026-11-05.json`. The private artifact
handoff's `pass6/` contains raw counters, per-file disk inventories, page checks,
renderer PNGs, logs, normalized summary, and the regression reports. The baseline
and final signed host bundles were retained on the build Mac; three stale earlier
bundles, failed intermediate bundles, and 12 stale scratch profile trees were
removed while preserving their measurement reports. All test processes were
terminated by recorded identity; the owner's other browsers remain untouched.


## Pass 8: browser allocation attribution

See [PASS8.md](PASS8.md) and `perf/pass8-measurements.json`. With the same final
app binary and 28 identical seeded component files, rolling the two new gates
on reduces main physical footprint from **155.75 MB to 142.69 MB** (13.06 MB,
8.4%; 7.31 MB below MEM-1). The original framework was 158.22 MB. Unseeded runs
varied with component arrival; an early 121.42 MB after sample is not a reliable
saving estimate. The largest removable sampled owner was the unused AI actor
navigation safety list. CRLSet, security updates, V8/ICU and site isolation remain.

This is a numeric budget pass on a locked display with seven responsive public
targets and an inherited Wikipedia renderer timeout, not full-product release
qualification. The two independent final on samples were 142.90 and 142.69 MB.
Native surfaces remain explicitly unqualified in [HOSTING.md](HOSTING.md).

## Perf pass (2026-11-06): pages off screen, Aperitif helpers, MEM-4 like for like

Build Mac, out/AircRelease, `scripts/perf.sh --instrumented` (infra/perf/README.md), the screen
locked: hidden background windows (`open -g -j`), frame timings to the Core Animation commit.

**Idle CPU: a page nobody could see drew every frame.** Per-process CPU at idle
(`infra/perf/idle.py`) put 9 of the 11.7% in one renderer (3.4%) and the GPU process (5.3%);
the page check showed the page the window shows reporting `visible` at 120 animation frames
a second (a Wikipedia page with one running CSS animation) while the window was ordered out.
Chrome's Views hide a tab's native view when its window is ordered out; the app's window
isn't a Views widget, so `WindowHost` now does it (HOSTING.md, "Window visibility"). With all
30 pages loaded, two more pages were visible though never shown: the first tab of the second
and third profiles' Browsers. Tabs opened in the background now start hidden.

**Memory: 12.9 MB of dirty `__DATA_CONST` in every child process.** `infra/perf/regions.py`
(vmmap by region, one Hacker News page in each browser) showed it in every Airc renderer,
GPU and utility process and in none of Chrome 157's. The helpers `dlopen()`ed the framework;
dyld only page-in links images loaded at launch, so the fixups were written into private
pages. Chromium's Aperitif helpers link the framework at launch; Chrome 157 runs them and our
framework already embeds them. `AperitifHelpers` is now on (off switch
`--airc-switches=aperitifHelpers=off`):

| One HN page | Airc before MB | Airc after MB | Chrome 157 MB |
|---|---:|---:|---:|
| GPU | 29.2 | 14.9 | 16.1 |
| Renderer (page) | 32.1 | 18.2 | 18.6 |
| Renderer (second) | 25.8 | 11.8 | 11.6 |
| Network service | 25.7 | 11.7 | 13.1 |
| Storage service | 20.2 | 5.9 | 6.1 |

**MEM-4 like for like.** The earlier comparison put Airc's reference run (8 of 30 tabs loaded) against
Chrome with all 30 loaded, which made Airc look ~3× smaller. The harness now also loads the same 8 URLs
in Chrome (`chrome_8`, the MEM-4 decision) and all 30 in both (`airc_30`, `chrome`), samples each Chrome
launch as long after launch as its Airc match, checks every page loaded in both browsers, and samples
Airc before its timed actions (which show every loaded page once; Chrome gets no such activity). Chrome
still runs one profile, Airc the reference three (each ~14 MB plus its network and storage contexts).

**Before → after** (`scripts/perf.sh --instrumented`; before = the 04:13 nightly bundle, `--airc-only`, 3 runs;
after = this pass, full runs, 3 runs; medians, each run in brackets; hidden windows, 30 s CPU-time deltas):

| Idle CPU, % of one core (median of runs) | Before | After |
|---|---:|---:|
| All processes, reference run (8 loaded) | 10.14 (10.50, 10.08, 10.14) | 0.50 (0.50, 0.47, 0.63) |
| gpu-process | 5.95 (5.92, 5.95, 5.98) | 0.00 (0.00, 0.00, 0.00) |
| renderer | 3.82 (4.25, 3.79, 3.82) | 0.47 (0.47, 0.43, 0.57) |
| main | 0.30 (0.30, 0.27, 0.30) | 0.03 (0.03, 0.03, 0.03) |
| utility:NetworkService | 0.03 (0.03, 0.07, 0.03) | 0.00 (0.00, 0.00, 0.03) |
| Chrome, same 8 URLs | — | 0.30 (0.03, 1.89, 0.30) |
| Airc, all 30 loaded | — | 5.52 (7.34, 4.42, 5.52) |
| Chrome, same 30 URLs | — | 2.96 (2.96, 2.69, 6.85) |

| Memory, decimal MB (median of runs) | Airc before | Airc after | Chrome, same pages |
|---|---:|---:|---:|
| Total, 8 loaded | 905 (905, 927, 905) | 527 (526, 532, 527) | 590 (586, 593, 590) |
| — main | 103 (103, 104, 103) | 78 (77, 78, 80) | 94 (94, 94, 94) |
| — gpu-process | 111 (111, 112, 111) | 16 (16, 16, 16) | 16 (16, 18, 16) |
| — renderer | 616 (616, 636, 616) | 403 (403, 409, 401) | 451 (447, 451, 451) |
| — utility:NetworkService | 40 (40, 40, 39) | 20 (20, 21, 20) | 18 (18, 18, 18) |
| — utility:StorageService | 25 (25, 26, 25) | 9 (9, 9, 9) | 8 (8, 9, 8) |
| Total, 30 loaded | — | 2756 (2756, 2759, 2694) | 2656 (2668, 2656, 2646) |
| **MEM-4 ratio Airc/Chrome**, 8 / 30 | | **0.897 (0.897, 0.898, 0.892)** / **1.033 (1.033, 1.039, 1.018)** | |
| Old comparison (Airc 8 loaded vs Chrome 30) | | 0.199 (0.197, 0.200, 0.199) | |

MEM-4 passes like for like at the reference load (0.897; target 0.8 not met). With all 30 loaded Airc is ~3% above
Chrome, unverified: Chrome got Reuters' bot-check page in every run. The 30-loaded idle CPU is hidden pages' own
work and varies run to run in both browsers; every Airc page reported hidden with no frames, the browser process
stayed ≤0.2% and the GPU process ~0%.

**Aperitif A/B, same build** (`--airc-switches=aperitifHelpers=off`): reference run 522 MB with the helpers vs 698 MB
without (−176 MB at 8 pages). Launch (`infra/perf/launch.py`, 5 alternating launches each, three-page workload):
interactive 237 ms vs 346 ms, first window 269 ms vs 396 ms (medians) — the helpers launch faster too. The
campaign's after runs show 575–588 ms interactive because each followed Chrome's 2.6 GB 30-page launch; the before
runs, launched back to back, 248–337 ms.

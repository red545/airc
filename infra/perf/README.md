# Performance harness

On the build Mac, after `scripts/build-app.sh`:

```sh
scripts/perf.sh --instrumented --app build/Airc-Chromium.app   # what the nightly runs (and --app build/Airc.app)
scripts/perf.sh --instrumented --no-30 …                        # without the all-30 MEM-4 variant (~4 minutes less)
scripts/perf.sh --instrumented --airc-only --app-arg=--airc-switches=aperitifHelpers=off …   # an A/B of one switch
```

Output: `~/arcfork/perf/<UTC timestamp>/results.json`, `summary.txt`, and latest
copies at the output root. `--output DIR` overrides the output root;
`--app PATH` selects the built Airc bundle. Exit 3 means incomplete measurements.
The nightly runner reserves perf for 23:00–07:00 UTC; `--perf` overrides this.

## What one instrumented run measures

Four launches, one after the other (about ten minutes, inside the nightly's 15-minute perf step; watchdog 840 s):

| Key in results.json | Browser | Pages loaded | What for |
|---|---|---|---|
| `airc` | Airc, `--script perf` | the 8 `recent` (22 kept unloaded) | every budget, the leak cycle |
| `chrome_8` | Chrome, throwaway profile | the same 8 URLs | MEM-4 like for like, idle CPU like for like |
| `airc_30` | Airc, `--perf-load all` | all 30 | MEM-4's second variant |
| `chrome` | Chrome | all 30 | MEM-4's second variant (and the older trend) |

MEM-4 compares totals for the same URLs: `mem4.8` (Airc's reference run vs `chrome_8`, which decides the budget) and
`mem4.30`. Each Chrome launch is sampled as long after its launch as the matched Airc run was, so both had the same
time to load and settle. Each page's load is checked in both browsers before a ratio counts as verified: Airc reports
its pages (URL, title, `document.visibilityState`, animation frames in a second) in a `pages` event; Chrome lists them
through its DevTools endpoint (`--remote-debugging-port=0` on the throwaway profile). A page counts as loaded when its
title isn't its address. Chrome still uses one profile and Airc the reference three, which costs Airc ~14 MB per
profile; Airc also runs its timed actions (and three throwaway profiles) before its sample.

Idle CPU is reported per process too (`idle_cpu_processes`: main, gpu-process, renderer, utility:<service>), and
MEM-6 fails when the all-process total is 1% or more. Results are written after every launch, so a killed run keeps
what it measured.

## Diagnosis tools

- `python3 infra/perf/idle.py --app build/Airc-Chromium.app [--timeline 120] [--sample 5]`: the reference workload
  only; per-process CPU and idle wakeups once it is idle, 5-second per-process buckets (settling vs steady work), and
  `sample` stacks of the hottest processes.
- `python3 infra/perf/launch.py --runs 5 --b-arg=--airc-switches=NAME=off`: launch time (the app's interactive_ms
  and the first window) over alternating launches with and without an argument, on a one-page workload.
- `infra/perf/trace.sh OUT chromium cbnew|cbkey|cburl|newspace|switch 60`: a headless Time Profiler trace of one timed
  action of `--script frames`, summarised (`tpsum.py`) to the main thread's samples inside the action's frames.

With the display asleep (the screen is locked at night) there are no presented frames: frame timings are then taken
to the Core Animation commit and say so (`frame_source`).

## Earlier capability notes (2026-11-05)

Historical: written before the app's `--script perf` hook existed. The measuring rules still apply.

The app currently supports `--snapshot DIR --script showcase`, `--data-dir DIR`
and `--ephemeral`. It does **not** implement a reference or leak scenario.
Default mode deliberately runs the existing showcase, which seeds its own demo
Spaces and pages and exits. It does not silently label this the reference workload.
All acceptance results remain unknown in fallback mode. An early main-process
sample and external first-window observation remain useful diagnostics. If the
scenario survives 60 seconds, the harness also records a physical footprint sample;
this is still not a steady reference-workload measurement. Its scripted activity
is not an idle acceptance test. Missing measurements are null/absent, never zero.

Chrome loads all 30 reference URLs in one throwaway profile, rather than the
reference's three logical profiles (Chrome has no Spaces equivalent). This is a
single-profile lower-overhead control, not an apples-to-apples profile comparison.
The eight recent URLs avoid media; autoplay requires a user gesture. Each URL is
submitted without a blocking navigation wait, followed by a 60-second settle.
Network outcomes are not currently verified. URLs can change content or redirect;
Google's public example sheet may be unavailable. Never sign in during a run.

`vmmap --summary` physical footprint is summed over the main process, descendant
processes and processes whose macOS responsibility PID is the launched PID. This
includes launchd-parented WebKit Networking, WebContent and GPU services, without
including unrelated WebKit instances. Every sample stores PID-level measurements.
The responsibility API is a private macOS API and may become unavailable; an error
must not silently fall back to an incomplete process-tree total. Samples are
sequential, not atomic; memory exits/permission failures invalidate the total.
CPU is process CPU-time delta over 30 seconds (100% = one core). Process churn
invalidates CPU rather than undercounting exited helpers. This does not prove
absence of idle timers.

Launch timing includes Launch Services, PID discovery and a small external
window probe; it is **not** interactive/cold-launch timing. No caches are purged.
Tests use background, hidden windows, not the spec's fullscreen environment.
The first run during an engine build is a smoke test, not a stable baseline.
Space timings from showcase are maximum synchronous layout duration, not GPU
presentation or animation smoothness. Ratios stay unavailable for incomparable
workloads; Chrome has no Space or Command Bar equivalent.

All launches use `open -g -j -n`; Airc uses snapshot mode because its normal mode
explicitly activates itself. The window probe hides only the observed test PID.
Chrome uses a fresh child of `OUTPUT/chrome-profile` and a separate user home.
The harness never launches Arc, sends app-name quit commands or reads owner profiles.
Cleanup signals only identity-checked PIDs belonging to this run. A whole-run
660-second watchdog and per-command/event deadlines bound work. SIGTERM/SIGINT
unwind through cleanup; SIGKILL cannot be cleaned up by any process.

## The app hook (implemented in apps/browser, Debug/PerfScenario.swift)

Add the following flags, keeping the existing snapshot background launch behavior:

```
--snapshot DIR --script perf --ephemeral --data-dir DIR
--perf-workload PATH --perf-events PATH --perf-control PATH
```

The perf script reads `workload.json`, creates exactly 3 profiles and 6 Spaces,
retains 30 entries, loads only the 8 `recent` entries (at most 20 seconds waiting
per page, then stop navigation), and keeps running without snapshots or periodic
UI work. Do not use showcase's 120-second auto-quit for this script; allow 660s.
Use a background safe control watcher and stop its timer during the idle sample,
or use filesystem events rather than polling. Do not focus/activate the app.

Append flushed JSON lines to the events path:

```json
{"event":"workload_ready","profiles":3,"spaces":6,"loaded_tabs":8,"unloaded_tabs":22}
{"event":"timings","interactive_ms":420,"space_frame_ms":12,"tab_paint_ms":35,"sidebar_ready_ms":150,"new_space_ms":7}
```

Numbers above illustrate the format, not measured results. Measure launch from
process start, interactions from input dispatch to actual presented frame, not
`layoutSubtreeIfNeeded`. Add `command_frame_ms`, `command_local_ms`,
`command_suggestions_ms`, `sidebar_hide_ms`, `sidebar_show_ms`,
`dropped_frames`, `idle_timer_count` and separate no-page profile deltas
(`empty_profile_mb`, maximum of three isolated deltas). Report refresh rate,
engine and sample distributions before certifying frame-based budgets.

After baseline memory and 30-second CPU sampling, the harness atomically writes:

```json
{"action":"leak","count":100,"url":"about:blank","page_timeout_seconds":20}
```

Open then close 100 **real engine tabs**, returning to the original workload,
release engine views and flush pending destruction. Emit:

```json
{"event":"leak_closed","opened":100,"closed":100}
```

The harness waits a further 60 seconds and compares all-process physical
footprint with the immediately preceding baseline (≤1.05). `about:blank` isolates
lifecycle leaks from network variability; add a second page-bearing stress test
later. MEM-3 needs a separate controlled timeout/pressure scenario proving the
visible/audio/unsaved-input exclusions and state restoration. MEM-6 remains
unknown until both idle CPU and timer absence are proven. MEM-4 needs verified
load outcomes and matched profiles before exposing a pass or a ratio.

## Validation

```sh
python3 -m unittest discover -s infra/perf -p 'test_*.py'
python3 -m py_compile infra/perf/*.py infra/status.py
bash -n scripts/perf.sh infra/nightly.sh
```

## First build-Mac smoke run — 2026-11-05 01:49 UTC

The release WebKit build completed successfully. The Chromium engine build was
running throughout; all acceptance budgets are **unknown**. The initial run used
Docs landing URLs; the checked-in workload now uses Google's public example sheet.

| Observation | Airc showcase | Chrome, 30 URLs |
|---|---:|---:|
| External first window | 544 ms | 653 ms |
| Early main-process physical footprint | 43.7 MB | 119.4 MB |
| Steady main-process physical footprint | unavailable | 207.6 MB |
| Sum of all measured processes | unavailable | 3811.4 MB |
| CPU over 30 seconds | unavailable | 3.06% of one core |
| Maximum synchronous Space layout | 6.2 ms | not applicable |

Airc exited before the 60-second sample, so no steady memory, idle CPU or leak
result was obtained. The 43.7 MB startup sample does not certify MEM-1's 150 MB
limit. The window proxy cannot certify the 500 ms interactive-launch budget;
6.2 ms synchronous layout cannot certify the 16 ms presented-frame budget.
MEM-2 (40 MB/profile), MEM-3 (unloading), MEM-4 (≤Chrome), MEM-5 (≤5% retention),
MEM-6 (<1% CPU and no timers), and every remaining speed-table requirement need
the instrumentation described above. All comparative ratios are unavailable.

The test main PIDs and sampled helpers were checked absent after completion.
The result JSON includes all 54 Chrome process footprints and the workload used.
Local safety/parser/event tests and status rendering tests pass (5 tests).

Largest risks: per-profile service duplication and the spare profile; retained
WebKit views/helpers after tab close; 22 background entries accidentally loading;
main-thread work hidden by synchronous layout-only timing; background throttling
making hidden-window measurements look better than foreground use. Concurrent
engine compilation, public-site variability, sequential memory sampling and
launch-probe overhead prevent interpreting this single run as a regression baseline.

## Repeated frame and 30-page checks

`frames.py --app build/Airc-Chromium.app --output build/frame-ab` alternates
baseline and optimized paths in the same test binary, five launches per side,
five actions per launch. `newspace` measures Create, `cbfirst` switches a loaded
tab 250 ms before each Command Bar opening, and `cbnew` reopens it without a tab
switch. Section timings are logged without the layout-counter swizzles or dirty
view census. The test-only `AIRC_NEW_SPACE_BASELINE=1` restores the earlier Create path.
`AIRC_COMMAND_BASELINE=1` restores Command Bar view-frame parking; the default
parks only the backing layer so AppKit can draw the contents at idle (see the
cold-opening pass below). The archived, reverted pruning experiment also used
this flag; its pruning is not present in either current path.
`--actions previewcache` fills the cache with 30 independent bitmaps
and checks retained decoded bytes, LRU eviction and the eight/zero pressure
trims (`AIRC_PREVIEW_BASELINE=1` selects the original 40-entry limit).
Results retain the frame
source: commit timing with an asleep display is not proof of 120 Hz presentation.

`memory30.py --app build/Airc-Chromium.app --output build/memory30-ab` repeats
five sequences of Airc with the original 40-entry preview limit and hidden-window
capture behavior, the 24-entry limit with hidden-window captures skipped, previews
off, and Chrome. The separate cache-fill control isolates the capacity change.
It seeds only the scratch `settings.json` (`tabPreviews`), loads the existing
30-URL workload, and uses `run.py`'s responsibility-based process census,
physical footprints, executable names and page checks (skipping the unrelated
30-second CPU interval). Chrome is sampled at the later Airc
sampling age and its version must stay fixed throughout. Both drivers stop if
HID idle is below five minutes. Public-site outcomes still need inspection;
a bot challenge with a title is not an equivalent page. The untouched memory
workload does not visit all tabs, so it does not fill a long-session preview
cache. Keep that distinction when interpreting previews-on/off results.
Memory runs require 15 GB free at the start and stop below 14 GB. Disk and HID
idle are checked every five seconds during each launch. Scratch profiles are removed after
identity-checked process cleanup, including on interruption. A complete steady
total requires every discovered process to be sampled and the process set to
remain unchanged; an exited helper in the independent startup census remains
a diagnostic and does not by itself invalidate that later total.

## Repeated app pass — 2026-11-06

Five interleaved launches per side, five actions per launch, same Chromium test
binary with action-specific baseline switches. Values are medians of launch
medians, with the min–max launch spread; hidden windows and asleep display mean
**CA commit timing**, not certified 120 Hz presentation.

| Action, ms | Baseline | Candidate at the time |
|---|---:|---:|
| Create Space | 8.44 (8.12–9.86) | 6.73 (5.77–7.36) |
| Command Bar after a verified tab switch | 6.95 (6.38–7.78) | 7.15 (6.13–7.38) |
| First Command Bar in each fresh process | 13.14 (12.04–15.17) | 13.06 (10.55–15.35) |
| Command Bar without switching tabs | 6.19 (4.33–6.90) | 6.70 (5.63–7.25) |

New Space skips a duplicate page reload/outgoing-palette chrome update, reuses
the provisional footer cell and defers covered-page/SwiftUI cleanup. Store work
was already deferred (0.05 ms median); add-page work falls 1.71 → 0.87 ms.
All 25 creates per side selected their Space and preserved footer order/icons.
Two candidate actions exceeded 8.3 ms (8.37 and 8.59): median progress is not a
strict one-frame guarantee. This test uses an existing selected profile; the
separate profile card already prepares/adopts a spare before Create Space.

Empty-query candidate pruning removed discarded computation, but these
Command Bar distributions overlap and do not demonstrate a speedup or establish
steady-state non-regression. It was later reverted; see the multi-window recheck.
Earlier five-pair passes were faster; the cold
first opening remains above budget. Font/index and explicit parked-view drawing
experiments were rejected and removed. A diagnostic cold-opening trace placed
8 of 11 main-thread samples in CA commit, including text/keycap drawing.

Preview capacity is now 24 keys, retaining the 640×400 px capture limit and
8/zero warning/critical trims. Five interleaved full-cache controls with 30
independent images retain **30.720 → 24.576 MB decoded**, with identical values
in every pair. LRU and pressure trim checks pass. Tab/item aliases count once
in decoded bytes. This establishes the cache saving, not a whole-browser
physical-footprint or MEM-4 improvement; the 30-page on/off comparison is separate.

## Multi-window recheck — 2026-11-07

The release testing app includes multi-window HEAD `8ccdc10`; the measured source
snapshot and working diff are retained with the evidence. Five interleaved A/B
launch pairs per action, five actions each, minimum observed HID idle 743 s.
Both engine app builds passed. No engine relink. Values below are medians of
five launch medians (min–max); the cold row uses the first opening from each
launch. These remain **CA commit timings**, with no presented-frame samples.

| Action, ms | Baseline A | Tested candidate B | Decision |
|---|---:|---:|---|
| Create Space | 9.58 (8.47–11.63) | 7.73 (5.82–9.70) | Retain B |
| Command Bar after verified tab switch | 6.50 (6.12–7.78) | 6.50 (6.20–6.75) | Retain A |
| First Command Bar in each fresh process | 12.12 (9.15–13.94) | 11.92 (10.91–13.34) | Cold target open |
| Command Bar without switching | 4.16 (3.90–5.24) | 4.93 (3.94–5.55) | Retain A |

New Space: store transaction 0.09 → 0.09 ms; build/claim sidebar page
1.46 → 1.44 ms; whole add-page path 2.56 → 1.51 ms. The duplicate reload
(0.39 ms median) disappears. The switch is 0.60 → 0.66 ms; background palette
work rounds to 0.00 on both sides. All 25 creates per side select the new Space
and preserve footer icons/order. Candidate p95 is 10.88 ms, maximum 10.93 ms,
with 6/25 actions over 8.3 ms. The median improved; the one-frame guarantee is
still open. This run uses an existing profile, not the separate Create Profile card.

Command Bar: all 100 timed openings entered make/add/focus. The short first
steady samples are real openings, not the toggle closing an already-open panel.
Empty-query pruning established neither a cold-opening improvement nor steady
non-regression, so `d015833` removes it. The retained baseline path was exercised
in every A launch above. Font/index warmup and parked-view drawing experiments
were also removed. The cold AppKit/CA drawing cost remains unresolved.

## Repeated 30-page census — 2026-11-07

Five complete interleaved quartets: original previews, current previews, previews
off, then the same Chrome 157.0.8103.38. One app runs at a time; every scratch
profile is removed immediately afterward. The Airc app (Chromium 156.0.8078.88,
build 202611062350) was pinned throughout. It predates multi-window; these memory
numbers do **not** certify the later frame build. Sampling starts about 70–83 s
after launch and ends about 101–116 s after launch; Chrome uses the later Airc
sample start. All accepted launches passed the five-minute HID guard and had a
complete, stable steady process census. Interrupted quartets were restarted.

Diagnostic summed physical footprint, decimal MB; median of five launches and
min–max spread:

| Variant | Total MB | Main process MB | Loaded-page count |
|---|---:|---:|---|
| Airc original preview behavior / 40 keys | 2823.26 (2748.65–2840.62) | 145.33 (143.97–145.54) | 29–30 |
| Airc current preview behavior / 24 keys | 2748.71 (2610.60–2781.49) | 145.33 (143.65–148.37) | 30 |
| Airc previews off | 2702.88 (2670.47–2736.84) | 143.97 (140.51–147.12) | 29–30 |
| Chrome | 2711.95 (2575.61–2750.36) | 204.68 (199.65–218.21) | 29 |

**MEM-4 remains unknown.** Reuters returned a different page in Chrome on every
launch and in some Airc launches; one BBC page also redirected differently.
Airc uses three profiles/six Spaces, Chrome one profile. Shared-machine load,
fixed within-quartet order and public-page variability remain confounders. Do not
turn these totals into a verified Airc/Chrome ratio or an optimization saving.

Every memory launch retained zero preview pictures and zero decoded bytes.
Original hidden-window picture requests were one per launch; current and off
were zero, with no successful pictures on any path. The guard saves a pointless
request; the census cannot establish a full-cache saving. The independent cache
control above still measures 30.720 → 24.576 MB decoded across five pairs.
The paired current-minus-original total is −74.75 MB median (−175.16 to −41.77);
previews-off minus current is −16.74 MB (−78.61 to +71.39). These are observations,
not causal preview savings, particularly with empty caches and different pages.

No WebKit helper appears in any of the 15 accepted Airc steady censuses.
The HybridEngine's WebKit side remains lazy in the audited source. Airc has one
NetworkService and one StorageService per launch, not one per profile. Renderer
footprints dominate: current Airc median 2433.95 MB (40–41 renderers), Chrome
2340.32 MB (41–42). Main-process Airc memory is lower; transient Metal compiler
services vary substantially. This comparison does not isolate profile overhead
or justify an engine change. The fresh-profile Boost CSS map is empty, so
installed-Boost costs remain unmeasured. No engine changes were made.


## Cold Command Bar layer parking — 2026-11-07

This supersedes the earlier unresolved cold-opening result. The existing idle
preparation already builds and refreshes a spare bar. Moving its NSView frame
outside the window clips AppKit's backing-store drawing. Keep its view geometry
in the window and translate only the backing layer, with implicit animations
disabled. Unparking restores the identity transform. The parked bar rejects hit
tests, has no accessibility children, refuses editing and registers no I-beam
cursor. No extra timer, bitmap cache, material or shadow was added.

The final implementation was measured in ten interleaved fresh-process pairs
for `cbfirst`, five for `cbnew`, and five for New Space, with five actions per
launch and alternating AB/BA pair order. Every launch was HID-idle for at least
300 s; the minimum observed for these frame runs was 12,626 s. Timings below
end at **Core Animation commit in hidden windows**, not display presentation.
Cold uses each process's first opening after a verified loaded-tab switch.
Other rows use medians of process medians; later openings exclude the first
sample. Parentheses are min–max process spreads.

| Metric, ms | View-frame parking A | Backing-layer parking B |
|---|---:|---:|
| First opening, ten processes per side | 12.34 (11.30–14.50) | 6.84 (4.90–9.01) |
| Later after-switch openings | 6.67 (5.11–7.65) | 5.40 (3.22–6.00) |
| Steady openings without switching | 6.33 (5.29–7.48) | 5.05 (4.32–5.88) |
| New Space, same existing optimization on both sides | 9.26 (8.92–11.11) | 9.56 (8.06–10.13) |

Every cold pair improved (paired reduction median 4.56 ms, range 3.73–7.84).
The first five-pair block was 12.66 → 8.63 ms; a fixed second block was
12.05 → 6.65 ms. Both blocks are included, not replaced by the faster one.
Three of ten candidate cold openings remain above 8.3 ms. This establishes a
median commit-time improvement, not a strict one-frame presentation guarantee.
All 150 timed Command Bar actions entered make/add/focus. New Space's paired
median difference was −0.09 ms, with overlapping spreads; all 25 creates on
each side selected their Space and preserved footer order/icons. Its strict
one-frame target remains open on both paths.

Five fresh-process idle pairs used the reference 3 profiles, 6 Spaces, 8 loaded
and 22 unloaded tabs. Each waited for the page report, settled 30 s and measured
CPU over 30 s, then sampled physical footprints. All eight page outcomes
matched within every pair, were hidden, and reported zero animation frames;
all CPU and memory process sets were stable. CPU is percent of one core, summed
across owned browser processes; memory is decimal MB.

| Idle metric | A median (min–max) | B median (min–max) |
|---|---:|---:|
| CPU % | 0.266 (0.200–1.264) | 0.266 (0.166–0.465) |
| Main footprint MB | 80.11 (79.27–83.78) | 80.32 (80.01–80.95) |
| Total footprint MB | 532.99 (530.56–537.16) | 533.69 (528.10–535.17) |

No idle CPU regression was observed; footprint distributions overlap. The
control's 1.264% outlier is retained. These are Airc regression checks, not a
new Chrome/MEM-4 comparison. An interrupted idle pair was discarded in full
and replaced with one fresh pair; the other four complete pairs were retained.

Both app engines built in release mode, linking the existing release framework
for Chromium. Native view-rendered images of the open, URL-editing and parked
bar were pixel-identical between A and B. A parked bar also rendered identically
to a hidden control. Ten functional checks per side passed, covering hit tests,
accessibility, first-responder preservation, typing, closing and URL editing.
A matched diagnostic trace sampled CA commit in 4/7 cold control stacks and
2/6 candidate stacks; action/keycap drawing appeared only in the control's
cold samples. These coarse profiler samples are diagnostic, not the timing
comparison. No engine build, focus activation, HID posting or screen capture
was used. The fallback before idle preparation and actual foreground 120 Hz
presentation remain outside this measurement.

## Missing-budget probes (`gaps.py`)

Build the test app from a clean source archive plus the probe changes, then run:

```sh
python3 infra/perf/gaps.py --app build/Airc-Chromium.app --output build/gaps --runs 5 --samples 5
```

The driver starts a fresh process/data/home for every action and repetition. It
uses the UI-check lock (refuses its timeout fallback), `open -g -n -W`, and checks
HID idle ≥300 s and free container space ≥14 GB before launch and every second.
Activity or low space aborts the sequence and retains completed evidence. Resume
in a fresh output directory; do not pool different binaries. The process cleanup
uses the existing responsibility/identity census. Remove the task work folder
only after exporting its results. No engine build, HID events, screen capture,
camera or microphone is needed. `--profile --actions ACTION --runs 1 --samples 20`
adds a separate diagnostic `sample` stack profile; never pool it into acceptance.

`gaps.json` retains binary SHA-256, per-launch guards, every sample and budgets.
Three or more completed launches are required for acceptance. Summaries are
medians of process medians and their min–max spread; first Command Bar opening
uses only the first opening in each process. Strict limits check every sample,
not only the headline median. Incomplete evidence remains unknown; a verified
failed component can fail a composite requirement without its other components.

- **swipe:** uses the pager's `track` phases, 24 updates then release, records raw
  display-link timestamps and missed vsyncs against both observed and 120 Hz rates.
  A 60 Hz/asleep display cannot certify 120 Hz. Callback gaps are a main-thread
  presentation proxy, not GPU fence measurements.
- **feedback:** calls the visible loaded tab row's native `mouseDown`, checks its
  pressed state, then releases it. Records commit and next display timestamp.
  This certifies the press case only, not hover or every selection path.
- **sidebar:** measures key action to `sidebarFraction` endpoint (tolerance .001),
  with a bounded 1 ms poll. Raw hide/show durations retain observation overhead.
- **command:** first opening after a verified loaded-tab switch; synthetic tab and
  history matches checked against the keystroke commit; loopback suggestions go
  through the production service's debounce, parsing and row application. A
  test-only URLProtocol redirects Google suggestion traffic to the driver's local
  server. Unique queries avoid cache hits; request counts prove interception.
  Suggestions include up to 1 ms row-observation overhead, not WAN latency.
- **MEM-3:** reuses the keep-loaded fixture pattern, 2 s timeout override, trusted
  DevTools form input, almost-silent synthetic WebAudio, shown/pinned/Favorite
  exclusions, real engine pressure hook, two eligible tabs for LRU ordering,
  and title/favicon/scroll restoration. The JSON includes fixture verification;
  no hardware media permissions. This is a synthetic Chromium check, not a
  real 30-minute wait or a mixed-engine acceptance suite.
- **MEM-6:** deterministic no-media pages, 3 profiles/6 Spaces/30 tabs/8 loaded,
  30 s settle then 30 s all-responsible-process CPU (100%=one core), stable process
  census required. The `census` control action captures the main CFRunLoop's
  description before CPU sampling, deduplicates timers across modes, and retains
  the raw text, intervals, next-fire offsets and count due within 30 seconds.
  Positive intervals include parked framework timers and must not be read as
  evidence of frequent wakeups. It includes framework timers, not just the archive
  timer previously exposed as `idle_timer_count`. Dispatch queues and engine
  worker timers are outside this census: nonzero fails literal timer absence;
  zero cannot prove global absence. CPU over budget gets a hottest-process
  `sample` profile; a nonzero timer census also captures a main-process profile
  when CPU is under budget. Run-loop description format changes leave the count unknown.

To display a reviewed result, copy its `gaps.json` to
`STATUS_DIR/perf-gaps/gaps.json` and regenerate `infra/status.py STATUS_DIR`.
The renderer recalculates budgets, links the evidence, shows timestamp and binary
hash, and labels these separate probes. It never fills missing values with zero
or silently merges these synthetic runs into a nightly reference workload.

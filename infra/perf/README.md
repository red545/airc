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

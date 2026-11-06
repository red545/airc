# Engine pass 7: page commands, shortcuts, discard and idle diagnostics

The implementation stays in `engine/` and the Chromium Swift adapter.
`app-pass7.patch` is the exact **unapplied** main.swift diff. It removes argv
allocation from the app; `ChromiumRuntime.run(arguments:started:)` owns the strings
for the lifetime of ChromeMain. The default argument preserves existing callers.
`extension-protocol-request.patch` is an optional **unapplied** protocol diff,
including WebKit defaults. No protocol change is necessary for page commands or
CB-3: both requirements already exist in BrowserEngine.swift.

## Page commands

ChromiumTab now overrides the protocol defaults for cache-bypass reload,
zoom in/out/reset, DevTools, console, find and system print. Find completes on the
final Chromium find result, with `(found, matches)` as expected by FindBar.swift;
stopFinding cancels its retained completion. View Source already opens a
`view-source:` URL through the app's existing navigation shortcut.

DevTools dispatch alone does not present its docked native view. The adapter
hosts that view in a resizable owned Developer Tools panel, closes the core tools
on dismissal/tab close, and supports the console command. View discovery is a
bounded startup retry, not a recurring idle timer. Print dispatches IDC_BASIC_PRINT
(35007), keeping the native system path rather than Chrome's Views print preview.
Native print completion is not implied by the returned dispatch boolean.

## Extension UI request for the app agent

Use these concrete ChromiumEngine methods (or adopt the supplied protocol diff):

- `installedExtensions(for:)`: profile-scoped id/name/version/enabled inventory.
- `extensionActions(_:for:)`: action state keyed by extension ID; title, enabled,
  PNG data URL `icon`, badgeText, badgeColor and badgeTextColor.
- `extensionActionIcon(_:)`: decodes that PNG locally into NSImage.
- `executeExtensionAction(_:for:)`: returns `popup`, `sidePanel` or `none` and
  performs the action/activeTab grant.
- `presentExtensionAction(_:for:anchorRect:in:)`: **performs the action itself**
  and presents its popup in the core's profile-bound native panel. Never call
  execute followed by present: that would execute twice. False means no popup;
  an onClicked action can have successfully run. Rect is in the supplied view's
  coordinates and must lie inside its bounds and the owning window.
- `closeExtensionPopup(in:)`: dismiss on teardown or URL-field UI dismissal.

Draw pinned enabled actions in the URL field on hover; use the title as accessible
label/tooltip, the decoded icon and the badge text/colours. Persist pinned IDs per
profile; never use a tab from another window/profile. Requery on hover, tab switch,
navigation and extension-menu opening. The core does not yet publish an action
state-change observer; do not add an idle polling timer to compensate. The puzzle
menu should include unpinned installed extensions and chrome://extensions.
Side-panel actions remain a separate product surface, not an implemented popup.

## CB-3 keys

AircTabDelegate adds `tab:didReceiveShortcut:pageUsedIt:`. TabBridge observes
RenderWidgetHost input acknowledgements, including child-frame widgets and new
renderers after navigation. Only keydowns with Command/Control are reported;
`kConsumed` is true. This is Chromium consumption, not a guessed JS handler.
Widgets unregister on destruction. The adapter exposes `reportsPageShortcuts=true`
and forwards the existing EngineTabDelegate callback. It defers delivery one main
queue turn so AppKit's native unhandled-key menu path can cancel the pending app
command before the false acknowledgement arrives (no duplicate command).
The existing KeyMonitor retains ownership of the one-second second-press rule.

## Discard

Hiding the NSView could emit WasHidden before the host visibility bit changed.
The memory observer saw the old `shown=true` bit and stopped its timer. The later
WasHidden was a no-op. Host visibility changes now explicitly reschedule the
one-shot after updating the authoritative bit. Actual renderer user edits remain
protected by PerformanceManager. Timeout discard also checks current form values
in each live frame's isolated world, preserving script-restored input that PM does
not classify as user interaction. Unknown/failed checks retain the tab; navigation
invalidates in-flight checks. No repeating retry was added.

## Startup CacheStorage warnings

In M156 `CacheStorageManager::OpenCacheStorage` calls `try_emplace` before
`CacheStoragePathIsUnique`. The latter iterates that same map, including the just
inserted key, and compares its path with itself. The warning therefore fires for
a fresh insertion with DCHECKs enabled. It is not evidence of duplicate Airc
profiles or a blocked cache scheduler. No storage deletion or new upstream patch
was used to hide it. Genuine bucket replacement collisions are still possible;
the warning as written cannot distinguish them.

## Idle diagnosis

`perf/idle.py` launches isolated app data with open -g, waits for the app's perf
scenario to finish its work, then samples process and per-thread CPU deltas. Its
static variant preserves 3 profiles/6 Spaces/8 live pages/22 model-only tabs but
substitutes static data URLs. `--public` retains the reference URLs. It samples
before enabling optional CDP tracing, so tracing overhead does not contaminate
CPU numbers. `perf/threads.c` uses libproc (no task_for_pid, sample or spindump).
`perf/trace-summary.py` groups task execution by posting site. Process identity
and churn are recorded; a churned interval is not a complete CPU comparison.

Chromium unbranded builds enable periodic stack profiling at 100%. The browser's
StackSamplingProfiler thread dominated the first static idle sample. The new
`quietProfiling` switch disables that unused telemetry collection with upstream's
`disable-stack-profiler`, in CreateThreadPool **before** Chrome constructs its
profiler (BasicStartupComplete is too late). Roll back with
`--airc-switches=quietProfiling=off`. Pass 6's seven switches are unchanged.

## Validation (build Mac, locked display)

Both app variants were built using `scripts/build-app.sh --snapshots build/snapshots`.
That first run reproduced the original ENGINE-FAIL. After fixes, the rebuilt
Airc-Chromium.app was run with `--script events` in a new isolated snapshot home:

```text
PASS prefer website: the first ⌘D goes to the page (title used, pinned false)
PASS prefer website: ⌘D again within a second pins the tab
PASS prefer website: ⌘L, which the page doesn't use, opens the Command Bar
ENGINE-PASS unload (MEM-3): hidden tab freed true, tab with typed input kept true, visible tab kept true
PASS unload (MEM-3): the freed tab loads again when shown
```

The separate adapter test now checks actual zoom factors, matching/no-match find
counts, reload removing a JS marker, and visible DevTools/console panels with
attached content, as well as the existing profile and renderer-snapshot checks:

```text
PASS Swift adapter: two profiles, switching, evaluate, snapshot, deactivateAll, zoom, find results, cache-bypass reload, DevTools and console panels
```

The engine incremental build succeeds. Both supplied app patches pass
`git apply --check` without being applied. The system print operation is wired,
but a native print sheet/printed output was not qualified on the locked display.
View Source uses the existing app path; it is not covered by the events scenario.
Extension popup/icon APIs compile, but visible URL-field drawing belongs to the
app agent; this pass does not claim new interactive extension acceptance.

The first stable static comparison (fresh roots, 60 s settle after perf timings,
30 s CPU interval, trace collected afterwards):

| Metric | Saved pre-change app | This pass |
|---|---:|---:|
| Main physical footprint, decimal MB | 151.29 | 148.10 |
| Whole process-tree CPU, one-core percent | 0.481 | 0.185 |
| Browser-only CPU, percent | 0.329 | 0.121 |
| Interactive launch timestamp, ms | 348.60 | 347.97 |

Both intervals had stable process sets. Before: StackSamplingProfiler alone used
0.168% CPU. After: no sampler thread in the raw thread inventory; browser main
thread cost stayed approximately 0.05%, and summed thread deltas (0.175%) agreed
with process counters (0.185%) within sampling/thread-lifetime overhead. The
process-counter timebase was separately checked against getrusage (ratio 1.001).
These are individual warm-machine launches with fresh profile roots, not cache-
flushed cold-launch statistics. They pass the numeric memory/CPU budgets for this
static diagnostic; they do not establish the public-workload or literal no-timers
requirements by themselves.

Ten seconds of post-measurement task tracing still sees 30 s disk-cache upkeep,
30 s tab-strip scrubbing metrics, 120 s resource-attribution queries, the retained
60 s disk-space check and 120 s security-cache cleanup. Profile-size logging at
112 s and credential/database work at 120 s are startup one-shots, not recurring
idle timers. Perfetto tasks in the trace are diagnostic overhead and are excluded
from CPU measurement. Security cleanup was not disabled to improve a benchmark.

Public reference URLs, same 60 s settle and 30 s interval:

| Metric | Saved pre-change app | This pass |
|---|---:|---:|
| Main physical footprint, decimal MB | 170.10 | 162.45 |
| Whole process-tree CPU, percent | 1.954 | 0.721 |
| Browser-only CPU, percent | 0.352 | 0.249 |
| Interactive launch timestamp, ms | 1018.56 | 274.31 |

MEM-1 **still fails** on the public workload: 12.45 MB over the 150 MB budget.
MEM-6's numeric CPU threshold is met in the after sample; its literal zero-idle-
timers clause is not. The launch sample is under 1 s after the change but this is
not a cold-launch guarantee. The original app3 observations (157 MB / 2.1% /
839 ms) were from a different run, so do not subtract these after numbers from
those and claim a controlled saving. Public content, service startup, machine
state and Chromium's probabilistic child-process profiling change between runs.

Both public intervals had stable process sets, but the Computer_memory Wikipedia
renderer failed the post-measurement CDP responsiveness probe in both runs; the
other seven pages reported complete without Chromium error pages. This limits
full browser qualification. In the before run the GPU's StackSamplingProfiler
alone used 0.259% CPU; browser main was 0.109%, while renderer pools supplied most
of the remainder. After, GPU total was 0.009%, browser main about 0.060%, and a
renderer supplied 0.330% of the total. Thus the old 2.1% was not all browser-loop
work, and the public-page improvement cannot all be attributed to one switch.

Remaining memory work needs allocation attribution for the public-page browser
heap/profile services; the measured profiling fix removes a real idle cost but
does not bring that workload under 150 MB. No security service, component update,
site isolation or real page functionality was disabled to force a budget pass.

Reproduce from a synced checkout on the build Mac (use fresh output directories):

```sh
engine/build.sh --run
scripts/build-app.sh --snapshots build/snapshots
engine/host/build.sh build/pass7-host
caffeinate -d -t 90 engine/tests/adapter.sh build/pass7-host/AircHost.app build/pass7-adapter
caffeinate -d -t 300 python3 engine/perf/idle.py build/Airc-Chromium.app build/quiet-on --settle 120
caffeinate -d -t 300 python3 engine/perf/idle.py build/Airc-Chromium.app build/quiet-off --off --settle 120
# Retain the reference URLs instead of static replacements:
caffeinate -d -t 300 python3 engine/perf/idle.py build/Airc-Chromium.app build/public --public
```

Run builds, events, acceptance and performance sequentially. `--off` means the
seven **pass-6** groups; the new profiler suppression stays at the same default
on both sides when the current app is used. JSON records the exact launch flags.
`--trace` collects task traces after CPU measurement; it is deliberately omitted
from the final matched switch pair. The runner terminates only its recorded test
processes and uses new data roots. Nothing is installed system-wide or pushed.

Final matched pass-6 switch comparison, **same current app**, profiler disabled
on both sides, fresh static workloads, 120 s settle and 30 s CPU interval:

| Pass-6 groups | Main MB | Whole-tree CPU % | Launch ms |
|---|---:|---:|---:|
| All seven on | 155.93 | 0.114 | 708.99 |
| All seven off | 197.31 | 0.147 | 383.59 |

Both process sets were stable, all eight pages responded, and neither complete
thread inventory contained StackSamplingProfiler. Keep pass 6: approximately
41.4 MB less main-process footprint in this pair, with only a small CPU difference.
The shorter original-build all-off probe was 180.72 MB / 0.402% with process churn;
its longer repeat was 180.11 MB / 0.149% without churn. Those are diagnostics, not
clean estimates of a CPU effect. The matched pair controls the profiling confound.
The longer all-on result also exceeds 150 MB, confirming that the earlier 148.10
MB point is not a robust memory-budget pass. Launch variance remains substantial.

Final app event log: **26 PASS, 1 ENGINE-PASS, no FAIL/ENGINE-FAIL**. The existing
AircDesign canary remains explicitly reported as expected; it is outside engine
ownership. Evidence includes before/after raw process/thread counters, task traces,
page outcome probes, paired-switch results, event logs and adapter output. All
work is committed locally in small owned-path commits; nothing was pushed.

DevTools renderer-surface captures were inspected: `adapter/devtools.png` shows
Elements with the fixture DOM, and `adapter/console.png` shows the Console prompt.
Whole-window readback was black under the locked display, so it is not used as
visual evidence. `attachDevTools(to:)` now uses the core host-attachment path to
set both native-view and WebContents visibility, and `copyDevToolsPicture` supplies
the surface check. The inspector is usable in an owned native panel; Chromium's
docked frontend still reserves an inspected-page placeholder area in that panel.
Full docking/undocking/layout parity remains unqualified. Foreground shortcut
opens focus the panel; background test launches do not activate the app.

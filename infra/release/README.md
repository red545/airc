
## Background suite and qualified candidates

`infra/suite/install.py --repo OWNED_CHECKOUT --remote ORIGIN_URL --status STATUS --queue QUEUE [--hours 6]`
installs a Linux user timer for main's full suite on the dedicated build Mac. It
also runs nightly at 01:15 UTC. The held legacy nightly, ship loop, engine kick
and laptop maintenance cron entries must stay held. This worker never publishes,
relinks, installs the UI driver or accesses the owner laptop.
The six-hour cadence starts after a completed run. An interrupted or failed
attempt restarts after 60 seconds; while release/quiet/relink/priority markers
exist it waits without a Mac lock and writes `suite/scheduler.json` with the
exact hold. Clearing a hold therefore resumes within a minute, not six hours.
Exit 75 must remain a failure for systemd's `Restart=on-failure`: a oneshot
successful exit is not restarted, even with `RestartForceExitStatus`.

The first invocation waits for queue.md's post-0.1.5 histsugg QUIET CLOSED,
touchpasskeys REBUILD NOTICE and ytads REBUILD NOTICE, in that order. It runs six
bootstrap cases (three per engine), then the full inventory. The bootstrap is
never a qualified run. Runs export origin/main, compare engine inputs to the
ready marker, test every Swift package, build both engines and execute the
canonical build-app.sh scenario function's inventory plus perf on both engines.
The inventory is evaluated with a recording launcher; no hand-maintained subset.
Media permission tests remain disabled. Fixtures survive dependent relaunch cases:
the canonical snapshot directory is shared within each engine, while each case
archives only its appended log and changed evidence files after releasing the lock.

Every build step takes the Linux and Mac build locks; every UI case takes and
releases the Mac UI lock.
Both Mac lock waits join the blocking kernel queue instead of polling for an
idle gap. Each case releases the lock before evidence copying and requeues for
the next case, allowing queued agents to interleave. A case-level environment
refusal is recorded and the remaining inventory continues; it cannot qualify.
All four priority markers are checked before work and
after lock acquisition. The coordinator revokes the worker's lease if any marker
appears or the engine-ready marker changes. EOF or 15 seconds without a heartbeat
also aborts, with exact-launch app cleanup before unlocking. Lock refusal and
partial runs stay unqualified. Logs and immutable attempts live under
`status/suite/<revision>/<attempt>/`; `summary.json` is the latest attempt.
During a run, `current_step` identifies the package, build or UI case;
`waiting_on` distinguishes the Linux build lock, Mac build/UI lock, transfer
and cleanup from active execution (`null`). `waiting_since`, `step_started`
and `updated_at` explain long waits even before the first UI case. Terminal
receipts clear the wait and retain `last_step` for interrupted runs.

A **qualified candidate** is the newest tested main revision with a complete
background suite and no unapproved reds. Currently this implementation accepts
no waivers: all cases and package/build steps must pass, including both engines.
ENV, missing cases, dry runs, crashes, hangs and no-PID results cannot qualify.
`status/suite/qualified.json` identifies that revision; `last-green.json` records
the last fully green revision. `latest.json` reports current counts, new reds and
critical crash/hang/no-PID cases, shown above the parity and work pages.
Critical warnings survive new or aborted attempts until that exact case passes
a later run. Removing a case from the inventory does not waive its crash.
They come from failing assertions, receipt failures and watchdog evidence, never
from scenario names or paths. Each case also records its worker exit status.
A preflight-only PASS, refused worker or missing completed launch cannot count
as a passing case. Outer worker deadlines are critical even if the app wrote
some passing assertions before it stopped progressing. Qualification requires
every case's worker to have exited successfully as well as a passing receipt.

The release agent may freeze the qualified revision rather than current main.
It must still run the release fast gate against that exact cut and matching
engine. The background suite never becomes a synchronous release-time gate;
known crash/hang reds still stop a release, including a critical latest run
newer than an older qualified pointer. Inspect latest.json as well as the pointer.
A new full run does not erase earlier attempts or turn a partial run green.

Local coordinator tests: `python3 -m unittest discover -s infra/suite -p 'test_*.py'`.
Timer logs: `journalctl --user -u airc-background-suite.service`.
Stop it with `systemctl --user stop airc-background-suite.timer airc-background-suite.service`.

The scheduler owns a separate clone marked in `.git/airc-suite-owner`. Each dry/full run fetches origin, detaches that clone at origin/main, and executes its run.py and engine-inputs.sh. The shared working tree is never read for source or scripts. Existing unmarked checkouts are refused, never reset. An outer scheduler lock protects the checkout across both runs.

The Mac worker selects Xcode's SDK explicitly (`DEVELOPER_DIR` and `SDKROOT`),
matching the app/release wrappers; the direct compiler and SwiftPM may otherwise
resolve FoundationModels differently. Each owned step uses caffeinate. Normal
build waiters join the kernel queue, but a release/quiet/relink/priority marker
interrupts the wait. Cleanup tracks exact descendant PIDs and birth identities,
including children that create new sessions. The coordinator waits for an explicit
worker cleanup acknowledgement before removing its export. A missing acknowledgement
or removal error is retained as an error, never a successful cleanup receipt.
The installed service uses KillMode=mixed so the scheduler can wait for its child's
cleanup when stopped. Do not delete the dedicated checkout's ownership marker or
point --repo at a shared worktree; unmarked existing directories are refused.


After a clean preemption, retries resume the same pinned revision when the engine
marker and suite runner SHA are unchanged and the saved executable bundles still
exist and match their hashes. The runner SHA covers the coordinator, worker,
inventory recorder, UI gate, engine-input guard and launch helpers. App source
and build-app.sh belong to the pinned build and saved inventory, so new app
scenarios on main alone do not invalidate a checkpoint. Completed cases are retained; the
interrupted case runs again. `latest.json` names the pinned revision and says
"resumed after preemption"; `current_main` records the newer fetched revision.
Each retry still fetches main into the scheduler's exclusively owned checkout.

Checkpoints live on the Linux host under `status/suite/checkpoints/`, with an
atomic `checkpoint.json` pointer. A checkpoint commits the completed case and its
profile/shared-fixture state together after app cleanup and UI unlock. Restoration
rolls back changes from the interrupted case, including paired write/read fixtures.
The Mac export is removed on preemption; only the Linux cache retains the pinned
bundles. Per-invocation cleanup receipts and interrupted logs remain in `segments/`.
A failed cleanup cannot authorize resume. Checkpoints older than 24 hours from
their first creation are discarded, as are changed engines/runners or missing
builds; the next attempt starts fresh from main. Preemption before both builds
finish also starts fresh. After all cases complete (green or red), the checkpoint
is removed and the next scheduled run selects current main. This does not waive
any red or change the release fast gate.

Background shutdown policy (lead approval, 2026-11-13): `SLOW-QUIT` at 3 seconds
is a warning. A 9.5-second line or Chromium's `Teardown watchdog expired` is a
severe-quit warning, red when its observed 1-minute load is below the host's core
count, or when three distinct cases report severe quits in the same full run.
Both signals from one quit count once; checkpoint resumes retain the count and
the third occurrence also escalates the earlier two cases. Missing load evidence
cannot excuse a severe quit. The worker samples these lines with load/core count
while the app runs and archives `shutdown.json`, app stdout and stderr per case.
Both status pages list every observation, load, and escalation reason.

Only a Chromium launcher exit 2 corroborated by its teardown-watchdog stderr can
be classified as this approved warning. Raw gate receipts and exit codes remain
available; assertions, other exit codes, crashes, independent watchdog failures,
and environment errors keep their original classification. The release fast gate
is unchanged and may enforce a stricter result.

### Background suite priority

The background suite is always below agent work: before every package/app build
and every single UI case it checks for peer lock contenders, takes the lock only
nonblocking, and checks again after acquisition. Linux uses `lslocks` waiter
records; on the build Mac, `lsof` conservatively treats any other process with
the lock file open as a contender. It never queues ahead of agents. Contention
returns 75, performs normal cleanup/checkpoint preemption, and retries after
60 seconds. Release, quiet, relink and priority-build markers still preempt it.

After six hours of contention without a completed case, retries wait for
00:00–06:00 UTC. Nighttime does not bypass peer waiters or priority markers.
The persistent `suite/low-priority.json` records the first deferral and reason;
`suite/scheduler.json` exposes the overnight hold. A completed case resets the
starvation clock. Checkpoint validation, pinned revision, interrupted-case rerun
and the 24-hour expiry remain unchanged. Changing the runner itself invalidates
older checkpoints under the existing runner-SHA rule.

## Link to paint (`linkpaint.py`)

The signed build's window timeline (each release's `timeline.py`, modes `late` and `atlaunch`) times windows only. In
0.1.18 a link opened while Airc was closed showed Little Airc in 0.8 s and painted its page at 5.3 s, and no gate saw
it. `linkpaint.py` times the page itself, black-box, on any build (signed or test):

    python3 infra/release/linkpaint.py --app NEW.app [--app PREVIOUS.app] --engine chromium|webkit \
        --pages PAGES_DIR --out OUT_DIR [--runs 5] [--budget 1.0]

- A loopback page with a paint beacon (infra/perf/arcbench_page.js, its first-contentful-paint) is handed to the app
  through Launch Services while the app is closed, so the link launches Airc and opens Little Airc, as a link from
  another app does. Times are seconds from the `open` call: window, page script, first paint.
- Per app: one plain launch with a fresh data folder (stays until its blocking rules are compiled), then `--runs` link
  launches with that data. **Gate:** median paint ≤ 1.0 s, no run over 2.0 s, every run painted, no new crash report.
  One more link launch with a brand-new data folder (first launch ever) is reported, not gated: its rules are compiled
  once before any page may load (WebKit ~4 s).
- `--pages` is an arcbench mirror (pages.json + pNN/site); only the first page is used.
- Each row also has `before_main_s` (process start → Airc's `main`, from the app's own LaunchTimeline) and the
  verdict counts `slow_before_main` (> 0.5 s). On the build Mac about half the launches of a Chromium build spent
  0.6–1.3 s there in Nov 2026, before any app code, with or without the fix (artifacts/linklaunch/REPORT.md); a FAIL
  made only of such runs is the system's start, not a page wait, and the release report says which it was.
- It's a timing run: inside the strict UI lock in a dedicated session, with status/timing-run declared by the
  Linux coordinator; the load average is recorded per run. Exit 0 pass, 1 over budget or no paint, 2 setup error.

Release order: run it on both engines next to `timeline.py late/atlaunch` on the signed stage, with the previous
published build as the second `--app`. It isn't part of the fast gate (fast-gate.json, prepare-fast-gate.py and
FastGateCheck.swift are unchanged, so fast-gate reuse is unaffected); a release states its verdict in the signed-build
timeline section and stops on a FAIL like a window-timeline regression.

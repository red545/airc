# Infra

Nightly build and status page scripts for the build Mac.

### Locked-screen UI gate

Ship runs check `CGSSessionScreenIsLocked` before building, again immediately before
snapshots, and after acquiring the shared UI-check lock for every launch. A locked
start records **waiting: screen locked**, exit 75, with no UI launch or publish.
The ship loop retries the same revision every three minutes. Restart the loop after
updating its script; replace the file atomically, never rewrite its running inode.

`ui_gate.py` samples the session every 0.5 seconds during each launch, independently
of the app's main thread and display link. `ui-gate.json` records UTC first-observed
lock times and observed durations (lower bounds), scenario times, raw failure
messages and their classifications. The nightly copies this to the run directory.
Raw snapshot logs remain unchanged. A lock-tainted scenario is ENV even if all of
its assertions passed: it cannot supply green evidence for publishing or release.
An unlocked scenario's failure remains red even if another scenario saw a lock.
SnapshotRunner timestamps each failure with its lock state, so a later lock in
the same scenario cannot excuse a failure already observed while unlocked.
A missing/unreadable lock probe also prevents publishing.

Independent failures win over lock exposure. Use `FAIL [independent] ...` or
`FAIL-INDEPENDENT ...` for assertions inside UI checks that do not depend on drawing;
`ENGINE-FAIL`, unit/model assertions, crashes and absent scenario logs stay red.
Package-test and compilation failures always stay red. Existing non-lock FAIL-ENV
handling (for example pasteboard interference) is unchanged. Exit 75 is never a
successful `build-app` step, so release green-evidence selection rejects it too.

Run `python3 -m unittest discover -s infra -p test_ui_gate.py -v`. To replay historic
logs without committing private data, set `AIRC_LOCKGATE_REPLAY_RUNS` to a local
status/runs folder. `python3 infra/ui_gate.py replay RUN/build-app.log` emits the
classification (75 for ENV). Historic logs have no lock timestamps; the replay
explicitly reports timing unavailable and only reclassifies recognized drawing
errors. It does not change the original run or make it release-eligible.

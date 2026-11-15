# Fast release gate

`fast-gate.json` is the release-time test inventory. The Python runner enforces a
600-second wall-clock limit, prints elapsed seconds and stops at the first red.
Build and distribution work are separate. A release never inherits another
release's failing-assertion waiver.

Prepare a **clean git archive** of the frozen application commit, then run
`python3 infra/release/prepare-fast-gate.py EXPORT`. This adds a test-only composite
scenario and shortens PiP repetitions (three same-player reentries, two of the
other race forms). Onboarding runs its first-run path, with real PID-targeted close
keys; re-import permutations and screenshots stay in the full suite. All four
overlay hashes are recorded. It changes no product
implementation and must never be applied to a public-build export.

Build both test engines on the build Mac under the normal compile locks. Run:

```
AIRC_UI_DEDICATED_SESSION=1 AIRC_UI_LOCK_STRICT=1 AIRC_UI_COORDINATOR=1 \
  python3 scripts/ui-check-lock.py python3 infra/release/fast-gate.py \
  --revision FROZEN_COMMIT --out EVIDENCE_DIRECTORY
```

The Linux coordinator must recheck quiet/relink holds and the engine marker
before replying `RUN` to the lock handshake. Refusal means no launch. The test
clock starts after lock acquisition; it includes fixture startup and final crash
audit. The local sharing server uses an existing Node installation (`AIRC_NODE_PATH` can select it).
The UI driver is read and invoked only, never built, replaced, or re-signed.
Each PID-targeted key waits up to eight seconds for Launch Services to register
the live process. The outside runner sends the key and returns an atomic response;
any driver rejection ends the scenario immediately. Full-screen exit requires a
confirmed entry and an acknowledgement of the real green-button click.

Nine launches replace the historical 54-launch inventory. Both engines exercise
HTTP/HTTPS, Notes create and read after a relaunch, PID-targeted real Option-Command-N,
a real green-button fullscreen exit, local sharing, rapid PiP, and first-run
onboarding. Chromium also runs redirects with blocking on/off and the independent
native History verifier. Each launch has a hard timeout, exact executable/argument
PID ownership, an outside PID/exit-status watch and pre-termination sample on failure.
Darwin's process events must show an exit status of zero for every app PID; an
`open -W` return alone cannot prove clean termination. Missing
logs/PIDs, FAIL, FAIL-ENV, SKIP, leftover apps, and new crash reports all fail closed.
The installed driver hash must be unchanged.
Exit records include the step and kernel status. A normal scenario finish is
reported as a clean exit, while missing status or abnormal termination stays red.
After the launcher returns, the runner allows up to five seconds (within the case
deadline) for a fresh empty PID sample, kernel exit status zero and the scenario's
finish marker. A PID sampled just before termination is not a hang by itself.
The final crash audit checks both user and system DiagnosticReports directories.

When developing this gate, keep every attempt in a new evidence directory. Require
three consecutive complete nine-launch passes on unchanged builds and runner,
then run a separate full gate for release qualification. Development timings are
reported separately; they do not replace the counted gate. Investigate each red
before another run. A product crash, non-runner signal/nonzero exit, or hang stops
development and release; a later passing rerun cannot clear it.

The full unit, feature, performance and long repetition suites belong in continuous
qualification on main (separate follow-up). Passing this gate is not a claim that
those suites passed. Signing, app/DMG notarization and stapling, Gatekeeper, mounted
privacy scan, stable identity and EdDSA continuity, a real previous-release delta
built/applied locally, and public install smoke remain mandatory distribution
checks. Actual automatic-update network proof remains separately recorded.

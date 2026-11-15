# Actual Sparkle proof defaults

Run the published app proof under `scripts/ui-check-lock.py`, wrapping the proof
command with `infra/release/update-proof.py --domain <bundle-id> --evidence <new-dir> -- <proof-command>`.
Use an unmodified published app in a scratch installation and synthetic data.
`CFFIXED_USER_HOME` and `--data-dir` do not isolate the Sparkle check timestamp:
cfprefsd can retain the bundle's `SULastCheckTime` and silently suppress a check.

The wrapper snapshots and clears only that timestamp, then restores its original
value (or absence) even when the child fails. It leaves other defaults intact and
does not restart cfprefsd. Snapshot failures refuse the launch. Evidence directories
must be unique; an existing snapshot is never overwritten. The defaults domain
must already exist; a missing/unreadable domain fails closed.

Keep the UI lock for the whole wrapper invocation. No other instance with this
bundle ID may update its defaults during the proof. The proof command must stop
its own app by exact PID before exiting, including on SIGTERM. The wrapper waits
for child cleanup before restoring preferences. SIGKILL or host loss cannot run
cleanup: preserve the before plist and restore the recorded key before another run.

Validate on the build Mac with:

```
python3 -m unittest discover -s infra/release -p test_update_proof.py -v
```

The integration test uses a unique disposable defaults domain, verifies a fresh
check precondition, simulates a failed child, and checks that the date is restored
without overwriting an unrelated preference changed by that child.

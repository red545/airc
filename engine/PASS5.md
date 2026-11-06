# Engine pass 5: seam audit and form qualification

This pass does **not** meet the ≤30-upstream-file target. Final footprint is
**51 → 51 files, 23 → 23 patches**. Two old touches were actually removed and two
new correctness fixes were needed. This is not another grouping-only reduction.
All remaining file reasons and seam assessments are in [patches/series](patches/series).
`python3 engine/patches/audit-series.py` checks coverage of the manifest.

| Category (series concerns) | Before | After |
|---|---:|---:|
| Build / framework entry | 4 | 4 |
| Window / viewless UI | 7 | 8 |
| Startup / policy | 4 | 2 |
| Permissions / choosers | 5 | 5 |
| Autofill / passwords | 2 | 3 |
| Content / history / external protocols / PiP | 5 | 5 |
| Extensions / script loading | 13 | 13 |
| Idle / storage / device policies | 10 | 10 |
| Keychain | 1 | 1 |
| **Total** | **51** | **51** |

Removed `chrome_content_browser_client.cc`: a core ContentBrowserClient override
intercepts only registration of Chrome's HandleWebUI pair. All policy, extension,
about/sync and new-tab handlers are still installed by Chrome. No testing setter,
weak-symbol replacement, or copied upstream implementation is used.

Removed `chrome_browser_main.cc`: the already-set `--no-startup-window` switch
selects upstream silent startup. Chrome creates the run loop and the existing core
ExtraParts keepalive keeps the host alive. Fresh startup, restart, host shutdown and
production app startup passed after removal.

Added `browser_view.cc`: `FindBrowserWindowWithWebContents` returned a null
BrowserView for our hosted tab despite promising BrowserWindow. Address submission
crashed in ShowSaveBubble. Resolve tab ownership first and return
BrowserWindow::FromBrowser; native-widget lookup remains for non-tab contents.
This also avoids selecting another profile simply because NSWindow is shared.

Added `address_bubbles_controller.cc`: accepting an address unconditionally cast
its window to BrowserView for an iOS toolbar promotion, causing a second crash.
Skip that toolbar-only promotion when there is no BrowserView. Address acceptance
and local card acceptance then pass without disabling autofill or lazy factories.

The retired hooks live in `patches/retired/` solely for exact migration. They are
not applied to pristine trees. `--check` rejects a build tree still containing
either retired hook; apply reverses only its exact pinned bytes and verifies the
original upstream hash. Unknown bytes, including drift on a retired file, fail
before mutation. Pristine/apply/repeat/applied checks, both migrations and both
retired-file drift refusals pass on the read-only mirror's disposable copy.

The seam audit distinguishes available overrides/observers from test-only setters.
BrowserWindow/feature construction, private timer ownership, and notifications that
occur after writes cannot simply become equivalent observers. The remaining
ContentBrowserClient/external-protocol override candidate would need to retain
Chrome's flood/policy pipeline. WebAuthn model observation still needs a production
registration point. KeyedService test factories are not used in production. The
single chrome_dll GN dependency hook already exists. No upstream weak-link seam
was found that would replace these concrete implementations without duplicate code.
Reaching 30 still requires substantial work; this pass does not establish that
30 is impossible. No inherited Bluetooth, quota or memory-pressure behavior was
silently removed to lower the count.

## Form and print results

All fixture values are synthetic; HTTP binds loopback on an ephemeral port. Tests
launch with `open -g`, mock keychain, fresh data, and quit. No owner credentials or
real card data are involved.

- **Password save/fill: pass for background API path.** Trusted renderer input
  submits the fixture; `passwordPrompt.state == save`; resolving save then returning
  to the form fills the synthetic username/password. Only boolean password equality
  and password length appear in the report. Native bubble appearance, real Keychain
  restart, and user keyboard selection remain unqualified.
- **Address/card save: pass for background API path.** Both prompt dictionaries
  arrive, accept succeeds, and read-only database checks after exit find one address
  and one v10-encrypted card in Profile One, zero in Profile Two. This is save and
  profile-isolation proof, **not address/card suggestion selection/fill proof**.
- **Upload: native sheet ownership/cancel pass.** A trusted click on input[type=file]
  opens an NSOpenPanel whose sheetParent is the host NSWindow. Cancellation reaches
  the renderer with an empty FileList. A later attempt to automate selection via
  NSSavePanel.ok raised Apple's “not implemented” exception; that test action was
  removed. Actual selection/submission remains a screen check. No picker override
  was needed; Chromium's existing FileSelectHelper/SelectFileDialog path works.
- **Print: API exposed, native panel unqualified.** Concrete Swift
  `ChromiumEngine.printPage(_:)` dispatches IDC_BASIC_PRINT (35007), preserving core
  policy, crash, modal and document-print restrictions. This calls Chromium's
  StartBasicPrint/system path rather than Views print preview. Its Boolean means
  command dispatched, not printed. Native panel, cancellation, PDF save, and the
  app's Command-P binding still need qualification. Existing generic IDC_PRINT
  remains available; app should use the explicit method for the native path.

Swift adapter now forwards password/autofill prompt updates and suggestion-display
rows, exposes snapshot queries and prompt resolution. See PROFILE-SERVICES.md for
contract details. Suggestion rows are descriptive; this pass does not add a row
selection API for app-drawn suggestion lists. Chromium still owns that interaction.

## App startup

The original pass-4 log is insufficient to prove its sole exit cause. While this
pass ran, the app agent committed `1b91420`: Chromium receives only its switches,
app-only option values no longer look like URLs, data directories are prepared
before startup, and automated runs use mock keychain and permit background paint.
Those changes belong to the app agent, not this engine pass.

A release rebuild initially failed in concurrent AircDesign actor-isolation edits;
a subsequent synced rebuild succeeded without engine-agent edits outside ownership.
A fresh signed Airc.app with the final framework and `--engine=chromium --snapshot
<scratch>/screens --script engine-startup --data-dir <scratch>/data` wrote:

```text
[engine-startup]
engine: Chromium 156.0.8078.88
unknown script engine-startup
```

The deliberately unknown script exercises app initialization, window creation,
report writing and normal exit immediately. It is a minimal startup smoke, not
showcase/screenshot acceptance. The former no-report behavior was not reproduced.
No additional engine startup fix is justified by this result. App requests:
wire the new concrete prompt callbacks/responses and native print method into the
product UI; do not infer successful printing from the return value. For a future
missing report, retain exact argv, user-data root and engine return status.

## Reproduce and evidence

On the build Mac, from the engine work copy:

```sh
engine/build.sh --start
engine/host/build.sh engine/host/build/pass5-acceptance
node engine/host/acceptance.mjs engine/host/build/pass5-acceptance/AircHost.app NEW_SCRATCH
node engine/host/acceptance.mjs engine/host/build/pass5-acceptance/AircHost.app NEW_SCRATCH forms
node engine/host/acceptance.mjs engine/host/build/pass5-acceptance/AircHost.app NEW_SCRATCH autofill
python3 engine/tests/audit_forms.py AUTOFILL_SCRATCH
node engine/host/acceptance.mjs engine/host/build/pass5-acceptance/AircHost.app NEW_SCRATCH memory
node engine/host/acceptance.mjs engine/host/build/pass5-acceptance/AircHost.app NEW_SCRATCH extension
engine/tests/adapter.sh engine/host/build/pass5-acceptance/AircHost.app NEW_SCRATCH
```

Each NEW_SCRATCH must be a different nonexistent directory. Final build: 29.92s,
`Build Succeeded`, `EXIT 0`. Final acceptance reports isolation write/read/restart,
memory/discard, extension install/popup and the warnings-as-errors signed Swift
adapter PASS. The artifact handoff contains `pass5-regression`,
`pass5-discard-verified`, `pass5-extension-verified`, `pass5-adapter-verified`,
`pass5-forms-verified`, `pass5-autofill-final`, and `pass5-app-current`, plus failed
qualification logs. Ten stale pass-4 signed bundles were removed before building;
all prior result files were retained.

## Morning checks and remaining implementation

Native fullscreen, visible permission/prompt anchoring and dismissal on profile
switch, DevTools undock, Cocoa context-menu tracking, actual IME candidates,
address/card suggestion selection and fill, actual file selection/submission,
Command-P panel/PDF-save/cancel, and app-drawn suggestion selection remain open.
No black-window capture is presented as native UI proof. The ≤30-file reduction
is also still open and is independent of the screen lock.

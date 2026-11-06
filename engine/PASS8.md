# Engine pass 8

Only `engine/` is owned/edited. The Swift integration is the **unapplied**
`app-pass8.patch`; app pass 5 must reconcile/apply it. No push was performed.

## Import and cleanup APIs

See [PROFILE-SERVICES.md](PROFILE-SERVICES.md) for the complete schemas/lifetimes.

- Password import now returns ordered `{index,status,reason}` rows and
  `saved/skipped/rejected` counts. Each accepted credential is read back from the
  profile password store after AddLogin. Existing keys, including conflicting
  passwords, are skipped without overwriting. Imports serialize per store;
  realm-scoped reads avoid repeatedly materializing the entire password database.
- Cookies return ordered outcomes, with explicit invalid-domain/expiry/partition
  reasons and Chromium secure/SameSite/prefix exclusion codes. Expired-cookie
  deletion is no longer counted as successful import.
- `deleteUnloadedProfile(directory:completion:)` does not load the profile.
  Default/reserved, loaded/loading/session-used, traversal, aliases and symlinks
  are refused. After worker validation and a UI ownership recheck, an atomic
  rename isolates the directory before worker deletion. Completion means deletion
  finished, not merely scheduled. A failed removal reports its quarantined name.

Synthetic acceptance passed: one saved login, one duplicate, one rejected login;
repeat import skipped; one cookie accepted, five rejected with reasons; default,
loaded, case alias, traversal and symlink cleanup refused; orphan fixture removed.
The saved login has nonempty v10 ciphertext; only one database row remains. The
existing services test also passed history/cookie isolation and second-window use.
No real credential/account or owner profile was used. The adapter addition was
Swift typechecked with warnings as errors in a separate patched copy; application
sources were not patched. `git apply --check engine/app-pass8.patch` passes at this
checkpoint. The complete app integration remains app-owned.

## Memory investigation

Measurements use the **same preserved Swift executable**, with only the embedded
framework replaced. Three profiles, six Spaces, eight live public pages and 22
model-only tabs; open -g; isolated roots; 120-second settle after app timings,
30-second sample. Physical footprint uses libproc and decimal MB, not RSS. Native
malloc/vmmap, footprint and detailed Chromium memory-infra dumps are taken **after**
the measurement. A separate 16 KiB sampled browser heap run provides allocation
stacks, symbolized against its exact framework with atos. Profiling overhead is
not included in the baseline/after runs.

Baseline: 158.22 MB. PartitionAlloc reported 132.70 MB allocator
size and 120.01 MB active objects (nested dump nodes must not be summed). Native
malloc zones accounted for roughly 2.8 MiB dirty+swapped, with about 0.7 MiB live.
The browser trace had about 2.6 MB SQLite memory and 0.2 MB LevelDB, tiny Skia
caches and no browser V8 heap dump. Native samples attributed about 0.66 MB to ICU,
0.05 MB to ResourceBundle, and zero sampled V8 allocations. These are sampled
lower-bound observations, not assertions that ICU/resources have no mapped cost.
Read-only mapped resources/code are not interchangeable with dirty footprint.

The largest clearly identified removable consumer was the AI actor navigation
safety list (at least 10.72 MB sampled). CRLSet parsing accounted for 9.52 MB
sampled and is deliberately retained. WebContents observer registrations accounted
for about 4.10 MB sampled and are retained. Lock telemetry contributed at least
1.05 MB sampled, plus allocations before the sampling session started. Inclusive
stack totals overlap; do not add them to allocator totals.

Two startup gates now omit AI actor list registration while Glic/actions are off
and disable unused lock-acquisition timing buffers. Their independent rollback is
`--airc-switches=quietActorLists=off,quietLockMetrics=off`. The actor gate also
requires `quietModels` on: enabling AI again restores its navigation list.
Safe Browsing, CRLSet, the shared component updater, site isolation, V8, ICU and
user-requested browser functionality remain. No periodic purge or timer was added.

Fresh-root measurements varied: initial after 121.42 MB, final build 142.90 MB,
rollback 122.26 MB. The low rollback lacked downloaded actor/CRL components, so
those runs **do not establish a controlled causal saving**. A matched pair seeds
identical public component files from the isolated baseline (never profiles or
Local State); per-file SHA-256 inventories are recorded for verification.

Matched controls, same final binary and identical SHA-256 inventories for 28
component files:

| Policy | Browser footprint MB | Margin to 150 MB | Whole-tree CPU % | Process churn |
|---|---:|---:|---:|---|
| Pass-8 gates off | 155.75 | -5.75 | 0.372 | none |
| Pass-8 gates on | **142.69** | **7.31** | 0.309 | none |

The matched saving is **13.06 MB (8.4%)**. The on result agrees with the independent
142.90 MB final-build sample. The 121 MB early result is not the headline saving.
Memory-infra reports malloc size 133.76 → 118.42 MB and active objects 119.17 →
102.45 MB. The 448-byte bucket falls from 11.66 to 1.30 MB of objects, consistent
with actor list node stacks. The 48-byte bucket remains approximately 13 MB in
both matched runs: the major component-loading confound is now controlled.

**Numeric MEM-1 passes this measured workload, not full release qualification.**
The screen remained locked. The Computer_memory Wikipedia target timed out in
both runs (an inherited renderer failure); seven targets responded, with one blank
GitHub page title in the on run. The probe checks readiness/error-page state, not
full public-page content equivalence. The benchmark also creates/deletes three
empty profiles while measuring profile creation. No claim of an unlocked/fullscreen
or complete eight-page acceptance, cold-launch guarantee, or literal no-idle-timers
pass is made. Remaining CPU timers and live-page variability are unchanged.
See `perf/pass8-measurements.json` for sanitized per-run outcomes.

## Final validation and handoff

Final incremental Chromium build: **30.35 seconds, 3 steps, EXIT 0**. Signed host
and patched concrete Swift adapter compile; the latter uses warnings as errors.
The complete post-policy regression returns:

```text
PASS write / read / restart: profile cookie and localStorage isolation
PASS forms: synthetic password save/fill and native upload cancellation
PASS autofill: address/card save, encrypted card storage, profile isolation
PASS memory: visible/form/audio protection, discard, restore and pressure
PASS extension: install, profile isolation and popup lifecycle
PASS Swift adapter: profiles, switching, evaluate, snapshot, zoom, find,
cache-bypass reload, DevTools and console panels
```

The native probe returns **ok:false**, `screen locked: native qualification not
attempted`, with an empty profile-load inventory. ioreg still reported locked
at the final check after 09:17 UTC. No native window screenshot or UI success
is claimed. The requested print/PDF, View Source, docking round trip, prompt/bubble
anchoring, native fullscreen, Cocoa menu tracking and file-selection journeys
remain **unqualified**. Existing form callbacks and renderer captures cannot
substitute for them. The app currently dismisses permissions and has no product
subscriber presenting the forwarded password prompt.

Artifacts under `engine/pass8/` include `imports-final/`, `services-final/`,
`native/native.json`, `screen-state.txt`, `regression.log`, `regression/`,
`memory-before/`, `memory-after/`, `memory-final/`, `seeded-on/`, `seeded-off/`,
`heap-samples.json`, `heap-symbols.json`, `shell-hashes.txt`, and `apply-check.txt`.
The matched app executable hashes are equal. Diagnostics use only owned test
processes; they quit after capture, and no screen/other-application capture or
foreground activation was performed. No source outside `engine/` was edited.

## Reproduction

Run Chromium builds sequentially on the build Mac. From the synced engine work
checkout:

```sh
engine/build.sh --run
engine/host/build.sh build/pass8-host
node engine/host/acceptance.mjs build/pass8-host/AircHost.app build/imports imports
node engine/host/acceptance.mjs build/pass8-host/AircHost.app build/services services
bash engine/perf/qualify.sh build/pass8-host/AircHost.app build/regression
# Refuses a locked screen and aborts if the application becomes active:
node engine/host/acceptance.mjs build/pass8-host/AircHost.app build/native native
python3 engine/perf/idle.py build/Pass8-Final.app build/on --public --allocations --settle 120 \
  --seed-components build/pass8-memory-before/chromium
python3 engine/perf/idle.py build/Pass8-Final.app build/off --public --allocations --settle 120 \
  --seed-components build/pass8-memory-before/chromium \
  --flag=--airc-switches=quietActorLists=off,quietLockMetrics=off
```

The native probe creates only a small owned window and captures only owned
windows. Its print path preconfigures a PDF destination and accepts the native
panel programmatically; it cannot establish human PDF-menu/save-dialog interaction.
Do not call its not-yet-executed paths qualified merely because it compiles.
Evidence is in the private handoff's `engine/pass8/`; qualification status is in
[HOSTING.md](HOSTING.md). Strict apply tests pass for 52 upstream files / 24 patches,
including pristine check, repeat apply, drift refusal and an unchanged source mirror.

# Sidebar sync groundwork

2026-11-07. AircKit implementation spike; no CloudKit calls, account changes, app
bundle build, signing changes or UI are enabled by this work.

## Recommendation and feasibility

Use **CloudKit's private database carrying encrypted sidebar operations**, behind
Settings → Sync → “Sync with iCloud”. Keep the folder transport as an advanced
fallback. This avoids a new account service while retaining the same merge and
cryptography code for either transport. It remains a conditional recommendation:
a Developer ID Chromium-bundle, two-Mac roundtrip must pass before enabling the
switch. SwiftPM tests cannot prove provisioning or iCloud availability.

**Yes: a non-App Store macOS app can use CloudKit.** Apple's current Developer ID
documentation explicitly includes CloudKit and push notifications among supported
advanced capabilities. An appropriate Developer ID provisioning profile authorizes
the entitlement; the signature alone does not. The profile is evaluated at each
launch, and current Developer ID profiles have an 18-year lifetime. This supersedes
older archived advice that iCloud requires the Mac App Store.
[Apple: Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

## Owner setup: about five minutes in the portal

Prerequisites: active Developer Program membership, Account Holder/Admin access,
and an existing Developer ID Application certificate with its private key on the
signing machine. No App Store listing or user-device registration is needed for
Developer ID distribution. Creating a certificate, if necessary, is separate.

1. Open **Certificates, Identifiers & Profiles → Identifiers → + → iCloud
   Containers**. Register a container with a description such as “Sidebar Sync”
   and ID **`iCloud.<public-bundle-identifier>`**, substituting the actual public
   bundle identifier. Do not paste angle brackets. Keep this identifier permanent.
   [Apple: Create an iCloud container](https://developer.apple.com/help/account/identifiers/create-an-icloud-container).
2. In **Identifiers**, select the explicit **App ID matching the public main
   app's CFBundleIdentifier** (register that explicit App ID if absent). Enable
   **iCloud → Include CloudKit support → Edit**, select the container, save the
   assignment and save the App ID. Do not enable the capability on Chromium
   helper App IDs. Capability changes require regenerated profiles.
   [Apple: Enable app capabilities, iCloud](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/).
3. Open **Profiles → + → Distribution → Developer ID**. Select **macOS**, the
   main App ID and the existing **Developer ID Application** certificate. Generate
   and download the `.provisionprofile`. Use a Developer ID profile, not Mac App
   Store or development provisioning. Keep it in private release configuration.
   [Apple: Distribution profiles for manually signed code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).
4. Hand the profile and container identifier to the release maintainer. Before
   shipping, create the operation record type in the container's development
   environment and deploy its schema to production in CloudKit Console. The
   portal registration alone does not deploy a schema.
   [Apple: Deploying an iCloud container's schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema).

### Release integration to implement next

`release.sh` is `scripts/release/release.sh`; packaging/signing flows through the
release Python orchestration, `package.sh` and `sign.py`. There is **no iCloud
profile option today**. Add private inputs for the profile and main-app iCloud
entitlements. After copying the bundle to staging, before its final signature:

```sh
cp "$AIRC_ICLOUD_PROFILE" "$STAGED_APP/Contents/embedded.provisionprofile"
```

These variable names describe the proposed interface, not existing switches.
Merge into **only the main app's** entitlement dictionary:

- `com.apple.developer.icloud-services`: array containing `CloudKit`;
- `com.apple.developer.icloud-container-identifiers`: array containing the exact
  registered container;
- `com.apple.developer.icloud-container-environment`: `Production` for distribution;
- the application/team identifiers and Keychain access group authorized by the
  downloaded profile, resolved from private signing inputs, never hard-coded.

See Apple's [iCloud entitlements](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-container-environment).
If passkeys are also enabled, use one regenerated profile authorizing **both**
capabilities; do not overwrite one profile with another. Extend the signer's
entitlement policy checks, reject missing/mismatched profiles, and keep the existing
hardened-runtime and notarization gates. Inspect the embedded profile with
`security cms -D -i`, compare its entitlements with `codesign -d --entitlements -`,
then verify the signed bundle and notarize/staple through the existing release
pipeline. Do not edit the app after signing.

**Chromium is not itself a CloudKit blocker.** Architectural inference: Airc's
Swift main process calls CloudKit; its loaded Chromium framework needs no separate
iCloud entitlement. Renderer/GPU/network/helper processes do not call CloudKit and
must not inherit the main app's cloud or Keychain access. Keep the current inside-out
signing order. Apple assigns entitlements to executable processes and explicitly
advises against applying them to libraries. This does not require converting the
browser to an App Sandbox app.
[Apple: Manual signing, entitlements and nested code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

## Core and local persistence boundary

`packages/AircKit/Sources/AircKit/Sync/` contains a value-only merge engine,
`SyncStoreAdapter`, AES-GCM envelope and `SyncTransport` with memory/folder actors.
No Store hook was added: `SpacesStore.observe` already reports committed actions.
The adapter consumes successive ordinary store states; the action's before/after
difference supplies field operations without trusting action labels.

The existing SQLite `entities` / `ops` transaction stores **whole local entities**,
with wall time and device ID; deferred writes can coalesce several actions. It
includes private-to-device fields and is **not safe to upload verbatim**. A new
durable sync sidecar/outbox must retain the Codable replica, adapter baseline,
ID aliases and encrypted pending batches. This is additive to the store schema.
The adapter is not yet attached to observers and does not apply remote records to
the Store. Persist its checkpoint atomically with the outbox; after a crash replay
pending batches rather than generate fresh operation IDs. Never acknowledge an
in-memory observer callback as durable before the store flush and sync checkpoint
both succeed. A production integration should atomically journal action changes
with the store or reconcile a durable baseline after restart.

Stable record IDs reuse Space IDs and namespace sidebar rows with `item:` or `tab:`.
A persistent alias map follows Today → pinned → Favorite → Today, unload and
archive transitions. A tab already pinned at first capture uses its item ID;
a Today tab seen before pinning keeps its tab ID. A remote Store materializer must
carry these aliases when assigning local item/live-tab IDs. Initial independent
imports are not deduplicated by URL: two intentional bookmarks may share a URL.

Each operation has a random ID and `(milliseconds, logical counter, device UUID)`
HLC stamp. Receiving advances the local HLC, including during wall-clock rollback.
Each field picks the greatest stamp; equal stamps use operation UUID as a final
tie-break. Duplicate operations do nothing; conflicting payloads reusing an ID
are rejected atomically. Device UUIDs are sync-installation IDs, never telemetry
identifiers. Checkpoints must persist the clock; copied installations need new
local device IDs. Retain all tombstones until a future device-acknowledgement and
compaction design proves deletion safe.

Order is a variable-length base-65536 fraction with a UUID suffix, not the Store's
`Double`. Insert/move changes only the affected row's order field; concurrent
inserts into one gap get distinct keys. Arbitrarily dense insertion grows the key
instead of rounding or rebalancing the list. Record ID breaks any remaining order
ties deterministically. Projection into local `Double` order must enumerate sorted
keys and preserve the canonical keys in the sync sidecar.

## Conflict rules

- **Folder deleted / child added remotely:** the folder's tombstone hides it.
  A surviving child whose parent is absent, deleted, in another container or part
  of a parent cycle appears at its own Space's pinned root. The raw parent register
  is retained; projection never manufactures repair operations. Existing descendants
  deleted by the local Store action receive their own tombstones. A deleted Space
  hides its rows; they remain in the log for explicit recovery.
- **Same tab pinned / archived:** pin, Favorite, Today and archived are values of
  one LWW `location` register on one stable row ID. The greater HLC wins (device UUID
  resolves concurrent equal time/counter). An archive is a lifecycle marker only,
  with no archive URL/title/time payload. A later intentional pin can win. This
  also works when Today export is off because the adapter tracks its IDs locally.
- **Space order edited on both Macs:** independent moves merge; two moves of the
  same Space use LWW on its order field. Sorting the fractional keys produces the
  same order on every replica; no index-based array replay or global renumbering.
- **Unknown profile assignment:** retain the remote profile ID; return unresolved
  until the owner maps it or creates an empty local profile. Never silently use the
  default profile, infer identity from a profile name, or copy credentials. The UI
  must withhold page loading and Favorites for unresolved bindings. Mapping is local
  unless the user explicitly changes the synced assignment.
- **Delete / rename:** a name edit does not clear a tombstone. Only explicit restore
  writes `deleted = false` with a newer stamp. Folder/Space restoration can expose
  surviving rows again. This supports undo without stale edits resurrecting records.

## Privacy and encryption

Default export: Space name/icon/theme/profile reference/order; folders; pinned tabs
and Favorites (saved URL, user title/icon, parent, container and order). Profile
records, engine directories, signed-in account display, page titles/favicon updates,
selection, window geometry and last-active times are excluded. Split rows and their
children are deferred as a unit pending a versioned split schema.

Today export is **off by default**. Its optional adapter mode exports initial open
URLs, not subsequent navigation updates or page titles. Archive entries are never
exported. Never supply private or Little Arc stores to this adapter: `StoreState`
has no privacy-mode bit, so integration must enforce that boundary. Blank-window
Spaces and their rows are filtered. There is no history, cookie, password, Boost
code or telemetry-ID field in the wire schema. Boost sharing requires a future
explicit opt-in/schema; this implementation cannot export Boosts at all.

`SyncEnvelope.newGroupKey()` generates a 256-bit key once per sync group.
CryptoKit AES-GCM uses a fresh random nonce for each sealed batch. Version, group,
author and envelope UUID are authenticated additional data. Opening verifies the
tag before decoding or merging; wrong key/group, altered payload or substituted
metadata fails. Replay is harmless through operation IDs. This does not prove
completeness: a storage provider can withhold/delete/roll back whole files. Add
acknowledgements/checkpoints and a user-visible sync-health state before shipping.
[Apple: AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm).

Keychain wiring is deliberately absent. Store raw group-key bytes as a generic
password, service scoped to sidebar sync and account set to the random group UUID,
with `kSecAttrSynchronizable = true` and `kSecAttrAccessibleWhenUnlocked` (not a
`ThisDeviceOnly` class). Use the provisioned app access group and the data-protection
Keychain. Query synchronizable items explicitly. Deleting this item deletes its
synchronized copies: turning off sync must **not** delete the group key. Concurrent
first setup on two Macs must join one selected group, never overwrite an existing
key. If iCloud Keychain is unavailable, wait or offer explicit secure key pairing;
never put plaintext keys beside the encrypted log or generate a replacement for
an existing group. Cross-account folder sharing needs explicit pairing/recovery.
[Apple: kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable).

## Folder fallback without CloudKit entitlements

A user picks a folder already managed by iCloud Drive, Dropbox or another provider.
Airc reads/writes ordinary files there, without using a CloudKit container API.
`FolderSyncTransport` writes append-only per-device streams as **immutable segment
files**, one JSON-line envelope per append. Paths contain device/writer/random
segment UUIDs. Each append writes `.partial`, flushes, closes and renames to
`.jsonl`. No two Macs share a mutable log or manifest, even if a backup cloned the
device ID (each writer and segment also has a fresh UUID).

Readers ignore `.partial` files and unfinished final lines, rescan on subsequent
reads, and reject malformed complete lines or wrong-author paths. No byte-offset
checkpoint can skip a later completed tail. Provider conflict copies may redeliver
operations; merge is idempotent. Completed segments are never modified. The fake
supports at-least-once delivery with the same interface.

Limits: eventual provider delivery, evicted files, offline accounts, permissions,
user deletion and provider conflict behaviour; no push/latency SLA, trusted global
manifest, rollback protection or safe garbage collection. The current small-data
transport scans whole files and retains the entire log; quotas, resource limits,
streaming/checkpoints, file coordination, download requests and filesystem change
notifications remain production work. User-picked folder access/bookmark handling
belongs in the app. “No entitlement” means no **CloudKit** entitlement; a sandboxed
variant would still need user-selected file access, and synchronizable Keychain
access must be validated separately. Local tests do not prove either provider's
real cross-Mac delivery.

## Follow-up to ship

1. Complete portal/signing setup, then test one encrypted operation between two
   Developer ID Chromium apps using a production private CloudKit database. Verify
   relaunch, offline/reconnect, account sign-out/change, missing Keychain key and
   notarized installation. Use synthetic data only; no app build in this spike.
2. Implement CloudKit transport (immutable envelope records, zone change tokens,
   retries/backoff, private database). Persist atomic outbox/checkpoint and preserve
   aliases. Add remote materialization through a Store transaction with echo
   suppression; rebase the adapter baseline after applying remote changes.
3. Add Settings → Sync (off initially), group/key setup, connection/error state and
   an optional folder picker. Keep Today separately opt-in and Boost code off.
4. First-sync UI: preview local/remote Spaces, offer **merge** or an explicit
   **replace this Mac's sidebar**, back up before applying, resolve profile mappings
   and duplicate imports, and keep unresolved content unloaded. Never silently
   delete a remote group or overwrite a device's sidebar on first connection.
5. Add resource limits, outbox recovery, device retirement/key recovery, deletion
   acknowledgements/compaction and split support before claiming full parity.

## Validation

Run `swift test --package-path packages/AircKit --filter Sync`, then the whole
AircKit suite on macOS. Tests exercise 24 deterministic randomized schedules with
2–3 devices and 120 edits each; shuffled exchange, duplicates, clock rollback,
field merging, tombstones, all four conflicts, cycles, 2,000 dense insertions,
actual Store actions, privacy filtering, AES-GCM tampering, folder partial tails
and corrupt complete records. There are no account, entitlement or live-provider
tests in this spike. Exact run results are recorded in the task artifact report.

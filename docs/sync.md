# iCloud sync

Settings → Sync → "Sync Spaces, pinned tabs and Favorites with iCloud" keeps the sidebar the same on a person's Macs
(spec §2.16). Off by default. Built on syncspike's merge core ([research/sync.md](research/sync.md)): per-field
last-writer-wins on a hybrid clock, tombstones, fractional order, AES-GCM sealed batches. This page is how the rest
works: the CloudKit transport, the group key, the first sync on a second Mac, and what the app does with remote changes.
The user's view is [user/sync.md](user/sync.md).

## What syncs

| Syncs | Never syncs |
|---|---|
| Spaces: name, icon, theme, order, which profile | Today tabs and the Archive (Today export exists in the core, off and not in the UI) |
| Pinned tabs and folders: saved URL, custom name, emoji, order, parent | History, passwords, cookies, logins, engine data |
| Favorites, per profile | Private windows and Little Arc (they're never in the store) |
| Profile name, emoji and "is the default" | Page titles and favicons, navigation, selection, window layout |
| | Splits (deferred as a unit), Boosts, blank-window Spaces, telemetry IDs |
| | Notes: their text and pictures, and their tabs and pinned rows (local-only, below) |

Profile descriptors are the one addition to syncspike's allowlist (`SyncRecordKind.profile`: name, emoji, default or
not). Profile IDs are per installation, so a second Mac can't place a Space without them. Each record carries the
group's profile ID. A Mac maps the group's IDs to its own (`SyncStoreAdapter.groupProfiles`); only profiles that started
on that Mac describe themselves. Logins never move: a profile new to a Mac is created there empty.

Everything a person wrote is inside `sealed`. CloudKit sees record names, the group and device UUIDs, a format version
and timestamps.

## Parts

| Where | What |
|---|---|
| `packages/AircKit/Sources/AircKit/Sync/SyncCloud.swift` | `SyncCloudDatabase` (the slice of CKDatabase used), record mapping, `CloudKitSyncTransport` |
| `Sync/SyncCloudKit.swift` | The live CloudKit database, CKError mapping, `SyncCapability` (entitlement detection) |
| `Sync/SyncCloudMock.swift` | The mock database: in memory (unit tests) and in a folder (app instances in scripted checks) |
| `Sync/SyncKeys.swift` | The group key: iCloud Keychain item, the key check, fake keychains |
| `Sync/SyncEngine.swift` | First/second Mac, merge or replace, outbox, cycles, failures, devices |
| `Sync/SyncMaterializer.swift` | `SpacesStore.applySync`: the synced sidebar into the store, in one transaction |
| `Sync/SyncFolderGroup.swift` | The encrypted folder transport as a group (test builds' `--sync-folder` only) |
| `apps/browser/Sources/Airc/Sync/SyncCenter.swift` | Backend choice, triggers (activation, push, timer), profile and backup hooks |
| `apps/browser/Sources/Airc/Settings/SyncSettings.swift` | Settings → Sync and the first-sync screen |
| `scripts/release/icloud.py` | The provisioning profile and the main app's iCloud entitlements (docs/release.md) |
| `infra/release/cloudkit-schema.ckdb` | The CloudKit schema |

## CloudKit layout

The private database, one custom zone **`AircSidebar`**, three record types:

| Type | Record name | Fields | Written |
|---|---|---|---|
| `SyncGroup` | `group` | `group` (UUID), `version`, `check` (bytes), `created` | once, by the first Mac, create-only |
| `SyncBatch` | `<device UUID>.<batch UUID>` | `group`, `device`, `envelope` (UUIDs), `version`, `sealed` (bytes) | by its device, create-only, never changed |
| `SyncDevice` | `device.<device UUID>` | `group`, `device`, `sealed` (its name), `seen` | by its device, overwritten at most every 6 hours |

A device only creates names with its own UUID; readers drop a batch whose name, `device` field and sealed author don't
agree. Batches hold at most 512 KB of operations (below).

Reading is incremental: `fetchChanges(since: token)` pages until `moreComing` is false. The transport holds the new
token as pending; the engine merges, saves its state, then calls `acknowledge()` and persists the checkpoint (token and
known devices). Until then a read returns the same changes again (at-least-once; the replica ignores operations it
has). A device's own batches are skipped.

A `CKRecordZoneSubscription` with `shouldSendContentAvailable` asks for silent pushes. They need the push entitlement
(the App ID's Push Notifications capability); without it, and as the fallback anyway, the app syncs when it becomes
active (at most every 20 s), every 10 minutes, after each local change (1.5 s debounce) and on Sync Now.

### Failures

| CloudKit says | The transport / engine does |
|---|---|
| network unavailable/failure, service unavailable, rate limited, zone busy | retries (1, 4, 15 s, CloudKit's retry-after if longer), then "Can't reach iCloud right now", backoff up to 15 min |
| not authenticated / no account | "Sign in to iCloud in System Settings to sync", checks again |
| quota exceeded | "Your iCloud storage is full", every 30 min |
| zone not found on save or read, or a full read missing any batch this Mac uploaded | recreates the zone and enters **recovery** (saved): puts the group record back and checks it is this group's, uploads this Mac's whole history again, and only then leaves recovery (every Mac does: a third Mac still gets everything) |
| a record of a page CloudKit couldn't return | the page's token isn't used: nothing is acknowledged past it, it comes again |
| change token expired | reads everything again |
| user deleted zone (System Settings → Apple Account → iCloud → Manage) | stops, turns itself off, forgets this Mac's sync state; never recreates it until the person turns sync on |
| another Apple ID (`userRecordID` changed) | stops the same way: "You're signed in to another iCloud account now" |
| missing entitlement | "available in release builds once set up" |
| a batch that won't open or merge (damaged, from a newer Airc) | kept in a quarantine (in the state file) and retried, at most 32 batches and 1 MB a cycle, round-robin; the others apply; Settings says "Some changes can't be read"; a new Mac's Replace is refused while iCloud's sidebar is incomplete |
| a batch record that can't even be parsed | its name is remembered and reported until a valid record of that name arrives, it's deleted, or a full read no longer has it; within one read, the record's last event across pages counts (malformed on page 1, repaired on page 3: valid) |
| this Mac can't save its state (disk full) | the cycle stops before anything more is sent or acknowledged; Settings says so |

The outbox (sealed batches not yet uploaded) is in the engine's state file, so a quit or a crash loses nothing.
A batch's sealed payload (the operations' JSON array, AES-GCM's nonce and tag) is at most 512 KB
(`SyncEngine.maxBatchBytes`). Names and titles sync cut at 2 KB, and saved URLs longer than 16 KB (data: URLs) don't sync,
so one operation is far smaller than a batch and no batch can get stuck.

### Local-only rows (saved URL over 16 KB)

A pinned tab or Favorite whose saved URL is longer than 16 KB is **excluded**: an explicit state per record
(`SyncStoreAdapter.excludedRows`), with one rule.

- **While excluded it sends nothing,** and other Macs keep its last synced values (or never see it, if it was never small).
- **No remote operation ever erases or changes it here.** A tombstone, an unpin and edits leave it as it is. If its
  folder is deleted elsewhere it moves to its Space's root; if its Space is deleted elsewhere, the Space stays on this
  Mac while it holds local-only rows (their synced neighbours still go). It's never archived: it stays where it is.
- **A kept Space is quiet until this Mac edits it.** Other Macs don't see it, and nothing is sent. A local edit of
  something synced in it (a new or changed pin or folder, or the Space itself) re-creates it under its record, with a
  newer stamp, so it and that content sync again. Only a local edit does this: a second deletion elsewhere just leaves it
  quiet again, so there's no ping-pong.
- **When it fits again it's re-created** under the same record, with every field, whatever happened to the record
  meanwhile; so are its Space and folders if another Mac deleted them and this Mac kept them for it. A local edit made
  after a remote deletion therefore brings it back everywhere.

The threshold stays 16 KB: the case is pathological (data: URLs), and every exclusion test exercises it with 20 KB URLs.

### Notes stay on this Mac

A note's pinned row (its saved URL is `airc-note:<id>`) is local-only by the same rule (`SyncStoreAdapter.isLocalOnly`),
so it's excluded from its first capture on and never sent, edited or tombstoned; what a note says is a `note` row, which
no record kind carries. A note's Today tab is never exported, even with Today export on. Remote changes never touch a
note: a folder deleted elsewhere drops it to the Space's root, Replace keeps it, and a Space deleted elsewhere stays here
while it holds a note, pinned or in Today. Tested in `SyncNotesTests` and `SyncEngineTests.testNotesStayOnThisMac`.

### Safety rules (from the 2026-11-07 review)

- **Acknowledge last.** A read's token is acknowledged only after what it brought is merged, applied to the store and
  saved. The first Mac's first read goes through the same exchange as any other (another Mac may join at once).
- **Journal before the store.** Applying remote changes first saves the replica with `applyMode` set; the store
  transaction follows; then the baseline and `applyMode = nil` are saved. After a quit or crash in between, the next
  cycle applies again instead of capturing the store's new rows as this Mac's own. Remote records have stable local
  IDs (`item:<id>` → `<id>`, `tab:<id>` → `synctab-<id>`) and profiles made for the group carry
  `sourceID = sync-profile:<group id>`, so applying twice changes nothing.
- **Fail closed.** Every save throws; a cycle that can't save stops before its next upload or acknowledgement, and
  after a failed save nothing is uploaded until a save succeeds (the outbox goes up only once it's on disk).
- **Sessions.** One transport is one session, and each session runs its own cycle loop in a task of its own, bound
  to the session it was created for: a task whose session ended before it started (or between its cycles) does nothing. Switching
  sync off, Cancel, CloudKit's account-changed notification and a stop cancel both at once: the retry sleep wakes, no
  further request, retry or page starts, and the old session's late errors, completions and bookkeeping are ignored.
  Every `await` in SyncEngine.swift is followed at once by its session check (`try live(gen)` or `isLive(gen)`),
  before any change to the replica, outbox, state file, store, key or status; the few exceptions return, or say why on
  the line (`// await-ok:`). A unit test reads the source and fails on an await without one. A new session never
  waits for an old one's loop, even one stuck in a sleep that ignores cancellation.
- **Accounts.** After the identity check at the start of a cycle, the transport is bound to that Apple Account and
  checks it before every request (saves, fetches, zone changes, recovery and retries included); the engine checks it
  again after a read, before anything read reaches the store, and before calling the cycle up to date. A different
  account stops sync. The first-sync choice is bound to the account and session it was offered in.
- **Nothing while off.** No transport, CloudKit container, timer, observer or push registration exists while sync is
  off; switching off removes them.

## The group key

One 256-bit AES key per sync group, in **iCloud Keychain**: a generic password, service "Airc sidebar sync", account
= the group UUID, `kSecAttrSynchronizable`, `kSecAttrAccessibleWhenUnlocked`, the data-protection keychain, the app's
own access group (`<team>.com.aircbrowser.Airc`, from the profile). Keys are only ever added: turning sync off never
deletes it (deleting a synchronizable item deletes it on every Mac). The group record's `check` is AES-GCM over a fixed
text, so a Mac can tell a missing key from a wrong one.

**First Mac:** sync on → no `group` record in the zone → it makes a group UUID and key, adds the key to iCloud Keychain,
creates the group record (create-only), uploads its sidebar, publishes its device record.
**Two Macs at once:** both may try; the create-only save lets one group win. The other removes the key it just made
(no one has it) and joins the winner as a second Mac.
**Second Mac:** sync on → it finds the `group` record → it looks for the key. iCloud Keychain may take a while to bring
it over: Settings says "Waiting for iCloud Keychain" and Airc checks every minute. Then it reads everything and, if
iCloud has a sidebar, shows the first-sync screen: both sidebars, the profiles to match, and

- **Merge with this Mac's sidebar:** this Mac's sidebar is captured first, then iCloud's is merged in; everything from
  both stays (Spaces on both, such as each Mac's first "Personal", appear twice);
- **Replace this Mac's sidebar with iCloud's:** this Mac's synced kinds are replaced; Today tabs of removed Spaces go
  to the Archive; profiles stay. Nothing of this Mac's old sidebar is sent.

A backup (`airc-before-icloud-…json` in the backups folder) is taken first either way. Profiles: the group's default
profile maps to this Mac's default profile; others to a choice (a profile of this Mac, offered first when the name
matches, or a new empty one). Several of the other Mac's profiles may share one profile here (the screen says so); it
then syncs back as the first one mapped, the default one if it's among them. Profiles another Mac makes later arrive as
new empty profiles with their names.
Cancel turns sync off and changes nothing.

## Applying remote changes

`SyncEngine` observes the store, so every committed action is captured (content-only page updates aren't). Before
applying remote operations it captures local edits synchronously, applies the replica with `SpacesStore.applySync`
(one transaction, not undoable), moves Spaces whose profile changed elsewhere with `setProfile` (and reloads their
pages), then rebases the adapter's baseline: nothing applied is sent back. Pinned items' open pages stay open when
their row moves within a profile, close when it crosses profiles, and become Today tabs when it's unpinned. At most 12
Favorites per profile show; the rest stay in the group. Splits and blank-window Spaces are never touched.

A copied data folder (Migration Assistant, a restored backup) gets a device ID of its own: the state file remembers a
hash of the hardware UUID.

## Capability detection

`SyncCapability.container` reads the process's own entitlements (`SecTaskCopyValueForEntitlement`) and returns the
container only when `com.apple.developer.icloud-services` includes CloudKit. Nothing creates a `CKContainer` otherwise
(CloudKit raises an exception without the entitlement). Dev builds (ad hoc), test builds and release builds before the
profile exists show "iCloud sync is available in release builds once set up", with the switch disabled. Scripted runs
never use the real CloudKit.

## Tests

- `swift test --package-path packages/AircKit --filter Sync`: the merge core (syncspike), the transport against the
  mock database (record mapping, paging and tokens, redelivery, retries and retry-after, quota, signed out, missing and
  reset zones, expired tokens, user-deleted zone, the group race, CKError and CKRecord mapping), syncspike's randomized
  convergence through CloudKit transports, and the engine on several "Macs" with fake keychains (waiting, merge,
  replace with backup, profile choices and later profiles, privacy, failures, outbox across a relaunch, deletes and
  moves, zone reset with a third Mac, concurrent first setup, copied data folders).
- `--script icloudsync`, then `icloudsync-second`, `icloudsync-replace`, `icloudsync-return` (Debug/ICloudSyncCheck.swift,
  in the snapshot suite on both engines): four app instances share a mock database in a folder, each with its own fake
  keychain; a copied key file plays iCloud Keychain. The first uploads (nothing of a Today tab, a private window or
  Little Arc), the second waits for the key, merges after a backup and sends edits, the third replaces, the first gets
  it all at launch and a "push" while running. `icloudsync-unavailable` checks the page without a backend.

Test-build switches (never in public builds): `--sync-mock DIR` (mock CloudKit database), `--sync-folder DIR` (the
encrypted folder transport), with `--sync-keychain DIR` (this instance's fake keychain) and `--sync-device-name NAME`
(or `AIRC_SYNC_DEVICE_NAME`).

## Deploying the schema

A Production build can't create record types, and a Developer ID profile allows only the Production environment, so
the schema goes Development → Production once (done 2026-11-07, owner and icloudsync):

1. The owner makes a CloudKit **management token** (CloudKit Console → Tokens & Keys → Management Tokens) and puts it in
   `~/arcfork/secrets/cloudkit-management-token.txt` on the build Mac (mode 600).
2. Import into Development. `cktool` reads the token from `CLOUDKIT_MANAGEMENT_TOKEN`, so it never goes on a command line;
   the team ID comes from the profile and isn't printed:
   ```sh
   team=$(security cms -D -i ~/arcfork/secrets/<profile>.provisionprofile | python3 -c 'import plistlib,sys; print(plistlib.loads(sys.stdin.buffer.read())["TeamIdentifier"][0])')
   CKTOOL_NO_PROMPT=1 CLOUDKIT_MANAGEMENT_TOKEN="$(cat ~/arcfork/secrets/cloudkit-management-token.txt)" \
     xcrun cktool import-schema --team-id "$team" --container-id iCloud.com.aircbrowser.Airc \
     --environment development --validate --file infra/release/cloudkit-schema.ckdb
   ```
3. The owner deploys it: CloudKit Console → container `iCloud.com.aircbrowser.Airc` → **Deploy Schema Changes…** →
   three added record types (SyncBatch 5 fields, SyncDevice 4, SyncGroup 4) → Deploy. `cktool export-schema
   --environment production` then lists them.

A schema change later (a new field) goes the same way; CloudKit never removes fields from Production.

## The real iCloud test

`Debug/ICloudRealCheck.swift`, not in the suite. It needs the profile and the deployed schema, and runs on the build
Mac under the UI-check lock:

1. A Developer ID-signed **test** build: the Chromium bundle from `scripts/build-app.sh`, its bundle ID set to
   `com.aircbrowser.Airc` and its version to 0.0.1 (1) (so Launch Services never prefers it to a real install), then
   `icloud.py prepare`, `sign.py` with the iCloud entitlements and the existing signing keychain (as package.sh), and
   `icloud.py verify`. Nothing prints the identity, team or keychain password. The profile must contain the build
   Mac's own Developer ID certificate: the first attempt (2026-11-07) had a profile made for the account's older one,
   and macOS refused to launch the app (AMFI -413 "No matching profile found"); `icloud.py verify` now fails on that.
2. Two installations (two data folders) on the build Mac and its Apple Account, in **Production**, with
   `--sync-cloudkit-test-zone AircSidebarTest` (test builds only; only names starting with AircSidebarTest): their own
   zone and subscription in the app's container, and a group key that is a **local** item (`synchronizable: false`,
   service "Airc sidebar sync test", the profile's access group), so nothing reaches the owner's other devices.
   - `icloudsync-real-a`: makes the group, saves the key, uploads a test Space.
   - `icloudsync-real-b`: finds the group and key, the first-sync screen with that Space, Merge, then a rename and a pin.
   - `icloudsync-real-cleanup`: the first installation gets the edits; then the test zone (records and subscription)
     and the test key are deleted, and both are checked gone.
3. Then the build, its data folders and the shots are deleted and the bundle unregistered (`lsregister -u`).

Still to test with the owner's OK and a second Mac: the synchronizable key through iCloud Keychain, two Macs with
pushes, offline and account changes, and a notarized release's first sync on a clean second Mac.

## Limits and follow-ups

- The log keeps every operation and tombstone (no compaction yet); fine for sidebars, but it grows.
- Merge doesn't detect the same Space on both Macs (each Mac's first "Personal" shows twice); Replace is the choice
  for a new Mac, and the screen offers it first when this Mac has nothing pinned.
- No key recovery or pairing without iCloud Keychain; no device retirement.
- Profile names sync only to name new empty profiles; renaming a profile on one Mac doesn't rename it on another.
- Silent pushes need the Push Notifications capability on the App ID (the profile's `aps-environment`); without it
  sync is on activation and every 10 minutes.

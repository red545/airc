# iCloud sync

Settings → Sync → "Sync Spaces, pinned tabs, notes and Favorites with iCloud" keeps the sidebar the same on a person's Macs
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
| Pinned notes: their row, text, title and pictures ([Notes](#notes), P14b1) | Today splits, Boosts, Easels, blank-window Spaces, telemetry IDs |
| Pinned and Favorite splits: their panes (saved URLs, order), name, icon, axis and sizes ([Splits](#splits), P14b2) | Which pane of a split has the keyboard; a split with a local-only pane (it stays whole) |
| | A note only in Today or the Archive (its Today tab never syncs) |
| | Folders in Today (`ItemContainer.today`, `LiveTab.folderID`): never in a snapshot, below |

Profile descriptors are the one addition to syncspike's allowlist (`SyncRecordKind.profile`: name, emoji, default or
not). Profile IDs are per installation, so a second Mac can't place a Space without them. Each record carries the
group's profile ID. A Mac maps the group's IDs to its own (`SyncStoreAdapter.groupProfiles`); only profiles that started
on that Mac describe themselves. Logins never move: a profile new to a Mac is created there empty.

Everything a person wrote is inside `sealed` (or a sealed asset). CloudKit sees record names, the group and device
UUIDs, note IDs (random), a format version, sizes and timestamps.

## Parts

| Where | What |
|---|---|
| `packages/AircKit/Sources/AircKit/Sync/SyncCloud.swift` | `SyncCloudDatabase` (the slice of CKDatabase used), record mapping, `CloudKitSyncTransport` |
| `Sync/SyncCloudKit.swift` | The live CloudKit database, CKError mapping, `SyncCapability` (entitlement detection) |
| `Sync/SyncCloudMock.swift` | The mock database: in memory (unit tests) and in a folder (app instances in scripted checks) |
| `Sync/SyncKeys.swift` | The group key: iCloud Keychain item, the key check, fake keychains |
| `Sync/SyncEngine.swift` | First/second Mac, merge or replace, outbox, cycles, failures, devices |
| `Sync/SyncMaterializer.swift` | `SpacesStore.applySync`: the synced sidebar into the store, in one transaction |
| `Sync/SyncFolderGroup.swift` | The encrypted folder transport as a group (test builds' `--sync-folder` only; it carries no notes) |
| `Sync/NoteSyncPayload.swift` | Notes: version vectors, sealed note records and picture assets, limits, the store's apply and conflicted copy |
| `Sync/SplitSyncPayload.swift` | Splits: the synced layout, and which operations go in version 3 batches |
| `apps/browser/Sources/Airc/Sync/SyncCenter.swift` | Backend choice, triggers (activation, push, timer), profile and backup hooks |
| `apps/browser/Sources/Airc/Settings/SyncSettings.swift` | Settings → Sync and the first-sync screen |
| `scripts/release/icloud.py` | The provisioning profile and the main app's iCloud entitlements (docs/release.md) |
| `infra/release/cloudkit-schema.ckdb` | The CloudKit schema |

## CloudKit layout

The private database, one custom zone **`AircSidebar`**, five record types:

| Type | Record name | Fields | Written |
|---|---|---|---|
| `SyncGroup` | `group` | `group` (UUID), `version`, `check` (bytes), `created` | once, by the first Mac, create-only |
| `SyncBatch` | `<device UUID>.<batch UUID>` | `group`, `device`, `envelope` (UUIDs), `version` (1; 2 with a note's row; 3 with a split's or a pane's), `sealed` (bytes) | by its device, create-only, never changed |
| `SyncDevice` | `device.<device UUID>` | `group`, `device`, `sealed` (its name), `seen` | by its device, overwritten at most every 6 hours |
| `SyncNote` | `note.<device UUID>.<note ID>` | `group`, `device`, `note`, `version` (format 1), `sealed` (bytes, ≤ 256 KB) or `payload` (asset, ≤ 8 MB) | by its device, overwritten with its latest version of that note |
| `SyncNoteAsset` | `noteasset.<40 hex>` | `group`, `version` (1), `data` (asset: one sealed picture, ≤ 32 MB) | by the first Mac that has the picture, create-only, never changed |

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

## Notes

A pinned note syncs (P14b1, `Sync/NoteSyncPayload.swift`). Its **row** is a pinned tab like any other (its saved URL is
`airc-note:<id>`), so moving, renaming, foldering and deleting it are sidebar operations. Its **text** (the
`NoteDocument`: lines, styles, checkboxes, links, picture references), its **title** and its dates go in a `SyncNote`
record, and each **picture** in a `SyncNoteAsset`. A note only in Today or the Archive stays on its Mac, like a Today
tab (a note in a [Today folder](#folders-in-today) too): pinning it starts its sync, and unpinning it (or dragging it
into a Today folder, deleting its row or its Space) sends a *removal*.

**Records.** Each Mac writes one record per note, `note.<its device>.<note>`, overwritten with its latest version; no
two Macs ever write one record, so CloudKit merges nothing. A version is sealed with the group key (AES-GCM, the
record's format, group, device and note ID as AAD) and carries its hybrid-clock stamp (the replica's clock) and a
**version vector** (per device, how many versions it made). Pictures are content-addressed already (`<sha256>.<ext>`);
the asset's record name is an HMAC of that file name under a key derived from the group key (HKDF), so iCloud can't
match a picture, and a Mac opening one checks its bytes hash to the file name. A picture is uploaded once, by
whichever Mac has it first; the same picture in two notes is one asset.

**Sizes.** A sealed version up to 256 KB is a `bytes` field (CloudKit allows 1 MB of fields per record); up to 8 MB it
goes in the record's `payload` asset; past that (far beyond any real note, pictures not counted) the row syncs and the
text stays, and Settings → Sync says "A note is too large to sync". A picture over **32 MB** isn't uploaded: other Macs
keep its place and draw "Picture not on this Mac" (the editor's existing placeholder). A change fetch doesn't download
pictures (`SyncCloudSchema.feedKeys`); a Mac fetches the ones its notes show by name, 24 a cycle, missing ones again at
the back of the queue.

**Order.** A cycle uploads pictures, then note removals, then batches, then note texts. So a Mac that reads a row's
tombstone has the removal too (CloudKit returns a zone's changes in order), and one that reads a text has its row.
A text whose row hasn't arrived (or a row whose text hasn't) waits: the text is applied once a row shows the note, and
a note with a row but not the latest text fetches it by name (`refetch`), so a relaunch's orphan cleanup
(`removeOrphanNotes`) can't lose it.

### Conflicts

Every Mac decides alike, so all end with the same text:

| What happened | Result |
|---|---|
| A version that has every count of the one here (it saw it) | taken |
| Two edits made apart (neither vector has the other) | **last writer wins per note**: the later stamp. The Mac whose own text lost keeps it as a new note pinned just below, "<title> (conflicted copy, <Mac>)", which syncs like any note. Only the losing text's author makes the copy, once |
| An edit and a removal made apart | **the edit wins**, whatever the stamps: the editing Mac sends the row again (with its folder and Space if those went too) and a new version; every Mac keeps the note pinned with the edit |
| A removal made after the last edit was seen | the deletion stands everywhere (by the rows' tombstones) |
| Typing while a remote version arrives | the typing is captured first, then decided like any concurrent edit; an open editor shows the winner at once |

A removal never deletes text by itself: rows do (their tombstones), and the store removes a note only when no row
points at it, at launch. The editing Mac's re-created rows stamp later than the removal (the replica's clock observes
note stamps), so they beat its tombstone. Restoring a Mac's sync state from scratch (a new device ID after a copied
data folder) keeps what it shows and sends only new edits.

**Replace this Mac's sidebar** keeps this Mac's pinned notes, with their folders and Spaces (`SyncMaterializer`'s
`kept`), and sends them; nothing a person typed is removed by a Replace.

**Recovery** (a lost zone) uploads, besides the batches, each Mac's latest version of every note it shows (whoever made
it) and their pictures, so a third Mac still gets every note.

### Older builds

A build from before notes synced (≤ the 2026-11-09 nightlies) reads the same zone safely:

- `SyncNote` and `SyncNoteAsset` are record types it doesn't know: its transport skips them (`read()`'s `default`), and
  its CloudKit mapping drops asset fields;
- a note's row goes only in a **version 2** batch (`SyncEnvelope`): it can't open those (`unsupportedVersion`), so it
  keeps them in its quarantine and says "Some changes can't be read here … updating Airc may help" instead of making
  note rows it has no note for; after an update the quarantine applies them;
- it keeps its own notes local, as before; once updated, its pinned notes are sent like returning local-only rows.

Its state file has no `notes` key; this build reads that as "nothing synced yet".

### iCloud refusing notes

Until the Production schema has the two record types, CloudKit refuses their saves. Such a refusal (`SyncEngine.holdsNotes`)
keeps notes and pictures queued and lets the rest of the cycle go on: Spaces, pinned tabs and Favorites sync, and
Settings → Sync says "Notes aren't syncing yet". Network, account, quota and zone failures stop the cycle as for batches.

## Splits

A pinned or Favorite split syncs (P14b2, `Sync/SplitSyncPayload.swift`). It needs **no record type of its own** and so
no CloudKit schema change: a split is a sidebar row like a folder, in the same sealed batches.

- **The split** is a `row` record of kind `split`: its place (Space or Favorites, folder, order), name and icon are
  ordinary row fields, and its **layout** is one `layout` field holding a `SplitSyncPayload`: a format number, the axis
  and each pane's share, by the pane's record. Shares are rounded to 1/10,000 so a layout read back never looks like an
  edit. Which pane has the keyboard is window state and stays on each Mac.
- **Each pane** is a `row` record of kind `tab` whose parent is the split, with its saved URL and its own fractional
  order key. A pane that was a pinned tab or Favorite keeps its record when it joins a split, as it does in the store.
- A Favorite split is one Favorite: its panes don't count towards the 12, and stay out with it when it's past them.
- A split with a **local-only** pane (a saved URL over 16 KB; an Easel, if older data has one) stays on its Mac as a
  whole, panes and all, like a [local-only row](#local-only-rows-saved-url-over-16-kb): other Macs keep its last synced
  version, or never see it.
- A **note** in a split now syncs like any pinned note (`SyncNotes.pinnedNotes`); a conflicted copy of it goes below
  the split, never into it as one more pane.

**What every Mac shows** (`SyncReplica.sidebar`, the same projection everywhere, so all Macs agree): only tabs sit in a
split, and a split only at a Space's root, in a folder or in Favorites. A split with fewer than two live panes isn't one:
its last pane takes its place (parent and order) as a pinned tab or Favorite, and the split row isn't shown. Panes
past four (`Split.maxPanes`, two Macs adding at once) sit next to the split as rows of their own.

### Conflicts

| What happened | Result |
|---|---|
| Two layout edits made apart (axis, sizes) | **last writer wins per split**: the later stamp's layout, whole |
| Panes reordered on one Mac, added or reordered on the other | **merged pane by pane**: each pane's order key is its own register, so a move and an add both stay |
| A rename or icon and a layout edit made apart | both stay (separate fields) |
| The split deleted on one Mac, edited on the other | **the deletion stands**: its tombstone and its panes' tombstones win over the edit. A pane the other Mac added meanwhile (one the deleting Mac never saw) isn't lost: it stays as a pinned tab where the split was |
| A pane deleted on the other Mac | the split keeps its other panes and their shares (in proportion); with one pane left it ends as that pane's row |
| Each Mac deletes a different pane of a three-pane split | the third pane is left alone, so it takes the split's place on both |
| Separate (one pane or all) | the panes are sent **whole** (kind, place, URL, no parent) in a version 1 batch, so a build that never read the split gets complete rows |

### Older builds

Every operation on a split or a pane goes in a batch of **envelope version 3** (`SyncSplits.isSplitOperation`: the
split's own record, a `layout` field, or a row whose parent is a split), the same way notes' rows use version 2. A
build from before splits synced (before P14b2) can't open version 3 (`unsupportedVersion`): it keeps those batches
in its quarantine, says "Some changes can't be read here … updating Airc may help", and applies them once updated. It
never makes split rows it doesn't understand, or panes without their split. Its own splits stay local, as before. Unknown
values inside a version 3 batch (a newer `SplitSyncPayload.format`) are ignored: the split keeps the layout it has here.

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
Favorites per profile show; the rest stay in the group. Today splits and blank-window Spaces are never touched.
Pinned and Favorite splits are applied with their panes.

A copied data folder (Migration Assistant, a restored backup) gets a device ID of its own: the state file remembers a
hash of the hardware UUID.

## Capability detection

`SyncCapability.container` reads the process's own entitlements (`SecTaskCopyValueForEntitlement`) and returns the
container only when `com.apple.developer.icloud-services` includes CloudKit. Nothing creates a `CKContainer` otherwise
(CloudKit raises an exception without the entitlement). Dev builds (ad hoc), test builds and release builds before the
profile exists show "iCloud sync is available in release builds once set up", with the switch disabled. Scripted runs
never use the real CloudKit.

## Tests

- `swift test --package-path packages/AircKit --filter SyncNotes`: notes (P14b1): vectors, sealing and record mapping, a
  large note in an asset, two and three Macs (text, title, pictures, row in its folder), concurrent edits and the
  conflicted copy, edit against delete (also a whole Space), offline edits across a relaunch, a picture over the limit,
  Replace keeping notes, a zone reset with a third Mac, unreadable records, older builds' view, and notes held while
  iCloud refuses their types.
- `swift test --package-path packages/AircKit --filter SyncSplits`: splits (P14b2): the payload's round trip and
  limits, version 3 batches and an older build's view (it quarantines them and has everything once updated), the
  projection (a split of one, five panes), a pinned split in a folder and a Favorite split on a second Mac, edits
  coming back, concurrent layout edits and pane order, delete against edit, a pane deleted on the other Mac, a pane
  left alone, and a split with a local-only pane or a note.
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
  it all at launch and a "push" while running. `icloudsync-unavailable` checks the page without a backend. With notes
  (P14b1): the first Mac's pinned note (title, text, a drawn picture) goes up sealed and its Today note doesn't; the
  second gets it in its folder with the picture and sends an edit; the third's Replace keeps its own note and Space;
  the first gets both at launch, and a pushed version shows in the open note's editor.

Test-build switches (never in public builds): `--sync-mock DIR` (mock CloudKit database), `--sync-folder DIR` (the
encrypted folder transport), with `--sync-keychain DIR` (this instance's fake keychain) and `--sync-device-name NAME`
(or `AIRC_SYNC_DEVICE_NAME`).

## Folders in Today

A Today folder (AircKit's `TodayFolders.swift`) is an `Item` in `.today(spaceID:)`; its tabs are Today tabs with
`folderID`. Today doesn't sync, so neither do they:

- `SyncStoreAdapter.snapshot` skips every Today folder (`supported`), and a Today tab's row (only with Today export,
  which is off) never carries `folderID`. A pinned folder dragged into Today leaves the snapshot: its record gets a
  tombstone and its pinned tabs leave Pinned as an unpin does, so other Macs lose the folder as if it were deleted.
- `SyncMaterializer` never touches a Today folder: a remote edit to the record of a folder this Mac moved into Today is
  skipped (`isTodayFolder`), a tombstone for it doesn't remove it, and Replace keeps it. A Space deleted elsewhere takes
  its Today folders with it (`removeTodayFolders`), after its Today tabs went to the Archive.
- Tests: `TodayFoldersTests.testTodayFoldersNeverEnterTheSyncPayload`; `paritytodayfolders` checks the payload in the app.

## Schema marks and going back to an older Airc

The store's meta `schema` is what its data needs (`SpacesStore.schemaMark`), not what wrote it: 1 for the first store,
2 from its first note (2026-11-07), 3 from its first Today folder (2026-11-10). The row that needs it raises it in the
same transaction, and it never goes down while a build that reads it runs. A backup is versioned the same way
(`StoreState.requiredSchema`: 3 with a Today folder, 2 with notes, else 1).

Every build so far treats a higher mark the same way (`SpacesStore.isNewer`): it says "Some data is from a newer Airc
and is kept for it", hides the rows it can't decode and keeps them on disk byte for byte (H4), keeps fields it doesn't
know in rows it writes (`SpacesStore.merge`), and refuses a backup with a higher version. So the downgrade rule for
schema 3 is:

| In the older build | What it does | Back in a schema-3 build |
|---|---|---|
| A Today folder row | Can't decode `.today`: hidden, kept on disk | The folder is there as it was |
| A tab in a Today folder | Reads it as a loose Today tab; a write keeps `folderID` | Back in its folder |
| It pins that tab, moves it to another Space or splits it | `folderID` stays on disk | `repairTodayFolders` takes it out of the folder |
| It archives the folder's last tab | The folder row stays (hidden) | An empty folder older than the archive interval goes at open |
| A backup with Today folders (version 3) | Refused, nothing restored | |

Checked against HEAD's real schema-2 AircKit (artifacts/todayfolders/downgrade-run.log) and in
`TodayFoldersTests.testANewFolderIsSafeInAnOlderBuild`.

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

### P14b1: notes (deployed 2026-11-10, verified)

`infra/release/cloudkit-schema.ckdb` adds two record types for notes. The owner deployed them to Production on
2026-11-10; `cktool export-schema --environment production` matches the file exactly (the same fields, and every
record type with `_creator` write, `_icloud` create, `_world` read). The real-iCloud check with notes
(`AIRC_SYNC_NOTES_SCHEMA=deployed`, below) then passed 27/0 in a test zone (`artifacts/notesreal/REPORT.md`). A
container without the types refuses note saves and the app keeps notes waiting (above); sidebar sync is unaffected.
These were the steps (keep them for the next schema change):

1. On the build Mac, with the management token as in step 1 above, import the updated file into **Development** (step 2
   above, unchanged command). `--validate` must pass.
2. CloudKit Console → container `iCloud.com.aircbrowser.Airc` → Development → Schema → Record Types: check **SyncNote**
   has `group` String, `device` String, `note` String, `version` Int(64), `sealed` Bytes, `payload` Asset, and
   **SyncNoteAsset** has `group` String, `version` Int(64), `data` Asset; both with the same security roles as SyncBatch
   (`_creator` write, `_icloud` create, `_world` read). No indexes are needed (records are only fetched by zone change
   and by name).
3. **Deploy Schema Changes…** → the summary must list exactly **2 added record types (SyncNote 6 fields, SyncNoteAsset
   3 fields)** and nothing modified or removed → Deploy.
4. Check: `xcrun cktool export-schema --team-id "$team" --container-id iCloud.com.aircbrowser.Airc --environment production`
   (token from the environment as in step 2) lists both, then run the real-iCloud check with notes (below).

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
   - With `AIRC_SYNC_NOTES_SCHEMA=deployed` (the schema has the note types): A's Space also holds a pinned note with a
     title, text and a drawn picture, and a note in Today. A reads the zone back from CloudKit: one sealed `SyncNote`
     with that title and text, one `SyncNoteAsset`, the row in a batch, none of the test's words or the picture's bytes
     readable in any field, and no Today note. B gets the note with its title, text and picture (not the Today note)
     and edits it.
   - `icloudsync-real-live-a` and `-live-b` (notes only): both installations at once under one UI-lock hold, taking
     turns through empty files in `AIRC_SYNC_REAL_HANDSHAKE`. B's edit arrives in A's open editor without a relaunch;
     then B edits and uploads, and A types in its editor before fetching: both Macs end with A's later text, and B
     keeps its own as "<title> (conflicted copy, <B>)", pinned, which reaches A.
   - Splits (P14b2): A also saves a pinned split (two panes, stacked, 30/70); its rows go up only in version 3
     batches, nothing readable. B gets it with its panes in order and its layout, renames it, turns it side by side
     and adds a third pane; A gets all of that in cleanup, and the zone is scanned again.
   - `icloudsync-real-cleanup`: the first installation gets the edits (with notes: scans the whole zone again for
     anything readable); then the test zone (records and subscription) and the test key are deleted, and both are
     checked gone.
3. Then the build, its data folders and the shots are deleted and the bundle unregistered (`lsregister -u`).

Still to test with the owner's OK and a second Mac: the synchronizable key through iCloud Keychain, two Macs with
pushes, offline and account changes, and a notarized release's first sync on a clean second Mac.

## Limits and follow-ups

- The log keeps every operation and tombstone (no compaction yet); fine for sidebars, but it grows.
- Note records and pictures are never deleted from iCloud: a deleted note's records (one per Mac that wrote it) and its
  pictures stay until the zone is deleted. Garbage collection needs the same all-device acknowledgement as the log.
- Merge doesn't detect the same Space on both Macs (each Mac's first "Personal" shows twice); Replace is the choice
  for a new Mac, and the screen offers it first when this Mac has nothing pinned.
- No key recovery or pairing without iCloud Keychain; no device retirement.
- Profile names sync only to name new empty profiles; renaming a profile on one Mac doesn't rename it on another.
- Silent pushes need the Push Notifications capability on the App ID (the profile's `aps-environment`); without it
  sync is on activation and every 10 minutes.

### Authorized two-Mac qualification

`--sync-two-macs` extends the real-cloud test only in `AIRC_TESTING` builds. It requires scripted/automated mode,
explicit isolated test data, an `AircSidebarTest` zone and a deadline less than thirty minutes away. The separate
service `Airc sidebar sync test (two Macs)` uses the provisioned access group, `synchronizable: true` and
`whenUnlocked`. Keys are never copied by the runner. Each zone gets its own test subscription. The existing
single-Mac `icloudsync-real-a/-b/-cleanup` scenarios retain their local-only key.

`Debug/ICloudTwoMacCheck.swift` drives the same SyncCenter and SpacesStore through a synthetic command mailbox.
It records first-sync sheet presence, backups, the independent same-named Spaces after Merge, Replace, edits,
Keychain lookup times and activation/push/fallback triggers. An injected network-unavailable error isolates the
app's CloudKit transport for offline conflict testing; it is not a physical network-disconnection test.

`scripts/sync-two-macs.py --dry-run --output DIR` runs both roles serially on the build host, under the UI lock.
Build/sign with `scripts/sync-test-build.sh` under the normal build locks; it uses the configured Developer ID
identity and provisioning profile with the matching Xcode compiler and SDK. Upload assertions read only committed
completion metadata from the isolated sync-state file (time, enabled state and pending-upload count), retaining
the UI timestamp separately. Account identifiers and sealed payloads are not exported by this probe.
The two-host mode additionally requires a prepared signed bundle archive and enforces the owner's single dated
access window. `scripts/sync-test-host.py` limits every launch, selects cleanup PIDs by the exact test bundle
executable path, and runs a bounded laptop guardian to remove its bundle/data and unregister it. No account
sign-out, real zone/key access, system network change, or public-build flag is introduced. Qualification remains
pending until both-host results and key/zone/subscription cleanup evidence are recorded by the operator.

### Qualification outcome, 2026-11-10

The two-Mac run was **not run**: all twelve connection probes in the authorized window timed out before a
connection was established. No test bundle was copied to the second Mac and no app was launched there.
Its process/filesystem state and test-resource absence were not remotely verified. The window is not reusable;
a further attempt requires a new authorization. Y01 remains owner-gated; Y02 was not covered.

Preparation at `786b641f` passed optimized builds for both engines, 94 Sync tests, 16 runner safety tests and
a full serial dry run on the build Mac. The Developer ID-signed test bundle passed Production/profile and
nested entitlement gates; it was not notarized and its profile has no push entitlement. Dry-5 verified the
first-sync sheet, Merge with duplicate same-named Spaces and a backup, edits in both directions after relaunch,
injected-offline rename versus delete, fresh-folder Replace with a backup, and test key/zone/subscription
cleanup in both roles on that one Mac. These are not cross-Mac key propagation or passive-arrival measurements.
The retained build bundle/helpers were unregistered and removed; a separate read-back found the task root
absent and zero own test processes. Evidence and exact timings: `artifacts/synctest/REPORT.md`.

The dry run exposed a UI timestamp follow-up: `SyncEngine.finishCycle()` saves a newer `lastSynced`, but a
cycle that remains `upToDate` with unchanged devices may not notify `SyncCenter`, leaving Settings' time stale.
Notify completion timestamp changes and add a regression for two consecutive successful `upToDate` cycles
refreshing SyncCenter/Settings. The harness qualifies uploads from persisted completion metadata and retains
the UI value separately; it does not fix this product issue.

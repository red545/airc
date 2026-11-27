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
| Pinned notes: their row, text, title and pictures ([Notes](#notes), P14b1) | Today splits, Easels, blank-window Spaces, telemetry IDs |
| Pinned and Favorite splits: their panes (saved URLs, order), name, icon, axis and sizes ([Splits](#splits), P14b2) | Which pane of a split has the keyboard; a split with a local-only pane (it stays whole) |
| App settings a person changed, from an allowlist ([Settings](#settings)) | Per-Mac settings: paths, Developer Mode, memory, approvals, onboarding |
| Boosts: style, zaps, CSS, on or off, deletions; their code only once allowed on each Mac ([Boosts](#boosts), P14b3) | A Boost held for its site (`needsSite`); Boost zoom bookkeeping |
| When an unpinned tab was last used, so its archive timer continues ([Archive timing](#archive-timing)) | The time of every use (it would be a browsing record) |
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
| `Sync/SettingSyncPayload.swift` | Settings: the payload, the allowlist and per-Mac list, the ledger of changed settings (version 4 batches) |
| `Sync/BoostSyncPayload.swift` | Boosts (code held per Mac) and archive timing (version 5 batches) |
| `apps/browser/Sources/Airc/Sync/SettingsSync.swift` | The app's settings as flat keys: reading, the ledger file, applying values from other Macs |
| `apps/browser/Sources/Airc/Sync/SyncCenter.swift` | Backend choice, triggers (activation, push, timer), profile and backup hooks |
| `apps/browser/Sources/Airc/Settings/SyncSettings.swift` | Settings → Sync and the first-sync screen |
| `apps/browser/Sources/Airc/Boosts/BoostCenter.swift`, `BoostEditor.swift` | Boosts from other Macs, and the editor's confirm for their code |
| `scripts/release/icloud.py` | The provisioning profile and the main app's iCloud entitlements (docs/release.md) |
| `infra/release/cloudkit-schema.ckdb` | The CloudKit schema |

## CloudKit layout

The private database, one custom zone **`AircSidebar`**, five record types:

| Type | Record name | Fields | Written |
|---|---|---|---|
| `SyncGroup` | `group` | `group` (UUID), `version`, `check` (bytes), `created` | once, by the first Mac, create-only |
| `SyncBatch` | `<device UUID>.<batch UUID>` | `group`, `device`, `envelope` (UUIDs), `version` (1; 2 with a note's row; 3 with a split's or a pane's; 4 for settings; 5 for Boosts and archive timing), `sealed` (bytes) | by its device, create-only, never changed |
| `SyncDevice` | `device.<device UUID>` | `group`, `device`, `sealed` (its name), `seen` | by its device, overwritten at most every 6 hours |
| `SyncNote` | `note.<device UUID>.<note ID>` | `group`, `device`, `note`, `version` (format 1), `sealed` (bytes, ≤ 256 KB) or `payload` (asset, ≤ 8 MB) | by its device, overwritten with its latest version of that note |
| `SyncNoteAsset` | `noteasset.<40 hex>` | `group`, `version` (1), `data` (asset: one sealed picture, ≤ 32 MB) | by the first Mac that has the picture, create-only, never changed |
| `SyncDevice` (an ack) | `ack.<device UUID>` | `group`, `device`, `sealed` (its `SyncGCAck`), `seen` (when written) | by its device, overwritten when its content changes ([Clean-up](#clean-up)) |

Records are deleted only by [Clean-up](#clean-up): a deleted note's text records, pictures no note uses, an old group.

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
| a read brings a `group` record of another group, or recovery finds one (another Mac started over, or set up anew after a reset) | **rejoins** (syncrecovery): forgets the old group's sync state (never the store), keeps the switches, joins the new group like a new Mac (waits for its key, then the first-sync screen with "started over on another Mac", Merge preselected, backup first). Before: recovery turned sync off |
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

## Settings

App settings sync too (syncsettings, 2026-11-16), with **no record type of their own** and so no CloudKit schema change:
each synced setting is one `setting` record in the same sealed batches, whose one field, `value`, holds a
`SettingSyncPayload`: the value as canonical JSON (sorted keys), at most 32 KB, and **when it was changed on its Mac**.

- **Keys.** The app (`SettingsSync.swift`) flattens its settings into keys: `app.<key>` for settings.json,
  `app.siteSearch@<profile>` and `app.askAI@<profile>` per profile, `blocking@<profile>` (on/off, third-party cookies,
  lists, exceptions; never the migration bookkeeping), `profile.archiveAfter@…`, `profile.searchEngine@…`,
  `profile.searchSuggestions@…` (store fields) and `window.sidebarOnRight`. Only keys on `SyncSettings.synced` ever leave
  a Mac; `SyncSettings.perMac` lists the ones that never do (backup folder, Library folders, Developer Mode and its sites,
  scripting from other apps, memory, pinned extensions, Little Airc's remembered profiles, the default-browser prompt,
  Calendar, per-row switches, dismissed cards, member name, onboarding). Agent and MCP settings (approvals, paired
  devices, tokens) live elsewhere and are never read. Per-profile keys carry the group's profile ID and map like Spaces'.
- **Only changed settings travel.** Each Mac keeps a `SyncSettingsLedger` (`Sync/settings-ledger.json`, never synced):
  every key's last seen value and, for those the person changed, when. It's kept whether sync is on or not. On its first
  look (or a key's: a new profile, an update), a value that differs from its default counts as changed at time 0;
  afterwards any change counts from then, even back to the default. A value from another Mac is adopted with that Mac's
  time. A default is never sent, so a Mac that never changed a setting takes the synced one.
- **Last writer wins per setting**: the later change time, then the later stamp, then the operation ID
  (`SyncRegister.precedes`), so every Mac picks alike, and a change made while sync (or "Sync settings") was off still
  counts from when it was made.
- **Engine.** `capture()` sends each changed setting whose value this Mac hasn't sent or applied yet (the state file's
  `settings.baseline`), then applies the winners it hasn't applied; `apply()` does the same after the sidebar, so the
  first sync's Merge captures this Mac's settings before iCloud's are applied. A value the app can't read (a newer
  build's), a newer payload format, or a profile this Mac lacks waits and is tried again. "Can't read" includes a value
  that would read as something else here (a search engine a newer build added): taking its fallback would send the
  fallback back as this Mac's change and replace the other Mac's choice. An archive interval is kept as it came
  (`ArchiveInterval` stores its raw string): one a newer build added acts as 12 hours here and syncs back unchanged.
  That is why Never, 1 hour and 6 hours (known to every build since) are offered in the pickers only from the release
  after the one that made intervals keep their value (`ArchiveInterval.moreChoicesByDefault`): up to 0.1.47 a Mac
  that receives "never" applies 12 hours and sends "twelveHours" back with the other Mac's change time, which replaces
  "never" everywhere (AircKit's ArchiveIntervalCompatTests shows it with the shipped enum). Replace replaces the sidebar,
  not settings: they follow the same rule.
- **The switch.** Settings › Sync › "Sync settings", on by default, per Mac (`settings.off` in the state file). Off sends
  and applies nothing (the replica still merges what arrives); on catches up by the rule.
- **Applying** is what Settings would do: settings.json's values, then the live parts (translucency in every window, the
  shortcut map and its menus, ⌘1–9 choices, the app icon); Little Airc follows settings.json by itself; the store's
  profile fields and the sidebar's side through the store; blocking through BlockingSettings (its rules reload).

### Older builds

Every setting operation goes in a batch of **envelope version 4** of its own (never mixed with sidebar operations). A
build from before settings synced reads 1...3: it keeps those batches in its quarantine ("Some changes can't be read
here … updating Airc may help") and applies them once updated. A version 3 batch could not carry them: a 1...3 reader
would fail on the unknown record kind inside, and a mixed batch would hold back a split's operations too.

### Tests

- `swift test --package-path packages/AircKit --filter SyncSettings`: the allowlist and the excluded keys, the payload in
  a sealed version 4 batch (refused by a 1...3 reader, malformed values refused), the later change winning whatever the
  stamps, the ledger, and two engines: theme, shortcut and Site Search arrive, per-Mac keys never leave, a Mac that never
  changed a setting takes it and defaults never travel, the conflict rule on both Macs, the switch, an unreadable value
  and a missing profile waiting, and an older build's view.
- `--script settingssync-a`, `-b`, `-a2` (Debug/SettingsSyncCheck.swift, in the snapshot suite on both engines): two app
  instances on a mock database. A's theme, shortcut (live in B's map), Site Search and sidebar side reach B, with
  nothing readable in iCloud and only allowlisted keys sent; per-Mac settings stay on each Mac; B's later change wins on
  both.

## Boosts

Boosts sync too (boostsync, 2026-11-17, P14b3), again with **no record type of their own** and no CloudKit schema
change: each site's Boost is one `boost` record (its ID the site, `BoostDomain.key`) in the same sealed batches, whose
one field, `value`, holds a `BoostSyncPayload`: its name, on or off, colours, font and size, zaps, CSS, JavaScript and
its host, where it came from (`BoostOrigin`), its dates (whole seconds), and **which Mac the person allowed the code
on** (`allowedOn`). A deletion is a payload too (`removed`), so it reaches every Mac and an older copy never comes back
(`BoostStore.removed` keeps when each site's Boost was deleted). At most 256 KB, like a Boost file; a larger Boost, and
one held for its site (`needsSite`), stay on their Mac.

- **Last writer wins per site**: the later change time on its Mac, then the stamp, as for settings. The editor's
  changes are whole-Boost writes, so two Macs editing one Boost at once keep the later one whole.
- **Style applies at once**: tint, filters, font, size, zaps and CSS show on the site's open pages as soon as they arrive,
  as a local edit would (CSS `@import`s keep their rules).
- **Code never runs because it synced.** JavaScript from another Mac lands in `Boost.heldCode`, never in `Boost.js` (the
  code that runs), so even a build that doesn't know `heldCode` can't run it. Code already allowed on this Mac, byte for
  byte and for the same host, keeps running; any other code arriving stops the old code here and waits.
- **The decision (P14b3).** The person's consent to run a Boost's code on one Mac is evidence, not authority, for the
  next Mac: the payload names the Mac where the code is allowed (where it was written or allowed, or installed through
  the review and switched on; BST-2 installs someone else's code off), and the next Mac asks with a **one-click confirm naming it** in the Boost editor ("Run this code
  here too? You allowed this Boost's JavaScript on <Mac>." · Show Code · Run on This Mac). Site Controls says "Its code
  waits for you". Code that no Mac vouches for gets the **full review**: the warning the install review shows, and Run
  only after Show Code. Nothing in sync turns code on: the click is per Mac. Why not one consent for all Macs: the person
  agreed to run code on one machine, whose pages and logins they had in front of them; a second Mac has other profiles
  and sites signed in, and anyone who could write into the person's zone with the group key could otherwise run code on
  every Mac at once. Why not the full review every time: the person already read and allowed this exact code; asking
  again in full would teach them to click through. Allowing sends the Boost again with this Mac as `allowedOn`; a Mac
  whose copy is the same code keeps running it.
- **Reset All Edits** and Delete act on every Mac, like any edit. Writing new code in the editor replaces held code.
- **The switch.** Settings › Sync › "Sync Boosts", on by default, per Mac (`boosts.off` in the state file). Off sends and
  applies nothing; on sends what changed here meanwhile and takes the rest by the rule. Held code waits either way.
- **Engine.** As settings: `capture()` sends each Boost whose content (the payload without `allowedOn`) this Mac hasn't
  sent or applied (`boosts.baseline`), then applies the winners; a newer payload format, or a site the app can't take
  now, waits and is tried again.

## Archive timing

Today tabs never sync, so a Today tab's archive timer is its own Mac's. One case crosses Macs: a pinned tab unpinned on
one Mac becomes a Today tab there, and on every other Mac that has its page open, the page stays as a Today tab too. Its
timer then ran from that Mac's own last use, which could be days old (archived at once) although the person had just
used it on the other Mac. Now the Mac that unpins also sends when it last used the tab (`SyncField.used` on the row, ms,
an operation of its own in a version 5 batch), and a Mac that keeps the page continues its timer from the later of its
own last use and that one (`SpacesStore.applySyncedUses`; never earlier, never past now, so a Mac whose clock runs ahead
can't keep a tab forever). The register keeps the latest use any Mac sent. Only unpins send it: the time of every use
would turn the append-only log into a browsing record. The unpin itself still goes in a version 1 batch, so an older
build unpins as before and only its timer starts from its own use.

### Older builds (Boosts and archive timing)

Boost and last-use operations go in batches of **envelope version 5** of their own. A build from before Boosts synced
reads 1...4: it keeps them in its quarantine ("updating Airc may help") and applies them once updated; every other batch
still reads there, so the sidebar, notes, splits and settings keep syncing with it. Its Boosts.json reader ignores
`heldCode` and `removed` (it never runs held code), and a Boost whose only content is held code looks empty there.

### Tests (Boosts and archive timing)

- `swift test --package-path packages/AircKit --filter SyncBoosts`: the payload (whole seconds, limits, `allowedOn` not a
  change), version 5 sealing refused by a 1...4 reader, malformed operations, the later change and the later use winning,
  the consent rule (held, kept running, stopped, the first vouching Mac kept, no vouch, exact hosts), an older build's
  Boosts.json never running held code, two engines on the mock database (style arrives, code waits naming A, no echo,
  allow, a style edit keeps allowed code running, a code edit asks again, deletion), the switch and a site applied later,
  an older build's view, and a tab unpinned on A continuing its timer on B from A's later use.
- `--script boostsync-a`, `-b`, `-a2`, `-b2` (Debug/BoostSyncCheck.swift, in the snapshot suite on both engines): two app
  instances on a mock database and a loopback page. A's Boost: B's page shows its CSS at once and its code doesn't run;
  the editor's one-click confirm names A (boostsync-confirm.png), Run on This Mac reloads the page and the code runs; a
  Boost no Mac vouched for needs Show Code first (boostsync-review.png); a tab A uses after B and unpins keeps its timer on
  B from A's use.

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

A backup (`airc-before-icloud-…json` in the backups folder) is taken first either way, through `settings.backUp` like
every other backup: a chosen folder that's gone or read-only falls back to the default one (the choice stays). If no
folder can be written, `choose` throws `SyncFirstSyncBackupFailure` before anything is merged, replaced or sent; the
engine stays `.choosing` (no retry, no other status) and the screen says the backup failed. Profiles: the group's default
profile maps to this Mac's default profile; others to a choice (a profile of this Mac, offered first when the name
matches, or a new empty one). Several of the other Mac's profiles may share one profile here (the screen says so); it
then syncs back as the first one mapped, the default one if it's among them. Profiles another Mac makes later arrive as
new empty profiles with their names.
Cancel turns sync off and changes nothing.

### Recovery key (no iCloud Keychain)

`SyncRecoveryKey` (K/Sync/SyncRecovery.swift) writes the group key out for a person: the 32 bytes plus a 3-byte checksum
(SHA-256 of a fixed prefix and the key), Crockford base32, 14 groups of 4 (`XXXX-…`). Parsing forgives case, spaces,
dashes and O/I/L; a wrong length, character or checksum is `.malformed` ("check it for typos").

- **Showing it:** Settings › Sync › Recovery key › Show… on a Mac that has joined and has the key, after
  LocalAuthentication's `.deviceOwnerAuthentication` (scripted test runs skip it). `SyncEngine.recoveryKey()`. It's
  shown and copied, never stored anywhere else.
- **Using it:** only while `.waitingForKeychain`. `useRecoveryKey(_:)` fetches the group record and checks the key with
  its `check` (another group's key: `.otherGroup`), then **adds** it to the key store, the same item iCloud Keychain
  would bring (never replacing one; a different key under that name is `.keychain`). The cycle goes on: a new Mac to
  the first-sync screen, a joined Mac where it left off (its replica, adapter and outbox are untouched while it waits; a
  capture needs the key, so nothing is sealed meanwhile and the next capture sends the edits made since).
- **A joined Mac without its key** fetches the group record once a minute while waiting: another group means it was
  started over elsewhere, and it rejoins (below).

### Starting over

`startOver()` is offered only while `.waitingForKeychain`, and refuses (`.notWaiting`) if the key is in the store after all.
1. The backup, through the first sync's hook: a failure throws `SyncFirstSyncBackupFailure`, nothing changes.
2. A new group UUID and key, added to the key store.
3. `replaceGroup(_:replacing:)` overwrites the `group` record if it's still the group this Mac was waiting for (or
   none), then reads it back. CloudKit has no compare-and-swap for it: two Macs starting over at once both write, the
   last wins, and the other rejoins at its next read. A Mac that sees another group already there removes its unused key
   and throws `.startedElsewhere`.
4. This Mac's state is the first Mac's: a new replica, outbox, checkpoint, note state, and cleared settings and Boost
   baselines (their switches kept). The adapter keeps its record aliases and profile mappings
   (`SyncStoreAdapter.restarted()`), so the same records and group profile IDs come back, and a Mac that rejoins maps
   them without asking and merges without duplicates.
5. A capture of the whole sidebar, then a normal exchange.

**Nothing in iCloud is deleted by the start-over itself.** The old group's batches, device and note records and pictures
stay. Batches, devices and notes of another group are skipped silently (a note record of another group isn't
"unreadable"). [Clean-up](#clean-up) deletes them once every Mac of the old group has rejoined or is gone.

**Rejoining** (`rejoin()`, any Mac that finds another group): a fresh state with the same device, account, switches
and `lastSynced`, the adapter's `restarted()` mappings, and `restarted = true`; the key is forgotten in memory only (the
old item stays in the keychain: deleting a synchronizable item deletes it on every Mac). Then `join` as for a new Mac.
`SyncFirstSync.restartedElsewhere` makes the screen say so and preselect Merge; profiles the old adapter mapped aren't
asked about again. Merge captures the store, edits that never reached iCloud included.

## Clean-up

syncgc (`Sync/SyncGarbage.swift`, the engine's `collect` step at the end of every cycle) deletes records nothing needs any
more, in two phases: what qualifies is first agreed by every Mac that counts, then deleted after a **settle delay**, if it
still qualifies then. No CloudKit schema change: deletes are plain record deletes (`SyncCloudDatabase.delete`; a record
that isn't there counts as deleted), and each Mac's answers go in an **ack**, a `SyncDevice` record named
`ack.<device>` whose `sealed` field is a sealed `SyncGCAck` (AAD `Airc-sync-ack|group|device`). Builds from before
syncgc map only `device.<device>` names, so they ignore acks.

| What | Deleted when | By |
|---|---|---|
| A deleted note's **text** records (a version the removal saw) | every Mac that counts lists the note as removed with the same version vector, and still does a settle delay later | each Mac its own record; the collector those of Macs that don't count |
| A deleted note's **removal** records | never: tombstones without text (~300 bytes), so a Mac that edited the note while away still finds the removal and keeps its edit ([Conflicts](#conflicts)) | |
| **Pictures** no note shown on any Mac uses | the collector proposed them, every Mac that counts answered which it still uses (`keep`), and a settle delay passed | the collector |
| An **old group** (after a Start Over) | no device record of that group was written within the horizon (each old Mac rejoined, so its device record names the new group, or is gone), still so a settle delay later | the collector |
| The current group's batches, device records, the group record | never (log compaction and device retirement are separate) | |

- **Who counts:** every Mac whose device record or ack of this group was written within the **horizon** (30 days;
  `SyncGarbage.horizon`), and this one. While one of them has no readable ack (an older build, a newer ack format),
  nothing is deleted. The **collector** is the one with the lowest device UUID.
- **Settle delay:** 24 hours (`SyncGarbage.settle`; scripted checks pass `--sync-gc-settle 2`).
- **Only from a clean state:** nothing is collected, and no ack sent, while this Mac has unreadable batches or note
  records, anything waiting to upload, a recovery or an unfinished apply. A clean-up failure never fails the cycle.
- **The ack** (`SyncGCAck`, format 1): `notes` (each note removed here, not pinned, nothing of it waiting to go up, with
  its `known` vector, and when this Mac deleted its own text record; kept 90 days after that), `seen` and `keep` (the
  proposal epoch read per collector, and which of its pictures this Mac still uses), `proposal` (the collector's own),
  `gone` (pictures it deleted, a year or 2000 at most). Published when its content changes.
- **The inventory:** the transport reports every record's name, type and group (`SyncReadReport.records`); the engine
  keeps pictures and other groups' records (`SyncGCState.inventory`). It's complete after a full read: the first cycle
  after an update rescans once (`rescan()`).
- **Checked again before each delete:** a text record is fetched and deleted only if its version is still one the
  agreed vector covers; another group's mutable record (`note.`, `device.`, `ack.`) only if it's still that group's.
  Batches and pictures are create-only.
- **Crash safety:** the plan is saved before anything is deleted; a quit, crash or network failure mid-way leaves it,
  and the next cycle checks it again and finishes. Pictures are announced in `gone` after they're deleted.
- **Pictures stay whole:** a Mac that reads a proposal stops counting those pictures as uploaded (unless it uses them),
  and one that reads `gone` queues the deleted pictures its pinned notes use again; so a picture used again after it was
  proposed or deleted is uploaded again. A proposed picture a Mac keeps (a Today note) isn't proposed again for a horizon.
- **A Mac that comes back after the horizon** loses nothing: it clears what it believes is uploaded (pictures go up again
  on their next use), its edits to a deleted note win over the kept removal, and its stray batches into an old group
  are collected later.

### Tests (clean-up)

- `swift test --package-path packages/AircKit --filter SyncGarbage`: the ack record and its older-build view, the
  transport's acks, inventory, deletes and rescan, and three engines on the mock database: a deleted note's texts and
  picture going after agreement and the settle delay (nothing before), a Mac away within the horizon holding it back,
  a Mac gone past the horizon not holding it back and losing nothing when it returns, a live older build blocking
  everything, a picture a Today note or another Mac uses staying and one used again going up again, a crash mid-delete
  finished after a relaunch, a note unpinned to Today and pinned again, and Start Over with the old group collected once
  every old Mac rejoined or is gone.
- `--script icloudsync-gc-a` … `-c3` (Debug/ICloudSyncGCCheck.swift, both engines, `--sync-gc-settle 2`): three app
  instances on a mock database; C deletes a note all three edited; nothing goes while A and B haven't answered; then each
  Mac's own text record, and the picture; only C's removal is left, the other note and picture stay, nothing readable.

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
- `swift test --package-path packages/AircKit --filter SyncRecovery`: the recovery key's round trip and typos, a Mac
  without iCloud Keychain joining with it, a joined Mac that lost its key resuming and sending its edits, start over with
  a failed backup (nothing changes) and while the key is there (refused), start over and the other Mac rejoining with an
  unsynced edit and nothing twice, a Mac without a key noticing a start-over, an old recovery key refused, a lost
  start-over race, and a zone reset to another group rejoining instead of turning sync off.
- `--script icloudsync-recovery-a`, `-b`, `-c`, `-a2` (Debug/ICloudSyncRecoveryCheck.swift, both engines, no key file ever
  copied): A shows its recovery key; B joins with it (a typo and another key refused, Merge after a backup); C starts over
  (backup, new group, old batches kept); A notices, keeps its unsynced tab, joins with C's key and merges, nothing twice.
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

- The log keeps every operation and tombstone (no compaction yet); fine for sidebars, but it grows. [Clean-up](#clean-up)
  deletes deleted notes' texts, unused pictures and old groups, not the current group's batches; compacting them would
  reuse its acks (a snapshot every Mac has acked past).
- Merge doesn't detect the same Space on both Macs (each Mac's first "Personal" shows twice); Replace is the choice
  for a new Mac, and the screen offers it first when this Mac has nothing pinned.
- No device retirement (a gone Mac's device record stays). Without iCloud Keychain, a Mac joins with the recovery key
  (above); a start-over's old group is deleted by [Clean-up](#clean-up).
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

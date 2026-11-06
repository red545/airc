# Code review: security, correctness, performance

Independent review of the tree at `bd7346c` (2026-11-05), with other agents' uncommitted work in progress. I
read the code; I did not run the Chromium engine build. Findings marked **verified** were reproduced on the
build Mac with throwaway tests (not committed). The rest are argued from code, with `file:line` references.
Line numbers are from this snapshot and will drift.

## Summary

No Critical findings. The security basics are sound: the engine's test hooks fail closed on signed builds,
Airc has its own Keychain item, secrets aren't logged, and the release entitlements match Chrome's. The
problems are the kind the owner hit with Create Space: features that look finished but drop their work without
saying so, and two places where one profile's data or pages can end up in another profile's Space.

- **Arc logins and cookies never reach the browser.** They are decrypted, held in plaintext until quit, then
  thrown away, while the onboarding copy says "Read and re-encrypted here" (H1). If Arc is running, the read
  usually fails, and the UI reports "0 logins and 0 cookies are ready" as a success (H2).
- **Profile isolation:** ⌘Z puts a closed tab back with its *old* profile, so a Personal Space can show a page
  signed in to Work (H3, verified). Tabs that arrive without an opener are filed under whatever Space is
  showing (M2).
- **Data loss:** one store row that this build can't decode makes launch delete that Space's pinned tabs from
  disk, permanently, and move its Spaces to the default profile (H4, verified).
- **Speed:** with a full history (20,000 entries), each keystroke in the Command Bar costs about 110 ms on the
  main thread, on an M5 in a release build (H5, verified). Every page-title change rebuilds every Space's
  sidebar (M3). Each launch of the Chromium engine creates and loads a new, unused Chromium profile (H6).
- **The Create Space root cause is still live** in AircDesign. The app works around it, but `AircSidebarCard`
  still uses the broken button style (M1).

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 6 |
| Medium | 7 |
| Low | 5 |

## High

### H1. Imported Arc logins and cookies never reach the engine, and the UI says they were re-encrypted

- **Where:** `apps/browser/Sources/Airc/Import/CredentialImport.swift:18-28` (`PendingCredentials`, the only
  `CredentialSink`), `apps/browser/Sources/Airc/Onboarding/OnboardingController.swift:409`,
  `apps/browser/Sources/Airc/Onboarding/OnboardingViews.swift:391` and `:418`,
  `apps/browser/Sources/Airc/Engine/ChromiumEngine.swift:36` (`importCredentials`, which nothing calls).
- **Problem:** "Import logins" asks for Arc's Keychain item, decrypts every password and cookie of every
  profile, and passes them to `PendingCredentials.shared`, which keeps them in a dictionary until the app quits.
  This happens even with `--engine=chromium`, where `ChromiumEngine.importCredentials` →
  `AircProfile.importLogins/importCookies` exists and works. The step's rows promise "Read and re-encrypted
  here", and Settings → Import says the logins are "held for the Chromium engine until you quit".
- **Failure scenario:** The owner runs onboarding on the Chromium build, presses Import logins, enters their
  Mac password, sees "1,240 logins and 8,300 cookies are ready", and quits Arc. In Airc they are signed out
  everywhere, and Password Manager is empty. Meanwhile every plaintext password stays in the app's heap for the
  whole session, with no use.
- **Fix:** Make the sink the engine. Add `importCredentials` to the `BrowserEngine` protocol; for each mapped
  profile, call it with `ProfileHost.whenLoaded(profileID)`, and report the engine's `submitted`, `rejected`
  and `accepted` counts, not the number read. On WebKit, don't read or decrypt at all: hide the step, or say
  "Logins come over with the Chromium engine". Remove `PendingCredentials`, and drop the plaintext arrays as
  soon as the engine's completion runs. Until this is wired, change "re-encrypted" to what actually happens.
- **Confidence:** high.

### H2. Credential import fails silently while Arc is running, or on any one bad row, and reports success

- **Where:** `packages/AircImport/Sources/AircImport/Credentials.swift:106` (`sqlite3_backup_step` on the live
  database), `:146`, `:171` and `:173` (one row throws for the whole profile),
  `apps/browser/Sources/Airc/Import/CredentialImport.swift:57` (`failedProfiles` is counted and never shown),
  `apps/browser/Sources/Airc/Onboarding/OnboardingController.swift:413`.
- **Problem:** Chromium opens `Login Data` with the default `sql::DatabaseOptions`, whose `exclusive_locking`
  is `true` (`sql/database.h:350`, `login_database.cc:1085`). While Arc runs, it holds an exclusive lock, so
  the backup step gets `SQLITE_BUSY` → `databaseFailed`. Logins are read before cookies, so that profile's
  cookies are lost too. Separately, any one row that fails (a non-UTF-8 value, a `v11` blob, a cookie whose
  host hash doesn't match) aborts the whole profile. Both cases end up in `outcome.failedProfiles += 1`, which
  no UI reads. `.done(logins: 0, cookies: 0)` then renders as a green check: "0 logins and 0 cookies are
  ready."
- **Failure scenario:** People switching from Arc keep it open during onboarding. Every profile fails, and
  the user is told the import succeeded. (I verified the lock behaviour from Chromium's source; I did not run
  the import against a live Arc.)
- **Fix:** (1) Check `NSRunningApplication.runningApplications(withBundleIdentifier: "company.thebrowser.Browser")`
  before reading, and ask the user to quit Arc. (2) Treat `SQLITE_BUSY` as its own error, "Quit Arc and try
  again", rather than `databaseFailed`. As a fallback, copy the file together with its `-journal`/`-wal`
  files into the 0700 temp folder and open the copy read-only. (3) Skip and count bad rows
  (`skippedLogins`, `skippedCookies`) instead of throwing. (4) Show `failedProfiles` and the skip counts. Treat
  zero logins with a failed profile as a failure, not "ready".
- **Confidence:** high that failures are silent; medium-high that the lock is held (from the source, not run
  against Arc).

### H3. ⌘Z restores a tab with its old profile: a Work page appears in a Personal Space (verified)

- **Where:** `packages/AircKit/Sources/AircKit/SpacesStore.swift:384-397` (`undo` puts back the before-image
  as it was), `packages/AircKit/Sources/AircKit/StoreActions.swift:159` (`setProfile` is not undoable, and the
  undo stack survives it), `apps/browser/Sources/Airc/Browser/WindowController.swift:376` (`ensurePage` loads
  the page in `tab.profileID`'s engine profile).
- **Problem:** Undo entries keep each entity's full earlier value, including `LiveTab.profileID`. If the
  Space's profile changes between the action and ⌘Z, undo puts the tab back with the old `profileID` in a
  Space that now uses another profile. That breaks the invariant documented at `Model.swift`
  (`profileID` "Always the Space's profile"). Nothing repairs it until the next launch.
- **Verified:** In a test, I closed a Today tab in a Work Space, changed the Space to the default profile and
  pressed undo. The result was `space profile=default tab profile=work tab space=true`.
- **Failure scenario:** Close a banking tab in the Work Space, then move that Space to Personal (or delete and
  recreate profiles), then ⌘Z. The tab reappears in the Personal Space, signed in with Work's cookies, and its
  visits go into Work's history while the user sees a Personal Space. The same goes for Delete Space → delete
  the now-unused profile → ⌘Z. That restores Spaces and tabs that point at a deleted profile, so the tabs can't
  load (`engineProfile(for:)` is nil) and fail without a message.
- **Fix:** After `undo` applies the before-images, normalise inside the same `perform`: give each restored tab
  its Space's `profileID` (Favorites keep theirs only if that profile exists). Return the tab IDs whose profile
  changed, so the window calls `reloadPagesInNewProfile`. Also clear or filter the undo stack on
  `setProfile`, `deleteProfile`, `applyImport` and `restore(fromBackup:)`. Add the invariant as a test that
  runs after every store action.
- **Confidence:** high.

### H4. One undecodable row in the store makes launch permanently delete pinned tabs and move Spaces to the default profile (verified)

- **Where:** `packages/AircKit/Sources/AircKit/SpacesStore.swift:167` (rows that fail to decode are skipped),
  `:180-221` (`repair()` runs next, and its changes are written to disk), especially `:195` and `:200-201`.
- **Problem:** `load()` drops any entity it can't decode. That happens with a new enum case (`SearchEngine`,
  `ArchiveInterval`, `SpaceIcon`, `ItemKind`), a new non-optional field, an older build reading a newer
  store, or one damaged row. `repair()` then treats the missing parents as gone. It calls `removeItemTree` on
  every pinned item and Favorite whose Space or profile it couldn't read, removes their tabs, and moves the
  Spaces of an unreadable profile to the default profile. All of this is committed, so the rows are deleted
  from `entities`.
- **Verified:** I opened a store with one Space and one pinned tab, renamed one key in that Space's JSON, and
  reopened it. The result was `items=1` before, `items=0` after, and 0 item rows left on disk.
- **Failure scenario:** A later build adds `SearchEngine.perplexity`; the owner tries it, then goes back to an
  older build or a nightly that lacks the case. Every profile with that engine fails to decode. Its Spaces move
  to Personal (so they run on Personal's cookies), and its Favorites are deleted for good. Sync, when it comes,
  will spread the deletions.
- **Fix:** Never write repairs caused by rows that failed to decode. Keep those rows' raw JSON, mark the
  store degraded, and either refuse to repair parents you couldn't read or keep their children hidden in
  memory. Write decoders that tolerate change: `decodeIfPresent` with defaults for every field, and enums with
  an `unknown(String)` case that round-trips. Bump `schemaVersion` with explicit migrations, and refuse to open
  a store whose schema is newer than the build (show "This data was written by a newer Airc").
- **Confidence:** high on the mechanism. No such field has been added yet, but the next model change triggers
  it.

### H5. The Command Bar costs about 110 ms of main-thread work per keystroke with a full history (verified)

- **Where:** `packages/AircKit/Sources/AircKit/History.swift:109-124` (scans every entry, parses its URL and
  scores both the title and the display URL), `apps/browser/Sources/Airc/CommandBar/CommandBar.swift:236`,
  `:251` and `:265` (inline completion plus `commandResults` on each keystroke, and again when suggestions
  arrive), `CommandBar.swift:584`.
- **Measured** in a release build on the build Mac (M5), with 20,000 entries (the per-profile cap):

  | Query | `search` | `inlineCompletion` |
  |---|---|---|
  | `g` | 107 ms | 7.7 ms |
  | `git` | 120 ms | 7.4 ms |
  | `site12` | 117 ms | 7.8 ms |
  | `page title` | 83 ms | 0.4 ms |

  Both run on the main thread, before the row reload and the rest of `commandResults`.
- **Failure scenario:** After a few months of use, typing in ⌘T or ⌘L stutters on every key, about 13 frames
  dropped per keystroke at 120 Hz, and twice when suggestions arrive. The 0.12 s suggestion debounce doesn't
  help, because this work isn't debounced.
- **Fix:** Precompute each entry's lowercased display URL and title once, at insert time. Keep a host/prefix
  index (a sorted array or trie) for inline completion, and score only prefix and word-boundary candidates.
  Cap the scan at the top N by frecency (Chrome scores about 100 candidates per keystroke). Then run the
  scoring off the main thread with a generation counter, as `SuggestionService` does, so the row update stays
  under 2 ms. Add a perf test that fails above about 4 ms per keystroke at 20,000 entries.
- **Confidence:** high. The timing is from the real `HistoryStore`, not the app.

### H6. Each launch creates and loads a new Chromium profile that is never used, and never removed

- **Where:** `apps/browser/Sources/Airc/Browser/ProfileHost.swift:60-68` (`prepareSpare` picks a random
  `Profile-xxxxxxxx` folder), `apps/browser/Sources/Airc/App/AppDelegate.swift:205` (called in `didOpen` on
  every launch), `engine/core/airc_engine.mm:189-214` (`CreateProfileAsync` creates the folder and registers
  it in Local State), `engine/core/airc_profile.mm:302-305`.
- **Problem:** The spare's folder name lives only in memory. If the user doesn't create a profile during that
  session, the folder stays in the Chromium user data folder, Local State's profile list keeps it, and next
  launch makes another one. Every session also keeps a whole extra Chromium profile loaded: its KeyedServices
  (history, password store, prefs, extensions). `warmSpareRenderer` aims Chromium's single spare renderer at
  this unused profile, so a real tab in the user's own profile no longer gets the warm process.
- **Failure scenario:** After 100 launches there are 100 orphan profile folders, each with its own databases.
  The engine carries tens of MB of profile services for nothing, and new tabs in the real profile start
  slower. The cost is my estimate, not measured; I didn't run a Chromium build.
- **Fix:** Persist the spare's folder in the store (for example `WindowState.spareEngineDirectory`) and reuse
  it on the next launch. Better, don't load a profile ahead of time: create it when "Create Profile" is
  pressed, while the card animates, and warm a renderer for the *current* profile only. At launch, delete any
  `Profile-*` folder in the user data folder that no store profile references.
- **Confidence:** high that the folders are orphaned (it follows from the code); medium on the memory cost.

## Medium

### M1. The Create Space bug's root cause is still in AircDesign, and a shipped component still has it

- **Where:** `packages/AircDesign/Sources/AircDesign/Tokens/AircShadow.swift:65-71` (`aircShadow` returns an
  `AnyView` wrapped once per shadow layer, so a press that changes the layer count changes the view's
  identity), `packages/AircDesign/Sources/AircDesign/Components/AircButton.swift:115`,
  `packages/AircDesign/Sources/AircDesign/Components/AircProfile.swift:287` (`AircSidebarCard`'s primary
  button uses `.airc(.primary, size: .small)`).
- **Problem:** The app worked around it with `AppButtonStyle`, but `.airc(.primary/.secondary/.destructive)`
  still doesn't fire on a real click. `AircSidebarCard` is the "sign in to Google" sidebar card
  (`DesignGaps.signInCardHeight` is already reserved in `SpacePage.swift`), and its primary button is dead as
  soon as the app uses it. The gallery and docs still recommend `.airc(…)`.
- **Fix:** Give `aircShadow` a fixed structure: always apply the same number of `.shadow` modifiers, using a
  clear colour and zero radius for missing layers, with no `AnyView`. Then delete `AppButtonStyle` (the canary
  in `EventTests.swift:173` will report it). Until then, make `AircSidebarCard` take its button style from the
  caller.
- **Confidence:** high.

### M2. A tab with no known opener is filed under the Space that is showing, even when its page runs in another profile

- **Where:** `apps/browser/Sources/Airc/Browser/WindowController.swift:696`
  (`let spaceID = openerTab?.spaceID ?? currentSpaceID`), with `store.openTab` setting `profileID` from that
  Space.
- **Problem:** Chromium creates a tab in the profile that asked for it. Examples are an extension's
  `chrome.tabs.create` or its welcome page, a web notification click, or an opener that isn't mapped. When
  that profile isn't the current Space's, the store records the tab under the current Space's profile while
  the page runs in the other one. The `EngineTab.profile` property exists, but nothing checks it.
- **Failure scenario:** A password-manager extension in Work opens a tab while the user is in a Personal Space.
  The tab appears in Personal, signed in to Work. Its visits are written to Personal's history and Command Bar
  (`recordVisit(profileID: tab.profileID…)`, `:742`). After relaunch, `ensurePage` reloads it in Personal.
- **Fix:** In `didInsertTab`, compare `tab.profile` with the chosen Space's engine profile. If they differ,
  use the last active Space of the tab's profile and switch to it for foreground dispositions. If the profile
  has no Space, close the tab or show a toast.
- **Confidence:** medium. The code path is clear; I didn't trace which engine events arrive with no opener.

### M3. Every page title, URL or favicon change rebuilds every Space's sidebar

- **Where:** `packages/AircKit/Sources/AircKit/StoreActions.swift:274` (`updateTab` → `perform(deferred:)`
  still notifies observers), `apps/browser/Sources/Airc/Browser/WindowController.swift:266-289`
  (`storeDidChange` → `scheduleReload` → `reloadAll` → `p.reload` for **every** `pageViews` entry),
  `:755` (title changes persist).
- **Problem:** `pageChanged` already refreshes the one row (`refreshRow`). The store observer then also
  reloads every Space: for each one it filters all items and tabs, sorts them, and configures every row and
  tile. Titles change often: unread counts, "(3) Inbox", chat apps, timers, media progress, and every
  `pushState`.
- **Failure scenario:** With 20 Spaces and a few hundred rows, a Slack tab that changes its title every few
  seconds does a full sidebar reload each time, including during typing and scrolling. I didn't measure the
  cost.
- **Fix:** Have `updateTab` with `deferred: true` notify only with the tab ref. In `storeDidChange`, when
  every changed ref is a tab or item already shown, call `refreshRow` for those IDs and skip `reloadAll`. Keep
  the full reload for structural changes (adds, removes, moves, Space and profile changes).
- **Confidence:** medium.

### M4. A failed store write is lost and the failure is hidden

- **Where:** `packages/AircKit/Sources/AircKit/SpacesStore.swift:297-318` (`pendingWrites = []` at `:304`
  runs *before* the transaction), `:275-292` (`commit` changes memory first, then flushes; it never rolls
  back). There are 51 `try? store.…` call sites in `apps/browser/Sources`.
- **Problem:** If SQLite fails (disk full, I/O error, a locked WAL), the changed refs are dropped from
  `pendingWrites`, so the 2 s flush timer never retries them. Memory now differs from disk, and most callers
  discard the error. The change shows on screen and is gone after relaunch.
- **Fix:** Clear `pendingWrites` only after `db.transaction` succeeds, or merge the refs back in the `catch`.
  Surface a failed write once, as a toast or a banner ("Airc couldn't save changes"), instead of `try?`. Add a
  test with a database that fails on demand.
- **Confidence:** high on the mechanism; such failures are rare.

### M5. The op log and the archive grow forever

- **Where:** `packages/AircKit/Sources/AircKit/SpacesStore.swift:311` and `:315` (every flush writes the full
  entity JSON to `ops`), `:444` (`compactOperations` is never called from the app),
  `packages/AircKit/Sources/AircKit/StoreActions.swift` (no retention for archive entries).
- **Problem:** Each tab URL or title change that gets flushed adds an `ops` row with the whole tab body.
  Archive entries each hold a full `LiveTab`. They are never pruned, are all loaded into memory at launch, and
  go into every daily JSON backup (14 are kept).
- **Failure scenario:** A heavy user does thousands of navigations a day. `spaces.sqlite` grows by MBs a day,
  launch reads an ever-growing archive on the main thread, and backups get bigger.
- **Fix:** Call `compactOperations(olderThan: 7 days)` at idle, once per launch. Give the archive a retention
  rule (Arc keeps archived tabs for a limited time; set it in the spec), plus a hard cap.
- **Confidence:** high on the growth; medium on when it starts to matter.

### M6. Favicons are fetched outside the engine, through one session for all profiles, and decoded in the unsandboxed app

- **Where:** `apps/browser/Sources/Airc/Engine/FaviconCache.swift:14-16` (one `URLSessionConfiguration.ephemeral`
  session, which still has an in-memory cookie store, shared by every profile), `:37` and `:43`
  (`NSImage(data:)` on untrusted bytes in the browser process).
- **Problem:** (a) Favicon requests for every profile go through one shared cookie jar and one disk cache, so
  a site that sets a cookie on its icon can link Work and Personal. They also bypass the engine's proxy and
  extension rules. (b) ICO/PNG/SVG from the network is decoded with ImageIO in the main app process, which
  holds the decrypted Arc credentials (H1) and has no sandbox. Chromium decodes favicons in sandboxed
  processes.
- **Fix:** Use `config.httpCookieStorage = nil`, `httpShouldSetCookies = false` and `httpCookieAcceptPolicy =
  .never`, or one session per profile. On Chromium, get favicons from the engine's favicon service
  (`airc_icon_fetch.mm`) instead of the app's own fetch. Limit the bytes accepted (for example 256 KB) and the
  decoded pixel size before decoding.
- **Confidence:** high on (a); (b) is defence in depth.

### M7. Deleting a profile removes its record even if the engine keeps its data

- **Where:** `apps/browser/Sources/Airc/Browser/ProfileHost.swift:88-93` (the store record is deleted first,
  then the engine is asked; an unloaded profile gets `completion(true)` without deleting anything),
  `apps/browser/Sources/Airc/Settings/SettingsWindow.swift:331` (`deleteProfile(p.id) { _ in }`).
- **Problem:** The sheet says deleting "will permanently remove any cookies, history, preferences, and
  logins". If the engine refuses (the Chromium `Default` folder, or a profile that failed to load), the
  cookies and passwords stay on disk with no record pointing at them. `PendingCredentials` and the
  suggestion cache for that profile aren't cleared either.
- **Fix:** Ask the engine first and delete the record only when it succeeds, or keep a tombstone and retry.
  When a profile isn't loaded, delete its folder through the engine anyway. Show failures. Clear every
  per-profile cache (suggestions, credentials, favicons once they are per-profile).
- **Confidence:** medium-high.

## Low

- **L1. `--ephemeral --data-dir X` recursively deletes X, at launch and again at quit, without checking it**
  (`apps/browser/Sources/Airc/Browser/WindowController.swift:784`,
  `apps/browser/Sources/Airc/App/AppDelegate.swift:246`). A typo such as `--data-dir ~` deletes the home
  folder. Fix: only delete a folder Airc created (check for a marker file it wrote), and refuse `$HOME`, `/`
  and any parent of the app support folder.
- **L2. Arc backup can crash.** `OnboardingController.swift:521-524` calls `try? p.run()` and then reads
  `p.terminationStatus`, which raises an Objective-C exception if the process never started. Fix: `do { try
  p.run() } catch { completion(nil); return }`.
- **L3. `Database.query` crashes on an empty BLOB or text value with a NULL pointer**
  (`packages/AircKit/Sources/AircKit/Database.swift:104`: `String(cString: sqlite3_column_text(...))`). No
  table stores BLOBs today. Fix: handle `SQLITE_BLOB` and a NULL pointer.
- **L4. Secrets stay in memory, and temp copies survive a crash.** The derived key, passwords and cookie
  values are Swift `Data` and `String`, which are never zeroed. The `AircImport-<uuid>` snapshot folder
  (0700, holding ciphertext only) is removed in `deinit` but stays in `$TMPDIR` if the app crashes
  (`packages/AircImport/Sources/AircImport/Credentials.swift:94` and `:111`). Fix: hand rows to the engine in
  batches and drop them (H1). At launch, remove leftover `AircImport-*` folders.
- **L5. History counts same-document URL changes as visits** (`WindowController.swift:742`: each
  `tabDidChangeURL` with a new URL string is a visit, including fragments and `pushState`). Single-page apps
  fill the 20,000 cap with noise, which makes H5 worse. Fix: record a visit on a main-frame commit that
  isn't same-document, and ignore fragment-only changes.

(The always-on 2 s flush timer and 60 s archive timer are being replaced in the working tree by another
agent's MEM-6 change, so they aren't listed.)

## Checked and fine

- The engine's test hooks (`--airc-test`, the file keychain, `start-over`) are refused unless the build is
  unsigned **and** on the mock keychain **and** using the scratch data folder. If `SecCodeCopySelf` fails,
  the build counts as distribution-signed (`engine/core/airc_launch_switches.cc`), so the gate fails closed.
- Airc's Keychain item is `Airc Safe Storage` / `Airc` (`engine/patches/021-keychain.patch`), never Chrome's
  or Chromium's. Arc's item is only read when the user presses Import logins, never in automated runs.
- The framework exports only `AircMain` and five Objective-C classes (`engine/core/airc.exports`).
- The password prompt dictionary shows the password's length, never the password itself. I found no logging
  of credentials in the import path or the engine services.
- Cookie import refuses partitioned cookies and sameSite values out of range. Login import only accepts HTML
  forms whose `signon_realm` equals the origin (`engine/core/airc_profile_services.mm`).
- Suggestion requests use one session per profile with no cookies (`SuggestionService.swift`). Typing
  `javascript:…` searches instead of navigating (`URLRules.normalizeInput`). Typed `file:` and `data:` URLs
  behave as they do in Chrome.
- Release: the entitlements match Chrome's set, `disable-library-validation` is added only for ad-hoc signing,
  the Sparkle key is checked against the repo's public key, and `package.sh` checks the version string before
  using it in paths. The scripts quote their paths. The `rm -rf` targets in CI are constants or temp folders
  the scripts created themselves.

## Tests that should exist and don't

1. **Real-event checks** (`EventTests.swift`) beyond New Space and the profile cards: clicking a sidebar row
   selects it; drag to pin; Library → Restore; Command Bar Enter on a history row; the onboarding buttons
   (Import everything, Import logins, Continue); Settings → Delete Profile; the Space context menu actions;
   the Favorite tile click.
2. **End-to-end credential import:** fixture `Login Data` and `Cookies` encrypted with a test key, covering a
   locked database (a second connection holding `locking_mode=EXCLUSIVE`), one corrupt row, a `v11` blob and
   a missing `Cookies` file. Then an app-level check that the sink hands the data to the engine, and that the
   counts shown are the engine's.
3. **The store invariant after every action, including undo:** `tab.profileID == space.profileID` for
   Space tabs, and every referenced profile exists. Cases: undo after `setProfile`, after `moveTab`, after
   Delete Space followed by Delete Profile.
4. **Forward compatibility:** a store containing a row with an unknown enum case or an extra field opens, keeps
   that row byte-for-byte, and deletes nothing.
5. **Write failure:** `flush()` with a database that fails on demand keeps the pending refs and retries them.
6. **Performance budgets:** Command Bar keystroke under 4 ms at 20,000 history entries; a title change with
   20 Spaces × 50 rows touches one row; launch and relaunch keep the number of Chromium profile folders
   constant.
7. **Opener-less tabs:** `didInsertTab` with a nil opener from a profile other than the current Space's lands
   in a Space of its own profile.

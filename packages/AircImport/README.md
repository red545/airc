# AircImport

Swift 6 library for macOS 14+, using system CommonCrypto, SQLite and Security.
No UI, engine integration, third-party dependencies or network requests.

## API

- `ArcImporter.locateData(home:)`: locate Arc data, with typed installation,
  missing-data and permission failures.
- `await ArcImporter.plan(at:includeToday:progress:)`: discover profiles and parse
  the sidebar on a worker task; returns `ImportPlan`.
- `ArcSidebarParser.parse(_:includeToday:)`: pure in-memory sidebar parser.
- `ArcImporter.discoverProfiles(at:referenced:)`: merge Local State metadata,
  profile folders and sidebar references.
- `ArcSafeStorage.readPassword()`: explicitly request Arc Safe Storage from
  Keychain. Call only after onboarding explains the system prompt.
- `ArcSafeStorage.deriveKey(password:)` and `decrypt(_:key:)`: PBKDF2-SHA1
  (1003 iterations), AES-128-CBC v10 decryption.
- `await ArcCredentialImporter.read(profileDirectory:key:includeLogins:includeCookies:progress:)`:
  return `ImportedCredentials` containing `ImportedLogin` and `ImportedCookie`.
  The caller selects each profile and provides the derived key.

`ImportPlan` contains `ImportedProfile`, `ImportedSpace`, recursive
`ImportedItem` / `ImportedFolder` / `ImportedTab`, profile-keyed Favorites and
`ImportWarning`. Source item and Space IDs remain stable for idempotent application.
The engine must upsert by source IDs; this package never applies a plan.
`ImportedTheme.raw` and Space `icon` retain lossless `JSONValue` source metadata;
`theme.colors` exposes discovered gradient colors and `theme.color` the predecessor
parser's preferred palette color. Rendering the raw Arc theme is the app's job.

Warnings are structural and never include source names, URLs or titles.
`ImportError` supplies user-facing messages; `ImportProgress` reports stages.
Callbacks execute on the worker, so UI callers must hop to the main actor.

## Credentials

Arc keeps its databases open while it runs, and Chromium holds `Login Data` with
SQLite's exclusive lock, so nothing is opened in place. `Login Data` and `Cookies`
are copied, together with their `-wal`, `-shm` and `-journal` files, into a private
0700 folder (`$TMPDIR/AircImport-<uuid>`); the copy is retried until no source file
changed during it. SQLite opens the copy, which replays committed WAL pages, and the
folder is deleted as soon as the read finishes. `removeStaleCopies()` removes any a
crash left behind. Keychain is never read implicitly. No credential values are
logged. Cookies retain extra source columns (partition keys, timestamps, source
scheme/port, etc.) in `metadata`. Schema 24+ domain hashes are validated before
removal.

One bad row never stops a profile: rows that can't be decrypted (a `v11` blob, a bad
ciphertext, a non-UTF-8 value, a cookie whose domain digest doesn't match) are counted
in `failedLogins`/`failedCookies` with a reason in `problems` (never a value); Arc's
"never save" entries are `skippedLogins`. A database that can't be read at all is
listed in `failedDatabases`, and the other one still comes over.

Returned credentials are plaintext in memory. The engine owns importing and
re-encrypting them, session restoration and device-bound login failures.

## Other browsers

Bookmarks and history from the Chromium family (Chrome and its channels, Brave, Edge, Vivaldi, Opera, Chromium, Dia,
Helium), Firefox and Zen; Safari's and any browser's exported bookmarks HTML file; saved passwords only from a CSV file
the user exported. Nothing here reads another browser's password store, cookies or Keychain item.

- `BrowserImporter.detect(home:)`: the installs under `home`'s Application Support and their profiles, from
  `Local State` (`profile.info_cache`: name, avatar colour, `profiles_order`) or `profiles.ini`. Only folders with
  bookmarks or history count; Firefox paths outside the data folder are ignored.
- `await BrowserImporter.read(_:profiles:includeHistory:historyLimit:)`: an `ImportPlan` with one profile and one Space
  per browser profile. The bookmarks bar becomes the pinned tabs and folders, "Other bookmarks" and "Mobile
  bookmarks" (Firefox: Bookmarks Menu, Other Bookmarks, Mobile Bookmarks) one pinned folder each; Favorites stay empty.
  Plus each profile's newest 20,000 history entries (`ImportedVisit`). `Bookmarks` is read in place, `History` and
  `places.sqlite` from private copies (`DatabaseCopy`), since the browser may hold them locked.
- `await BrowserImporter.readBookmarksFile(_:kind:)`: a NETSCAPE-Bookmark-file-1 export; Safari's "Favorites" or the
  `PERSONAL_TOOLBAR_FOLDER` is the bar. IDs are hashes of folder path, address and name.
- `await PasswordCSV.read(_:)`: Chrome's, Firefox's and Safari's export columns, by name. Duplicates (same site and
  username), rows without a password, and non-website logins are counted, never included.

Source keys are `<install>-profile:<profile>`, `<install>-space:<profile>` and `<install>-item:<profile>/<GUID>`
(Chromium's and Firefox's bookmark GUIDs), so importing again updates in place. A profile whose bookmarks or history
can't be read still brings the other part (`unreadableBookmarks`, `unreadableHistory`). Limits: 10,000 bookmarks per
profile, 64 folder levels, 128 MB per bookmarks file, 64 MB and 100,000 rows per CSV file.

## Tests

```sh
swift test --package-path packages/AircImport
```

Synthetic fixture and parser behavior were ported from Airc's predecessor
`arc-sidebar/src/shared/arcImport.ts` and its fixture generator. The predecessor's
two apply tests are intentionally replaced with stable-ID/repeated-plan, Today
selection and per-profile Favorites assertions: global Favorites deduplication,
Google account rewriting and model merge/replace are not native import semantics.

The opt-in local test reads only Arc sidebar and profile metadata and prints
counts. It never reads credential databases or calls Keychain:

```sh
AIRC_IMPORT_LOCAL_SMOKE=1 swift test --package-path packages/AircImport --filter LocalSmokeTests
```

`BrowserTests` covers the other browsers on a synthetic home folder (a Chrome-layout user-data folder, a Firefox
profile, HTML exports, CSV files with example.com entries), including locked databases, malformed and huge files.

Archives, Arc's history, extensions, backups and applying plans are outside this package's assigned scope. Split views in pinned tabs and Favorites stay
splits (`ImportedItem.split`, `ImportPlan.favoriteItems`); in Today they become individual
tabs with a warning. Easels are skipped with a warning; unknown containers keep known children.

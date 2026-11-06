# Profile services and host UI contract

All calls run on the main thread after `engineDidStart`. A profile must remain
loaded (normally a prepared window keeps it alive). Off-the-record profiles cannot
import credentials or query persistent history. No changes to `app-wiring.patch`.

## CredentialSink

The app owns `CredentialSink.receive(_:forProfile:)`. Resolve the app profile ID to
its loaded `EngineProfile`; never pass an app UUID as a Chromium directory without
using the app's mapping. The concrete `ChromiumEngine.importCredentials(logins:
cookies:into:completion:)` accepts dictionaries matching `ImportedLogin` and
`ImportedCookie` (encode their Codable values and decode to dictionaries in memory).
Do not retain credentials in `PendingCredentials` after handing them off.

Objective-C / imported Swift methods on `AircProfile`:

- `importLogins(_:completion:)`: keys `origin`, `signonRealm`, `actionURL`,
  `username`, `password`. Only HTTP(S) HTML credentials with a matching origin-only
  realm are accepted. Completion returns `saved`, `skipped`, `rejected`, and ordered
  `results`: `{index, status, reason}`. Status is `saved`, `skipped-duplicate`, or
  `rejected`. No credentials are included in results. Imports serialize per profile
  store, read the matching realm before adding, and read it back after AddLogin.
  `saved` means the stored key/password matched on readback, not just submission.
  Existing Chromium unique keys (realm, URL, username element/value, password
  element) are preserved even when the incoming password differs; they count as
  skipped. The import boundary supplies empty element names. This is not semantic
  deduplication across different login URLs or field names. Store/readback failures
  are rejected with a reason. Ordinary concurrent password UI changes are not an
  atomic database transaction with import. Keep the engine alive through completion;
  store shutdown may cancel outstanding work. No `submitted` count remains.
- `importCookies(_:completion:)`: keys `host`, `name`, `path`, `value`, `expiresUTC`,
  `secure`, `httpOnly`, `sameSite`, optional string-valued `metadata`. Expiry uses
  Chromium microseconds since 1601; zero is session-only. SameSite is -1 unset,
  0 none, 1 lax, 2 strict. A leading dot denotes a domain cookie; otherwise host-only.
  Completion returns `accepted`, `rejected`, and ordered `{index,status,reason}`
  results. Invalid domains, expired cookies, invalid SameSite and partition metadata
  receive explicit reasons; Chromium exclusion strings describe prefix and secure/
  SameSite failures. Expired rows are rejected rather than counted as successful
  deletion operations. Accepted means CookieManager inclusion, not disk fsync.

## Unloaded profile cleanup

`AircEngine.deleteUnloadedProfile(directory:completion:)` accepts one directory
component under the configured user-data root. It never calls CreateProfile or
loads services. It refuses default/system/guest profiles, traversal, symlinks,
missing/non-profile folders and **any profile observed loaded or creating in this
engine session**, including pending destruction. Retry those after restart.
Filesystem validation runs on a worker; the UI sequence rechecks session ownership
(including case/Unicode aliases), atomically renames to a unique hidden tombstone,
removes a matching profile registry entry, then deletes the renamed tree on a worker.
Later loads of the original name cannot race deletion of the renamed directory.
Completion returns `{deleted, reason}`, plus `retainedDirectory` after quarantine.
`deleted:true` means filesystem removal finished. A failed removal leaves the
hidden tombstone named in the result for diagnosis; crash recovery of tombstones
is not automatic. This is an in-process cleanup API, not protection against another
process maliciously replacing files inside the user-data root.

`engine/app-pass8.patch` is an **unapplied** Swift integration diff: concrete adapter
cleanup method, orphan-spare cleanup without loading, and import counts based on
`saved` (duplicates included in skipped). App pass 5 owns applying/reconciling it.
The adapter already forwards the complete per-row dictionaries unchanged.

Plaintext exists only in memory at this API boundary. Do not pass source encrypted
blobs or write source databases into a destination profile. Both stores use the
already-pinned **Airc Safe Storage / Airc** OSCrypt identity. The `services` test
uses only synthetic values and a mock keychain; database inspection confirms
nonempty v10 encrypted values and empty plaintext cookie storage. Real Keychain
consent, real imported login fill and persistence after an actual-key restart are
still release tests, not established by this mock-keychain proof.

## History and Google accounts

`queryHistory(_:limit:completion:)` returns URL/title/visits/lastVisit dictionaries,
with Unix seconds and limits clamped to 1–1000. Chromium supplies its normal search
and deduplication behavior. A destroyed profile cancels outstanding history work.
`observeHistoryVisits(_:)` installs one block per profile, nil removes it; records
also contain visitID and time (Unix seconds). Observe before navigation. Do not
strongly capture the profile in its own block. Visits include sync-originated visits;
these callbacks are a notification source, not a second database to increment.
Title changes and deletions do not currently emit this callback: requery on focus
and after the app clears data. The app can remove its history.sqlite only after
adopting those refresh rules.

`googleAccounts` returns `{fresh, accounts:[{id,email}]}` from IdentityManager's
cookie-account cache, never the app's own ListAccounts fetch. `fresh:false` must be
shown as unknown/stale, not signed out. This is web cookie identity, not browser
sync identity. Query after sign-in navigation; there is no account-change subscription
yet. Empty signed-out profiles were tested; actual Google sign-in was not.

## Downloads

`observeDownloads(_:)` installs one block per profile and emits existing items and
updates. Nil removes the block. Each dictionary has id (GUID), url, path, received,
total, state (0 in progress, 1 complete, 2 cancelled, 3 interrupted), paused,
dangerous. Total may be unknown; render indeterminate progress until it is positive.
A path may be empty until target determination. Never auto-open a dangerous item.
The app draws the footer progress indicator and Library download rows. Cancellation,
resume and danger-confirmation actions are not exposed by this addition.

## Page/window UI

`setPageVisible(_:)` changes the existing view's hidden flag and Chromium visibility,
including prompt eligibility and discard timers, without changing its parent. Hide
an outgoing view before activating/showing the next. `attach(to:)` now does nothing
structural if already in that parent. The Swift adapter uses this path for switches
and deactivateAll; explicit `AircWindow.deactivateAll` still detaches by its original
contract. First responder is cleared only if inside the outgoing page.

`uiAnchorView` + `uiAnchorRect` describe the URL field rectangle in view coordinates.
Setting the view resets the rectangle to its bounds. `uiAnchorRectInScreen` converts
it to screen coordinates, or returns zero for a view in the wrong window. The
Swift adapter's `setUIAnchor(window:view:rect:)` updates both. The app draws permission,
password/autofill and device panels and dismisses them on switch/close. Permission
responses are `accept` (remember false means temporary where supported), `deny`
with remember true for a persisted block, or `dismiss`. Deny without remember
currently dismisses; it is not a temporary block.

`findState` exposes text, matches, active (1-based), final; negative match/active
values mean a result is pending. Existing `didFindMatches` drives the concrete
adapter's `findStateDidChange`. Draw an overlay find field, match counter, previous,
next, close; wire Command-F, Enter/Shift-Enter and Escape. Invoke `find(_:forward:)`
and `stopFinding()`. Preserve query/UI per tab, and hide it on switch. The engine
supplies highlights and selection; it does not draw the Arc-style field.

`spacesForContextMenuLink` supplies at most 100 `{id,title}` records; the native
menu creates "Open link in Space ›". `openContextMenuLink:inSpace:` returns the
URL and Space ID. Concrete adapter closures are `contextMenuSpaces` and
`openLinkInSpace`. The app opens a **new** tab in the selected Space's profile,
never moves the source WebContents across profiles. The background test exercises
the real menu model and command dispatch, not the foreground Cocoa menu runner.

Route Option-Command-I to `showDevTools(for:)` and close via `closeDevTools(for:)`.
AircTab's `devToolsView` and `devToolsLayoutForSize` support app-owned docking;
the two-profile host qualifies shortcut delivery and attaching that view. Automatic
layout callbacks/undocking are still not qualified. Command-P remains
`executeChromeCommand:35003` (IDC_PRINT); native print UI is not qualified.

A second AircWindow with its own NSWindow and host view was tested with a shared
profile: the page attached to the second window and saw that profile's imported
cookie, while the other profile did not. The app must retain each window and route
engine-created popup windows through `engineWindowForNewBrowserOfProfile:type:`;
the current production adapter still returns nil there.

Startup appends no-first-run, no-default-browser-check and no-startup-window before
Chrome startup. The fresh-data background host recorded no Chrome welcome UI; it also enumerates
the Views scaffolding window titled Item-0. Native-window enumeration is retained
in the hosting evidence. ON-4 is not a universal proof against every future
Chromium startup dialog.

## Pass 5 concrete Swift prompt and print bridge

`ChromiumEngine.passwordPromptDidChange` and `autofillPromptDidChange` deliver the
originating EngineTab and engine payload. Query `passwordPrompt(for:)` /
`autofillPrompt(for:)` when activating a tab. Nil means no prompt. Autofill payloads
have an integer `id`; `{id, closed:true}` closes that prompt. Only resolve the
currently displayed tab/id. Call `resolveAutofillPrompt(in:id:action:)` with accept,
decline or dismiss. Password actions are save/update, never (save state), nope
(update state), or dismiss; optional username/password are explicit edits. Prompt
snapshots expose password length, never the stored password. Hide product panels
on navigation, tab/profile switch and close; password state has no universal
closed-notification subscription.

`autofillSuggestionsDidChange` reports displayed label/sublabel/minorText/type rows.
`showAutofillSuggestions(in:passwords:)` asks Chromium for suggestions in the
focused field. These are descriptive rows, not stable row IDs or an app-owned
selection API. Do not build a selectable custom list on the assumption that this
pass supplies selection dispatch.

`printPage(_:)` dispatches IDC_BASIC_PRINT (35007) to Chromium's native system print
path. Bind Command-P to this method for system printing; a true return means only
that the request was dispatched. Native panel/PDF-save behavior is unqualified.
See [PASS5.md](PASS5.md) for actual form, picker and persistence evidence.

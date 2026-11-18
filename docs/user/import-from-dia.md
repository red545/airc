# Importing from Dia

Airc brings over what you have in Dia: on the first launch, or later with **Airc › Import from Another Browser…**
(or **Settings › Import › Import from another browser**), choose **Dia**. Importing again is safe: it updates what
came over before and never doubles it.

## What comes over

- **Profiles.** Each Dia profile becomes an Airc profile with its own Space, named after the profile. Dia's main
  profile can become Airc's first profile.
- **Bookmarks,** as each Space's pinned tabs and folders.
- **History,** for that profile's ⌘T suggestions.
- **Search engines:** your default and the shortcuts you made.
- **Extensions,** as a checklist to reinstall from the Chrome Web Store, as for Arc
  ([Importing from Arc](import-from-arc.md#extensions)). Dia's own built-in helpers aren't listed.
- **Saved passwords and cookies**, with the Chromium engine, after you choose **Import logins**, and with them the
  **sites' own storage** (localStorage) of the 50 sites you visit most.

## Dia's key

Dia locks passwords, cookies and, since Dia 1.54, bookmarks with a key in your Keychain called **"Dia Safe
Storage"**. So right after the import, the Logins step asks for it. Choose **Import logins**, and when macOS asks
whether Airc may use the key, choose **Allow**. Airc unlocks them on this Mac, locks passwords and cookies again with
its own key, and sends nothing anywhere. macOS asks once for all of them.

Until then, the import step says **"1 profile's bookmarks are locked with Dia's key"**: those profiles' Spaces come
over with their history, and their bookmarks join them in the Logins step.

- **You chose Deny, or cancelled:** passwords, cookies and the locked bookmarks stay in Dia, and the results say so.
  Sites' storage, which isn't locked with the key, still comes over. Choose **Try Again**, then **Allow**.
- **Your login keychain is locked:** the same; unlock it (log in to your Mac again), then **Try Again**.
- **"Dia Safe Storage" isn't in this Mac's Keychain:** Dia never saved anything locked on this Mac.
- **"Logins didn't open with the key in Dia Safe Storage":** the key changed since Dia saved them (a reset Keychain,
  another Mac's data). Airc can't open them.

Everything else works as for Arc: the per-site results with **Imported**, **Skipped** or **Failed** and why, **Try
Again** for what couldn't be read, passwords for a site's own sign-in box, "Sign in with Google" sites, partitioned
cookies. See [Importing from Arc](import-from-arc.md#logins-and-cookies).

**On the WebKit engine,** passwords, cookies and sites' storage aren't read. The Logins step still offers **Import
bookmarks**, which unlocks only Dia's bookmarks.

You don't need to quit Dia: Airc reads copies of its files.

## What can't come over

- **Dia's sidebar arrangement:** its pinned tabs, open tabs, custom tab names and how tabs are grouped. Dia keeps them
  in an encrypted database whose key only Dia itself can read, so no other app can import them. Your bookmarks and
  history come over; pin what you use most again in Airc.
- **Dia's AI features and their history** (chats, skills, memory).
- Whatever can't come over from Arc either: autofill addresses and payment cards, sites' offline data (IndexedDB),
  notes on saved passwords ([the list](import-from-arc.md#what-cant-come-over)).

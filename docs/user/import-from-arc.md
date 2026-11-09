# Importing from Arc

Airc brings over what you set up in Arc: on the first launch, or later with **Airc › Import from Another Browser…**,
where Arc comes first (or **Settings › Import › Import from Arc**). Importing again is safe: it updates what came over before and never doubles it.

## What comes over

- **Spaces** with their names, icons and themes; **pinned tabs and folders** (split views stay split); **Favorites**,
  per profile; **Today** tabs.
- **Profiles.** Each Arc profile becomes an Airc profile with the name Arc gave it. Arc's main profile becomes Airc's
  first profile, with Arc's name for it; what you already made there stays. Every Space goes into its profile, and so do that profile's history,
  extensions, logins and cookies.
- **History** of the last 90 days (up to 20,000 pages per profile), for that profile's ⌘T suggestions.
- **Extensions** as a checklist to reinstall from (below).
- **Saved passwords and cookies**, with the Chromium engine, after you choose **Import logins** (below).

The import step lists what changes on the way, such as Notes and Easels left out or live folders becoming plain
folders, with a line on each.

## If Arc is open

You don't need to quit Arc: Airc reads copies of its files. Arc keeps its newest visits in a file it's still writing,
so the import may say **"1 profile may have newer history in Arc"**. Quit Arc and import again: those visits are added,
and nothing is doubled.

## Logins and cookies

Arc locks passwords and cookies with a key in your Keychain called **"Arc Safe Storage"**. When you choose **Import
logins**, macOS asks whether Airc may use it: choose **Allow**. Airc unlocks them on this Mac, locks them again with its
own key, and sends nothing anywhere.

- **You chose Deny, or cancelled:** nothing was read. Choose **Try Again**, then **Allow**.
- **Your login keychain is locked:** unlock it (log in to your Mac again), then **Try Again**.
- **"Arc Safe Storage" isn't in this Mac's Keychain:** Arc never saved logins on this Mac, or its data came from another
  Mac. Sign in to your sites again.
- **"Logins didn't open with the key in Arc Safe Storage":** the key changed since Arc saved them (a reset Keychain,
  another Mac's data). Airc can't open them.

Afterwards every login and every site's cookies are listed as **Imported**, **Skipped** or **Failed**, with why, and the
most common reasons first. If some couldn't be read or stored (Arc was writing to its database, macOS didn't let
Airc read a file, a store didn't answer), **Try Again** reads only those again; everything that came over stays.
macOS may ask for the key once more. Until you quit Airc, the results are also in
**Settings › Import**.

## What can't come over

- **Logins:** Android app logins; sign-ins through another account such as "Sign in with Google" (Arc has no password
  for them: use that sign-in again); passwords for a site's browser sign-in box (HTTP authentication); entries with a
  username but no password; sites Arc was told never to save; passwords encrypted in a way Airc can't read.
- **Cookies:** partitioned cookies (a site's cookie kept only inside one other site's pages), cookies that had already
  expired, and ones Chromium's rules refuse; each is listed with why.
- **Sites' own storage.** Some web apps keep you signed in with their own storage rather than cookies; sign in to
  them again.
- **Autofill addresses and payment cards.**
- **On the WebKit engine,** logins and cookies: nothing is read.

## Extensions

Extensions are never installed for you. **Reinstall your extensions** lists each one with its profile and whether Arc
had it turned off, and counts them ("1 of 4 reinstalled"):

- **Open in Chrome Web Store** opens its page in a Space of the right profile; choose **Add to Chrome** there. The row
  then says it's opened, and **Installed** once the profile has it.
- An extension **loaded unpacked** in Arc (developer mode) says so: load its folder again in **Manage Extensions…**.
- One **not from the Chrome Web Store** says to reinstall it from where you got it.

Extensions' own settings and data don't come over.

## Privacy

Airc reads Arc's folder only when you import, and the Keychain only when you choose Import logins. Nothing leaves your
Mac; the extension checklist is kept with Airc's data on this Mac.

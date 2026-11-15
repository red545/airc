# Importing from Arc

Airc brings over what you set up in Arc: on the first launch, or later with **Airc › Import from Another Browser…**,
where Arc comes first (or **Settings › Import › Import from Arc**). Importing again is safe: it updates what came over before and never doubles it.

## What comes over

- **Spaces** with their names, icons and themes; **pinned tabs and folders** (split views stay split); **Favorites**,
  per profile; **Today** tabs, with Today's folders (in order, nested, with their names). Tabs in them stay Today
  tabs and archive when they would have in Arc; a folder goes with its last tab ([folders in Today](sidebar.md)).
- **Profiles.** Each Arc profile becomes an Airc profile with the name Arc gave it. Arc's main profile becomes Airc's
  first profile, with Arc's name for it; what you already made there stays. Every Space goes into its profile, and so do that profile's history,
  extensions, logins and cookies.
- **History** of the last 90 days (up to 20,000 pages per profile), for that profile's ⌘T suggestions.
- **Extensions** as a checklist to reinstall from (below).
- **Saved passwords and cookies**, with the Chromium engine, after you choose **Import logins** (below), and with them
  the **sites' own storage** (localStorage) of the 50 sites you visit most, which some web apps keep you signed in with.

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

- **You chose Deny, or cancelled:** passwords and cookies stay in Arc, and the results say so. Sites' storage, which
  isn't locked with the key, still comes over. Choose **Try Again** in the results, then **Allow**.
- **Your login keychain is locked:** the same; unlock it (log in to your Mac again), then **Try Again**.
- **"Arc Safe Storage" isn't in this Mac's Keychain:** Arc never saved logins on this Mac, or its data came from another
  Mac. Sign in to your sites again.
- **"Logins didn't open with the key in Arc Safe Storage":** the key changed since Arc saved them (a reset Keychain,
  another Mac's data). Airc can't open them.

Besides websites' passwords and cookies, these come over:

- **Passwords for a site's sign-in box** (HTTP authentication, the browser's own box rather than a page's form) come
  over, and fill that box when the site asks.
- **"Sign in with Google"** and other sign-ins through another account come over as such (Arc had no password for
  them). The results list which sites they were: **Use "Sign in with Google" on …**, in case a site asks again.
- **Android app logins** come over for the websites Arc linked to the app (a bank's app and its website, say).
- **Partitioned cookies** (a site's cookie kept only inside one other site's pages, such as a chat box on a shop) go
  back into the same partition.
- **Sites' storage:** a site's localStorage comes over only if Airc has none for that site yet, so a site you already
  use in Airc keeps its own. Which sites count as visited most comes from Arc's history.

Afterwards every login, every site's cookies and every site's storage are listed as **Imported**, **Skipped** or
**Failed**, with why, and the most common reasons first; a last line names what never comes over. If some couldn't be read or stored (Arc was writing to its database, macOS didn't let
Airc read a file, a store didn't answer), **Try Again** reads only those again; everything that came over stays.
macOS may ask for the key once more. Until you quit Airc, the results are also in
**Settings › Import**.

## What can't come over

- **Logins:** Android app logins with no website linked to the app (each is listed with the app's name); a proxy
  server's sign-in; entries with a username but no password; sites Arc was told never to save; passwords encrypted in
  a way Airc can't read.
- **Cookies:** cookies that had already expired, and ones Chromium's rules refuse; each is listed with why.
- **Sites' offline data** (IndexedDB): what a web app keeps on your Mac to work offline or start faster. It stays in
  Arc; most sites download it again when you use them. For a site that keeps your work only on this Mac (a drawing or
  notes app without an account), export it in Arc first. Each of your most visited sites that has some is listed.
  Airc can't bring it over safely: a site's database can only be written by the site's own pages.
- **Other sites' storage,** beyond the 50 you visit most (one line says how many), a site's storage over 10 MB, a
  site's storage kept only inside another site's pages (partitioned, such as a chat box's on a shop; one line says how
  many sites), and a tab's own storage (sessionStorage, gone when a tab closes). Sites set up their service workers (offline pages,
  notifications) again the next time you open them.
- **Notes on saved passwords** (the password itself comes over).
- **Autofill addresses and payment cards.**
- **On the WebKit engine,** logins, cookies and sites' storage: nothing is read. WebKit in an app has no store for
  another browser's passwords, and no way to add a partitioned cookie or a site's storage without opening the site.

## Extensions

Extensions are never installed for you. **Reinstall your extensions** lists each one with its profile and whether Arc
had it turned off, and counts them ("1 of 4 reinstalled"):

- **Open in Chrome Web Store** opens its page in a Space of the right profile; choose **Add to Chrome** there. The row
  then says it's opened, and **Installed** once the profile has it.
- An extension **loaded unpacked** in Arc (developer mode) says so: load its folder again in **Manage Extensions…**.
- One **not from the Chrome Web Store** says to reinstall it from where you got it.

Extensions' own settings and data don't come over.

After the import, onboarding offers your password manager: Arc's 1Password, Bitwarden or another one from the
checklist is picked for you ([password-manager.md](password-manager.md)).

## Privacy

Airc reads Arc's folder only when you import, and the Keychain only when you choose Import logins. Nothing leaves your
Mac; the extension checklist is kept with Airc's data on this Mac.

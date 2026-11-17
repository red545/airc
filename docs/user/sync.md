# Sync with iCloud

Airc can keep your sidebar and your settings the same on your Macs: **Settings → Sync → Sync Spaces, pinned tabs, notes
and Favorites with iCloud**. It's off until you turn it on. Both Macs need the same Apple Account, with iCloud and iCloud
Keychain on. While it's on, **Sync settings** (on by default) keeps your settings the same too, and **Sync Boosts** (on by
default) your [Boosts](boosts.md).

## What syncs, and what never does

Synced: your Spaces (name, icon, colour, order and which profile each uses), pinned tabs and folders (their addresses,
names and icons), Favorites, pinned [notes](notes.md) with their pictures, pinned and Favorite splits (their pages in
order, name, icon, and whether they're side by side or stacked, with their sizes), and the names of your profiles, so a
Space finds its profile on the other Mac.

Never synced: Today tabs, their [folders](sidebar.md), splits in Today and the Archive, history, passwords, cookies and
logins, private windows and Little Airc windows, Easels, and which tab, pane or Space you're on. A note only in Today
stays on this Mac. Each Mac signs in to sites in its own profiles. A profile that's new to a Mac starts there empty:
sign in to its sites once.

If two Macs change the same split at once, the later layout wins, and pages added or moved on either Mac both stay.
Deleting a split on one Mac deletes it on the other, but a page the other Mac added to it meanwhile stays as a pinned
tab. Older versions of Airc don't show synced splits until they're updated.

## Settings

With **Sync settings** on, a setting you change on one Mac changes on your other Macs too:

| Synced | Settings |
|---|---|
| Appearance | The theme new Spaces start with (and light, dark or automatic), translucency, the app icon, sounds and haptics, tab previews, Site Previews, the Send Feedback button, the Space header, the sidebar's side |
| Command Bar and search | Search suggestions, each profile's search engine and its suggestions, each profile's Site Searches (and which one is the default), Ask AI in the Command Bar, Instant Links |
| Shortcuts | Your shortcut changes, and the ⌘1–9 and ⌥ sidebar choices |
| Links | Air Traffic Control rules, where links from other apps open, Little Airc (its shortcut, looking up the selection, ⌥⌘-click, when Little Airc windows go to the Archive), Peek, Shared Quotes, dragging the window from the top of pages, picture in picture and its site choices |
| Archive | Each profile's "Archive tabs after" |
| AI | Tidy tab titles, Ask on Page, link previews and their never-list, Tidy downloads and Rename automatically |
| General | When Airc starts, restarting to update by itself, what you see after an update, which app New Note uses |
| Privacy and blocking | Sharing anonymous usage data, playing DRM sites with Safari's engine, and each profile's blocking: on or off, third-party cookies, the lists and the sites you allowed |

These stay on each Mac: the backup and Library folders, Developer Mode, the memory choices (when tabs free their memory,
keeping chat sites loaded), Calendar, the default-browser reminder, pinned extensions, the per-tab menu switches, the name
on your member card, which profile Little Airc remembers for a site, and everything about agents and connected apps
(approvals, paired devices). Sync never sends a password, token or key.

- **Only what you changed travels.** A setting you never touched keeps following your other Mac; its default never
  overwrites a choice you made there. A setting you'd changed before this version of Airc counts as older than any
  change made since; if both Macs had, the Mac that sends it last wins.
- **The latest change wins**, per setting: change the theme on one Mac and a shortcut on the other, and both Macs end with
  both. Change the same setting on both, and the one you changed last wins on both, even if that Mac was offline or had
  sync off when you changed it.
- Per-profile settings (Site Search, blocking, the archive timing, the search engine) go to the same profile on the other
  Mac, as your Spaces do. A profile only on one Mac keeps its own.
- A setting a newer Airc made that this Mac can't read yet keeps this Mac's value until you update.
- Turn **Sync settings** off to keep this Mac's settings to itself; your sidebar still syncs. Turn it on again and it
  catches up by the same rule.
- Older versions of Airc don't get synced settings until they're updated, and say "Some changes can't be read here" until
  then.

## Boosts

With **Sync Boosts** on, a Boost you make, change, switch on or off, or delete on one Mac does the same on your other
Macs: its colors, font and size, zaps, CSS and name show on the site at once.

A Boost's **JavaScript** never runs on a Mac just because it synced. On your other Mac it waits until you allow it there:
open the Boost (Site Controls says **Its code waits for you**) and the editor asks **Run this code here too?**, naming
the Mac where you allowed it. **Show Code** shows it; **Run on This Mac** runs it from then on. If no Mac says you
allowed the code, the editor shows the full warning and lets you run it only after you've looked at the code. Code you
allowed stays allowed when the Boost's style changes elsewhere; if the code itself changes on another Mac, this Mac asks
again. If you edit the same Boost on two Macs, the one you changed last wins. A Boost made by an earlier test build for a
shared address (see [Boosts](boosts.md)) stays on its Mac until you choose its site.

## Archive timing

Today tabs stay on each Mac, and so does their archive timer. When you unpin a pinned tab on one Mac, its open page on
your other Macs becomes a Today tab too, and its timer counts from the last time you used it on any of them, not only
on that Mac, so a tab you just used elsewhere isn't archived early.

## Encryption

It's end-to-end encrypted. The key is in your iCloud Keychain, so only your Macs can read what Airc keeps in iCloud.

## Setting it up

1. On your first Mac, turn the switch on. Status shows **Up to date**.
2. On the other Mac, turn it on. It may say **Waiting for iCloud Keychain** for a minute or two while iCloud Keychain
   brings the key over (check System Settings → your name → iCloud → Passwords & Keychain on both Macs).
3. Airc then shows both sidebars and asks how to start:
   - **Merge with this Mac's sidebar** keeps everything from both Macs. A Space you have on both shows up twice.
   - **Replace this Mac's sidebar with iCloud's** takes the other Mac's sidebar. This Mac's Today tabs go to the
     Archive; your profiles and logins stay.

   Either way Airc saves a backup of this Mac's sidebar first (Settings → Sync shows where; restore it in Settings →
   Import → Restore from Backup). If iCloud has profiles this Mac doesn't, pick one of yours or a new, empty one.

After that, changes on either Mac show up on the other within seconds, or when you switch to Airc.

## Turning it off

Turning sync off stops syncing on this Mac and keeps your sidebar as it is. Turn it on again and it picks up where it
left off. To delete what Airc keeps in iCloud: System Settings → your name → iCloud → Manage → Airc. Sync then turns
itself off on your Macs; turning it on again uploads that Mac's sidebar as a new start.

# Sync with iCloud

Airc can keep your sidebar the same on your Macs: **Settings → Sync → Sync Spaces, pinned tabs and Favorites with
iCloud**. It's off until you turn it on. Both Macs need the same Apple Account, with iCloud and iCloud Keychain on.

## What syncs, and what never does

Synced: your Spaces (name, icon, colour, order and which profile each uses), pinned tabs and folders (their addresses,
names and icons), Favorites, pinned [notes](notes.md) with their pictures, pinned and Favorite splits (their pages in
order, name, icon, and whether they're side by side or stacked, with their sizes), and the names of your profiles, so a
Space finds its profile on the other Mac.

Never synced: Today tabs, their [folders](sidebar.md), splits in Today and the Archive, history, passwords, cookies and
logins, private windows and Little Airc, Boosts, Easels, and which tab, pane or Space you're on. A note only in Today
stays on this Mac. Each Mac signs in to sites in its own profiles. A profile that's new to a Mac starts there empty:
sign in to its sites once.

If two Macs change the same split at once, the later layout wins, and pages added or moved on either Mac both stay.
Deleting a split on one Mac deletes it on the other, but a page the other Mac added to it meanwhile stays as a pinned
tab. Older versions of Airc don't show synced splits until they're updated.

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

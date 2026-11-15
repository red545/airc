# Updates, app icon and sounds

## Updates

When an update has downloaded, **New Airc Version Available** appears above the sidebar's footer, and the Airc menu
gets "A new version of Airc is ready. Restart to update". Click either one to restart into the new version. Your
windows, Spaces, tabs and splits come back as they were.

If restarting now would interrupt something, Airc asks first and names it:

- music or video playing in any tab (also when it's muted),
- a call (a page using the camera or microphone), or screen sharing,
- downloads that are still running,
- pages with changes they haven't saved, or with text you typed into a form.

**Not Now** keeps the update ready. If a page still asks "Leave site?" while Airc quits and you choose to stay,
Airc keeps running as it was: every window and tab stays, and the update is still ready for later.

**See What's New** opens the update's release notes in a new tab. It's in the pill's right-click menu, in the
question, and in the Airc menu under the ready item. Help › Release Notes always has the notes too.

When the update says what it brings, the pill lists its first two or three highlights under its title, one line
each. Older updates don't, and the pill is just the pill.

### What's new

The first time Airc opens after an update, it opens a **What's New in Airc** tab in your window. For each new
thing it says, in a sentence or two, what it does and why it helps, shows where to find it, and has a **Show me** or
**Try it** button that takes you there: Settings at the right place, the Command Bar, the Library or Send Feedback.
Some have a picture. If you skipped versions, the tab gathers every version since the one you had, newest first.
At the bottom, **Read the full changelog** opens the complete release notes. The tab works offline, opens only
once per version, and never after a fresh install. Close it like any tab.

Prefer something smaller? Settings › General › Automatic Updates › **After an update** has three choices:

- **Open a tab** (the default): the What's New in Airc tab, as above.
- **Show a card**: the spot above the sidebar's footer shows **Airc 0.1.15 is here** (with your new version) and up
  to five highlights, one line each, with "And more" when there are more. Click the card or **See All** for the
  What's New tab. The card stays for three launches, or until you close it with ×.
- **Don't show**: "Updated!" names the new version after the restart, with a link to the release notes.

With a tab or a card, the "Updated!" message doesn't show, and Restart to Update lists the next version's first
highlights before you restart. With Don't show, it doesn't.

### Automatic updates

Left alone, an update installs the next time you quit Airc. As in Arc, you can let Airc restart into it by itself
while you're away: Settings › General › Automatic Updates › **Automatically update my Airc**. It's off until you
turn it on.

With it on, Airc restarts into a downloaded update only when all of these are true:

- nobody has used the Mac's keyboard, mouse or trackpad for 30 minutes (Airc merely being in the background isn't
  enough), and Airc isn't the app in front,
- no music or video is playing or paused part-way, and nothing is in picture in picture,
- no call is on and nothing shares the screen,
- no download is running and no page is still loading or sending something,
- no page would ask "Leave site?" and no page has text you typed into a form,
- no page is in Developer Mode (such as a local development server's page),
- no private window is open with pages in it (a private window's tabs don't come back after a restart),
- no dialog or sheet is open.

It tries once per update, and also a minute after the Mac wakes from sleep (if nobody has touched it since). Your
windows, Spaces, tabs and splits come back as they were.

Pages that upload in the background without asking "Leave site?" can't be seen from outside the page; most upload
pages do ask while they send.

## App icon

Settings › Appearance › **App Icon** chooses Airc's icon in the Dock, the app switcher and the Finder: **Holographic**
(the standard icon), **Outline**, **Sunset**, **Ocean**, **Midnight** or **Graphite**. All of them are Airc's own icon in
other colours.

The Dock shows your choice at once. The Finder, and the Dock while Airc isn't running, show it too: Airc gives its own
app a custom icon, as the Finder's Get Info does. Airc's signature stays valid, and an update keeps your choice (Airc
puts the icon back on the new app when it starts). Choosing Holographic again removes the custom icon. If Airc can't
change its app where it's installed (a folder you can't write to), the Finder keeps the standard icon and Settings
says so.

## Sounds and haptics

In Settings › General › Sounds and Haptics (both on, as in Arc):

- **Play Airc sound effects**: the alert sound when Airc can't do something, such as a key with nothing to act on.
  Turn it off and Airc makes no sound of its own. Web pages can still play sound, and macOS still plays its own alerts.
- **Haptic feedback when reordering tabs**: a tap from the trackpad each time a tab you drag moves to a new place in
  the sidebar, when it moves on to the next Space, and when a swipe past the first or last Space is far enough to open
  the Library or make a new Space.

## When Airc starts

Settings › General › **When Airc starts** chooses the windows Airc opens:

- **Open my windows and tabs from last time** (the standard choice): every window comes back with its Space, tab,
  split, size and sidebar, as before.
- **Open a new window**: one window on the Space you used last, with no tab open. Your pinned tabs, Favorites and
  Today tabs are still in the sidebar; only the windows start fresh.

Whatever you choose, your windows come back after a crash (or a force quit, or a power cut) and after Airc restarts
for an update. Only quitting Airc yourself starts fresh.

## Not yet

- Arc's other sound effects. Airc doesn't have sound effects of its own yet, only the Mac's alert sound.

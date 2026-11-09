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

After the restart a message says "Updated!" with the new version.

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

Settings › Appearance › **App Icon** chooses the icon in the Dock and the app switcher while Airc is open:
**Holographic** (the standard icon) or **Outline**. The Finder, and the Dock when Airc isn't running, keep the
standard icon.

## Sounds and haptics

In Settings › General › Sounds and Haptics:

- **Play Airc sound effects**: the alert sound when Airc can't do something, such as a key with nothing to act on.
  Turn it off and Airc makes no sound of its own. Web pages can still play sound.
- **Haptic feedback when reordering tabs**: the trackpad's tap when a tab you drag moves on to the next Space, and when
  a swipe past the first or last Space is far enough to open the Library or make a new Space.

## Not yet

- More app icons. Only Airc's own artwork is used, and the brand kit has two icons so far.
- Arc's other sound effects. Airc doesn't have sound effects of its own yet, only the Mac's alert sound.

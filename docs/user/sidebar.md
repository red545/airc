# The sidebar: folders in Today

Arc lets the unpinned part of a Space, Today, hold folders, and so does Airc. A folder in Today groups Today tabs
without pinning them: they stay Today tabs, so they still archive on their own after the Space's archive time, and
**Clear** still clears them. [Tidy Tabs](ai.md#tidy-tabs) puts its folders there.

## Making one and filling it

- Right-click the Space name (or an empty part of the sidebar) and choose **New Folder in Today**. The folder appears
  at the top of Today with its name ready to type; press Return to keep it, Esc to keep "New Folder".
- Drag a Today tab onto the folder's row to put it inside, or between the folder's tabs to put it at that place. A
  folder can hold folders too: right-click it and choose **New Nested Folder…**, or drag one folder onto another.
- Drag a tab out of the folder to anywhere else in Today, or above the divider to pin it (it leaves the folder).
- Select tabs with ⌘-click and use **Add to Folder ›** to move them into a folder in Today at once, or **New Folder
  with N Tabs** to put them in a new folder in Today, where the first one was. If the selection starts with a pinned
  row (pinned rows are above Today), the new folder is pinned instead.
- A link you open in the background from a tab in a folder lands in the same folder, just below it.

## Using it

- Click the folder's row to close or open it. A closed folder hides its tabs; they keep loading and archiving as usual.
- Double-click the name, or right-click and choose **Rename…**, to rename it. **Change Icon…** gives it an emoji.
- **Copy All Links** (and **as Markdown**) copies its tabs' addresses, nested folders included.
- **Ungroup** puts its tabs back in Today where the folder was and removes the folder.
- **Move to ›** takes the folder, with its tabs, to another Space's Today.
- **Delete Folder** sends its tabs to the Archive and removes the folder. ⌘Z brings both back.

## Between Today and Pinned

Drag a folder from Today above the divider and it becomes a pinned folder: its tabs become its pinned tabs, which
keep their place when you quit and don't archive. Drag a pinned folder below the divider and it becomes a folder in
Today: its pinned tabs become Today tabs inside it (one not loaded yet loads when you open it). A pinned folder that
holds a split can't go to Today, because a split in Today is a row of its own.

## Archiving and Clear

- Each tab in a folder archives on its own, by how long since you last looked at it, like any Today tab. When the
  folder's last tab goes, the folder goes too. A tab you close with ⌘W goes to the Archive, and its folder goes with it
  if it was the last one; ⌘Z brings back both.
- **Clear** (and ⇧⌘K) archives every Today tab but the one on screen, those in folders included, open or closed. The
  folders it leaves empty go, and so do empty folders you made and never filled. The tab on screen keeps its folder.
  One ⌘Z brings everything back.
- A tab you reopen from the Library goes back into its folder if the folder is still there, else to the top of Today.
- An empty folder you made and left empty goes at a later launch, once it's older than the Space's archive time.

## Sync and older versions

Folders in Today stay on this Mac, like Today itself: iCloud sync never sends them, and another Mac never moves or
removes them. A pinned folder you drag into Today stops syncing from then on (on your other Macs it goes, as if you'd
deleted it); drag it back to Pinned to sync it again.

Opening your data in an Airc from before folders in Today is safe. That version says some data is from a newer Airc,
keeps the folders untouched for this one, and shows their tabs in Today without folders. Back in this version, the
folders are there again with the tabs you left in them; a tab you pinned or archived there has left its folder. That
version won't restore a backup that holds folders in Today.

## Right-click or ⌃-click

Everywhere in the sidebar, ⌃-click does what a right-click does, as elsewhere on the Mac. That includes tabs,
Favorites, folders, split rows, the Space name, the Space bar's icons, the empty space under your tabs and the buttons
on the footer and on a tab's row. A ⌃-click on a tab opens its menu. It doesn't open or select the tab, and a ⌃-click on a
tab's ✕ opens the tab's menu instead of closing it.

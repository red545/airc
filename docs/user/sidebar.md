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

## Keeping your sidebar tidy

A long Today list is tiring to scan. Airc has Arc's tools for it, and a small card that points to them when you need
them. Nothing here ever runs by itself: each is one click, and each can be undone.

- **The tidy card.** When a Space's Today has 12 tabs or more outside folders (or 6 or more and Today is taller than
  the sidebar), a card shows at the top of Today. It offers:
  - **Tidy N tabs into folders**: see Tidy below.
  - **Archive N tabs idle X h**: the tabs you haven't looked at for 6, 3 or 1 hours (the longest that finds three or
    more). The page on screen is never one of them.
  - **Pin a site** (to Favorites): the one or two sites with the most Today tabs, so the Favorites grid at the top
    starts working for you. The tab becomes the Favorite; the site's other tabs stay.
  - **Archive after**: the Space's profile's auto-archive time, the same choice as **Settings → Profiles**
    (12 hours, 24 hours, 7 days, 30 days).
  - **Not now**: no card again today.

  The card shows at most once a day on this Mac: any choice, or Not now, puts it away until tomorrow. Each action
  leaves a message with **Undo** (⌘Z works too).
- **Tidy** (in the card, in the Today header next to Clear, or "Tidy Tabs" in the Command Bar) groups Today's tabs into
  folders: by topic with Apple Intelligence, by site without it. It shows the folders first, with **Apply** and
  **Cancel**; nothing moves until you apply. See [Tidy Tabs](ai.md#tidy-tabs).
- **Clear** (in the Today header) moves every Today tab except the one on screen to the Archive (Library → Archive).
  A message says how many, with **Undo**; the first time it also says where they went.
- **Auto-archive** does the same over time: a Today tab you haven't looked at for the profile's archive time (12
  hours unless you change it) goes to the Archive on its own. Tabs in a Pinned folder never do; tabs in a Today folder
  do, each on its own.
- **Folders and pinned tabs** are for what you keep: drag a tab above the divider (or press ⌘D) to pin it, and use
  **+ → New Folder…** for a folder. **Favorites** are the grid at the top: drag a tab up into it, choose **Add to
  Favorites** in the Command Bar, or use the card's Pin.

Arc had no card: it relied on auto-archive and its broom. Airc keeps Arc's tools and defaults (12 hours, Clear without
asking) and only adds the reminder, once a day at most.

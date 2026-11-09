# Menus, copying and sharing

Right-click a row in the sidebar for the same actions Arc offers there. Every one of them, and every command in the
menu bar, is also in the Command Bar: press ⌘T and type its name, or another word for it (for example "share",
"reset", "folders" or "read aloud").

## The menus

| Where you right-click | What it offers |
|---|---|
| A Today tab | Copy Link (⌥: Copy Link as Markdown), Share, Change Icon, Rename, Mute, Customize Page, Add Split View, Duplicate, Move to, Move to New Window, Pin Tab, Add to Favorites, Archive Tab, Archive Tabs Below |
| A pinned tab | Copy Link (⌥: as Markdown), Share, Change Icon, Rename, Edit Pinned Page › (Replace Pinned URL with Current, Edit…), Back to Pinned URL (when it's away from its saved page), Mute, Customize Page, Open in Split View, Duplicate, Move to another Space, Unpin, Add to Favorites, Close and Keep Pinned, Delete |
| A Favorite | Copy Link (⌥: as Markdown), Share, Change Icon, Edit Pinned Page ›, Back to Pinned URL, Mute, Customize Page, Open in Split View, Show Unread Badge (Gmail, Slack, X and other sites that count unread items), Move to › another profile's Favorites, Remove from Favorites, Close and Keep in Favorites, Delete Favorite |
| A folder | Rename, Change Icon, Copy All Links, Copy All Links as Markdown, Duplicate, New Nested Folder, Reset all tabs in this Folder, Move to › another Space, Turn into Space, Delete Folder |
| A split's pane | Copy Link (⌥: as Markdown) and Share for that pane, then the split's own actions |
| Several selected rows | Copy N Links (⌥: as Markdown), Share, then the selection's other actions |
| A Space | Its usual actions, and Export Space… (its tabs, folders and Favorites as Markdown or HTML); Show Space Header or Hide Space Header for an only Space with no name and no icon |
| The sidebar's + button | Its usual new things, and Add Files… (files and folders into this Space) |

Actions that can't do anything right now are greyed out: Archive Tabs Below with no tabs below, Replace Pinned URL with
Current while the tab is on its saved page, Open in Split View on the tab already on screen.

A Today tab keeps the icon you give it when you pin it or make it a Favorite, and gets it back when you unpin it.
Open in Split View puts the pinned tab or Favorite beside the page on screen, as ⌥-clicking it does.

## The menu bar

- **File**: Share (the page on screen), Export All Spaces….
- **Airc**: Services, the Mac's own ([Find and Replace](find.md#services)).
- **Edit**: Delete; Find and Replace (⌥⌘F: replace in the page's editable text, [Find and Replace](find.md)); Use
  Selection to Find (the find bar opens with the selected text) and Jump to Selection (⌘J: scrolls back to the
  selection), in pages and notes; Spelling and Grammar, Substitutions, Transformations (upper case,
  lower case, capitalize) and Speech (Start Speaking reads the selection aloud), for whatever has the keyboard. Which
  of these a web page takes depends on the engine; notes and text fields take all of them.
- **Format › Font**: Bold ⌘B, Italic ⌘I, Underline ⌘U, in notes (as their own formatting) and in a page's editable
  text.
- **Tabs**: Reset all tabs in this Space, Expand All Folders, Collapse All Folders, Expand or Collapse Pinned Section,
  Reveal Current Tab (⌃Space), Reveal Tab in Sidebar.
- **Help**: Getting Started, Essential Keyboard Shortcuts (a window of the keys that matter most, as you've set them in
  Settings → Shortcuts), Release Notes, Privacy Policy, and the Mac's search field, which finds any menu item.

## Copying links

- **⇧⌘C** (Edit › Copy URL) copies the page on screen. With a Peek open, it copies the Peek's page; in a split, the
  pane you're in. With rows selected in the sidebar, it copies their links.
- **⌥⇧⌘C** copies it as a Markdown link, `[Title](address)`. **⌃⇧⌘C** copies the text you selected on the page as a
  Markdown quote with a link back. If you copy something else, switch tabs, or the Peek closes before the page has
  handed over its selection, that quote is dropped rather than replacing what you copied since.
- **A link to the text you copied.** After ⌘C on text you selected in a page, Airc offers "Share a link directly to
  this text instead?". Copy Link replaces what you copied with a link that opens the page at that text, highlighted.
  The offer goes away by itself; nothing changes unless you click it. To stop the offers, right-click it and choose
  **Disable Shared Quotes**, use Disable Shared Quotes in the Command Bar (Enable Shared Quotes turns them back on), or
  turn off **Settings → General → Shared Quotes → Enable Shared Quotes when highlighting text**.
- **Clean links.** Copy URL, Copy Link and Share leave out the tracking parameters that ads, newsletters and share
  buttons add (`utm_…`, `fbclid`, `gclid`, YouTube's and Spotify's `si`, X's `s` and `t`, and similar). Everything the
  page needs stays, in its order. When something was removed, the message says "Copied a clean link without
  trackers".
- **Copy All Links as Markdown** on a folder copies a list of its tabs with their names, in sidebar order, with each
  nested folder as an item and its tabs indented under it. Tabs use their saved addresses. Notes have no link and are
  left out.

## Sharing

Share opens the Mac's share menu (Messages, Mail, AirDrop, Notes and the share extensions you have) with exactly the
links you chose: the row's page, or each selected row's, in order. Only the addresses are shared, without trackers,
with no page titles or content.

## Going back to a pinned page

Back to Pinned URL (or clicking a pinned tab's favicon) takes the tab back to its saved page. If the page has changes
it may not save, such as text typed into a form, Airc asks first ("Leave site?"). Cancel keeps the page as it is. Leave
goes back without a second question.

**Reset all tabs in this Space** (Tabs menu, or the Command Bar) does the same for every pinned tab in the Space that
is away from its saved page, including tabs in folders and pinned splits. Favorites belong to the profile, not the
Space, so they stay. If some pages have unsaved changes, one question covers them all: Reset All, Cancel, or Reset
Others to leave those pages as they are. The tab on screen stays on screen.

⌘Z undoes a reset: each page goes back to where it was (a page you chose to leave comes back without what you'd typed).

**Reset all tabs in this Folder** (the folder's menu) does the same for the pinned tabs in that folder, nested folders
included, and nothing outside it.

## Folders and Favorites elsewhere

- **Move to ›** on a folder moves it, with everything inside, to the pinned section of another Space. Into another
  profile's Space its pages reload with that profile's logins, so Airc asks first.
- **Turn into Space** makes the folder a Space of its own, right after the current one, in the same profile and theme,
  named after the folder and with its emoji. The folder's tabs and nested folders become the new Space's pinned
  section, in the same order. ⌘Z puts the folder back.
- **Move to ›** on a Favorite lists your other profiles. The Favorite moves to that profile's Favorites. A page that's
  open reloads with that profile's logins, so Airc asks first.

## An unnamed Space

If you have only one Space and it has no name and no icon, Airc hides its name row, as Arc does. Right-click the
sidebar's empty space (or the Space's footer button) and choose **Show Space Header** to see it again, or Hide Space
Header to hide it. Giving the Space a name or an icon shows the row. Rename Space… with an empty name leaves a Space
unnamed.

## Not yet

- Sharing a folder or Space as a link.
- Find and Replace (the find bar finds; it doesn't replace).

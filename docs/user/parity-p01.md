# Menus, copying and sharing

Right-click a row in the sidebar for the same actions Arc offers there. Every one of them, and every command in the
menu bar, is also in the Command Bar: press ⌘T and type its name, or another word for it (for example "share",
"reset", "folders" or "read aloud").

## The menus

| Where you right-click | What it offers |
|---|---|
| A Today tab | Copy Link (⌥: Copy Link as Markdown), Share, Change Icon, Rename, Mute, Customize Page, Add Split View, Duplicate, Move to, Move to New Window, Pin Tab, Add to Favorites, Archive Tab, Archive Tabs Below |
| A pinned tab | Show Hover Preview, Copy Link (⌥: as Markdown), Share, Change Icon, Rename, Mute, Edit Pinned Page › (Edit…, Replace Pinned URL with Current), Back to Pinned URL (when it's away from its saved page), Open in Split View, Duplicate, Move to › a Space of any profile or a folder, Unpin, Add to Favorites, Close Tab, Remove Pin, Customize Page |
| A Favorite | Show Hover Preview, Copy Link (⌥: as Markdown), Share, Show Unread Badge (Gmail, Slack, X and other sites that count unread items), Change Icon, Mute, Edit Pinned Page ›, Back to Pinned URL, Open in Split View, Move to › a Space or another profile's Favorites, Unfavorite, Close Favorite, Remove Favorite, Customize Page |
| A folder | Share Folder…, New Nested Folder…, Turn “‹folder›” into Space, Copy All Links, Copy All Links as Markdown, Change Icon, Rename, Duplicate, Move to › a Space of any profile or a folder, Reset Folder, Delete Folder |
| A split's pane | Copy Link (⌥: as Markdown) and Share for that pane, then the split's own actions |
| Several selected rows | Copy N Links (⌥: as Markdown), Share, then the selection's other actions, Move to Space › grouped by profile (selected Favorites become pinned there), Reset N Folders when only folders are selected; with Today tabs among them, Archive Tabs Below and Archive Other Tabs |
| A Space | Its usual actions, and Export Space… (its tabs, folders and Favorites as Markdown or HTML); Show Space Header or Hide Space Header for an only Space with no name and no icon |
| The sidebar's + button | Its usual new things, and Add Files… (files and folders into this Space) |

Actions that can't do anything right now are greyed out: Archive Tabs Below with no tabs below, Replace Pinned URL with
Current while the tab is on its saved page, Open in Split View on the tab already on screen.

The pinned tab, Favorite and folder menus follow Arc 1.171's own order and titles. Unpin, Unfavorite, Add to Favorites
and Reset Folder are Airc's additions (Arc unpins with ⌘D and resets only a whole Space).

**Move to ›** lists the Spaces of the row's profile, then each other profile under its name with its Spaces, then this
Space's folders (nested ones indented), then New Space…. A Today tab
can go into any folder: a pinned one pins it there, a Today folder keeps it in Today. A pinned tab or folder goes into
the pinned folders, never into itself or a folder inside it. ⌘Z puts the row back where it was.

**Archive Tabs Below** on several selected tabs archives the Today tabs under the lowest one; **Archive Other Tabs**
archives every Today tab you didn't select. The tab on screen always stays. ⌘Z brings them back.

A Today tab keeps the icon you give it when you pin it or make it a Favorite, and gets it back when you unpin it.
Open in Split View puts the pinned tab or Favorite beside the page on screen, as ⌥-clicking it does.

## The menu bar

- **File**: Share (the page on screen), Export All Spaces…. In a private window, Share sends the page's link alone,
  without trackers, and Airc keeps nothing of it: no history and no recent item.
- **Airc**: Services, the Mac's own ([Find and Replace](find.md#services)).
- **Edit**: Delete; Find and Replace (⌥⌘F: replace in the page's editable text, [Find and Replace](find.md)); Use
  Selection to Find (the find bar opens with the selected text) and Jump to Selection (⌘J: scrolls back to the
  selection), in pages and notes; Spelling and Grammar, Substitutions, Transformations (upper case,
  lower case, capitalize) and Speech (Start Speaking reads the selection aloud), for whatever has the keyboard. Which
  of these a web page takes depends on the engine; notes and text fields take all of them.
- **Format › Font**: Bold ⌘B, Italic ⌘I, Underline ⌘U, in notes (as their own formatting) and in a page's editable
  text.
- **Tabs**: Reset all tabs in this Space, Expand All Folders, Collapse All Folders, Expand or Collapse Pinned Section,
  Reveal Current Tab (⌃Space), Reveal Tab in Sidebar. The Command Bar finds the folder commands by Arc's other words for
  them too: "close all folders", "reveal all folders".

Arc kept a few tab commands in the Command Bar only, and so does Airc: **Mute All Tabs** (while a tab plays sound) and
**Unmute All Tabs**, **Rename Current Tab** (a Today tab is pinned first, as Rename… does), and **Pin to “Folder”** for
each pinned folder in the Space (⌘Z puts the tab back).
- **Help**: Getting Started, Essential Keyboard Shortcuts (a window of the keys that matter most, as you've set them in
  Settings → Shortcuts), Release Notes, Privacy Policy, and the Mac's search field, which finds any menu item.

## Copying links

- **⇧⌘C** (Edit › Copy URL) copies the page on screen. With a Peek open, it copies the Peek's page; in a split, the
  pane you're in. With rows selected in the sidebar, it copies their links.
- **The copy button on a tab.** Rest the pointer on a tab in the sidebar (a Today tab, a pinned tab, a Favorite shown
  as a row) and a copy button shows beside its ✕. Click it to copy that tab's link, without its trackers, as ⇧⌘C
  would; "Copied Link" confirms it. The tab isn't opened or selected. With VoiceOver, it's the row's **Copy Link**
  action.
- **⌥⇧⌘C** copies it as a Markdown link, `[Title](address)`. **⌃⇧⌘C** copies the text you selected on the page as a
  Markdown quote with a link back. If you copy something else, switch tabs, or the Peek closes before the page has
  handed over its selection, that quote is dropped rather than replacing what you copied since.
- **A link to the text you copied.** After ⌘C on text you selected in a page, Airc offers "Share a link directly to
  this text instead?". **Copy Quote Link** replaces what you copied with a link that opens the page at that text,
  highlighted, and "Copied Link · With Quote" confirms it, as in Arc. The link takes whole words, so a selection that
  starts or ends partway through a word still finds its text; a long passage, or one over several paragraphs, is
  found by its first and last words. You can also right-click (or ⌃-click) the selected text and choose **Copy Quote
  Link**, right under Copy (the engine's own **Copy Link to Highlight**, on Safari's engine **Copy Link with
  Highlight**, is there too).
- **Pages that get a plain link.** Where a link to the text can't work, Copy Quote Link and Share Quote copy the
  page's clean link instead, and the toast says just "Copied Link": PDFs, pages that aren't websites (a browser
  page, a file), and sites that ask browsers to always open them at the top (`Document-Policy: force-load-at-top`).
  To find that out, Airc asks the site once for the page's headers. Private windows offer no quote links at all.
- **Share Quote in the address.** While you have text selected on a page, a small **❝ Share Quote** button slides in at
  the right end of the address at the top of the sidebar (the address fades a little earlier to make room; nothing else
  in the sidebar moves). In a narrow sidebar it's just the ❝. Click it to copy the same link to that text (whole words,
  without trackers); "Copied Link · With Quote" confirms it. It appears once you let go of the mouse (or the key
  that made the selection), never while you're still dragging, and goes when the selection does, when you switch
  tabs, or when you hide the sidebar. Text you select inside a field or an editor gets no button: a link can't point
  there. Right-click it for **Disable Shared Quotes**.
  The offer goes away by itself; nothing changes unless you click it. To stop the offers, right-click it and choose
  **Disable Shared Quotes**, use Disable Shared Quotes in the Command Bar (Enable Shared Quotes turns them back on), or
  turn off **Settings → General → Shared Quotes → Enable Shared Quotes when highlighting text**. With them off,
  **Copy URL as Quote** (⌃⇧⌘C) still copies the URL with your selection as a quote, as in Arc.
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

**Reset Folder** (the folder's menu) does the same for the pinned tabs in that folder, nested folders included, and
nothing outside it. With several folders selected, **Reset N Folders** resets them all at once. ⌘Z undoes it.

## Folders and Favorites elsewhere

- **Move to ›** on a folder moves it, with everything inside and its nested folders as they are, to the end of the
  pinned section of another Space, in this profile or another one. A Space of another profile shows a tooltip: its
  pages reopen there with that profile's logins and cookies, so they may look different or ask you to sign in. If any
  of them is open, Airc asks first, and a message confirms the move. ⌘Z moves it back.
- **Turn “‹folder›” into Space** makes the folder a Space of its own, right after the current one, in the same profile and theme,
  named after the folder and with its emoji. The folder's tabs and nested folders become the new Space's pinned
  section, in the same order. ⌘Z puts the folder back.
- **Move to ›** on a Favorite lists the Spaces of its profile, then each other profile with its Favorites and Spaces.
  Choosing a Space makes the Favorite a pinned tab there; choosing another profile's Favorites keeps it a Favorite
  there. Into another profile the page reopens with that profile's logins and cookies (the rows' tooltip says so), and
  an open page asks first. ⌘Z undoes either move. A full Favorites grid (12) says so.

## An unnamed Space

If you have only one Space and it has no name and no icon, Airc hides its name row, as Arc does. Right-click the
sidebar's empty space (or the Space's footer button) and choose **Show Space Header** to see it again, or Hide Space
Header to hide it. Giving the Space a name or an icon shows the row. Rename Space… with an empty name leaves a Space
unnamed.

## Not yet

- Sharing a folder or Space as a link.
- Find and Replace (the find bar finds; it doesn't replace).

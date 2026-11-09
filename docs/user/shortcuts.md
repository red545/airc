# Shortcuts

Use **Settings → Shortcuts** to see the full list and change a key. The defaults include:

| Action | Keys |
|---|---|
| Search or open a tab | ⌘T |
| Edit the current address | ⌘L |
| Show or hide the sidebar | ⌘S |
| Close a tab / reopen a closed tab | ⌘W / ⇧⌘T |
| Pin or unpin | ⌘D |
| Copy the address / copy as Markdown | ⇧⌘C / ⌥⇧⌘C |
| Previous / next Space | ⌥⌘← / ⌥⌘→ |
| Go to Space 1–9 | ⌃1–9 |
| Previous / next tab | ⌥⌘↑ / ⌥⌘↓ |
| Sidebar item 1–8 / the last item | ⌘1–8 / ⌘9 |
| Reveal Current Tab: the keyboard goes to the sidebar | ⌃Space |
| Recent tabs: hold ⌃ and press Tab again for older ones, ⇧ to go back | ⌃Tab / ⌃⇧Tab |
| Cycle through every tab of the Space, most recently used first ([details](parity-p03b.md)) | ⌃⌘→ / ⌃⌘← |
| Library | ⇧⌘L |
| Find on the page / Find and Replace ([Find](find.md)) | ⌘F / ⌥⌘F |
| Capture part of the page ([Capture](capture.md)) | ⇧⌘2 |
| New note ([Notes](notes.md)) | ⌃⇧N |
| New window / private window | ⌘N / ⇧⌘N |
| Little Airc | ⌥⌘N |
| Open a link in Little Airc ([Little Airc](little-arc.md)) | ⌥⌘-click the link |
| Add a split pane | ⌃⇧= |
| Previous / next split pane | ⌃⇧[ / ⌃⇧] |
| Join the current or next meeting (Live Calendar) | ⌃⌘J |
| Developer Mode on or off for the site on screen | ⌃D |
| Enter or exit fullscreen | ⌃⌘F |

Click a key in Settings to record its replacement. Esc cancels; Delete removes the binding. If another command
already uses it, choose Swap or Replace. Reset one row or use Reset All to restore defaults. macOS-reserved keys
cannot be assigned. On keyboard layouts that type [ ] { } only with ⌥ (German, French …), the bracket shortcuts also
work from the key where a US keyboard has the bracket ([details](parity-p03b.md#keyboard-layouts-without--and-)).

Commands a web page could also use have Arc's three choices for who gets the key:

- **Use Both** (the default): the page gets the key first. Press it again within about a second to run Airc's command.
- **Prefer Websites**: a page that uses the key keeps it, however often you press it. Airc's command runs only on pages
  that don't use the key.
- **Prefer Airc**: Airc's command always runs, and pages never see the key.

Text-editing shortcuts still belong to the field you are editing. Little Airc uses its own
browser key handling: ⌘O moves its page into the Space on its Open in button. The button's chevron (⇧⌘O) opens Open
In: your Spaces in their colours (↑ ↓ and Return pick one, or start typing to search them), then Profile and Copy Link
(⇧⌘C). ⌥⌘O opens it straight into Search Spaces.

In fullscreen, a single Esc goes to the page or closes the active overlay; double-press or hold Esc to exit
when no overlay or text field is using it. You can also use the View menu or ⌃⌘F.

For the detailed command inventory and test notes, see the [shortcut reference](../qa/shortcuts.md).

## The sidebar from the keyboard

Press **⌃Space** (Arc's Reveal Current Tab) and the keyboard moves from the page to the current tab's row in the
sidebar. Folders and a folded pinned section that hide the row open first, and a hidden sidebar slides out. From there:

| Key | What it does |
|---|---|
| ↑ ↓ | Move through every row: Favorites, the Space name, pinned tabs and folders, New Tab, Today |
| ← → | In the Favorites grid, move along the row. On a folder or the Space name, close or open it without loading anything. On a tab inside a folder, ← goes to its folder |
| Tab / ⇧Tab | Jump to the next or previous section (Favorites, pinned, Today) |
| Home / End, Page Up / Page Down | The first or last row, or ten rows at a time |
| Letters | Jump to the next row whose name starts with what you type (an ä is the ä key on your layout). Wait a second to start a new name |
| Space | Show the row's page and keep the keyboard in the sidebar |
| Return | Show the row's page and give it the keyboard |
| Esc | Give the keyboard back to the page (an open find bar closes first; [Esc's order](parity-p03b.md#esc-closes-one-thing-at-a-time)) |
| ⇧↑ ⇧↓ | Select pinned or Today rows, as ⇧-clicks do: then Delete archives them, ⌘W closes, ⌘D pins or unpins, ⇧⌘C copies their links. ↑ ↓ go back to one row; Esc clears the selection |

**⌃Tab** shows the tab you used before this one at once. Keep ⌃ held and press Tab again to go further back through the
five most recent tabs of the Space, or ⌃⇧Tab to come forward again; let go of ⌃ to stay. Only the tab you stop on counts
as used, so the tabs you passed keep their place, as with ⌘Tab. **Cycle Tab** (⌃⌘→, ⌃⌘← back) goes through every tab of the
Space in the same order, with no ⌃ to hold ([Cycle Tab](parity-p03b.md#cycle-tab--and-)).

With the pinned section folded, the arrows skip the pinned rows, and the Space name turns bold while the tab on screen
is one of them. The Tabs menu also has **Reveal Tab in Sidebar** (show the current tab's row without moving the
keyboard), **Expand/Collapse Pinned Section** and **Expand/Collapse All Folders**. ⌃Space is also macOS's key for
switching input sources when you have more than one, and then macOS gets it first. Settings → Shortcuts notes this on
the row, where you can give Reveal Current Tab another key.

## Numbers and Favorites

Under the list in **Settings → Shortcuts → Sidebar**, as in Arc:

- **Include Favorites in ordering** (on): ⌘1 is your first Favorite. Turn it off and ⌘1 is the first item after the
  Favorites.
- **Switch to ninth tab** (off): ⌘9 jumps to the last item at the bottom of your sidebar. Turn it on and ⌘9 is the ninth
  item.

Folders don't count. Neither do tabs in a folded pinned section or a closed folder. A pinned tab or Favorite that isn't
loaded counts and loads when you press its number; a split counts once. Each ⌘ row in Settings says which item it jumps
to with your choices. The choices are kept across restarts.

## Holding ⌥

While the sidebar is hidden (⌘S), hold **⌥** on its own for a moment and the sidebar slides out over the page. Let go
and it slides away, unless you moved the pointer into it: then it stays until the pointer leaves, as when you reveal it
from the window's edge. ⌥ used for anything else does nothing: typing an ⌥ character (such as @ or [ on German and
Austrian keyboards), an ⌥⌘ shortcut, an ⌥-click or a scroll. While you're typing in a field, ⌥ stays the field's (⌥← ⌥→
move by word). Turn it off with **Hold ⌥ to show a hidden sidebar** in Settings → Shortcuts → Sidebar.

## VoiceOver and accessibility

The sidebar is one outline for VoiceOver (named "Sidebar" and the Space's name). Each row says its name and what it is
(Favorite, Space, folder, pinned tab, tab, split view, note), with the tab on screen as the selected row. Folders and the
Space name also say whether they're expanded or collapsed. A folded Space name says when it holds the current tab, and a
pinned tab or Favorite says when it isn't loaded. VoiceOver's Press opens a row, as a click does: a tab shows, and a
folder or the Space name opens or closes in place. Show Menu opens the row's menu. The keyboard focus above is
VoiceOver's focus too, so ⌃Space, the arrows and Esc work the same way with VoiceOver on.

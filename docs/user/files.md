# Files, folders and exporting your Spaces

## Adding files, folders, links and text

Drag things from the Finder or another app onto the sidebar, or use **Add Files…** at the end of the sidebar's **+**
menu (it's in the Command Bar, ⌘T, too).

Arc opened dropped files as tabs, imported dropped folders and searched for dropped text, and it had an Add Files
entry in 2021. Current Arc has no Add Files. **Add Files…** is an Airc addition modelled on it, as are the
note for longer text and the limits below.

| What you drop | What it becomes |
|---|---|
| A file | A tab with the file (PDFs, pictures, web pages, text and anything the browser can show) |
| A folder | A folder in the pinned section with the folder's files as pinned tabs, its folders inside it, in the Finder's name order |
| A link (from Safari, Mail, Notes…) | A tab with the link, named as the link was |
| Text that is a link, or lines that are all links | A tab for each link |
| A word or a phrase | A search with your profile's search engine |
| Longer text (more than one line) | A note with the text |

- Dropped files and links go to the top of Today, in the order you dragged them, and the first one opens.
- Dropped on the pinned section or into a folder, they go where the drop line is, as pinned tabs.
- Folders always go to the pinned section, as Arc's do.

A folder is read in full before anything is added:

- Hidden files (such as `.DS_Store`) are left out.
- Links (aliases) are followed once. A link that leads back into the folder being read, or to nothing, is left out.
- Folders more than eight levels deep come in empty.
- At most 300 tabs come from one drop. Above 25 Airc asks first, and with more than 300 files it says only the first
  300 are added.
- A slow read shows a sheet with **Cancel**.

Cancelling at any point, in Add Files…, in the question, or while a folder is read, adds nothing. Whatever one drop
added, however many rows, goes back with a single **⌘Z**.

## Exporting a Space

**Export Space…** saves one Space, and **Export All Spaces…** in the File menu saves all of them, as a file you can open
anywhere. Export Space… is in a Space's menu: the **•••** next to its name, or right-click its name or its icon at
the bottom of the sidebar. Both are in the Command Bar (⌘T) too. Exporting is an Airc addition: Arc can export its notes, but not your Spaces.

- **Markdown**: the Space's name, then its pinned section and Today as lists of links, folders as items with their
  rows indented under them.
- **HTML (bookmarks)**: the bookmarks file every browser imports (Chrome, Safari, Firefox and Airc). Each Space
  becomes a folder with Pinned and Today folders inside.

Names, the order and the folders are kept. Pinned tabs export the address they stand for; Today tabs their current
one. Export All Spaces also includes each profile's Favorites.

Nothing private goes into the file:

- A link's user name and password (`https://name:password@…`) are taken out.
- `data:`, `blob:` and `javascript:` links are left out.
- A note is listed by its title only; its text stays in Airc.
- Private windows' tabs are never part of your sidebar, so they're never exported.
- Blank windows' Spaces aren't exported.

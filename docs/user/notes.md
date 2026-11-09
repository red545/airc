# Notes

A note is a page of your own in the sidebar, as Arc's Notes were: it sits among your tabs, opens in the page area,
and keeps what you type. Make one with **⌃⇧N** (File › New Note), **New Note** in the Command Bar (⌘T, then type
"note") or **New Note** in the sidebar's **+** menu.

- A new note is **pinned** at the bottom of the Space's pinned tabs (Arc pinned new notes too, so they're hard to
  lose), and its first line is ready for a title. The sidebar shows the note's first line as its name, "New Note" until
  it has one. ⌘D moves it to Today and back; drag it like a tab, into a folder, to another Space, or ⌥-drag it for a copy.
- It saves as you type. There's no Save and nothing to lose when you quit.
- **⌘W** archives a note in Today like a tab, and the Library's Archive brings it back as it was. A note with nothing in
  it doesn't go to the Archive: closing it deletes it (⌘Z brings it back). Archived notes are kept until you clear the
  Archive, not only 90 days as pages are.
- **New Note in Split** (File › New Note in Split, or the Command Bar beside a page; Arc's "New Note (in Split)") puts
  a new note beside the page you're on, in Split View, with the keyboard in the note. The page stays as it was. A
  note in a split is a Today note: click a pane or use ⌘[ and ⌘] to move between them, ⌘W archives the note and the
  page is a tab of its own again. Notes don't go into Favorites or pinned splits, and dragging a note onto a tab
  doesn't split them.

## Writing

| | |
|---|---|
| Heading 1, 2, 3, text | `# `, `## `, `### ` at the start of a line, or ⌥⌘1, ⌥⌘2, ⌥⌘3 and ⌥⌘0 |
| Bulleted list | `- ` or `* `, or ⇧⌘8 |
| Numbered list | `1. `, or ⇧⌘7 |
| Checklist | `[] ` or `- [ ] `, or ⇧⌘9. Click a box to tick it |
| Nesting | Tab and ⇧Tab in a list. Return on an empty item moves it out a level, then ends the list |
| Bold, italic, underline, strikethrough | ⌘B, ⌘I, ⌘U, ⇧⌘X |
| As you type, in a line | `*bold*` or `**bold**`, `_italic_`, `-strikethrough-` or `~~strikethrough~~`, `` `code` ``, then a space or punctuation. ⌘Z right after gives the marks back |
| Link | ⌘K, or paste an address onto selected text. A click opens it in a new tab |
| Undo, redo | ⌘Z, ⇧⌘Z: each note has its own |
| Find | ⌘F, ⌘G, ⇧⌘G: the same find bar as on pages, every match highlighted |
| Print, PDF | ⌘P; the print panel's PDF menu saves a PDF |

Right-click for the Format menu (with Code for inline code), Add Link… and Insert Image….

**Pictures**: paste one (⌘V), drop one in, or use Insert Image…. A [Capture](capture.md)'s Copy goes straight into a
note with ⌘V: that's how Arc's notes took Captures too. A picture gets a line of its own and is never wider than the
note. Text you paste from another app keeps its headings, bold, italic, links, lists and checkboxes, not its fonts or
colours; ⇧⌘V pastes plain text. Several lines copied out of a note paste into other apps as Markdown.

## Export and import

**Export Note…** (File, the note's right-click menu in the sidebar or in the note, or the Command Bar) saves the note
in the format you pick under the file name:

| Format | What you get |
|---|---|
| Markdown | A `.md` file, and its pictures in a folder beside it ("Lisbon plan files/Picture 1.png") |
| Rich Text with Pictures (RTFD) | For TextEdit and Pages, pictures inside |
| Rich Text (RTF) | For Word and others; pictures are left out |
| PDF | The note as Print shows it, on white paper |
| Web Page (HTML) | One page with its pictures inside, as Arc's own "Export Arc Notes" wrote |

**Export All Notes…** (File or the Command Bar) writes every note with something in it, archived ones too, into a new
folder "Airc Notes" (then "Airc Notes 2", …) where you choose, one file per note named by its title.

**Import Notes…** (File or the Command Bar) makes a note of each Markdown, text, RTF, RTFD or HTML file you choose,
pinned in the current Space. What Airc exported comes back as it was: headings, lists, checkboxes, marks, links and
pictures (a Markdown file's pictures are read from beside it; pictures on the web stay links). Arc's exported HTML
reads too. PDF doesn't import.

## New Note in another app

Arc later let New Note open your notes app instead. Airc has the same choice in **Settings → General → Notes → New
Note opens**: Airc Notes (the default), Google Docs, Notion, Microsoft Word or Confluence. With one of those chosen,
⌃⇧N, File › New Note, the "+" menu and the Command Bar open a new document of that app in a new tab, signed in as the
Space's profile is, and their name says it ("New Google Doc"). **New Airc Note** stays in the Command Bar and the "+"
menu. New Note in Split opens the chosen app's new document beside your page in the same way. When the Mac is
offline, New Note makes an Airc note instead and says so. Airc never switches this for you.

## Where notes are

Notes are in Airc's store on this Mac, with its other sidebar data, and in its daily backups; restoring a backup brings
its notes back. Going back to an Airc from before notes (0.1.2) is safe until you make your first note: from then on
that version keeps your notes untouched for this one, says some data is from a newer Airc, and won't restore backups
that hold notes. Pictures are files in the data folder's `Notes/Images`, one per picture however often it's used; a
picture no note shows is removed at a later launch, unless a backup still names it.

**Notes stay on this Mac for now.** iCloud sync never sends a note, its text, its title or its pictures, and other
Macs never move, archive or remove one: a pinned note is left where it is, and a Space deleted on another Mac stays
here while it holds a note. See [iCloud sync](sync.md).

**Private windows** have no notes: New Note does nothing there.

Usage data: making a note counts one `feature.used` event (feature `note.create`, variant `shortcut`, `command_bar` or
`plus_menu`); never what it says, its title, its pictures or where it is. Exporting, importing and opening another app's
document count nothing. See [Usage data and crash reports](telemetry.md).

## What's not here yet

Arc's notes could be shared by link (read-only or editable) and synced through Arc's account; Airc's can't yet. There's
no separate title field (the first line is the title), no tables and no code blocks (inline code only; a Markdown
code block imports as code lines).

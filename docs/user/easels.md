# Easels

An Easel is a canvas of your own in the sidebar, as Arc's Easels were: a board you fill with text, pictures, shapes,
arrows, links and Captures, then arrange freely. Make one with **⌃⇧E** (File › New Easel), **New Easel** in the
Command Bar (⌘T, then type "easel") or **New Easel** in the sidebar's **+** menu.

- A new Easel is **pinned** at the bottom of the Space's pinned tabs, with its title ready to type ("Untitled Easel"
  until you name it). Return goes from the title to the canvas. Drag it like a tab, into a folder or to another Space.
- It saves as you work. There's no Save and nothing to lose when you quit, and your **undo history survives a
  relaunch**: ⌘Z after reopening Airc undoes what you did last time.
- **⌘W** archives an Easel in Today like a tab; the Library's Archive or **Library › Easels** brings it back.
- Easels stay on this Mac for now: they aren't synced to your other Macs. They can't be Favorites or part of a
  Split View (⌥-click on an Easel just shows it), and dragging a tab onto an Easel adds a link card rather than a split.
- **Duplicate** (or ⌥-drag) an Easel's row and you get a new Easel with the same blocks and pictures, as with notes;
  changing one leaves the other alone. **⌘Z** right after takes the copy away again, its Easel too: it isn't left
  behind in Library › Easels. An Easel's row has no **Add Split View** in its menu.

## Adding things

| | |
|---|---|
| Text | **T**, then click where it goes (or drag for its width) and type. Esc or a click elsewhere ends it. Double-click or Return edits it again. ⌘B, ⌘I, ⌘U and ⇧⌘X mark the selected words |
| Rectangle, ellipse | **R** or **O**, then drag. A click makes one of the usual size. ⇧ keeps it square |
| Arrow, line | **A** or **L**, then drag from one end to the other. ⇧ keeps it to 45° steps |
| Picture | Paste one (⌘V) from anywhere, drop an image file or a page's picture, or use the toolbar's picture button |
| Link | Paste or drop an address, drop a link from a page, drag tabs from the sidebar onto the Easel, or use the toolbar's link button. Each becomes a link card; double-click one to open the page in a new tab |
| Capture | In a Capture (⇧⌘2), choose **Easel** in the bar, then the Easel or New Easel. The picture lands on it with the page's address, and stays **live** (see below) unless you turn off **Keep It Live** in that menu |
| Text from elsewhere | Paste or drop it: a text block |

The toolbar at the bottom has the same tools, plus **Color** (Arc's eleven colours, for shapes, lines and text) and
**Text Style** (Clean, Mono, Fancy, Hip; five sizes; alignment). New blocks keep the colour and style you picked last.

## Arranging

| | |
|---|---|
| Select | Click a block; ⇧-click adds or removes one; drag across empty canvas for a marquee; ⌘A selects all; Esc lets go |
| Move | Drag. Edges and centres **snap** to other blocks' with a pink guide; hold ⌘ while dragging to place freely. ⌥-drag moves a copy |
| Nudge | Arrow keys move 1 pt, ⇧ with them 10 pt |
| Resize | Drag a handle. Pictures and Captures keep their shape at a corner (⇧ frees them); other blocks keep theirs with ⇧ |
| Rotate | Drag the round handle above a block. ⇧ turns in 15° steps |
| Arrow ends | Drag either end of a selected arrow or line |
| Duplicate, delete | ⌘D, ⌫ |
| Group | ⌘G groups the selection: a click on one selects them all, and they move and resize together. ⇧⌘G ungroups |
| Order | ⌘] and ⌘[ bring forward and send backward; ⇧⌘] and ⇧⌘[ to the front and back. Also in the right-click menu |
| Copy and paste | ⌘C, ⌘X, ⌘V, within an Easel or between Easels (pictures come along). Copied text, links and pictures paste into other apps too |
| Undo | ⌘Z and ⇧⌘Z, every step, including after a relaunch |

## Live Captures

A Capture you add to an Easel remembers where it came from: the page, the part of it you selected, and the profile
you were signed in with. So it can be taken again whenever you like, and keep itself up to date.

- A live Capture has a **Live** chip in its corner. When its Easel opens, any live Capture older than 15 minutes
  refreshes by itself, and so do they every 15 minutes while the Easel is on screen. **⌘R** refreshes all of an
  Easel's Captures at once; **Refresh Capture** in a Capture's right-click menu refreshes that one.
- Refreshing loads the page out of sight, in the same profile, at the size it had, scrolled to where it was, and
  takes the same part of it again. Zoom doesn't matter: the part is kept in the page's own measures, so a Capture taken
  at 125 % still finds the same part after the page reloads at 100 %.
- If the page asks you to sign in, is gone, or you're offline, the last picture stays and says so ("Sign in to
  refresh", "Offline", "Page not found"). Sign in to the site in a tab of that profile, then refresh. Failed refreshes
  wait longer each time before trying again by themselves.
- **Double-click** a live Capture to use it: the real page appears in its place, at its size, and you can scroll, click
  and drag links out of it. **Esc** or a click outside ends it, and the Capture is taken again as the page is then.
- **Update Automatically** (right-click menu) switches between refreshing by itself and only when you ask.
  **Detach from Page** makes it an ordinary picture that never changes again (⌘Z brings the link back).
- A refresh never makes an undo step, and undoing something else never brings an old picture back.
- What the page does out of sight is kept quiet: it's muted and doesn't play media, it can't ask for your camera,
  microphone, location, notifications or devices, it opens no windows or dialogs and downloads nothing, and it's closed
  as soon as its picture is taken (at most 20 seconds). Detaching or deleting a Capture stops a refresh under way.
- Pages in Private windows can't go onto an Easel at all, so they can never become live Captures.

## Sharing and exporting

The **Share and Export** button at the end of the Easel's toolbar (the square with an arrow), the canvas's right-click
menu and an Easel's menu in **Library › Easels** have Arc's two export items. Each asks where to save:

- **Export as Image…** saves the whole Easel as a **PNG** at 2×, on a transparent background, cut to what's on it (no
  empty margin around the blocks).
- **Export as Web Page…** saves a **ZIP**: unzip it and open `index.html` in any browser, offline. It's the board as it
  looks on aircbrowser.com, with its pictures in `assets/` beside it (HEIC pictures converted to JPEG, or PNG when they
  have transparency) and the Easel as data in `easel.json`. File and folder names are safe on any system.

**File › Export Easel…** and the Command Bar ("export easel") open the same save panel with a **Format** menu:
**Image (PNG)** or **Web Page (ZIP)**. It starts with the one you used last. Typing a name that ends in `.zip` or `.png`
picks that format too. An exported picture is 2× and says so, so it places at its real size. An export is always the
whole Easel: to save only some of it, use **Copy as Image** with those items selected.

**File › Share Easel…** and the Command Bar ("share easel") have:

- **Copy as Image** puts a 2× picture of the selection (or the whole Easel) on the clipboard, to paste anywhere.
- **Share…** sends that picture with the system's share menu: Messages, Mail, AirDrop, Notes…
- **Share Link…** makes a **read-only link** on aircbrowser.com/e/…, as Arc's Easel sharing did. The sheet first
  shows the page exactly as it will be published, and what's left out or changed. Nothing is sent until you click
  **Create Link**. Then **Copy Link** or **Share…** it. Anyone with the link sees the Easel in any browser, and links
  on it open in a new tab. It's a snapshot: later changes don't reach it. Share again for a new link with what's on
  the Easel then. **Take Back** (in the sheet, also for links you made earlier) removes the page and its pictures, so
  the link stops working for everyone. Only this Mac can take a link back: its key is in your login Keychain.

**Open an Easel someone shared.** Click the link anywhere, type or paste it into Airc, or click **Add to Airc** on its
page. Airc shows the Easel as the page draws it, and the Space it goes to. **Add Easel** adds a copy that's yours, at the
end of that Space's pinned tabs: text, pictures, shapes, arrows, link cards and Captures (a Capture as its picture, never
live). Nothing is added until you click it. The new Easel opens with its canvas ready, so ⌘Z there undoes your
edits on it; click the sidebar first and ⌘Z takes the added row back (the Easel stays in Library › Easels). Your copy isn't linked to the original: what you
change stays on this Mac, later changes to the original don't reach it, and sharing it makes a new link. A link that
was taken back, or that holds anything but web addresses and pictures, is refused whole. (Arc kept a shared Easel live
in your sidebar; Airc has no account or server for that, so it adds a copy.)

What leaves your Mac in an export or a link is only what's on the board: text, pictures, shapes, arrows and link cards.
A **Live Capture** goes as its latest picture and the address of its page, never the page itself, the profile it's
signed in with or its refresh state. Addresses lose any user name, password, and the parts of a link that carry
sign-in or session secrets (`?token=`, `?session=`, an OAuth `#access_token=`…). Links that aren't web addresses are
left out. Cookies, history, your undo steps and where a picture came from are never included. Private windows have
no Easels, so nothing from one can be in an export or a link. Shared links follow the same rules as shared Spaces
(no account, nothing about you stored, see [Sharing](sharing.md)).

## Moving around

The canvas has no edges. Scroll with two fingers (or the mouse wheel, ⇧ for sideways) to pan, or hold **Space** and
drag, or use **H** for the hand. Pinch, or ⌘-scroll, to zoom. **⌘+** and **⌘−** zoom in steps, **⌘0** is actual
size, **⇧1** fits everything in view and **⇧2** fits the selection. The zoom control at the bottom right does the
same. Each Easel opens where you left it.

## Library › Easels

The Library has a list of every Easel on this Mac, newest first, wherever its row is: in another Space, in a folder,
archived, or no longer in the sidebar at all. Search matches titles and the text on them.

- **Click one** to open it in **Peek** over the page you're on, as Arc's Library did: edit it right there. The
  expand button at the top of the Peek (or ⌘O) is **Open in Space**: the Easel opens where its row is (an archived one
  comes back from the Archive). ✕, Esc, ⌘W or a click outside closes the Peek. An Easel already on screen in another
  window opens in its Space instead.
- **Right-click** one for **Open in Peek**, **Open in Space**, **Archive** (an open Today Easel), **Export as Image…**,
  **Export as Web Page…**, **Share Link…** and **Delete Easel…**.
- **Delete Easel…** asks first ("Are you sure you want to delete this Easel?"), then removes its rows and moves its
  folder to the Trash. **⌘Z** brings both back; otherwise it stays in the Trash (Finder's Put Back works too). Arc
  deleted an Easel for good; Airc doesn't.

**Export All Easels.** The card at the top of Library › Easels, "Your Easels are yours to keep", saves every Easel as a
web page, all in one ZIP, as Arc's card did. It's named after the date ("Airc Easels - 2026-11-14 21.55.zip"). While
it works, a sheet shows how far it's got, and **Cancel** stops it without leaving a file behind. When it's done, a
message has **Show in Finder**. Unzipped, the folder has:

- `index.html`: the list of your Easels. Click one to open its page.
- one folder per Easel, the same as **Export as Web Page…** makes: `index.html`, `easel.json` and `assets/`. Two Easels
  with the same name get "Trip" and "Trip 2".
- `README.md`: how to open the pages or put them online (any host for plain web pages works), and a log of what
  happened to each Easel. An empty Easel isn't in the archive; one that couldn't be read is listed as such.

Everything a single export leaves out is left out here too (see below). Your Mac keeps working while it exports: the
work happens in the background, one Easel at a time.

## Where Easels are kept

Each Easel is a folder in Airc's data folder (`~/Library/Application Support/Airc/Easels/<id>/`): `easel.json` (a
versioned JSON document), `assets/` with its pictures, `easel.json.bak` with the version before the last save, and
`history.json` with its undo steps. Saves are atomic, so a crash never leaves a half-written Easel. If a file is ever
damaged, Airc opens the previous version or whatever still reads, says so in a bar over the canvas, and keeps the
damaged file beside it (`easel.json.damaged-…`).

## Not yet

- Arc's pencil.
- **Editing together.** Arc let people you invited edit an Easel with you. An Airc link is read-only: someone who
  wants to build on it needs Airc and their own Easel (there's no Add to Airc for Easel links yet). Editing together
  needs a realtime service, which Airc doesn't have.
- Sync between Macs.

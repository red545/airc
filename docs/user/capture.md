# Capture

Capture takes a picture of part of the page you're looking at, as Arc's Capture did. Start it with **⇧⌘2**,
**View › Capture…** or **Capture…** in the Command Bar (⌘T, then type "capture" or "screenshot").

- The page dims. **Drag** a rectangle over it; its size shows beside it in points. Drag a corner or an edge's
  middle to resize it, drag inside it to move it, or nudge it with the arrow keys (⇧ for ten points).
- **Space** (or **Visible Page** in the bar) selects the whole visible page; press it again to go back to your
  rectangle.
- **F** (or **Full Page** in the bar) takes the whole page, top to bottom: see [Full page](#full-page) below.
- **P** (or **Portrait** in the bar) frames the page as a picture to share: see [Portrait](#portrait) below.
- **Hold ⌘** and point at something on the page: the element under the pointer is outlined, and a ⌘-click selects
  exactly its box.
- **Return** (or the **Capture** button, or a double-click inside the rectangle) takes it. Then:
  - **Copy** (⌘C) puts the PNG on the clipboard;
  - **Save** (⌘S) writes it to your Downloads folder as "Capture example.com 2026-11-07 at 10.15.32.png".
    Option-click Save, or press ⇧⌘S, to choose the folder and name;
  - **Share** opens the macOS share menu (Messages, Mail, AirDrop, Notes …) with the PNG file.
  A short message confirms each.
- **Esc**, ⇧⌘2 again, the ✕ button or a click outside the page cancels; nothing is copied or saved. Another ⌘
  shortcut (⌘T, ⌘W …) cancels Capture and does what it always does.

What Capture can and can't take:

- Only the page area, never the sidebar or other apps' windows. The pixels come from Airc's own copy of the page
  as drawn, at your screen's resolution (2 pixels per point on a Retina display), so Capture needs no Screen
  Recording permission. The page stays still while you select: what you see under the rectangle is what you get.
- In Split View it takes every pane under the rectangle; with Peek open, the Peek page too.
- A note on the card, alone or beside a page in Split View, is taken as it's drawn.
- Known limitation: in a full-page Capture of a page that opens in [Safari's engine](protected-media.md) and is longer
  than 14,000 points, a fixed footer can come out a few points short (10 points in Airc's tests), with the page showing
  below it. The page above the footer is complete.
- Protected video (Netflix, Disney+ and other DRM streams) usually comes out black, as in other browsers'
  screenshots.
- Page zoom doesn't change the picture's resolution, only how much of the page is in it.

## Full page

**Capture Full Page** takes the page from its top to its foot, as Arc's did. Press **F** in Capture, click **Full
Page** in Capture's bar, or choose **View › Capture Full Page** (also in the Command Bar: type "full page").

- "Capture in Progress" shows while Airc takes it; **Esc** stops it and nothing is kept. Then the whole page is shown,
  scaled to fit, with its size in points above it and Copy, Save and Share under it. Click outside it to make a
  selection instead.
- It's the page you're on: in Split View the pane you're in, with Peek open the Peek.
- The picture has your screen's resolution (2 pixels per point on a Retina display), page zoom included, and only the
  page: never the sidebar or the toolbar.
- The page is taken as it is at its top, whatever you've scrolled to (Airc scrolls it there for the picture and back
  again). Parts that stay put on screen show once: a fixed header at the top; a fixed footer, cookie bar or "back to
  top" button where the bottom of the window is (on [sites that open in Safari's engine](protected-media.md), at the
  page's foot, or at the foot of its first 14,000 points on a longer page). Sticky headers are in their place in the
  page.
- A very long page is limited to keep memory in check: over about 48 megapixels it's taken at fewer pixels per point
  (down to one per point), and past that the picture stops at 48 megapixels or 32,000 pixels, whichever comes first.
  The size above the picture then says "the first … of … pt".
- What the page loads only as you scroll to it (lazy pictures, endless feeds) may be missing until you've scrolled
  through once. A page that scrolls inside a box of its own (many web apps, chat and mail) is taken as far as its window
  goes.

## Portrait

**Capture in Portrait Mode** makes a framed picture of the page to share, as Arc's did. Press **P** in Capture, click
**Portrait** in Capture's bar, or choose **Capture in Portrait Mode** in the Command Bar.

- The page you see (every pane in Split View, Peek on top) sits in rounded corners with a soft shadow, centred on a
  background with room around it: about a third of its width at each side, a sixth of its width above and below.
  Airc's mark sits in the bottom-left corner.
- Under the picture you choose the background, as in Arc: **Use Website Color** (the page's own colour), a colour
  picked on the **slider**, or **Use Desktop Wallpaper**, your desktop picture. Next to them you can turn the mark off.
  A colour becomes a soft gradient, a little lighter at the top. Airc remembers your choices; the first time, the
  slider's cyan is picked.
- Airc reads your desktop picture only when you pick it, never to show a thumbnail. It takes the picture's pixels
  and nothing of its file.
- **Copy**, **Save** and **Share** take that one picture, at your screen's resolution (2 pixels per point on a Retina
  display). The file holds the picture, its resolution and its colour profile, nothing else: no date, no location, no
  names, nothing about your Mac or the desktop picture's file.
- **Option-click Portrait** to copy it at once in your last choices. **Option-click Full Page** to frame the whole
  page instead of what you see.
- A very large picture keeps to 48 megapixels: it gets fewer pixels per point, not cut.

Private windows: Capture works the same, and Airc keeps nothing about it. Captures aren't listed anywhere; a saved
file is only where you saved it, and the file handed to the share menu is removed with the next share.

Usage data: copying, saving or sharing a capture counts one `feature.used` event (feature `capture`, variant
`copy`, `save` or `share`); never the page, its site, the picture or where it was saved, and nothing from a private
window. See [Usage data and crash reports](telemetry.md).

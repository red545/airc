# Sharing Spaces, folders and Boosts

Share a Space's pinned tabs or a folder as a link. (An Easel shares as a read-only page of its own, and Add to Airc
adds a copy of it: see [Easels](easels.md#sharing-and-exporting).) Anyone can open it in any browser to see the titles and addresses,
or add it to their own sidebar in Airc. Share a Boost by link or file, or send it to the Boost Gallery for everyone.

No account, no sign-in: Airc never sends who you are.

## Share a Space or a folder

- Right-click a Space (its name, or its icon at the bottom of the sidebar) and choose **Share Space…**, or use the
  Command Bar's **Share This Space…**.
- Right-click a folder and choose **Share Folder…**.

Airc first shows exactly what the link will hold, and nothing is sent anywhere yet:

- the pinned tabs, folders and splits, in their order;
- what isn't in it.

Only titles and addresses are ever in a link. Never cookies, history, your Favorites, your Today tabs, notes or what's
on the pages. Addresses lose any user name or password, and only web addresses (http and https) can be shared.

Click **Create Link**. The titles and addresses go to aircbrowser.com, and you get a link like
`https://aircbrowser.com/s/Ab3dEf6hIj9K`. **Copy Link**, or **Share…** for Messages, Mail, AirDrop and the rest.

The link is a snapshot: later changes to the Space or folder don't reach it. Share again for a new one. Private windows
can't share Spaces or folders.

## Take a link back

Choose **Share Space…** or **Share Folder…** again: the links you made of it are listed, each with **Take Back**.
From then on the link shows "This link was taken back", in a browser and in Airc. What people already added to their
own sidebar stays with them.

Only the Mac that made a link can take it back. It keeps the link's key in your Keychain ("Airc Shared Link"), and
the key never leaves your Mac. aircbrowser.com stores only a fingerprint of the key.

## Open one someone sent you

Click the link anywhere, paste it into Airc, or click **Add to Airc** on its web page. Airc shows what it holds first,
and you choose where it goes:

- **A shared Space:** **Add as New Space**, in the profile you pick.
- **A shared folder:** **Add Folder**, at the end of the pinned tabs of the Space you pick.

Nothing is added until you choose, and ⌘Z undoes it. The new tabs don't load until you open them, so adding a link
contacts none of its sites.

A link that was taken back, or that holds anything but web addresses, is refused whole: nothing from it is added.
Links opened in a private window aren't added: the page just shows what's in them.

Links that carry the list inside the link itself (`aircbrowser.com/s#v1.…`) open the same way. They aren't stored
anywhere, so they can't be taken back.

## Open a shared Easel

A shared Easel's link (`aircbrowser.com/e/…`) opens the same ways: click it, paste it into Airc, or click **Add to
Airc** on its page. Airc fetches the Easel and its pictures from aircbrowser.com over a secure connection and checks
everything before showing it: only web addresses (http and https), only PNG, JPEG, GIF and WebP pictures that are
exactly the bytes the Easel lists, and nothing over the size limits (4 MB a picture, 20 MB in all). Nothing on an Easel
runs: it has no scripts, and its links open only when you click them. Anything that fails is refused whole.

The sheet shows the board and the Space it goes to. **Add Easel** adds a copy that's yours, pinned at the end of that
Space. It isn't linked to the original: the person who shared it can't change it, and sharing your copy makes a new
link. Nothing is added until you choose. With the sidebar focused (the new Easel's canvas has its own undo), ⌘Z takes
the row back; the Easel stays in Library › Easels.

## The Boost Gallery

**File › Boost Gallery…** shows Airc's own Boosts and the ones people shared, also at
[aircbrowser.com/boosts](https://aircbrowser.com/boosts). Every Boost from the community was checked and approved by a
person before it was listed. **Get** shows the usual review (what it changes, and all of its code) before anything is
added. A Boost you already have says **Review**, or **Update** when the gallery has a newer version of it. Without a
connection, Airc's own are still there.

To send one of yours: open the Boost, then **File › Share Boost…** and **Submit to the Gallery**. What it sends is what
the sheet shows: the Boost, its name, the name you sign it with (optional), the line about it and, if you leave it
on, the screenshot. Before a person reviews it, the gallery checks that it loads nothing from other sites and that its
code is readable (no packed or escaped code). If it doesn't pass, Airc tells you why.

See a Boost that's broken, harmful or a copy? **Report** it in the gallery, in Airc or on the website.

## What's stored, and for how long

- **A shared Space or folder:** its titles and addresses, when it was shared, and the key's fingerprint, until you take
  it back.
- **A shared Easel:** what's on its board (text, pictures, shapes, arrows, link cards), when it was shared, and the key's
  fingerprint, until you take it back.
- **A Boost sent to the gallery:** until it's reviewed. Rejected ones are deleted, and so are ones nobody reviewed in
  30 days. Approved ones stay listed until they're removed.
- **Reports:** the reason and your note, until they're handled.
- **Abuse limits:** sharing counts requests per network for an hour, under a keyed hash of the IP address (never the
  address), deleted at your next request after the hour or, at the latest, by the next day's cleanup.

Nothing records who shared, submitted or reported anything. The details are on the
[privacy page](https://aircbrowser.com/privacy#sharing).

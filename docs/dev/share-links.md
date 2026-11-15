# Share links (v1)

Airc shares Spaces and folders as hosted links, `https://aircbrowser.com/s/<id>` ([sharing-service.md](sharing-service.md)):
the snapshot below is stored on aircbrowser.com, so a link is short and can be taken back. This page is the snapshot's
format, which hosted links use as it is, and the fragment links that carry it without a server.

A fragment link carries the snapshot entirely inside its URL. No server stores anything: the snapshot is in the URL's
fragment, which browsers never send to a server. The website only serves a static viewer page. Airc opens these links
(AircKit `ShareLink`; its Share sheet makes hosted links); the viewer at `aircbrowser.com/s` reads them in the browser.

```
https://aircbrowser.com/s#v1.<payload>
airc://share#v1.<payload>          (the viewer's "Open in Airc")
```

- `v1`: the format version. A reader accepts exactly the versions it knows; anything else is refused (below).
- `<payload>`: base64url (RFC 4648 §5, alphabet `A–Z a–z 0–9 - _`, **no padding**) of the snapshot JSON, UTF-8,
  compressed with **raw DEFLATE** (RFC 1951: no zlib or gzip header). In a browser,
  `new DecompressionStream("deflate-raw")` reads it.
- `www.aircbrowser.com` and a trailing slash (`/s/`) are accepted. Query strings are ignored and never needed.

Arc hosted shared Spaces and folders on its server (`arc.net/space/…`, `arc.net/folder/…`). Its prompt said "Viewers
won't receive future updates and this permalink cannot be deleted". Airc links behave the same way, for a simpler
reason: the link *is* the content. A link can't be revoked, and it shows the snapshot as it was when it was made.

## The snapshot (JSON)

```jsonc
// A Space: its pinned tree, in sidebar order.
{ "kind": "space", "name": "Trip to Lisbon", "icon": "🧳",
  "items": [
    { "type": "tab", "url": "https://www.visitlisboa.com/", "title": "Visit Lisboa" },
    { "type": "folder", "name": "Food", "items": [
        { "type": "tab", "url": "https://example.com/pasteis" } ] },
    { "type": "split", "axis": "horizontal", "items": [
        { "type": "tab", "url": "https://maps.example.com/", "title": "Map" },
        { "type": "tab", "url": "https://example.com/plan", "title": "Plan" } ] } ] }

// A folder: its contents.
{ "kind": "folder", "name": "Reading", "items": [ … ] }

// A Boost: Airc's Boost file (version 2), without its "preview" picture.
{ "kind": "boost", "boost": { "version": 2, "name": "…", "site": "…", … } }
```

| Key | In | Type | Rules |
|---|---|---|---|
| `kind` | top | string | `"space"`, `"folder"` or `"boost"` |
| `name` | space, folder (top and nested) | string | required; 1–200 UTF-16 units after trimming |
| `icon` | space, folder (top) | string | optional; an emoji, 1–16 UTF-16 units |
| `items` | space, folder (top and nested), split | array of nodes | required; see limits |
| `boost` | boost | object | Airc's Boost file v2 (`BoostFile`), validated as a file is; no `preview` |
| `type` | node | string | `"tab"`, `"folder"` or `"split"` |
| `url` | tab | string | required; see addresses |
| `title` | tab | string | optional; 1–500 UTF-16 units; the custom name, else the page's last title |
| `axis` | split | string | optional; `"horizontal"` (side by side, the default) or `"vertical"` (stacked) |

A split's `items` are 2 to 4 tabs, and only tabs. A folder's `items` may be empty.

**Strict.** Every object has exactly the keys above for its kind. An unknown key, a missing required key, a wrong type
or `null` anywhere makes the whole link invalid. A later format adds keys under a new version, never under `v1`.

## Addresses

A tab's `url` is accepted only when **all** of these hold:

- absolute, with scheme `http` or `https` (any case) and a non-empty host;
- no user name or password (`https://user:pass@…`);
- at most 4,096 UTF-16 units, with no whitespace or control characters.

So `javascript:`, `data:`, `file:`, `blob:`, `about:`, `chrome:`, `airc:` and the rest are refused. Airc doesn't put
them in links: when you share, tabs with other addresses (Airc's notes, local files) are left out and the preview says
so. A link that contains one anyway is refused whole.

## Limits (v1)

A reader checks these in this order, before it allocates anything big:

| Limit | Value |
|---|---|
| Payload (the characters after `v1.`) | at most 32,000 characters |
| Inflated JSON | at most 524,288 bytes. Inflating stops there: a payload that would grow past it (a "zip bomb") is refused without inflating the rest |
| Tabs (in a space or folder snapshot) | 1 to 2,000 |
| Nodes (tabs, folders and splits) | at most 4,000 |
| Folder depth | at most 10 levels below the top |
| Strings | no control characters (U+0000–U+001F, U+007F–U+009F) |

Writers keep links short where they can: Airc warns when a link is longer than 8,000 characters, since some chat apps
cut long links.

## Reading a link: all or nothing

1. It must be a share link: the scheme and host (or `airc://share`), path `/s`, and a fragment `v<digits>.<payload>`.
2. A version other than 1: a number above 1 is "made by a newer Airc", anything else is a damaged link.
3. Then come the payload's alphabet and length, inflating with the cap, JSON parsing, and the schema and limits above.

Any failure refuses the whole link, and Airc adds nothing. The errors are:

- **Damaged:** "This link is damaged or incomplete."
- **Newer version:** "This link was made by a newer version of Airc. Update Airc to open it."
- **Too large:** "This link is too large to open."
- **Unsafe address:** "This link contains an address Airc doesn't open (only web addresses can be shared)."

## In Airc

- **Sharing.** Share Space… and Share Folder… are in the Space and folder menus and the Command Bar. Airc shows exactly
  what the link will contain before anything is sent: the tree, the count, and what's left out. What's left out is
  Today tabs, Favorites, notes and local files, and nothing else is ever included: no cookies, history, page content,
  theme or profile. Create Link publishes it as a hosted link; the same sheet lists earlier links with Take Back.
  Private windows can't share.
- **Opening.** Airc catches a link of either kind when a tab goes to it (a link clicked anywhere, typed, or opened from
  another app) and when `airc://share/<id>` (a hosted page's Add to Airc) or `airc://share#v1.…` (the viewer's Open in
  Airc) opens. It shows a preview with the tree and the count first.
  - A Space: Add as New Space, in the profile the person picks (this window's by default).
  - A folder: Add Folder, at the end of the pinned tabs of the Space the person picks (this one by default).
  - A Boost: the usual Boost review before it's installed.

  Nothing is added until you choose, and then it's added in one step that ⌘Z undoes. Order, nesting, folder names and
  splits are kept. The new tabs aren't loaded until you open them, so opening a link makes no requests to the sites
  in it.

Boost links made before v1 (`https://aircbrowser.com/boost#1.<payload>`, the Boost file alone) keep working.

## The viewer (`/s` on the website)

A static page that reads `location.hash` in the browser and never sends it anywhere:

- **No analytics, no third-party requests:** no fonts, scripts or favicons from other sites. Favicons would tell those
  sites someone viewed the list.
- **Decoding:** it validates exactly as above, and shows the same errors in its own words.
- **Rendering:** the name and icon, then the tree: folders open, splits as one row with their tabs. Each tab is a link
  (`rel="noopener noreferrer nofollow"`, `target="_blank"`) showing its title, else its host, with the full address on
  hover.
- **Actions:**
  - **Open in Airc** links to `airc://share#v1.<payload>`, the same fragment.
  - **Get Airc** is for people who don't have it.
  - **Copy all links**, as plain text, one per line.
- **No HTML from the payload:** every string is inserted as text.

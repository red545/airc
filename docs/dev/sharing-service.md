# The sharing service (aircbrowser.com)

Hosted share links for Spaces and folders (H01, H02) and the Boost Gallery (B03). They're Vercel functions in the
website's project (`apps/marketing`, Vercel project airc-homepage), deployed with the site. The app's client is AircKit
`SharingService` (`packages/AircKit/Sources/AircKit/Sharing/`); the app's side is `apps/browser/Sources/Airc/Sharing/`
and the gallery parts of `Boosts/BoostSharing.swift`.

No accounts. Nothing stored names a person, a device or an IP address.

## Endpoints

| Request | Answer |
|---|---|
| `POST /api/share` with a snapshot (JSON, [share-links.md](share-links.md), kind `space` or `folder`) | `201 { id, url, token }` |
| `GET /api/share?id=<id>` | `200 { id, createdAt, snapshot }`, or `404` |
| `DELETE /api/share?id=<id>` with `Authorization: Bearer <token>` | `204`; `403` with another token; `404` when gone |
| `GET /s/<id>` (rewritten to `/api/s`) | the shared Space or folder as a page, or a `404` page |
| `POST /api/easel` with an Easel ([below](#easel-links)) | `201 { id, url, token, missing }`: the pictures still to send |
| `PUT /api/easel?id=<id>&asset=<name>` with `Bearer <token>` and the picture's bytes | `204`; `422` when the bytes aren't what the name and size say |
| `POST /api/easel?id=<id>&publish=1` with `Bearer <token>` | `200 { id, url }` once every picture is there (`409 { missing }` before) |
| `GET /api/easel?id=<id>` | `200 { id, createdAt, easel }` for a published link, else `404` |
| `DELETE /api/easel?id=<id>` with `Bearer <token>` | `204`; the page, its pictures and the API answer `404` from then on |
| `GET /e/<id>` and `/e/<id>/a/<sha256>.<ext>` (rewritten to `/api/e`) | the shared Easel as a page and its pictures, or `404` |
| `GET /api/boosts` | `{ boosts: [Entry] }`, newest first, cached at the edge for 60 s |
| `GET /api/boosts?id=<id>` | the approved Boost's file (Boost file v2, no preview) |
| `GET /api/boosts?preview=<id>` | its preview picture (PNG or JPEG) |
| `POST /api/boosts` with a Boost file | `202 { id, status: "pending" }`, or `422 { message }` from the static review |
| `POST /api/boosts?report=<id>` with `{ reason, note? }` | `202` |
| `GET, POST /admin/boosts` (rewritten to `/api/admin`) | the owner's review queue (below) |
| `GET /api/sweep` (Vercel cron, daily at 03:17 UTC) | deletes past rate windows and 30-day-old submissions |

Ids are 12 random letters and digits (about 71 bits). A token is 32 random bytes; only its SHA-256 is stored, and it's
compared in constant time. Errors are `{ error, message }`, and the message is a sentence the app shows as it is.

A `GalleryEntry` is `{ id, fileID, name, site, author, about, code, preview, link, approvedAt, revision }`. `link` is the
Boost's own link (`https://aircbrowser.com/boost#1.<deflated file>`, BoostLink), or null when the file is over 8,000
characters as a link. The app then fetches the file. `revision` is the file's (null without a file id, or missing on
entries approved before it was added); the gallery's button says Update when it is later than the revision installed
from the same file id (`GalleryEntry.action(installed:)`), Review for the same or an older one, Get otherwise.

## Checks

- **Snapshots:** `src/lib/share-core.js`, the same rules as AircKit `ShareLink` and the `/s` viewer: an exact schema,
  http(s) addresses only (no `javascript:`, `data:`, `file:`, credentials), at most 512 KB, 2,000 tabs, 4,000 nodes and
  10 folder levels. A record is checked again when it's read.
- **Boosts** (`api/_lib/boost-review.js`, the gallery's static review): Airc's Boost file v2 with exactly its keys,
  ranges and sizes (CSS and JS at most 128 KB each, 200 zaps, a preview PNG or JPEG of at most 300 KB), no hidden
  text (control and bidirectional characters). Then the gallery's own rules:
  - CSS loads nothing from other sites: `url()`, `@import` and any quoted absolute address must be relative, on the
    Boost's site or `data:` CSS or a picture. No `expression()`, `-moz-binding`, `behavior:` or `javascript:` URLs, and
    no `\` escapes.
  - JavaScript doesn't load code or contact other sites: no `<script>` elements, `import`, `eval`, `Function`, string
    timers, `document.write`, `fetch`, `XMLHttpRequest`, sockets, `sendBeacon`, workers, `.src`/`.href` assignments,
    page navigation or literal web addresses. It must be readable: no line over 400 characters, no `\u` or `\x`
    escapes. Comments are checked as written.
  - What passes but deserves a close look (cookies, storage, `innerHTML`, key and form listeners, passwords) is listed
    for the owner as notes.

  The static review is a filter, not a proof: the owner reads all of a Boost's code before approving it, and Airc
  shows it again before anyone installs it.

## Easel links

P19c (Arc's Easel sharing): a read-only snapshot of an Easel at `aircbrowser.com/e/<id>`. The schema is
`src/lib/easel-core.js`, the same form AircKit's `EaselPublic` writes and File › Export Easel… puts in its
`easel.json`: `{ kind: "easel", version: 1, title, background, blocks, assets }`. Each block is
`{ frame, rotation?, content }` in stacking order, content one of `text` (paragraphs of runs with marks and links),
`image`, `shape`, `line`, `link` or `capture`, colours as `#RRGGBB(AA)`. Pictures are
`{ name: "<sha256>.<png|jpg|gif|webp>", size }`; every picture a block shows is listed, and only those.

- **Checks:** exact keys per kind, finite numbers in range, no control or direction-override characters, http(s)
  addresses only (share-core's rule, so no credentials), at most 2,000 blocks, 200 pictures, 4 MB a picture, 20 MB in
  all, 1 MB of JSON. A picture must be exactly the bytes its name (SHA-256) and size say, and of the type its name says
  (sniffed from its first bytes). A record is checked again when it's read.
- **Publishing in three steps** keeps each request under Vercel's 4.5 MB body limit: the Easel (nothing shows yet), each
  picture, then publish. A link whose pictures never all arrived is swept a day later.
- **The page** (`api/e.js`, `api/_lib/easel-page.js`) renders the blocks on the server, absolutely placed on a board
  that keeps the Easel's proportions at any width (percentages and container-query units, no scripts). Pictures come
  from `/e/<id>/a/…` with a fixed `Content-Type`, `nosniff`, `Cross-Origin-Resource-Policy: same-origin` and
  `private` caching, so a taken-back link's pictures stop showing at once. Links are
  `target="_blank" rel="noopener noreferrer nofollow"`.
- **Privacy:** what the app sends is only the board (AircKit `EaselPublic`): no ids, profile, live Capture source or
  state, undo history or a picture's source page, and addresses without credentials or sign-in/session query and
  fragment parts. Nothing about the person is stored.
- **Not here:** editing together (a realtime service) and importing an Easel link into Airc.

## Limits

Per visitor and hour (`api/_lib/rate.js`): 30 new links (Spaces, folders and Easels together), 60 take-backs, 400 Easel
pictures, 10 submissions, 20 reports, 20 failed admin
sign-ins. Counters are named by `HMAC-SHA256(SHARING_RATE_SALT, hour + kind + IP)`, never the address. They expire lazily:
a visitor's first request in a new hour deletes their counter of the hour before, and the daily sweep deletes every
past window that's left (one cron a day works on any Vercel plan). At most 200 submissions wait at once, from everyone together.

## Storage

A private Vercel Blob store of its own, **airc-sharing** (iad1, separate from the releases store), connected to the
project with the prefix `SHARING` (env `SHARING_READ_WRITE_TOKEN`). No Marketplace store is needed: conditional writes
(`ifMatch`) keep counters and the gallery index consistent.

```
shares/<id>.json            { version, createdAt, tokenHash, snapshot }
boosts/pending/<id>.json    { id, submittedAt, notes, file, preview }
boosts/index.json           { entries: [GalleryEntry] }
boosts/files/<id>.json      the approved Boost's file
boosts/previews/<id>        its picture
boosts/reports/<id>.json    { id, boost, reason, note, at }
rate/<hour>/<kind>-<hash>.json   { n }
easels/<id>.json            { version, createdAt, tokenHash, published, easel }
easels/<id>/<sha256>.<ext>  its pictures
```

Production uses these keys as they are. Previews and `vercel dev` use the same store under `preview/` and
`development/`, so nothing made while testing reaches aircbrowser.com.

## Environment variables (Vercel, never in the repository)

| Name | Where | What |
|---|---|---|
| `SHARING_READ_WRITE_TOKEN` | all | the store (set by connecting it) |
| `SHARING_RATE_SALT` | all | the rate limits' HMAC key (random) |
| `SHARING_ADMIN_SECRET` | Production (sensitive; see below); Preview: a test value | the admin page's password, at least 24 characters |
| `CRON_SECRET` | optional | when set, `/api/sweep` answers only Vercel's cron |

Without the token, every endpoint answers `503`. Without `SHARING_ADMIN_SECRET`, the admin page is closed (`503`).

## Approving Boosts (the owner)

1. The password is `SHARING_ADMIN_SECRET`, a sensitive Vercel environment variable (Production). It's set; its value
   is in Vercel (airc-homepage → Settings → Environment Variables, which shows a sensitive value only while it's being
   replaced) and in the lead's secrets folder on the build box (`secrets/sharing-admin-secret.txt`, readable by its
   owner only). It's never in the repository or a log.
   - **To rotate it:** make a new long random value (`openssl rand -base64 33`), replace it in Vercel
     (`cd apps/marketing && vercel env rm SHARING_ADMIN_SECRET production`, then
     `vercel env add SHARING_ADMIN_SECRET production --sensitive` and paste it, or edit it in the dashboard), save it
     to the secrets file, and redeploy Production (any push to the site, or `vercel redeploy <latest production URL>`).
     The old password stops working with that deployment.
2. Open **https://aircbrowser.com/admin/boosts**. The browser asks for a user name and password: any user name, and the
   password from step 1.
3. Each waiting Boost shows its name, site, the author's name (not verified), its description, picture, settings, zaps,
   and all of its CSS and JavaScript, with the static review's notes. **Approve and list it** publishes it (a new
   revision of a listed Boost replaces it); **Reject** deletes it.
4. Reports list the reason and note. **Remove the Boost** takes it out of the gallery with its files and reports;
   **Dismiss** deletes only the report. The gallery's lists are cached for a minute, so a removal shows everywhere
   within about two.

## Testing

- `cd apps/marketing && node --test test/sharing.test.mjs`: every endpoint against the in-memory store (create, read,
  page, revoke, 404s, unsafe addresses, tampered and oversized payloads, escaping, rate limits, the static review's
  refusals and passes, approve, list, link, file, preview, revisions, reports, remove, reject, the admin page's
  password, origin check and failure limit, the sweep, the Preview prefix).
- `node scripts/sharing-dev.mjs [port]`: the same functions on `127.0.0.1` with the in-memory store (vercel.json's
  rewrites included), for Airc's `--script paritysharing` (`AIRC_SHARING_BASE=http://127.0.0.1:4390`).
- `SHARING_ADMIN_PASSWORD=… VERCEL_BYPASS=… node scripts/sharing-smoke.mjs <Preview URL>`: the whole flow against a
  Preview with the real store; it refuses aircbrowser.com and cleans up after itself.
- `node --test test/easel.test.mjs`: Easel links (publish in three steps, the page and pictures, take back, unsafe
  addresses, tampered and oversized Easels, picture types, escaping, the shared rate limit, the sweep).
- `node scripts/sharing-smoke.mjs <URL> --easel-only`: the Easel steps alone (they need no admin password), e.g.
  against `vercel dev`. Astro 7's dev server detaches itself, which `vercel dev` takes for an exit: run it with a
  local config whose dev command stays in front, `vercel dev -A <config>` with
  `"devCommand": "node -e \"require('http').createServer((q,r)=>r.end()).listen(process.env.PORT)\""` (the functions
  and rewrites are `vercel dev`'s own).
- AircKit: `swift test --filter 'SharingServiceTests|ShareLinksTests|EaselExportTests'`.
- Airc: `--script parityp19c` (Easel export and links) against `AIRC_SHARING_BASE`.

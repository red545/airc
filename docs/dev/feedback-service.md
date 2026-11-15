# Feedback service

Help › Send Feedback… (user guide: [docs/user/feedback.md](../user/feedback.md)) posts one message to
aircbrowser.com. The service is part of the homepage's Vercel project (`apps/marketing`), next to sharing, and uses
sharing's store, rate limits and admin sign-in.

## The app

- `packages/AircKit/Sources/AircKit/Feedback/Feedback.swift`: `FeedbackReport` (what a message may hold, each app
  detail checked against its format), `FeedbackImage` (a pasted, dropped or chosen PNG/JPEG/HEIC of ≤ 5 MB redrawn
  upright from its pixels alone: no Exif, GPS, TIFF, XMP or text; HEIC → JPEG; a PNG over 4 MB → JPEG; ≤ 4096 px),
  `SharingService.sendFeedback`, and `FeedbackOutbox` (one JSON file per message, pictures included, in
  `Feedback Outbox/` in Airc's data folder; at most 20; sent or refused ones leave it).
- `apps/browser/Sources/Airc/Feedback/`: `FeedbackCenter` (the outbox, retries when `NetworkWatch` says the network
  is back and every five minutes while something waits, app info, the window's picture) and `FeedbackSheet`.
- The address is the sharing service's (`SharingCenter.shared.service`), so test builds follow `AIRC_SHARING_BASE`.
- The window's picture is Airc's own: the root view's layers plus the engines' pictures of the pages on the card
  (Capture's sources), composed at the window's scale and sent as a JPEG of at most 1920 px. It is taken only from
  "Add Screenshot…" › Screenshot of This Window, and never offered in a private window.
- Entry points: Help › Send Feedback…, the Command Bar's Send Feedback (keywords feedback, bug, report…), and the
  sidebar footer's speech bubble (`SpaceBarView`, `AppSettings.sidebarFeedbackButton`; shown while the Space icons keep
  ≥ 24 pt, `SpaceBarLayout.showsFeedback`).

## The API

`POST /api/feedback`, `Content-Type: application/json`:

| Field | |
|---|---|
| `version` | `1` |
| `message` | required, 1–5000 characters, no hidden or control characters but tab and line breaks |
| `email` | optional reply address, ≤ 254 |
| `app` | optional; only `version`, `build`, `engine` (`chromium`/`webkit`), `macOS`, `model`, `locale`, each in its format |
| `images` | optional, ≤ 5 of `{ type: "image/png" \| "image/jpeg", size: ≤ 4 MB, sha256 }`; needs `client`. The bytes follow (below) |
| `screenshot` | 0.1.10–0.1.11's single picture: `{ type, base64 }`, ≤ 2 MB, first bytes must match its type; not with `images` |
| `client` | the app's random id for the message, so a resend after a lost answer stays one entry |
| `writtenAt` | ISO time it was written |

Any other field refuses the request (422). Answers: `201 { id, missing }`, `200 { id, duplicate: true, missing }` for a resend,
400 (not JSON), 413 (over the body cap), 415 (not JSON content), 422 (with a sentence), 429 (10 an hour per visitor,
`rate.js`'s keyed-hash counters), 503 (no store). `GET` answers 405.

Pictures go one per request, because Vercel's functions take at most 4.5 MB a request (Easel links do the same):

- `PUT /api/feedback?id=<id>&image=<n>`, `Authorization: Bearer <client>`, `Content-Type` the listed type, the bytes:
  their size and SHA-256 must be the listed ones and their first bytes the type's. The server walks the file and
  drops a JPEG's APP1 (Exif, XMP), APP3–15, COM and non-ICC APP2 segments and a PNG's eXIf, tEXt, zTXt, iTXt and tIME
  chunks before storing it (a malformed file is 422). 204; 60 an hour per visitor. `missing` lists what's left.
- `POST /api/feedback?id=<id>&publish=1`, same Bearer: `200 { id }` once every picture is there (then the admin page
  shows it and the owner is mailed), `409 { missing }` before. A message without pictures is published at once.
- The app sends only what `missing` lists, so a resend after a lost answer continues; a 409 at publish keeps the
  message in the outbox.

Records, in the sharing Blob store (Previews and `vercel dev` under their own prefix, as for sharing):
`feedback/entries/<id>.json`, `feedback/images/<id>/<n>.(png|jpg)` (`feedback/shots/<id>.*` for the old single
picture), `feedback/clients/<hash>.json` (the resend marker; the daily sweep deletes markers older than 30 days, and
messages whose pictures never all arrived after a day, with what did arrive). Nothing about the sender is stored beyond what they typed.

Each entry in **Production** mails `hello@aircbrowser.com` through Resend (`RESEND_API_KEY`, as the waitlist does),
with Reply-To the sender's address; `infra/mail-forward` passes it on. Previews and tests never mail.

## The owner's page

**https://aircbrowser.com/admin/feedback** (vercel.json rewrites it to `/api/feedback?view=admin`), behind the same
password as /admin/boosts (`SHARING_ADMIN_SECRET`, `api/_lib/admin-gate.js`). It lists open and done entries with
their message, reply address, app details and pictures (`?shot=<id>&n=<n>`), with Mark as done, Mark as open and
Delete (which removes the entry, its pictures and its marker). Messages still waiting for pictures aren't listed. Delete anything someone asks to have deleted.

## Testing

- `cd apps/marketing && node --test test/feedback.test.mjs`: validation, the resend marker, storage, the rate limit,
  the notice (Production only, no picture), the admin page's sign-in, listing, escaping, done/open/delete, the sweep.
- `SHARING_ADMIN_PASSWORD=… VERCEL_BYPASS=… node scripts/feedback-smoke.mjs <Preview URL>`: the whole flow against a
  Preview with the real store; it refuses aircbrowser.com and deletes what it sent.
- `node scripts/sharing-dev.mjs [port]` serves it locally for `--script parityfeedback` (real keys and clicks:
  `AIRC_REAL_KEYS=1`, a dedicated session, `AIRC_SHARING_BASE=http://127.0.0.1:<port>`).
- AircKit: `swift test --filter FeedbackTests`.

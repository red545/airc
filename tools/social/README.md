# Social studio

Material for X (Twitter) about Airc's releases and features: images, short videos and post drafts, made from the
real app. Only `xpost.py` posts, and only what the owner has approved (see Posting).

A **pack** is one release or feature: `packs/<date>-<topic>.toml` holds its images (which shot, what to show, the
headline, alt text), its videos, its posts and the posting order. Building it writes, outside the repo:

```
artifacts/social/<date>-<topic>/   images (PNG, 1600 × 900 and 1200 × 1200), videos (MP4 1920 × 1080 and 1080 × 1080,
                                    GIF 960 × 540), copy.md (posts with X's character count, alt text, order),
                                    pack.json and check.json
artifacts/social/index.html        the gallery of every pack, for review on a phone
```

## Making a pack

```bash
(cd apps/marketing && pnpm install)      # once: Figtree and Inter, the homepage's fonts
python3 tools/social/social.py build 2026-11-07-release-0.1.2
```

`build` renders the images, the videos (when their frames exist), copy.md, runs the checks and rewrites the gallery.
`cards`, `video`, `copy`, `check` and `gallery` do one step each. Needs Python 3.11+ with Pillow and numpy, headless
Chrome, and ffmpeg/ffprobe on PATH (or `AIRC_FFMPEG_DIR`); the OCR check needs `rapidocr_onnxruntime`.

## Images

Each image is a window from `assets/screenshots/` (its 2× PNG original when one under `artifacts/` matches the
committed WebP, else the WebP) on the brand's paper, with a two-tone headline in Figtree and the brand kit's lockup,
rendered by headless Chrome. `focus` (window points from the top left) is the part of the window that fills the
picture area; the window runs off the edge and is cut where the text begins. `clip` shows only part of a window (to leave
out what isn't ours to show, such as a site's artist photos). `mode = "plate"` uses the whole shot, desktop and all,
for shots of several windows. Nothing in a window is drawn here: no mockups.

A `teaser` pack ("Coming soon") uses the cool half of the brand's ring and puts its `note` ("In development. Not in Airc
0.1.3.") on every image. Teasers never present a feature as available; when a release ships it, its release pack
replaces the teaser. One image can carry a `note` of its own: a caveat the release notes make (iCloud Sync, tested on
one Mac). A release pack's `shots_rev` takes every shot as it was in that release's source.

## Videos

Motion comes from the app's own rendering, never from a screen recording:

```bash
tools/social/mac-frames.sh --motions swipe,capture     # build on the build Mac, render, copy the frames back
tools/social/mac-frames.sh --rev bde185a --motions …   # a release's own source, for its features' videos
tools/social/mac-frames.sh --clean                     # delete the Mac copy when done
```

`--script social` (`apps/browser/Sources/Airc/Debug/SocialFrames.swift`) seeds the marketing demo and renders one
motion frame by frame: each frame's state is set from the motion's curve (a Space swipe settles on the pager's own
spring) and drawn offscreen with the snapshot runner's `captureNow`. The Mac copy is built from `git archive HEAD` plus
this tool's files; launches wait for an unlocked, idle screen (HID idle ≥ 120 s), run under `scripts/ui-check-lock.py`
with `open -g` (the Mac kept awake with `caffeinate -i` while it draws), and quit if the lock times out. `--keep` leaves
the build on the Mac for later renders (`--no-build`); `AIRC_MAC_WORK=social-<name>` gives a second build its own
folder, there and here. `video.py` puts the frames on a captioned plate, holds each for as long
as its list says, and encodes H.264 at 60 fps and a GIF. Captions follow the frames' labels, so videos read without sound.

A video with `web = "<feature>"` also gets the website's copy in `artifacts/social/web/<feature>/`: the window alone at
1440 × 900 (square corners, no caption or end card, so the page gives it its radius, shadow and headline), looping,
with `poster.jpg` and `meta.json` (title, line, alt, `since`, `released`, `rendered_from`). A window other than the
browser's (onboarding, a private window) has its own corner radius in the frames' manifest. The feature ids are the homepage's
(apps/marketing/src/data/catalog.ts) where one video covers a group.

New motions (`AIRC_SOCIAL_MOTION`) go in the file of the release their feature came in, so a release's own source
builds them: SocialMotions.swift (0.1.2 and before), SocialMotions013.swift (0.1.3), SocialNext.swift (no release yet).
A later release's file says the commit it needs (`// social-needs: <commit>`) and goes into builds of that commit and
after; SocialNext.swift only into builds of HEAD. When a release ships a feature, its motion moves to that release's
file. Real interaction that can't be rendered this way (a drag between windows, a native menu) goes in the pack's
`requests` for the owner.

## The X profile

`python3 tools/social/brandx.py` makes the profile's own pictures from the brand kit into `artifacts/social/brand-x/`:
three 1000 × 1000 avatars (the app icon on paper, on its own colours, on night; sized to stay inside X's circle) and two
1500 × 500 headers that keep the bottom left clear for the avatar. The gallery lists them with download links.

## Posting

`xpost.py` is the posting queue (the owner's call, 2026-11-08: posts go out through X's API, each one approved first).
`plan <pack>` puts a pack's posts on a schedule: a release's thread first (its `reply = true` posts a few seconds apart
under the post above them), then three posts a day, about six hours apart (`--slots`). `run` keeps to the owner's
ceiling of ten top-level posts a day (replies not counted), two hours apart, one per run.

Only the owner approves posts (`approve … --by`, who and when logged) and starts posting (`start --by`); until then
only `run --dry`, and nothing runs on a schedule. Before a post goes, the studio reviews it (`review`: its media looked
at, its text against the published release notes, no unreleased feature); a later change to its text or media voids
that. `run` then posts what's approved, reviewed and due: media uploaded with its alt text, a reply under its parent.
A post with a link in its text is refused (X charges a link post far more; the profile links the site), a post whose
media isn't built yet waits, and the first error pauses the queue. If anything posts wrongly: pause, tell the owner and
the lead, and delete or repost nothing without the owner. The keys stay in a file outside the repo
(`AIRC_X_CREDENTIALS`). The gallery shows the queue, with each live post's link.

## Checks

`check` fails a pack on: a wrong size or format, an image of 5 MB or more, a video outside 6–30 s or not H.264, a GIF
of 15 MB or more, a post over 280 characters (counted as X counts: a link is 23, ⌘ and emoji are 2), missing alt text,
or OCR finding a word from the private patterns file (`AIRC_PRIVATE_PATTERNS`, default `private-patterns.txt` next to
the repo), an e-mail address or a home folder in any image, poster or video frame. Look at every image yourself too.

## Copy

Calm and specific, like the homepage: what it is and what you get, no hype words. Every claim comes from the release
notes or the user docs (each pack's `checked` says which). Caveats the notes make about a feature (streaming tested
logged out, Capture of the visible page only) stay true in the posts.

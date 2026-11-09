# Homepage

The Airc homepage for aircbrowser.com. It is a static Astro site, deployed on Vercel, set up like T3 Code's
`apps/marketing`. The page ships one tiny inline script (the Arc countdown) and no trackers.

```bash
cd apps/marketing
pnpm install
pnpm dev        # http://localhost:4381
pnpm build      # astro check, then a static build into dist/
pnpm preview
```

## Layout

| Path | What |
|---|---|
| `src/pages/index.astro` | The page, as a story: the day Arc got an end date (with the real post), why AI changes the upkeep, Airc, the agent and the person behind it, FAQ. Attio's system inside the Airc window: a hairline grid, two-tone headings, small tinted tags, cells with a dotted visual half |
| `src/components/SpacesDemo.astro`, `CommandDemo.astro`, `TintPicker.astro` | The live parts: the window that swipes between Spaces, the command bar that types, and the colour picker that re-tints this page's window |
| `src/components/Download.astro` | The Download button (to `/download`, the latest signed DMG) with the release's facts, in the hero and the closing |
| `src/components/Tweet.astro` | Arc's shutdown post set like an X post, real text, light and dark |
| `src/components/Countdown.astro` | Days, hours, minutes and seconds until Arc stops: a pill at the top of the hero (one tiny script) |
| `src/components/NavIcon.astro` | The little favicon beside each sidebar tab |
| `src/layouts/Layout.astro` | Head, meta and social card, and the shell: the whole site is an Airc window in the default stone theme (sidebar with toolbar, URL pill, Favorites, one tab per section, the Space bar; the page as the white card). Scroll-spy selects the current tab. The sidebar works: the toggle hides it, Back and Forward use real history, folders collapse, the Space dots jump between groups, and ⌘K (Ctrl+K, or `/`) opens a command bar over the sections |
| `src/lib/nav.ts` | The sidebar's sections and the Space (tint) each one sits in |
| `src/styles/global.css` | Tokens from `docs/design.md` (stone ramp, ink alphas, Airc blue, red), buttons |
| `src/components/Shot.astro` | Responsive WebP product shots, with an optional dark-mode variant |
| `src/lib/site.ts` | Contact address, Arc's end date, the GitHub repo (the nav shows its star count, read at build time) |
| `src/pages/s.astro`, `src/lib/share-link.ts` | `/s`, where a share link (`aircbrowser.com/s#v1.…`, docs/dev/share-links.md) opens in a browser: the shared Space, folder or Boost, read from the fragment in the browser and validated all or nothing as Airc does, with Open in Airc (`airc://share#…`), Copy all links and Get Airc. Standalone, without the layout and its analytics; no requests to other sites; nothing from the link in titles or tags; every string inserted as text |
| `src/pages/boost.astro` | `/boost`, where a Boost link (`aircbrowser.com/boost#…`, the whole Boost in the fragment) lands in another browser: how to open it in Airc, and Download. Standalone and script-free, without the layout: the site's analytics would record the full address, fragment included |
| `src/pages/features/[id].astro`, `public/video/`, `scripts/sync-videos.mjs`, `src/data/videos.json` | A page per `/features` group with the social studio's video of it (frames Airc rendered itself, from `artifacts/social/web/<id>/`), the two-tone headline, what it does, its features' own videos (the sync's `placement` puts a feature's video on its group's page) and its stills. A video shows in production once it says released and its release is published, and a page once its group has a released feature and a video that shows; previews show every group's page and every video. The sync holds a video with a reason (`held`) |
| `public/motion/`, `scripts/make-motion.mjs` | The Capture cell's real motion: the social studio's offscreen frames (`--script social`) as an animated WebP with each frame's own timing, and its last frame as the reduced-motion still. Served as is; re-run the script after the studio re-renders |
| `src/assets/screens/` | The marketing screenshots the page uses, copied from `assets/screenshots/` by `scripts/sync-screenshots.mjs` |
| `src/assets/shots/` | `swipe-*.webp`: the Spaces demo's layers (one window in three Spaces, its sidebar rows lifted onto transparency); `app-accounts-card` and `app-import-card`: onboarding cards. Captures of the real app from the Nov 6 nightly, the build 0.1.0 came from. The rest are older design-mockup renders, unused |
| `src/pages/features.astro`, `src/data/catalog.ts` | `/features`: every feature, grouped, each with one line and its screenshot where there is one |
| `src/pages/changelog.astro`, `src/content/changelog/` | `/changelog`: each release's notes, newest first |
| `scripts/` | `sync-screenshots.mjs`, `sync-privacy.mjs`, `sync-changelog.mjs`, `sync-status.mjs` (run before or by builds); `shots.sh` (old mockup renders) |

Light and dark follow `prefers-color-scheme`. Motion is CSS only: a load-in rise, the hero bloom, scroll
reveals (`animation-timeline: view()`), and the Space switcher. All of it is off under
`prefers-reduced-motion`.

## What works, and the screenshots: kept up to date by the nightly

The page's "What works today" list is not written by hand. `src/data/features.json` says which
check lines in the nightly's log belong to which feature (`checks` are regular expressions over the lowercased line,
for example `^split`). `scripts/sync-status.mjs` reads the newest green run (its Chromium `log.txt`, `rev.txt`,
`steps.tsv`) and writes:

- `src/data/status.json`: per feature **passing** (a check passed, none failed), **failing**, or **in the app** (no
  nightly check yet), the check counts, the run's time and build, and the Chromium version;

```bash
AIRC_STATUS_DIR=<folder with runs/> pnpm sync       # or: pnpm sync --run <one run dir>
```

`infra/nightly.sh` runs it after every run, best effort. It only changes files in the working tree: committing the
result and deploying stay a person's call. Both outputs are committed, so the site builds anywhere. To add a feature,
add it to `features.json`; to give one a "Passing" badge, add the check that proves it to the Swift scenarios and a
pattern for its log line here.

## Product shots

The page uses the marketing screenshots in the repo's `assets/screenshots/` (the real app on a synthetic demo setup,
made by `scripts/marketing-shots.sh`; their README says what each shows). `scripts/sync-screenshots.mjs` copies the
ones the page uses into `src/assets/screens/` before each build (Vercel only receives this folder, so the copies are
committed); add a name to its list to use another. Each shot already includes its window shadow and a soft desktop, so
the page only rounds them. Where a shot's page is someone else's artwork (Apple's product page, Spotify's covers), the
script crops it to the part that shows the feature (`crops` in the script). The shots come from git, never the working
tree: a released feature's as of the source of the newest published release (the `Source:` line its notes in
`src/content/changelog/` end with), the next release's (`upcoming`) as of HEAD. So a shot retaken after a release waits
for the next one by itself, and nobody's uncommitted shot reaches the site.

## Addresses Airc itself links to

The app links to these, so keep them where they are: `/download` and `/latest.json`, `/appcast.xml` (updates),
`/features` (Help › Getting Started), `/changelog` (Help › Release Notes), `/privacy` (Help › Privacy Policy) and
`/boost` (Boost links) and `/s` (share links).

## Features and changelog: only what's released

`/features` lists `src/data/catalog.ts`, built from `docs/user/README.md`, the release notes and
`docs/qa/arc-parity.md`. Each feature has `since`, the release that brings it, or `coming` for planned work, which the
page marks Coming. `/changelog` renders `src/content/changelog/<version>.md`: `scripts/sync-changelog.mjs` copies
`docs/release-notes-beta.md` there before each build, under the version in its title, and earlier releases keep their
committed files (0.1.0 is the published notes).

Production shows a release, and the features it brings, once the stable feed (`/appcast.xml`) lists it, as of the
deploy; redeploy after publishing. Preview deployments (`vercel deploy`) and `astro dev` show the staged release
too, marked Not published yet (`SHOW_UNRELEASED` in `src/lib/release.ts`). When a release ships, add its features
with `since` set to it, and add the shots to `scripts/sync-screenshots.mjs`. Work in the repo for a release whose version
isn't set yet has `since: "next"` (Notes): production never shows it; replace it with the version when that release is
cut.

### Older routes (unused by the page)

The mockup renders below are the older route and are no longer used by the page.

The shots are the design mockups (`docs/design/mockups/build.py`), rendered with WebKit and the real SF fonts on
the build Mac:

```bash
apps/marketing/scripts/shots.sh
```

1. `shots.py` builds HTML from the mockups. It swaps in neutral demo data (no real usernames, repos or email
   addresses), leaves out the design annotations, and stops if anything private is left.
2. The build Mac renders each page at 1440 × 900 pt (2880 × 1800 px) with `aircdesign-gallery --html`.
3. `optimize-shots.mjs` writes the WebP files and the sidebar crops.

Check every new shot for personal data before you commit it: only demo content is allowed.

## Downloads, updates and privacy

Airc's releases live in Vercel Blob; the homepage only routes to them (`vercel.json`, from the release handoff in
`docs/release.md`):

| Path | What |
|---|---|
| `/download` | `api/download.ts` reads `feeds/latest.json` and sends a 307 to the immutable DMG. No token |
| `/appcast.xml` | The Sparkle feed (proxied from Blob, 60 s cache). **Installed copies check this for updates** |
| `/latest.json` | The latest stable release: version, build, URL, size, SHA-256 |
| `/releases/:path*` | Permanent redirect to Blob: DMGs, update ZIPs, deltas, release notes |

`src/lib/release.ts` reads `latest.json` at build time for the version and size shown under the
Download button (`src/components/Download.astro`). `/privacy` renders `docs/user/telemetry.md`, copied into
`src/content/telemetry.md` by `scripts/sync-privacy.mjs` before each build (Vercel only receives this folder, so the
copy is committed). GitHub links appear only while the repo is public (`src/lib/github.ts`).

## Deploying

Vercel project `airc-homepage`, root directory `apps/marketing` (settings in `vercel.json`; Git deploys are off).

```bash
cd apps/marketing && vercel deploy        # preview
```

The owner decides production (`vercel --prod`) and the aircbrowser.com domain at launch.

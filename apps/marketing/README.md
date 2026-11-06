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
| `src/pages/index.astro` | The page, as a story: the day Arc got an end date (with the real post), why AI changes the upkeep, Airc, the agent and the person behind it, FAQ |
| `src/components/Tweet.astro` | Arc's shutdown post set like an X post, real text, light and dark |
| `src/components/Countdown.astro` | Days, hours, minutes and seconds until Arc stops: a pill at the top of the hero (one tiny script) |
| `src/components/NavIcon.astro` | The little favicon beside each sidebar tab |
| `src/layouts/Layout.astro` | Head, meta and social card, and the shell: the whole site is an Airc window in the default stone theme (sidebar with toolbar, URL pill, Favorites, one tab per section, the Space bar; the page as the white card). Scroll-spy selects the current tab. The sidebar works: the toggle hides it, Back and Forward use real history, folders collapse, the Space dots jump between groups, and ⌘K (Ctrl+K, or `/`) opens a command bar over the sections |
| `src/lib/nav.ts` | The sidebar's sections and the Space (tint) each one sits in |
| `src/styles/global.css` | Tokens from `docs/design.md` (stone ramp, ink alphas, Airc blue, red), buttons |
| `src/components/Shot.astro` | Responsive WebP product shots, with an optional dark-mode variant |
| `src/lib/site.ts` | Contact address, Arc's end date, the GitHub repo (the nav shows its star count, read at build time) |
| `src/assets/screens/` | The marketing screenshots the page uses, copied from `assets/screenshots/` by `scripts/sync-screenshots.mjs` |
| `src/assets/shots/` | Older design-mockup renders, unused by the page |
| `scripts/` | `sync-screenshots.mjs`, `sync-privacy.mjs`, `sync-status.mjs` (run before or by builds); `shots.sh` (old mockup renders) |

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
the page only rounds them.

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

`src/lib/release.ts` reads `latest.json` at build time for the version, size and release-notes link shown under the
Download button (`src/components/Download.astro`). `/privacy` renders `docs/user/telemetry.md`, copied into
`src/content/telemetry.md` by `scripts/sync-privacy.mjs` before each build (Vercel only receives this folder, so the
copy is committed). GitHub links appear only while the repo is public (`src/lib/github.ts`).

## Deploying

Vercel project `airc-homepage`, root directory `apps/marketing` (settings in `vercel.json`; Git deploys are off).

```bash
cd apps/marketing && vercel deploy        # preview
```

The owner decides production (`vercel --prod`) and the aircbrowser.com domain at launch.

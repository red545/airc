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
| `src/pages/index.astro` | The page: hero, Arc import, Spaces, sidebar, how it's built, FAQ |
| `src/layouts/Layout.astro` | Head, meta and social card, nav, footer |
| `src/styles/global.css` | Tokens from `docs/design.md` (stone ramp, ink alphas, Airc blue), buttons, nav |
| `src/components/Shot.astro` | Responsive WebP product shots, with an optional dark-mode variant |
| `src/lib/site.ts` | Contact address, waitlist link, Arc's end date |
| `src/assets/shots/` | Product shots (WebP masters at 2880 px; Astro makes the sizes) |
| `scripts/` | How the shots are made |

Light and dark follow `prefers-color-scheme`. Motion is CSS only: a load-in rise, the hero bloom, scroll
reveals (`animation-timeline: view()`), and the Space switcher. All of it is off under
`prefers-reduced-motion`.

## Product shots

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

## Deploying

Vercel project `airc-homepage`, root directory `apps/marketing` (settings in `vercel.json`; Git deploys are off).

```bash
cd apps/marketing && vercel deploy        # preview
```

The owner decides production (`vercel --prod`) and the aircbrowser.com domain at launch.

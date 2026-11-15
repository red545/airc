# Downloads per day

`python3 tools/downloads/daily.py [--days 14] [--json] [--record FILE]` prints, per UTC day:

| Column | Source | What it counts |
|---|---|---|
| downloads | PostHog `site.download` | GETs of aircbrowser.com/download. `api/download.ts` sends one anonymous event per GET: a fresh random ID, the country, the referrer's host name and the version. No IP, no cookies, no user agent. HEAD requests aren't counted. |
| new installs | PostHog `app.launched` with `first_launch` | First launches of copies with usage data on (the default). |
| active installs | PostHog `app.active_day` | Distinct installs that used Airc that day (usage data on). |
| DMG, via /download, update checks, updates | Vercel CDN request logs | The last 24 hours only. Direct `/releases/*.dmg` GETs, `/download` GETs, Sparkle's `/appcast.xml` fetches by Airc (with versions), and update archives (`.zip`/`.delta`) fetched by Airc. Scripted user agents (curl, python, our own probes) are counted apart. |

Every count is read-only, and nothing new is tracked. The script needs PostHog's personal API key
(`posthog-cli.env`) and the Vercel scope (`public-release.env`) in `$AIRC_SECRETS_DIR` (default `~/arcfork/secrets`),
plus a logged-in `vercel` CLI (or `VERCEL_TOKEN`). It never prints a key.

## Limits

- **Vercel keeps CDN request logs for one day** on this plan. Older ones need Observability Plus (`402
  payment_required`). `--record FILE` appends the last 24 hours' Vercel counts as one JSON line, so running it once a day
  keeps a history.
- **/download is already counted** in PostHog for as long as PostHog keeps events, so it doesn't need a new counter.
  The gap is a direct link to `/releases/<version>/<build>/Airc-<version>.dmg` (e.g. from /versions). Those requests go
  through vercel.json's rewrite to Blob, which runs no code, so they appear only in the 24-hour logs. Counting them for
  longer means routing that rewrite through a function, which the release path depends on. Not done.
- Update checks are Sparkle feed fetches. Each install checks several times a day, so they trend with active installs
  but don't count people. `active installs` counts people, but only copies with usage data on.
- `site.download` also counts scripted GETs of /download (link checks use HEAD and aren't counted), so a day with release
  checks can read a little high.

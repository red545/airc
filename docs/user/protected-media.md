# Protected media: Spotify, Netflix and friends play with Safari's engine

Spotify, Netflix, Disney+, Max and the other big streaming services open in a **WebKit page** inside Airc: the
engine Safari uses, with Apple's **FairPlay** DRM, which macOS gives every app. Every other site stays in Chromium.
You see it once per service: "Spotify plays with Safari's engine", with **Why?** and **✕**.

The design follows Cra's ([github.com/VictorKildahl/cra](https://github.com/VictorKildahl/cra), MIT,
`docs/protected-media.md`); the rules are adapted from its `ProtectedMediaSites`.

## Why

Chromium's Widevine installs in Airc (engine/DRM.md) and plays sites whose licence policy asks for nothing more
(Shaka's public demo streams do). The big services ask for more: Widevine's **Verified Media Path** (VMP), a signature
over the browser's own binaries made with a certificate Google licenses through paid partners. That costs about
€10,000 up front plus a yearly fee and an agreement, and would tie every release to a third party. Without it Spotify
says "protected content not enabled" or skips track after track, Disney+ shows error 83, and Netflix refuses to play.
FairPlay needs none of that: the content provider pays for its licence, and the browser only hosts Apple's CDM.

## Which sites

A page Airc opens on one of these, or a subdomain, is a WebKit page (`ProtectedMediaSites` in AircKit):

open.spotify.com, netflix.com, disneyplus.com, max.com, hbomax.com, primevideo.com, hulu.com, paramountplus.com,
peacocktv.com, tv.apple.com, music.apple.com, listen.tidal.com, deezer.com, crunchyroll.com, joyn.\* (any country),
rakuten.tv, Prime Video on Amazon's stores (amazon.\*/gp/video) and Amazon Music (music.amazon.\*). The rest of
Amazon (shopping, Login with Amazon) stays in Chromium.

Sign-in hosts never count: accounts.spotify.com, login.tidal.com, connect.deezer.com and account.deezer.com. Other
sites send their "Sign in with Spotify" through them, and that has to finish in the engine it started in.

## Which engine a page gets

- **A page Airc opens** (an address you type, a restored tab, a new tab, Little Arc, a link from another app, a
  pinned tab's reset): WebKit for a listed site, Chromium for anything else.
- **A Chromium page's link** to a listed site is stopped before its request goes out and opens again in WebKit at that
  address, in the same tab, the same split pane, with the same focus. A target=_blank or ⌘-click link opens a WebKit
  tab. A redirect after a link, an address you typed or a new tab's address (t.co, a mail app's link wrapper) moves the
  page once it lands on the service. **A form's POST stays in Chromium**: its body can't move.
- **A WebKit page stays WebKit** for its own navigations, wherever they go: sign-in goes through other sites
  (accounts.google.com, appleid.apple.com) and has to come back to the same cookies. Only the URL bar picks again.
  New tabs it opens follow the rules.
- **A popup** (`window.open` with a size) keeps its opener's engine, so `window.opener` still works for sign-in
  windows.
- **Peek** of a listed site, or from a WebKit page, is WebKit.

## Your choices

- **Settings → Privacy → "Play DRM sites with Safari's engine"**, on by default. Off, every page opened from then on is
  Chromium's (WebKit pages already open stay until you navigate them from the URL bar).
- **Site Controls → "Safari's engine"**: on a WebKit page, switch it off to send the site back to Chromium; on a
  Chromium page that asked for Widevine, switch it on to try the site with FairPlay. The page opens again in the other
  engine at once. These choices and the toasts you closed are kept in the data folder's `protected-media.json`.
- The toast stays until its **✕** (then it never comes back for that service); **Why?** opens Site Controls.

## Your data on WebKit pages

Each Airc profile has its own persistent WebKit store (cookies, storage, cache), named from the data folder plus the
profile, so a test instance with its own `--data-dir` never shares yours. It lives under
`~/Library/WebKit/<bundle id>/WebsiteDataStore/`. Deleting the profile deletes its store. The user agent is Safari's
(`Version/<this Mac's Safari> Safari/605.1.15`), because the services choose their DRM by browser.

## What a WebKit page doesn't have (and what happens instead)

- **Chrome extensions**, including password managers' autofill: their buttons are dimmed on these pages, with
  "Extensions don't run on Spotify", and the ⌘E list says so too. Sign in once by hand, or from the password
  manager's own app.
- **Chromium's logins and cookies**: the first visit to a service signs in again, in WebKit. Imported Arc logins and
  cookies are in Chromium, not here.
- **Chromium's site settings and permission prompts**: WebKit asks per request, and Site Controls lists no saved
  permissions for the page.
- **DevTools**: ⌥⌘I opens Safari's Web Inspector in its own window (or right-click → Inspect Element).
- **Arc's picture in picture window**: a video goes to the system's picture in picture window with its own controls
  (WebKit draws it; Airc's controls can't go over it). Leaving the tab in the window you're using sends a playing video
  there when automatic picture in picture is on (Settings → General), except on sites set to never.
- **Chromium's fullscreen**: a fullscreen video uses WebKit's own fullscreen window, as in Safari; Esc leaves it.
- **Chromium's tab sleep**: Airc unloads a WebKit page itself after the same inactive-tab timeout (Settings →
  General), by the same rules: never the tab on screen, one playing audio or video, one in picture in picture, one
  using the camera, microphone or screen, one still loading, or one with typed-in form input. Its web view closes; the
  tab keeps its title and icon, and comes back with its back/forward list and scroll position when you show it.
  Pinned tabs and Favorites of chat and mail sites stay loaded, as Chromium pages do ("Keep chat and mail sites
  loaded", Settings → General).
- **The Chromium session**: Chromium's history and Command Bar suggestions still record WebKit pages (the app keeps
  history), but Chromium's own `chrome://` pages don't see them.

## What works the same

The sidebar's media tray and its buttons (through the page's Media Session), find (⌘F, with a match count), zoom
(⌘+/⌘−/⌘0, per tab), downloads (in the same Downloads list), Little Arc (a link in its page to a service moves to
WebKit in place, as in the main window), splits with one engine per pane, Peek, the toast, Boosts (colours, fonts and
CSS from the first paint, edits live) and Site Controls (with the page's location use and what macOS keeps from Airc).

## Testing

- `swift test --package-path packages/AircKit --filter ProtectedMediaTests`: the rules.
- `--script drmwebkit` then `--script drmwebkit-read` on the same `--data-dir` (Chromium; launch with
  `AIRC_WEBKIT_HOSTS=localhost`): on loopback pages, "localhost" plays a listed service and 127.0.0.1 another site. A
  listed host opens in WebKit with Safari's user agent and the toast; find, zoom, a download and the media tray work
  on it; its popup stays WebKit; a Chromium popup to it stays Chromium; a Chromium new-tab link opens a WebKit tab; a
  split with one engine per pane; a Chromium pane's link hands off in place, keeping the split and focus; the URL bar
  picks again; a redirect moves; a POST stays; a WebKit page's own link stays WebKit; Little Arc; the setting off; Site
  Controls' switch both ways, with no Chromium permissions listed on a WebKit page; after a relaunch the tab comes back
  in WebKit with its cookie, and the store is deleted. No account, no camera or microphone (the media check plays a
  canvas stream). It runs in the Chromium suite (`scripts/build-app.sh --snapshots`).
- `--script followups3` (both engines; on Chromium with `AIRC_WEBKIT_HOSTS=localhost` and the engine's test gate,
  `--airc-data-dir`): on loopback WebKit pages, a Boost's style at document start and live; the extension buttons
  dimmed with "Extensions don't run on localhost" (an unpacked test extension); a Little Arc link handing off in place;
  a hidden WebKit page unloading after the timeout and coming back with its history and scroll, while one playing a
  video stays; picture in picture on leaving the tab (the request itself needs a key window: FAIL-ENV in a background
  run). In the suite.
- `--script fairplay` (needs the network): EZDRM's public FairPlay test stream plays, muted, in a WebKit page
  (key system, certificate, licence, keys, advancing time). WebKit's legacy FairPlay API (`WebKitMediaKeys`) plays
  this HLS stream; the modern EME path gives a decode error for it.
- `--script drmservices` (needs the network, never signs in): the real services' pages open in WebKit and say
  nothing like "browser not supported".
- Test builds also read `AIRC_WEBKIT_DRM=0|1` (the setting, forced).
- By hand, with real accounts (not done by the agents): Spotify plays track after track, Netflix and Disney+ play,
  and sign-in through Google or Apple comes back signed in.

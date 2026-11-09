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

- **A page Airc opens** (an address you type, a restored tab, a new tab, Little Airc, a link from another app, a
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
  there when automatic picture in picture is on (Settings → General), except on sites set to never. A muted video
  playing next to sound from elsewhere on the page is decoration and never goes (Spotify's Canvas loop beside the
  music): that tab's player is in the sidebar's media tray instead.
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
(⌘+/⌘−/⌘0, per tab), downloads (in the same Downloads list), Little Airc (a link in its page to a service moves to
WebKit in place, as in the main window), splits with one engine per pane, Peek, the toast, Boosts (colours, fonts and
CSS from the first paint, edits live) and Site Controls (with the page's location use and what macOS keeps from Airc).

## Media controls

Safari-engine pages share the media tray with Chromium pages. The title and artwork come from the page’s Media
Session; play/pause, previous/next and seeking use its handlers when provided. Without a position handler, an audio
or video element supplies its duration and position and accepts seeks. Live streams without a finite duration have
no seek bar. The clock follows the page’s position state when it sets one; otherwise the element making the sound,
never a muted or looping one beside it (Spotify sets no position state, and its Canvas loop plays muted next to the
song), and it picks again when an element pauses, ends, goes in or out of picture in picture, or the track changes.
Tab mute keeps the player and its clock visible; newly started elements inherit it. Embedded players and detached
elements report through the same bridge: Spotify’s web player keeps its audio element out of the page, plays
MediaSource buffers through Web Audio and sets its Media Session only after Play, and it shows in the tray like any
other player.

As in Arc, the tray stacks the players of every tab playing or paused in the background, the latest first (up to
three; more go in the last row’s menu). Each has Arc’s close: under the pointer its artwork becomes ✕ (Close Player,
also in its right-click menu). The media pauses, its picture in picture closes, and the row stays away until the tab
plays again or you go back to it. A call’s row has no close: it’s where its microphone shows.

WebKit draws protected video in the system picture-in-picture window (macOS’s own: ✕ at the top left, the return
button at the top right, ±10 s, play/pause and a scrubber). Airc cannot draw over, resize or collapse it. Its return
button works as Back to Tab: WebKit asks Airc to show the page first, so the tab is selected, in its Space, and its
window comes forward (macOS goes to that window’s desktop), then the video goes back into the page and plays on. Its
✕ pauses, as Arc’s close does. That window has no –, so the tray player’s menu (right-click) has the rest: Back to
Tab, Play/Pause, Mute, Hide Mini Player while it’s open (the window goes, the media plays on in the tray), Picture in
Picture to open it again, Close Mini Player (pauses) and Don’t Show for This Site. Private pages do not offer a
persistent site exception.

Airc’s own Mini Player (Chromium video and the call fallback) has Arc’s buttons: ✕ closes it (a video pauses, a call
goes on in its tab), – hides the window while playback goes on (click the tray’s player to bring it back), and Back to
Tab. Esc collapses it to a pill. If the video changes while the player is collapsed or hidden, it takes the
new video's shape when it expands or returns; it does not keep the previous video's aspect ratio.

Airc publishes one Now Playing destination: the tab that most recently started playing, across both engines.
Pausing keeps that destination so Play resumes it, including when paused at the very beginning. Media that has
never played does not create a player. Closing or unloading the tab clears its Now Playing entry and returns
commands to the previous session, if one remains. Chromium’s independent hardware-key listener is disabled;
WebKit transport handlers forward system commands to the same destination. Next/previous are offered only when
the page supports them. This does not add account access or provider-specific playback controls.

## Testing

- `--script parityp16a`: two-window remote command routing, pause at zero, never-played media, source replacement,
  close/unload cleanup, synthetic call teardown while hidden, and video aspect changes through the pill and hide.
  The Chromium run needs `--airc-test=parityp16a` and a scratch `--airc-data-dir` with its `Chromium` subdirectory.
  Test PiP windows stay at normal level on their own desktop; the check reads the production floating policy
  without applying it. `parityp16a-video` runs just the Chromium video portion. Native fullscreen, deliberate
  app switching and desktop movement still require an attended check.

- `--script webkitmedia`: silent loopback audio, canvas video, metadata/artwork, tray transport and seeking,
  mute, embedded/detached elements, system PiP and its Airc menu equivalent, and cross-engine Now Playing routing.
  The check lists localhost as a WebKit service itself (also compatible with `AIRC_WEBKIT_HOSTS=localhost`).
  It uses no accounts, media devices, keyboard injection or screen capture. Automatic PiP still requires the
  browser’s key window; a background run checks that policy without taking focus.

- `--script pipreturn-tray` and `--script pipreturn-return` (`pipreturn` runs both; both engines; the Chromium build
  lists localhost as a service itself). The first: a Spotify-like loopback player (its element never in the page,
  MediaSource audio through Web Audio, started by the page’s own Play button, the Media Session set after play, no
  position state, a muted looping Canvas clip beside it) reaches the tray with its title, artwork, clock and handlers;
  its Canvas never goes to picture in picture by itself; when the page sends the Canvas there and it’s closed, the
  row’s length and position are the song’s throughout; two players stack, and Close Player pauses and hides one until
  it plays again. The second: the system window’s return button for a video in a hidden tab, a tab in another Space
  and a tab whose window is behind another one (the tab comes back and the video goes back into the page, playing),
  its ✕, the tray’s Hide and Close, and the Mini Player’s corner. WebKit’s controller for that window is in Airc’s
  process (the window is macOS’s PIPAgent’s), and the check calls its delegate as the button does; it can’t press the
  button itself (no HID events) or move a window to another macOS desktop. Every case records the window’s Space and
  occlusion and reports FAIL-ENV when it was covered or off the active Space. Loopback pages and media generated in
  the run; no accounts, devices, focus changes, posted input or screen capture.
- `swift test --package-path packages/AircKit --filter ProtectedMediaTests`: the rules.
- `--script drmwebkit` then `--script drmwebkit-read` on the same `--data-dir` (Chromium; launch with
  `AIRC_WEBKIT_HOSTS=localhost`): on loopback pages, "localhost" plays a listed service and 127.0.0.1 another site. A
  listed host opens in WebKit with Safari's user agent and the toast; find, zoom, a download and the media tray work
  on it; its popup stays WebKit; a Chromium popup to it stays Chromium; a Chromium new-tab link opens a WebKit tab; a
  split with one engine per pane; a Chromium pane's link hands off in place, keeping the split and focus; the URL bar
  picks again; a redirect moves; a POST stays; a WebKit page's own link stays WebKit; Little Airc; the setting off; Site
  Controls' switch both ways, with no Chromium permissions listed on a WebKit page; after a relaunch the tab comes back
  in WebKit with its cookie, and the store is deleted. No account, no camera or microphone (the media check plays a
  canvas stream). It runs in the Chromium suite (`scripts/build-app.sh --snapshots`).
- `--script followups3` (both engines; on Chromium with `AIRC_WEBKIT_HOSTS=localhost` and the engine's test gate,
  `--airc-data-dir`): on loopback WebKit pages, a Boost's style at document start and live; the extension buttons
  dimmed with "Extensions don't run on localhost" (an unpacked test extension); a Little Airc link handing off in place;
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

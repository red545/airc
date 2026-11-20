# FairPlay bridge: protected media in Chromium pages

Status: landed, off by default. Step 2 (video) serves Disney+ and Netflix (Netflix with a Safari user agent on its
origin). Step 1 (audio) serves no site any more: Spotify plays in WebKit (owner, 2026-11-20), because its web
player takes FairPlay only through Safari's own `WebKitMediaKeys` and Airc doesn't impersonate Safari. Ardia
removed FairPlay in Chromium altogether on 2026-11-17 over the services' licence terms; see REPORT.
User-facing behaviour: docs/user/protected-media.md, "Play protected media in Chromium with FairPlay".

## Why

Today Spotify, Netflix, Disney+ and the other big services open in a WebKit page (docs/user/protected-media.md),
because their licence servers refuse Chromium's Widevine without Google's Verified Media Path. A WebKit page has no
Chrome extensions, no Chromium logins and no Chromium ad blocker. Ardia (github.com/ardia-browser/ardia) showed the
other way: keep the page in Chromium, offer it Apple's FairPlay key system from the page script, let the page's own
code exchange the licence with the service, and play the media natively with AVFoundation. The DRM is honoured: the
keys go from the service's licence server into Apple's CDM in AVFoundation and never reach the page or Airc's code.

Ardia's own files are Apache-2.0 (their NOTICE). Airc adapts only those (packages/ardiacore/ios/ArdiaFairPlay.mm,
packages/ardiacore/fairplay/main.swift, the FairPlay block of packages/ardiacore/ios/page_script.js, and later the
ArdiaPVSession*/ArdiaVideoMirror* files and video_mirror.js); adapted files keep Ardia's copyright line and NOTICE has an
entry. Nothing comes from their engine patches, Helium or uBlock Origin.

## How it maps onto Airc

| Ardia | Airc |
|---|---|
| page_script.js FairPlay block, always in every page, told `config` on/off | a page-script **part** `fairplay` (`PageScripts.set`, Media/FairPlayBridgeScript.swift), present only while the setting is on; it acts only in the top frame of a listed origin |
| `ArdiaFairPlay.mm` in the browser + `ArdiaFairPlay.app` helper (sandboxed, AVPlayer, Now Playing, stdin/stdout JSON) | `FairPlayBridge` (Media/FairPlayBridge.swift): the same AVPlayer + `AVContentKeySession` logic **in the app process**, no helper |
| helper publishes Now Playing and remote commands itself | the bridge reports an `EngineMediaSession` for its tab to `MediaCenter`, so the tray, Airc's one Now Playing destination (MediaNowPlaying) and the media keys work as for every other player |
| `FAIRPLAY_IN_CHROMIUM_ORIGINS` in three files + a test keeping them equal | one list, `FairPlayBridgeSites.origins` (AircKit); the page script gets it from Swift when it's composed, and `FairPlayBridgeTests` checks the script, the routing and docs/user/protected-media.md against it |
| Settings › Engines › Play protected media in Chromium with FairPlay (off) | Settings › Privacy › Protected content › "Play protected media in Chromium with FairPlay" (off by default), next to "Play DRM sites with Safari's engine" |
| media error + "Open in WebKit" prompt | media error to the page + a toast "Spotify couldn't play here" with **Open in Safari's engine** (saves the choice; the page reopens in WebKit) |

No engine change: Airc's page script already runs in every frame's main world before the page's scripts, posts carry
the origin the browser process committed, and `callDocument` reaches only the document that posted.

### Routing

`ProtectedMediaSites` gains `chromiumOrigins`: an address whose exact origin (scheme, host, port) is listed stays in
Chromium even though its host is a listed service. `ProtectedMedia.sites` fills it with `FairPlayBridgeSites.origins`
while the setting is on, minus origins the person sent back to WebKit (`ProtectedMediaChoices.webKitOrigins`, from the
failure toast or Site Controls' "Safari's engine" switch). Setting off: `chromiumOrigins` is empty and every rule is
exactly today's. Other hosts of a service (accounts.spotify.com, spotify.com) are untouched.

### Spotify (step 1)

1. The part replaces `navigator.requestMediaKeySystemAccess` on the listed origin: Widevine and PlayReady are refused
   (NotSupportedError), so the player falls back to `com.apple.fps.1_0`, which gets a JavaScript `MediaKeys` stand-in.
2. The player calls `setServerCertificate` (kept), `setMediaKeys` (remembered on the element), then sets the element's
   `src` (or a `<source>`) to a `data:application/vnd.apple.mpegurl` playlist with an `skd://` key URI and https segments.
   The part takes that playlist instead of the element, fires `encrypted` (`initDataType` "cbcs", the skd URI), and
   sends `load` (playlist in ≤30 kB parts, the certificate) to the app.
3. The app checks the sender (top frame, committed origin listed, setting on), the playlist (`#EXTM3U`, only https and
   skd URIs, ≤2 MB) and the certificate (≤64 kB), and loads it into an `AVURLAsset` through a custom-scheme resource
   loader, with an `AVContentKeySession` (`.fairPlayStreaming`) whose recipient is the asset.
4. The CDM's key request becomes an SPC; the app sends it to the page, which dispatches it as the session's
   `message` event. The page's own code POSTs it to Spotify's licence server and calls `session.update(ckc)`; the part
   forwards the CKC, the app calls `processContentKeyResponse`. A licence that doesn't arrive in 30 s fails.
5. The element's `paused`, `currentTime`, `duration`, `readyState`, `buffered`, `volume`, `muted`, `play()`,
   `pause()`, `load()` and `error` are answered by the part from the native player's reports (position every 0.5 s,
   ready with duration, ended, failed), with the usual events.
6. The Media Session's metadata and action handlers are mirrored to the app; the tray and the media keys call the
   page's own handlers (or the element), as for any page.

### Netflix and Disney+ (step 2)

Ardia's design: the part intercepts the player's `MediaSource`/`SourceBuffer` appends and EME, the app feeds the
samples to `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` under an `AVSampleBufferRenderSynchronizer`,
with keys from an `AVContentKeySession` whose recipients are the renderers; the layer is drawn over the page's video
rectangle and a click-through copy of the site's controls is drawn on top; PiP is `AVPictureInPictureController` on
the sample-buffer layer. That is roughly 3,000 lines in Ardia and lands separately, with its own check.

What it takes in Airc, in landing order (each with a fixture check on clear fMP4 served through MediaSource):
1. The part grows a MediaSource/SourceBuffer stand-in for listed video origins (Ardia's `PROTECTED_VIDEO_ORIGINS`
   block): appends go to the app in ≤62 kB parts, `buffered`/`duration`/`seekable` come back from the native side.
2. `FairPlayVideoSession` (Media/): fMP4 init/fragment parsing into `CMSampleBuffer`s (`AVStreamDataParser`), video and
   audio lanes with eviction, `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` under an
   `AVSampleBufferRenderSynchronizer`, `expectMinimumUpcomingSampleBufferPresentationTime` for B-frames.
3. Keys: one `AVContentKeySession` per page with the renderers as recipients, one EME session per key ID, raw
   (`cenc` pssh → FairPlay key ID) and `sinf` init data, licence timeouts, renewals.
4. The layer view over the Chromium page's video rectangle (the page reports it; Airc's page host places an NSView
   above the engine's view), clipped by the tab's split pane, hidden with the tab; a black-backdrop fix as Ardia does.
5. The controls copy (Ardia's `video_mirror.js` + `ArdiaVideoMirror.mm`): a transparent overlay that copies the site's
   control DOM above the layer and forwards clicks, so the site's own controls stay usable.
6. Native PiP on the sample-buffer layer, and the tray/Now Playing session like step 1.
7. Netflix serves FairPlay only to Safari: a per-origin Safari user agent for www.netflix.com (Ardia uses a component
   extension's request rule; Airc would need its own way, which may be an engine change: ask the engine owner).
8. YouTube's DRM films (Safari's FairPlay HLS path in an `AVPlayer` under the mirrored controls) after that.

## Threat model

- **Only listed origins.** The part does nothing unless `window === top` and `location.origin` is in the list it was
  composed with. The app independently drops every `fairplay.*` message unless it came from the top frame, its
  committed origin (from the browser process, not the page) is listed and the setting is on. Frames, other sites and
  other tabs can't start, steer or listen to the player.
- **One owner.** The bridge plays for one document at a time (tab + frame + origin). A new load from another document
  takes it over and the previous one gets `stolen` (paused). Events go back with `callDocument`, so a document that
  navigated away, or another origin now in that tab, gets nothing.
- **No key material exposed.** The page sees exactly what EME gives any page: its own SPC (an opaque request it must
  send to its licence server) and the CKC it got back. Content keys stay inside AVFoundation's FairPlay CDM; Airc never
  sees them, never persists anything (no offline keys, no `AVContentKeySession` storage directory), and logs no
  playlist, URL, title or licence bytes.
- **Untrusted input.** Sizes are capped (certificate 64 kB, licence 64 kB, playlist 2 MB in ≤40 parts); the playlist may
  name only https and skd URIs, so a page can't make AVFoundation read files or local addresses; artwork for Now
  Playing is fetched through Airc's usual artwork policy, never by the bridge itself.
- **Not a bypass.** The service's own licence server decides; Airc doesn't fake a licence, change a CKC or record
  decrypted output. Output protection is AVFoundation's (HDCP rules apply as in Safari).

## Lifetime

- Nothing exists while the setting is off: the part isn't in the page script, `FairPlayBridge` has no player.
- The `AVPlayer` and its content key session are made on the first valid `load`, replaced on the next one, and torn
  down on `stop`, when the owning tab closes, unloads (tab sleep never unloads a playing tab) or navigates away
  (`pagehide` sends `stop`; a closed tab is noticed on the next event), and when the setting is turned off (the page
  gets `stolen` and its element pauses; pages opened later don't get the part).
- In-process instead of Ardia's helper app: one less signed executable to build, notarize and keep in the update
  delta, and the player's state joins Airc's media tray directly. The cost: an AVFoundation crash would take the
  browser with it (a helper would only lose the track). AVFoundation runs its decoding in its own system services
  (mediaserverd/VTDecoderXPCService), so the in-process part is thin; if crash reports point here, the helper split is
  a contained change (the bridge's API is already message-shaped, like Ardia's helper protocol).

## Tests

- `swift test --filter FairPlayBridgeTests` (AircKit): the origin list, routing on/off, the person's WebKit choice, the
  playlist checks, and that the page script and the user doc name exactly the listed origins.
- `--script fairplaybridge` (Chromium, `AIRC_TESTING`): a loopback page plays the part of a listed origin
  (`AIRC_FAIRPLAY_TEST_ORIGIN`) and drives the part as Spotify's player does; a clear (unencrypted) HLS audio fixture
  generated in the run checks start, pause, seek, ended, volume, the tray/Now Playing session and its play/pause, the
  failure path (media error + the offer), and the key system offered only on the listed origin; EZDRM's public FairPlay
  test stream (when reachable) checks the real SPC → licence → CKC → playback path. Setting off: the key system isn't
  offered and the listed site opens in WebKit as before.
- By hand (the owner, real account): see docs/user/protected-media.md.

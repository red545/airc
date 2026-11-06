# Airc 0.1.0 public beta

**Public beta release notes.** The staged manifest records the exact version, build, source and checksums.

Airc is an Arc-style browser with a native macOS interface on Chromium 156.0.8078.88.

- **Mac:** Apple silicon only. macOS 14 or later is required; this build has been tested on macOS 26.
- **Installing:** open the signed, notarized DMG and drag Airc to Applications.
- **Updates:** Stable checks automatically. Choose Nightly in Settings → General to opt into newer builds.
  The update button offers Restart to Update when a verified update is ready. Switching back never downgrades data.
- **Keychain:** macOS may ask for your login password the first time Airc stores its encryption key.
  Developer ID signing keeps the app's identity stable across updates.

## Please know

- **Safe Browsing is not active. Do not rely on Chrome-equivalent phishing or download protection.**
- **No Chrome Sync.** Signing in to Google websites works and is separate from browser sync, which Airc doesn't have.
- **Protected content:** Widevine installs automatically; turn it off in Settings → Privacy → Play protected content.
  Turning it off applies to newly loaded pages; reload existing tabs. Public encrypted playback passed in a
  disposable Developer ID–signed qualification app. The big subscription services play with Safari's engine instead
  (below); Widevine certification and licensing clearance are still pending.
- **Protected media:** Spotify, Netflix, Disney+, Max, Prime Video, Hulu, Apple TV, Apple Music, Tidal, Deezer and a
  few others open in a WebKit page with Apple's FairPlay; every other site stays in Chromium. Turn it off in Settings →
  Privacy → Play DRM sites with Safari's engine, or per site in Site Controls. **Checked logged out only:** Spotify,
  Netflix, Disney+, Max, Apple TV, Apple Music, Prime Video and Tidal open there without a "browser not supported"
  message, and EZDRM's public FairPlay test stream plays (licence, 720p). Playback with a real subscription is untested.
  On those pages extensions don't run, you sign in once more (Chromium's logins don't carry over), ⌥⌘I opens Web
  Inspector, and picture in picture is the system's. See docs/user/protected-media.md.
- **Anonymous usage data:** Airc sends anonymous usage data by default (which features get used and how fast Airc is,
  never what you browse). Turn it off, or see what is sent, in Settings → Privacy.

## New today

- Spotify, Netflix, Disney+ and the other big streaming services play with Safari's engine (FairPlay), inside Airc:
  a link to one opens there in the same tab or split pane, with a one-time note that says so.
- The first ⌘T after launch opens the Command Bar faster.
- Saved logins: choose between them in an Arc-styled list under the field.
- Little Arc: closing a window while its video or sound plays hands it to picture in picture (the mini player).
- Split View: drag a pane out of a split by its handle; dropped in the sidebar it becomes a tab of its own.
- Back and Forward show their history on right-click or a long press; ⌘-click opens that page in a background tab.
- Calls keep going: a call tab isn't unloaded when you switch Spaces, under memory pressure or by the unload timer.
- Passkey and other page dialogs no longer attach to a window on another Space.

## Known limitations

- **Split View:** Today, pinned and Favorite splits are supported; mixed-direction nesting and multi-window tear-out are not.
- **Saved-login list:** on pages with a strict content security policy (Google sign-in, many banks) the list appears
  at the caret line instead of under the field.
- **Picture in picture:** the mini player needs picture in picture allowed for the site. Automatic picture in
  picture for calls is tested only with simulated calls, not a real Meet call with screen sharing, and doesn't start
  when the window is merely covered by another window. There is no generic fallback for calls on other sites yet.
- **Passkeys:** signing in with a passkey on your phone (the QR code) isn't qualified yet; macOS's Bluetooth prompt
  can arrive after the sign-in request has already given up, so you may need to try again. Passkeys saved in iCloud
  Keychain need Apple's approval for Airc first.
- **Importing from Arc:** logins and cookies that Arc encrypted in a way Airc can't read, and partitioned cookies, are
  skipped. Google may ask you to sign in again.
- **Smoothness:** 120 Hz animation and zero idle work have not been measured on an unlocked, idle Mac yet; treat them
  as goals, not promises.

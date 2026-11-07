# Airc 0.1.1 public beta

Airc is an Arc-style browser with a native macOS interface on Chromium 156.0.8078.88.
This update adds more ways to browse, brings streaming sites into Airc, and improves everyday reliability.
The staged manifest records the exact build, source and checksums.

- **Mac:** Apple silicon only, macOS 14 or later. Tested on macOS 26.
- **Installing:** open the signed, notarized DMG and drag Airc to Applications.
- **Updates:** Stable checks automatically. Choose Nightly in Settings → General to try newer builds.
  Restart to Update appears when a verified update is ready. Switching back never downgrades your data.

## New in 0.1.1

- **Streaming sites inside Airc.** Spotify, Netflix, Disney+ and other supported services now open with
  Safari's engine (WebKit and FairPlay) in the same tab, split pane or Little Arc window. A one-time note
  explains the switch. **Checks were logged out only; playback with a real subscription is untested.**
  The public FairPlay test stream played successfully. Extensions don't run on these pages, and you
  need to sign in again because Chromium's logins don't carry over. Control this in Settings → Privacy →
  Play DRM sites with Safari's engine, or per site in Site Controls.
- **Private windows.** Open one with ⇧⌘N, with its own private browsing session, Find and downloads.
  Files you download remain on disk.
- **Multiple windows.** Open another with ⌘N, move a tab to a new window or drag it out of the sidebar.
  Your Spaces and tabs stay shared; showing a tab in another window moves its live page without reloading.
  ⌃⌘N opens a blank window with separate tabs. Window titles show the Space and page.
- **Tab previews.** Hover over a sidebar tab for a preview and quick actions. Turn previews off in
  Settings → Appearance → Show tab previews.
- **Shortcuts you can change.** Settings → Shortcuts lets you record, swap and reset shortcuts.
  More familiar navigation, window and editing shortcuts work throughout Airc, including in page fields.
- **Save Page As.** Use ⇧⌘S to save a page with Chromium's formats; on Safari's-engine pages, use Print → Save as PDF.
- **Manage Spaces.** Reorder, rename and customize your Spaces together, including their icons, themes and profiles.
- **Sidebar on the right.** Choose Left or Right in Settings → Appearance → Sidebar position.
- **Import from other browsers.** Bring bookmarks and history from Chromium browsers, Firefox and Zen,
  or a bookmarks file. Import passwords from a CSV file you export yourself. Find these options during
  onboarding, in Settings → Import, or under Airc → Import from Another Browser.
- **Boosts.** Customize a site's colors, font and appearance, hide elements, or add your own CSS and code
  from Site Controls.
- **Chat and mail stay ready.** Pinned tabs and Favorites for supported chat and mail sites stay loaded
  when you switch away. Active call tabs also stay loaded.

## Fixes and improvements

- Little Arc takes the first click, stays in front, opens over fullscreen apps and moves a page into
  your browser window with one click.
- Fixed a crash when leaving fullscreen caused by titlebar layout during the transition.
- After the initial macOS Keychain approval, Airc adopts its encryption key so later launches and
  signed updates stop asking repeatedly.
- Onboarding and Arc import have steadier layouts, clearer account choices and warnings, and imports
  merge existing data instead of duplicating it. Repeated bookmark identifiers no longer collapse entries.
- Crash reporting now records browser crashes and unexpected page, GPU and utility process exits,
  making failures easier to diagnose when anonymous reporting is enabled.
- Improved page-save error handling, password suggestion placement, and the isolation of Boosts between
  sites and documents. Opening the Command Bar no longer requests site icons while you type.
- Site Controls shows blocked pop-ups and explains when macOS is blocking a permission. Split tabs,
  the downloads card, favicons and the update button have reliability and layout fixes.

## Please know

- **Safe Browsing remains off. Do not rely on Chrome-equivalent phishing or download protection.**
- **No Chrome Sync.** Signing in to Google websites is separate from browser sync, which Airc doesn't have.
- **Protected content:** Widevine can install automatically; disable it in Settings → Privacy → Play protected
  content, then reload existing tabs. Public encrypted playback passed in a disposable signed qualification app;
  Widevine certification and licensing clearance remain pending. Subscription playback is not qualified.
- **Anonymous usage data and crash reports:** on by default, never browsing content. Turn them off, or see what
  is sent, in Settings → Privacy.
- **Split View:** mixed-direction nesting is not supported.
- **Picture in picture:** it must be allowed for the site. Calls were tested with simulated media, not a real
  Meet call with screen sharing. Covering a window alone does not start picture in picture; other call sites
  do not yet have a generic fallback.
- **Passkeys:** phone/QR-code sign-in is not qualified; delayed Bluetooth permission may require a retry.
  Passkeys saved in iCloud Keychain need Apple's approval for Airc first.
- **Arc import:** unreadable encrypted logins and cookies, and partitioned cookies, are skipped.
  Google may ask you to sign in again.
- **Smoothness:** 120 Hz animation and zero idle work remain goals, not measured promises.

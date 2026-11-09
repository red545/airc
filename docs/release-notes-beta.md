# Airc 0.1.3 public beta

Airc is an Arc-style browser with a native macOS interface on Chromium 156.0.8078.88.
This update adds Notes, iCloud Sync, Capture Full Page, Little Arc from any app and many Arc details.
These notes cover changes since 0.1.2.
The staged manifest records the exact build, source and checksums.

- **Mac:** Apple silicon only, macOS 14 or later. Tested on macOS 26.
- **Installing:** open the signed, notarized DMG and drag Airc to Applications.
- **Updates:** Stable checks automatically. Choose Nightly in Settings → General to try newer builds.
  Restart to Update appears when a verified update is ready. Switching back never downgrades your data.

## New since 0.1.2

- **Ads and trackers are blocked by default; turn it off per profile in Settings.**
- **Notes.** Press ⌃⇧N for a note pinned in your sidebar, with headings, lists, checkboxes, links and pasted
  Captures, saved as you type. New Note in Split puts one beside the page. Export Note… and Export All Notes…
  write Markdown, RTF, PDF or HTML; Import Notes… reads Markdown, text, RTF or HTML, including Arc's exported notes.
  Notes stay on this Mac.
- **iCloud Sync.** Settings → Sync keeps your Spaces, pinned tabs, folders and Favorites the same on your Macs.
  It's off until you turn it on, end-to-end encrypted with a key in your iCloud Keychain, and backs up your sidebar
  before the first sync. Today tabs, history, logins, Boosts and notes don't sync.
- **Little Arc from any app.** Turn on Settings → Links → Little Arc → Open Little Arc from any app, then press ⌥⌘N
  in any app, even one in full screen. Little Arc's chevron (⇧⌘O) lists your Spaces; pick one or type to search,
  and the page moves there. Choose when Little Arc windows go to the Archive in Settings → Links.
- **Capture Full Page.** In Capture (⇧⌘2), press F for the whole length of the page, or choose View › Capture
  Full Page.
- **Developer Mode per site.** It turns on by itself for localhost; ⌃D turns it on for any other site. Its strip
  under the address has Inspect, Hard Reload and a console error count. Private windows never use it.
- **Split View extras.** Expand Current Split shows one pane alone and Restore Current Split brings the others back.
  Separate Page from Split View makes the pane a tab of its own. ⌥-click a split in the sidebar to separate it.
- **Site Search in the Command Bar.** Type a site's shortcut or name, such as "yt", and press Tab to search that
  site. Edit the sites in Settings → Site Search. ⌥⌘⌫ removes the highlighted history suggestion.
- **Extensions in the toolbar.** With View › Show Toolbar (⇧⌘D), your pinned extensions move to its top right, and
  their popups open under their buttons.
- **Boosts.** Browse the Boost gallery, share a Boost with its own share sheet, or Try It On before adding it.
  Boosts now apply in a page's same-site frames, and a Boost's size uses page zoom.
- **Your Space's colours on pages.** Pages that use Arc's page colours (`--arc-palette-*`) get your Space's theme
  from their first paint.
- **Media and picture in picture.** Spotify and other pages that play with Safari's engine show the song's real
  length and position in the sidebar player. For their videos, the return button in macOS picture in picture brings
  you back to the tab. The Mini Player has Arc's ✕ and – corner: “–” hides it while playback continues, and it takes
  a new video's shape. Close a sidebar player from its artwork.
- **Arc import results.** Logins that didn't come over are grouped by reason, and Try Again imports only what failed.
  The extension checklist shows which extensions are still to install.
- **Drag the window from the top of a page**, as from a title bar. Hold ⌘ to use the page there instead.
- **More from Arc.** ⌃Tab goes back to your recent tabs. Drop files, folders, links and text on the sidebar, and
  export a Space as Markdown or bookmarks. After copying text on a page, Airc offers a link straight to that text.

## Fixes and improvements

- Tabs that unload to save memory come back at the same scroll position.
- With Reduce Motion on, the sidebar and long Space switches cross-fade instead of sliding.
- ⌘B, ⌘I and ⌘U in a page's own editor apply once. Failed site icons are fetched again later.
- Fixes to Little Arc, Split View, the media tray, onboarding, Arc import and the sidebar.

## Please know

- **Safe Browsing remains off. Do not rely on Chrome-equivalent phishing or download protection.**
- **iCloud Sync is new.** It was tested with iCloud on one Mac; syncing between two Macs through iCloud Keychain
  hasn't been tested yet. Your changes upload right away; another Mac picks them up when you switch to Airc there,
  or within 10 minutes. A Space you have on both Macs shows twice after Merge; Replace avoids that on a new Mac.
- **Capture Full Page** stops at 32,000 pixels or 48 megapixels on very long pages and says so. Protected video may
  appear black.
- **Boosts** still apply to pages in private windows.
- **Dragging from the top of a page** can't be turned off yet; hold ⌘ there to select text or drag a link.
- **Protected content:** Widevine can install automatically; disable it in Settings → Privacy → Play protected
  content. Widevine certification and licensing clearance remain pending. Subscription playback is not qualified.
- **Anonymous usage data and crash reports:** on by default, never browsing content. Turn them off, or see what
  is sent, in Settings → Privacy.
- **No Chrome Sync.** Signing in to Google websites is separate from browser sync.
- **Arc import:** unreadable encrypted logins and cookies, and partitioned cookies, are skipped.
- **Smoothness:** 120 Hz animation and zero idle work remain goals, not measured promises.

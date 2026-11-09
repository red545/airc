# Screenshots

Product shots of the real app for the homepage, the launch posts and the press kit: Airc on the Chromium engine,
in a synthetic demo setup (four Spaces, two profiles, real public sites, nobody's data), on a code-drawn desktop.
WebP, at most 2400 px wide. The 2× PNG originals are kept outside the repo.

Refresh them after a user-visible change with one command (it builds on the build Mac and takes about ten minutes):

```bash
scripts/marketing-shots.sh                       # everything
scripts/marketing-shots.sh --parts views,media   # some parts: browser, views, media, calls, settings, onboarding
```

The scenario is `--script marketing` (`apps/browser/Sources/Airc/Debug/Marketing*.swift`). A new feature adds its shot
there and to the list in `scripts/marketing-shots.sh` (AGENTS.md, "Marketing screenshots").

The Document PiP shot uses a synthetic call page with illustrated participants, not an authenticated Meet session.
Not shown yet: the profile menu itself (a native menu, which can't be drawn off screen; `profiles.webp` shows
profiles through Create Profile instead).

| File | Feature | What it shows | Date | Build |
|---|---|---|---|---|
| `cast-picker.webp` | Cast | Native picker anchored below the URL field, with safe no-device recovery on a public Lisbon article | 2026-11-09 | 202611092331 (7cfb398f + Cast changes) |
| `blocking.webp` | Ads and trackers | Built-in blocking in Site Controls: eight blocked requests and hidden sponsored content on a synthetic Field Notes page served over loopback | 2026-11-09 | 202611092129 (bb2f55c; owner defaults and migration) |
| `arc-import-checklist.webp` | Arc import | Per-profile history counts, installed status and the extension reinstall checklist with its count, from synthetic Arc data | 2026-11-08 | 202611080726 (c87da37) |
| `arc-import-logins.webp` | Logins from Arc | Every login and each site’s cookies with what happened: what couldn’t come over and why, and Try Again for the profile whose passwords couldn’t be read, from synthetic Arc data | 2026-11-08 | 202611080726 (c87da37) |
| `profile-sign-in.webp` | Google sign-in | A new profile signed in as a synthetic account, with Gmail and Calendar offered as Favorites | 2026-11-07 | 202611070739 (Profile sign-in candidate) |
| `boost-import.webp` | Share a Boost | A shared Boost reviewed before it's added: a sketch of what it changes, the full CSS and JavaScript with its warning, and Try It On | 2026-11-08 | 202611080059 (ec4ae90) |
| `developer-mode-dark.webp` | Developer Mode, dark | Developer controls in a dark Space | 2026-11-08 | 202611080856 (19e4afd + b7af8d3) |
| `developer-mode-narrow.webp` | Developer Mode, narrow | Compact developer controls at the minimum sidebar width | 2026-11-08 | 202611080856 (19e4afd + b7af8d3) |
| `developer-mode.webp` | Developer Mode | A synthetic app on localhost, in Developer Mode by itself: its full URL, Inspect, Network, Hard Reload, the console error count and the outlined sidebar row | 2026-11-08 | 202611080856 (19e4afd + b7af8d3) |
| `developer-mode-site-controls.webp` | Developer Mode: Site Controls | Site Controls on the same local app: the Developer Mode switch for the site, which follows it to every tab and port | 2026-11-08 | 202611080856 (19e4afd + b7af8d3) |
| `hero-light.webp` | The window | Personal Space in Mint: Favorites, pinned folders, Today tabs and apple.com on the page card | 2026-11-06 | 202611061538 (6312e1a) |
| `hero-dark.webp` | The window, dark | The Work Space (Grape, the Work profile) on linear.app, in dark mode | 2026-11-06 | 202611061538 (6312e1a) |
| `spaces.webp` | Spaces | Four Spaces side by side, each in its own colour and profile: Personal, Travel, Studio, Work | 2026-11-06 | 202611061538 (6312e1a) |
| `command-bar-light.webp` | Command Bar (⌘T) | "lisbon" in Travel: history, open and pinned tabs and live search suggestions, the top hit completed inline | 2026-11-06 | 202611061538 (6312e1a) |
| `command-bar-dark.webp` | Command Bar (⌘T), dark | "linear" in the dark Work Space, from the Work profile's own history | 2026-11-06 | 202611061538 (6312e1a) |
| `command-bar-sites-light.webp` | Command Bar: well-known sites | "spot" with no history of it: Spotify first with its own icon, spotify.com completed inline | 2026-11-06 | 202611061631 (005428d) |
| `command-bar-site-search.webp` | Command Bar: Site Search | "wiki", Tab, "Belém Tower" in Travel: the Wikipedia pill leads the field, the search first, then your Wikipedia pages | 2026-11-08 | 202611080155 (216db2e) |
| `command-bar-site-search-hint.webp` | Command Bar: Search Wikipedia | "wiki" typed in Travel: the "Search Wikipedia · Press Tab" row under the top hit | 2026-11-08 | 202611080155 (216db2e) |
| `settings-site-search.webp` | Settings: Site Search | Each profile's sites with their shortcuts and %s addresses, and adding one | 2026-11-08 | 202611080155 (216db2e) |
| `toolbar-extensions.webp` | Extensions in the toolbar | Show Toolbar (⇧⌘D) in Work on linear.app: the pinned extensions at its top right, ⌘E's list under the puzzle | 2026-11-08 | 202611080249 (ceaac8d) |
| `task-manager.webp` | Task Manager | Help › Troubleshooting › Open Task Manager over Work: each tab, the browser and its helpers with memory, CPU and process ID | 2026-11-09 | 202611091908 (03f0dc4) |
| `profiles.webp` | Profiles | Create Profile, step 2: which Spaces move to the new profile, each in its own colour | 2026-11-06 | 202611061538 (6312e1a) |
| `split-view-2.webp` | Split View | Two panes in Studio: Apple design pages beside Color theory | 2026-11-06 | 202611061538 (6312e1a) |
| `split-view-3.webp` | Split View, three panes | A map, the city and its trams in Travel | 2026-11-06 | 202611061538 (6312e1a) |
| `pinned-split.webp` | Pinned splits | A split pinned as one row in Studio (Bauhaus and Helvetica) | 2026-11-06 | 202611061538 (6312e1a) |
| `favorite-split.webp` | Favorite splits | A split as one Favorite tile in the Work profile (Linear and SwiftUI), dark | 2026-11-06 | 202611061538 (6312e1a) |
| `favorite-split-icon.webp` | Favorite split icons | The same Favorite split with its own icon (Change Icon…, as in Arc), dark | 2026-11-08 | 202611080045 (ec4ae90) |
| `peek.webp` | Peek | A link from the Lisbon article opens over the page: the map of Belém | 2026-11-06 | 202611061538 (6312e1a) |
| `little-arc.webp` | Little Arc | A link from another app in its own small window, over the Personal Space | 2026-11-07 | 202611071052 (13b740d, with uncommitted changes) |
| `little-arc-menu.webp` | Little Arc: Open In | The chip's chevron: the Spaces in their own colours, ⌘O on Personal, Work reloading in its own profile, Search Spaces, Profile and Copy Link | 2026-11-07 | 202611072355 (72b2d73, with uncommitted changes) |
| `sidebar-files.webp` | Files and folders | A "Lisbon trip" folder dropped on the Travel sidebar: a pinned folder with its files as tabs and its Tickets folder inside, the itinerary open from disk | 2026-11-08 | 202611080217 (216db2e, with uncommitted changes) |
| `sidebar-right.webp` | Sidebar on the right | Settings → Appearance → Sidebar position: Right. Travel on the Lisbon article, the traffic lights over the page | 2026-11-07 | 202611070422 (f0ca8c3, with uncommitted changes) |
| `multiple-windows.webp` | Several windows | Two windows on different Spaces, each with its own tab: Travel on the Lisbon article in front, Work on linear.app behind | 2026-11-07 | 202611070055 (9970131) |
| `private-window.webp` | Private windows | A private window (⇧⌘N): dark, its own tabs and New Tab, nothing kept, on Wikipedia's Private browsing | 2026-11-06 | 202611062051 (abc32c5) |
| `private-window-start.webp` | Private windows: a new one | A new private window before its first tab: what it keeps and what it doesn't | 2026-11-06 | 202611062051 (abc32c5) |
| `private-window-find.webp` | Private windows: find | ⌘F in a private window: "cookie" found on Wikipedia's Private browsing, the same find field as the main window's | 2026-11-06 | polish1 copy (4b0791f) |
| `manage-spaces.webp` | Manage Spaces | Every Space in one card: drag to reorder, rename, icon, theme, profile and delete | 2026-11-06 | 202611062051 (abc32c5) |
| `media-controls.webp` | Media controls | A background radio tab with artwork, pause, skip and seeking in the sidebar, over Kyoto on Wikivoyage | 2026-11-08 | 202611080811 (P16a isolated build) |
| `calendar.webp` | Live Calendar | The Calendar Favorite counting down to the next meeting, and its card: a big Join for the one moments away, + for a new event | 2026-11-08 | 202611080045 (ec4ae90) |
| `calendar-join.webp` | Live Calendar, Join | A minute before: the meeting and Join under the Favorites | 2026-11-08 | 202611080045 (ec4ae90) |
| `site-controls.webp` | Site Controls | Site Controls from the URL field on swift.org: Capture, Capture in Portrait Mode and Copy link, permissions, zoom and site data for that site | 2026-11-09 | 202611091921 (d10f6cd) |
| `boosts.webp` | Boosts | Wikipedia boosted into a warm, bookish page (an amber tint, Charter), the Boost editor open on Colors | 2026-11-08 | 202611080059 (ec4ae90) |
| `boosts-font.webp` | Boosts: fonts | The same Boost on Font: the page in Charter, a size step up, the macOS fonts to choose from | 2026-11-08 | 202611080059 (ec4ae90) |
| `boosts-zap.webp` | Boosts: Zap | The same Boost on Zap: Wikipedia's Appearance column zapped away, with its undo | 2026-11-08 | 202611080059 (ec4ae90) |
| `boosts-gallery.webp` | Boost Gallery | Airc's starter Boosts: each a sketch of its colors and font, with Get to review and add it | 2026-11-08 | 202611080059 (ec4ae90) |
| `boosts-share.webp` | Share a Boost | The share sheet over the boosted Wikipedia page: its screenshot, a name, the author, Copy Link and Save File | 2026-11-08 | 202611080059 (ec4ae90) |
| `theme-palette.webp` | Space colors on pages | Wikipedia in the Peach Space wearing its theme through Arc's --arc-palette-* variables (a Boost of nothing else) | 2026-11-08 | 202611080446 (905c0b7) |
| `theme-palette-dark.webp` | Space colors on pages, dark | The same page and Boost in the Grape Space: the page turns dark with the theme | 2026-11-08 | 202611080446 (905c0b7) |
| `boosts-review.webp` | Boost: Try It On | A shared Boost under review with Try It On: Wikipedia already shows it behind the sheet, before it's added | 2026-11-08 | 202611080059 (ec4ae90) |
| `tab-preview.webp` | Tab previews | The pointer resting on the Kyoto tab over apple.com: its card with the page as it was left, and pin, Favorites, split and Peek | 2026-11-06 | 202611062158 (eabcfe2) |
| `tab-preview-dark.webp` | Tab previews, dark | The Work Space in dark mode on linear.app: the card of the swiftlang/swift tab | 2026-11-06 | 202611062158 (eabcfe2) |
| `site-preview.webp` | Site previews | The Work Space: resting on the Linear Favorite shows the Linear pages visited there, newest first, with + for a new issue | 2026-11-08 | 202611081432 (1f33f4b with site previews and the shot's own code) |
| `drm-spotify.webp` | Protected media | Spotify's web player, logged out, in Safari's engine with Apple's FairPlay: the note that says so, with Why? | 2026-11-06 | 202611062002 (fd02319) |
| `drm-site-controls.webp` | Protected media: Site Controls | Site Controls on Spotify: the Safari's engine switch, and what a WebKit page does differently | 2026-11-06 | 202611062002 (fd02319) |
| `mini-player-pill.webp` | Minimized Mini Player | A playing film collapsed to its title and pause button | 2026-11-08 | 202611080811 (P16a isolated build) |
| `picture-in-picture.webp` | Picture in picture | A playing film over the Lisbon article: Back to Tab, hide, skip 15 s, pause and the scrubber | 2026-11-08 | 202611080811 (P16a isolated build) |
| `picture-in-picture-call.webp` | Picture in picture, call | A call's video floating over another page, with microphone, camera and Leave | 2026-11-07 | 202611070855 (ac85637, with uncommitted changes) |
| `picture-in-picture-meet.webp` | Document picture in picture | A synthetic call page opens its own 640×400 window through its registered site action, with illustrated participants and one site control row below Airc's bar | 2026-11-09 | 202611092210 (b0affccc + PiP changes) |
| `downloads.webp` | Downloads | A film downloading, with its progress in the sidebar | 2026-11-06 | 202611061538 (6312e1a) |
| `downloads-library.webp` | Downloads Library | The Library's Downloads list: finished files and the one still running | 2026-11-06 | 202611061631 (005428d) |
| `call-window.webp` | Call window | A synthetic full call page in the resizable 800×600 fallback; Airc's permanent bar sits above the page and its single call-control row | 2026-11-09 | 202611092210 (b0affccc + PiP changes) |
| `multi-select.webp` | Multi-selection | Three Today tabs ⌘-clicked in Personal, with their menu: copy, share, duplicate, split, pin, a new folder, move, close, archive | 2026-11-08 | 202611080125 (8196410, with this part's own commit) |
| `tab-menu.webp` | Tab menus | The Kyoto tab's menu in Personal, as Arc's: Copy Link, Share, Rename, Mute, Customize Page, Add Split View, Move to, Archive | 2026-11-08 | 202611080343 (e9abd05, with this part's own commit) |
| `folder-markdown.webp` | Folder links as Markdown | The Recipes folder's menu: Copy All Links and Copy All Links as Markdown, titles and order kept | 2026-11-08 | 202611080343 (e9abd05, with this part's own commit) |
| `quote-link.webp` | A link to copied text | After ⌘C on a sentence in Wikipedia's Typography article: Share a link directly to this text instead? with Copy Link | 2026-11-08 | 202611080343 (e9abd05, with this part's own commit) |
| `essential-shortcuts.webp` | Essential Keyboard Shortcuts | Help › Essential Keyboard Shortcuts: tabs, Spaces, pages, Split View and notes, each with the key it has now | 2026-11-08 | 202611080343 (e9abd05, with this part's own commit) |
| `library-media.webp` | Library: Media | Library › Media in the Work Space: downloaded pictures and films and a Capture, newest first, as a grid of thumbnails | 2026-11-07 | 202611070859 (ac85637, with uncommitted changes) |
| `library-recent.webp` | Library: recent files | The pointer resting on the Library button: the five newest downloads and Captures in a card above it | 2026-11-07 | 202611070859 (ac85637, with uncommitted changes) |
| `library-folders.webp` | Library: folders | Library › Media showing a Desktop folder the person allowed: pictures and a film from the top of the folder, newest first | 2026-11-08 | 202611080410 (1fe2431) |
| `library-notes.webp` | Library: Notes | Library › Notes: every note in one list, newest first, wherever its row is (two Spaces, a closed folder) | 2026-11-08 | 202611080410 (1fe2431) |
| `capture.webp` | Capture (⇧⌘2) | A card on a trip-planning page selected with Capture: the page dimmed around it, and Copy, Save and Share under it | 2026-11-07 | 202611070744 (d7418d4) |
| `capture-full-page.webp` | Capture Full Page | A long trip itinerary taken with Capture Full Page: the whole page shown over the dimmed card, its size above it, Copy, Save and Share under it | 2026-11-08 | 202611080717 (d57ddb2 with Capture Full Page and the shot's own code) |
| `capture-portrait.webp` | Capture in Portrait Mode | The trip page framed in Portrait Mode on a soft cyan gradient with the Airc mark, the background choices under it, then Copy, Save and Share | 2026-11-08 | 202611080833 (1052320 with Portrait Mode and the shot's own code) |
| `notes.webp` | Notes (⌃⇧N) | A note pinned in Travel: a few lines, a checklist with one tick, and a Capture of the trip page pasted into it | 2026-11-08 | 202611080006 (805a81b, with the shot's own code) |
| `notes-split.webp` | New Note in Split | The Lisbon trip page with a packing note beside it in Split View, the note being written | 2026-11-08 | 202611080350 (27066c3 with New Note in Split and the shot's own code) |
| `settings-appearance-light.webp` | Settings: Appearance | Translucency, the default look of new Spaces and Show tab previews | 2026-11-06 | 202611062158 (eabcfe2) |
| `settings-appearance-dark.webp` | Settings: Appearance, dark | The same page in dark mode | 2026-11-06 | 202611062158 (eabcfe2) |
| `settings-links.webp` | Settings: Links | Air Traffic Control routes links leaving a site before Peek, and external links into Spaces | 2026-11-07 | 202611070605 (routing working tree) |
| `settings-privacy.webp` | Settings: Privacy | Anonymous usage data and crash reports, off with one switch | 2026-11-06 | 202611061538 (6312e1a) |
| `settings-privacy-events.webp` | See what Airc sends | The sheet listing every event Airc recorded, word for word | 2026-11-06 | 202611061538 (6312e1a) |
| `settings-sync.webp` | Settings: Sync | iCloud sync on, up to date between two Macs, with what syncs and what never leaves the Mac | 2026-11-07 | 202611071710 (icloudsync working tree) |
| `settings-sync-first.webp` | First sync on another Mac | Both sidebars side by side, the other Mac's Work profile matched to this one's, then merge or replace (a backup first) | 2026-11-07 | 202611071710 (icloudsync working tree) |
| `settings-shortcuts.webp` | Settings: Shortcuts | Every command by menu with its key and who gets it first: Open Location at Airc first (pages never get ⌘L), and ⌘N typed for New Private Window asking to swap with New Window | 2026-11-08 | 202611080115 (22e48ba) |
| `onboarding-welcome.webp` | Onboarding | The first window | 2026-11-06 | 202611061915 (9e1fd56) |
| `onboarding-import.webp` | Onboarding: Arc import | Arc found on the Mac, first among the browsers found: Spaces, pinned tabs, folders and Favorites come over as they are | 2026-11-06 | 202611062324 (importbrowsers copy, 550fc0a) |
| `onboarding-import-browsers.webp` | Onboarding: other browsers | Chrome picked on the same step: each profile with its colour, its bookmarks and folders, and the history for ⌘T | 2026-11-06 | 202611062324 (importbrowsers copy, 550fc0a) |
| `onboarding-profiles.webp` | Onboarding: profiles | Each Arc profile becomes an Airc profile, with its Spaces | 2026-11-06 | 202611061915 (9e1fd56) |
| `onboarding-colours.webp` | Onboarding: Space colours | A colour for each Space before the first window opens | 2026-11-06 | 202611061915 (9e1fd56) |
| `onboarding-default-browser.webp` | Onboarding: default browser | The default-browser step | 2026-11-06 | 202611061915 (9e1fd56) |
| `onboarding-done.webp` | Onboarding: done | The last card before the window opens | 2026-11-06 | 202611061915 (9e1fd56) |
| `update-button.webp` | Update button | A downloaded update waiting in the sidebar (a fake ready update) | 2026-11-06 | 202611061538 (6312e1a) |
| `update-whats-new.webp` | See What's New | The update pill's menu on apple.com in Personal: Restart to Update, and See What's New for the update's release notes | 2026-11-09 | 202611091515 (14e4ab1, with this part's own commit) |
| `update-playing.webp` | Restart to Update asks first | Restart to Update with music playing in another tab: what it would stop, Restart or Not Now, and See What's New | 2026-11-09 | 202611091515 (14e4ab1, with this part's own commit) |
| `settings-app-icon.webp` | Settings: App Icon | Settings › Appearance › App Icon: Holographic or Outline in the Dock and the app switcher, Airc's own artwork | 2026-11-09 | 202611091459 (6b1cd22, with this part's own commit) |
| `archive-library.webp` | Archived Tabs | The searchable Archive and its confirmed Clear Archive action, across all Spaces and profiles | 2026-11-07 | 202611070639 (archive working tree) |
| `copy-quote.webp` | Copy URL as Quote | Command Bar copy commands for a synthetic reading page | 2026-11-07 | 202611070831 (b842c64, with uncommitted changes) |
| `remembered-profiles.webp` | Little Arc profiles | Settings → Links, with remembered profiles and Forget remembered profiles | 2026-11-07 | 202611070831 (b842c64, with uncommitted changes) |
| `show-toolbar.webp` | Show Toolbar | A full address bar above a synthetic reading page, with back, forward and reload | 2026-11-07 | 202611070831 (b842c64, with uncommitted changes) |

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
| `call-chat.webp` | Call chat | Full call page with one provider chat row below the slim browser bar, light appearance | 2026-11-10 | 202611100316 (a733c880 + callcontrols) |
| `call-chat-dark.webp` | Call chat, dark | The same single provider chat row in dark appearance | 2026-11-10 | 202611100316 (a733c880 + callcontrols) |
| `cast-picker.webp` | Cast | Native picker anchored below the URL field, with safe no-device recovery on a public Lisbon article | 2026-11-09 | 202611092331 (7cfb398f + Cast changes) |
| `blocking.webp` | Ads and trackers | Built-in blocking in Site Controls: eight blocked requests and hidden sponsored content on a synthetic Field Notes page served over loopback | 2026-11-09 | 202611092129 (bb2f55c; owner defaults and migration) |
| `arc-import-checklist.webp` | Arc import | Per-profile history counts, installed status and the extension reinstall checklist with its count, from synthetic Arc data | 2026-11-13 | 202611130706 (importcard) |
| `arc-import-logins.webp` | Logins from Arc | Synthetic HTTP-auth and federated logins, partitioned cookies and site storage, precise skipped/failed rows, provider sign-in guidance and Try Again | 2026-11-10 | 202611100450 (0833b87f + P22b app side and suite fixes) |
| `profile-sign-in.webp` | Google sign-in | A new profile signed in as a synthetic account: its picture and name, with Gmail, Calendar and Drive offered as Favorites | 2026-11-16 | 202611161627 (profilesignin) |
| `profile-journey-colour.webp` | New profile: a colour | Right after Create Profile, the same card asks for a colour for the Space that moved; the window already shows Lilac | 2026-11-20 | 202611200138 (8d54b5c3) |
| `profile-journey-signed-in.webp` | New profile: signed in | The journey's last step: the synthetic account's picture and name, before the card closes by itself | 2026-11-20 | 202611200138 (8d54b5c3) |
| `boost-import.webp` | Share a Boost | A shared Boost reviewed before it's added: a sketch of what it changes, the full CSS and JavaScript with its warning, and Try It On | 2026-11-08 | 202611080059 (ec4ae90) |
| `share-space.webp` | Share a Space | Share Space… over the Travel Space: exactly what the link will hold, in order, what's left out, and Create Link | 2026-11-10 | 202611100411 (2c94f7b) |
| `share-import.webp` | Open a shared Space | A shared Space opened from its link: what it holds, the profile to add it to, and Add as New Space | 2026-11-10 | 202611100411 (2c94f7b) |
| `send-feedback.webp` | Send Feedback | Send Feedback over a page: a message, two pictures with their thumbnails, the app details ticked, and exactly what will be sent | 2026-11-16 | 202611161811 (feedbackbtn) |
| `whats-new-card.webp` | What’s new | The sidebar’s card after an update: Airc 0.1.12 is here, five highlights from 0.1.12 and 0.1.11, And more, See All and × | 2026-11-13 | 202611131854 (whatsnew) |
| `whats-new-tab.webp` | What’s New, explained | The What’s New in Airc tab after an update from 0.1.13: each new thing in a sentence or two, where to find it, Try it and Show me, and the Command Bar’s picture | 2026-11-14 | 202611142032 (7ce33cbb, with uncommitted changes) |
| `developer-mode-dark.webp` | Developer Mode, dark | Developer controls in a dark Space | 2026-11-08 | 202611080856 (19e4afd + b7af8d3) |
| `developer-mode-narrow.webp` | Developer Mode, narrow | Compact developer controls at the minimum sidebar width | 2026-11-08 | 202611080856 (19e4afd + b7af8d3) |
| `developer-mode.webp` | Developer Mode | A synthetic app on localhost, in Developer Mode by itself: its full URL, Inspect, Network, Hard Reload, the console error count and the outlined sidebar row | 2026-11-08 | 202611080856 (19e4afd + b7af8d3) |
| `developer-mode-site-controls.webp` | Developer Mode: Site Controls | Site Controls on the same local app: the Developer Mode switch for the site, which follows it to every tab and port | 2026-11-08 | 202611080856 (19e4afd + b7af8d3) |
| `hero-light.webp` | The window | Personal Space in Mint: Favorites, pinned folders, Today tabs and apple.com on the page card | 2026-11-06 | 202611061538 (6312e1a) |
| `hero-dark.webp` | The window, dark | The Work Space (Grape, the Work profile) on linear.app, in dark mode | 2026-11-14 | 202611150013 (b517491c) |
| `spaces.webp` | Spaces | Four Spaces side by side, each in its own colour and profile: Personal, Travel, Studio, Work | 2026-11-14 | 202611150013 (b517491c) |
| `command-bar-light.webp` | Command Bar (⌘T) | "lisbon" in Travel: history, open and pinned tabs and live search suggestions, the top hit completed inline | 2026-11-13 | 202611130233 (73e9dbfd with the shot code) |
| `command-bar-dark.webp` | Command Bar (⌘T), dark | "linear" in the dark Work Space, from the Work profile's own history | 2026-11-14 | 202611150013 (b517491c) |
| `command-bar-sites-light.webp` | Command Bar: well-known sites | "spot" with no history of it: Spotify first with its own icon, spotify.com completed inline | 2026-11-06 | 202611061631 (005428d) |
| `command-bar-site-search.webp` | Command Bar: Site Search | "wiki", Tab, "Belém Tower" in Travel: the Wikipedia pill leads the field, the search first, then your Wikipedia pages | 2026-11-08 | 202611080155 (216db2e) |
| `command-bar-site-search-hint.webp` | Command Bar: Search Wikipedia | "wiki" typed in Travel: the "Search Wikipedia · Press Tab" row under the top hit | 2026-11-08 | 202611080155 (216db2e) |
| `command-bar-ask-chatgpt.webp` | Command Bar: Ask ChatGPT | "gpt", Tab, a question about Lisbon in Travel: the ChatGPT pill, and Return opens it on chatgpt.com in a new tab | 2026-11-10 | 202611100543 (35084b24) |
| `command-bar-instant-links.webp` | Command Bar: Instant Links | "top 3 things to do in lisbon", ⇧↵: what will open, before it does, with the normal search under it | 2026-11-10 | 202611100543 (35084b24) |
| `settings-site-search.webp` | Settings: Site Search | A profile's default search engine (Wikipedia here) and Ask AI from the Command Bar, off by default as in Arc; its sites with their shortcuts follow | 2026-11-10 | 202611101039 (7de42be) |
| `settings-profiles-search.webp` | Settings: Profiles search | Settings › Profiles: each profile's default search engine (Personal DuckDuckGo) and Include search engine suggestions | 2026-11-13 | 202611130233 (73e9dbfd with the shot code) |
| `toolbar-extensions.webp` | Extensions in the toolbar | Show Toolbar (⇧⌘D) in Work on linear.app: the pinned extensions at its top right, ⌘E's list under the puzzle | 2026-11-08 | 202611080249 (ceaac8d) |
| `extension-profile-results.webp` | Extensions in every profile | The actual results card with synthetic installed, already-installed and denied outcomes | 2026-11-10 | 202611100131 (7af1785c + isolated app changes) |
| `capture-page-menu.webp` | Page Capture commands | The app-owned Capture, Capture Full Page and Capture in Portrait Mode menu rows; native context/action checks are separate | 2026-11-10 | 202611100131 (7af1785c + isolated app changes) |
| `live-folders.webp` | Live Folders | A Pull Requests folder in Work that fills itself from GitHub, from a synthetic GitHub on loopback with fictional pull requests | 2026-11-10 | 202611100714 (6528de0c + polish4) |
| `task-manager.webp` | Task Manager | Help › Troubleshooting › Open Task Manager over Work: each tab, the browser and its helpers with memory, CPU and process ID | 2026-11-10 | 202611101039 (7de42be) |
| `tidy-tabs.webp` | Tidy Tabs | Tidy in Personal's Today header: Apple's on-device model groups the Today tabs into folders by topic at the top of Today, and ⌘Z puts them back | 2026-11-10 | 202611100841 (822c7e5 + todayfolders) |
| `today-folders.webp` | Folders in Today | Personal's Today with a Japan Trip folder open and a closed Reading folder: Today tabs in folders still archive like any Today tab | 2026-11-10 | 202611100841 (822c7e5 + todayfolders) |
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
| `calendar.webp` | Live Calendar | The Calendar Favorite counting down to the next meeting, and its card: Today with a big Join for the one moments away, then Tomorrow, + for a new event (synthetic events, the macOS Calendar route) | 2026-11-13 | 202611130233 (73e9dbfd with the shot code) |
| `calendar-join.webp` | Live Calendar, Join | A minute before: the meeting and Join under the Favorites | 2026-11-13 | 202611130233 (73e9dbfd with the shot code) |
| `site-controls.webp` | Site Controls | Site Controls from the URL field on swift.org: Capture, Capture in Portrait Mode and Copy link, permissions, zoom and site data for that site | 2026-11-09 | 202611091921 (d10f6cd) |
| `boosts.webp` | Boosts | Wikipedia boosted into a warm, bookish page (an amber tint, Charter), the Boost editor open on Colors | 2026-11-08 | 202611080059 (ec4ae90) |
| `boosts-font.webp` | Boosts: fonts | The same Boost on Font: the page in Charter, a size step up, the macOS fonts to choose from | 2026-11-08 | 202611080059 (ec4ae90) |
| `boosts-zap.webp` | Boosts: Zap | The same Boost on Zap: Wikipedia's Appearance column zapped away, with its undo | 2026-11-08 | 202611080059 (ec4ae90) |
| `boosts-gallery.webp` | Boost Gallery | Airc's starter Boosts: each a sketch of its colors and font, with Get to review and add it | 2026-11-08 | 202611080059 (ec4ae90) |
| `boosts-share.webp` | Share a Boost | The share sheet over the boosted Wikipedia page: its screenshot, a name, the author, Submit to the Gallery, Copy Link and Save File | 2026-11-10 | 202611100748 (241ac8d) |
| `theme-palette.webp` | Space colors on pages | Wikipedia in the Peach Space wearing its theme through Arc's --arc-palette-* variables (a Boost of nothing else) | 2026-11-08 | 202611080446 (905c0b7) |
| `theme-palette-dark.webp` | Space colors on pages, dark | The same page and Boost in the Grape Space: the page turns dark with the theme | 2026-11-08 | 202611080446 (905c0b7) |
| `boosts-review.webp` | Boost: Try It On | A shared Boost under review with Try It On: Wikipedia already shows it behind the sheet, before it's added | 2026-11-08 | 202611080059 (ec4ae90) |
| `tab-preview.webp` | Tab previews | The pointer resting on the Kyoto tab over apple.com: its card with the page as it was left, its age pill (Pictured 12 min ago), and pin, Favorites, split and Peek | 2026-11-13 | 202611130233 (73e9dbfd with the shot code) |
| `tab-preview-dark.webp` | Tab previews, dark | The Work Space in dark mode on SwiftUI's documentation: the card of the swiftlang/swift tab, pictured 3 hr ago | 2026-11-13 | 202611130233 (73e9dbfd with the shot code) |
| `site-preview.webp` | Site previews | The Work Space: resting on the Linear Favorite shows the Linear pages visited there, newest first, with + for a new issue | 2026-11-08 | 202611081432 (1f33f4b with site previews and the shot's own code) |
| `mail-preview.webp` | Mail previews | Resting on a pinned Gmail look-alike (a loopback fixture, fictional mail): its card with the unread messages, newest first, read from the account's own page | 2026-11-13 | 202611130233 (73e9dbfd with the shot code) |
| `calendar-preview.webp` | Calendar previews | Resting on a pinned Google Calendar tab: Arc's hour grid from a quarter hour before now, overlapping meetings side by side, the now line, a big Join for the meeting moments away, the all-day strip, Arc's six hours without scrolling and tomorrow in one line under them (synthetic events) | 2026-11-15 | 202611151524 (calcard, with the shot code) |
| `calendar-preview-dark.webp` | Calendar previews, dark | The same hour grid in the Work Space's dark theme, on a pinned Google Calendar tab (synthetic events) | 2026-11-15 | 202611151524 (calcard, with the shot code) |
| `favorite-badges.webp` | Favorite badges | The Work Space's Favorites with their own badges: X's count, Slack's @ mention, Gmail's dot, the Calendar's bright meeting-soon pill and a call's camera badge | 2026-11-13 | 202611130233 (73e9dbfd with the shot code) |
| `favorite-badges-dark.webp` | Favorite badges, dark | The same Favorites in dark mode | 2026-11-13 | 202611130233 (73e9dbfd with the shot code) |
| `drm-spotify.webp` | Protected media | Spotify's web player, logged out, in Safari's engine with Apple's FairPlay: the note that says so, with Why? | 2026-11-06 | 202611062002 (fd02319) |
| `drm-site-controls.webp` | Protected media: Site Controls | Site Controls on Spotify: the Safari's engine switch, and what a WebKit page does differently | 2026-11-06 | 202611062002 (fd02319) |
| `mini-player-pill.webp` | Minimized Mini Player | A playing film collapsed to its title and pause button | 2026-11-08 | 202611080811 (P16a isolated build) |
| `picture-in-picture.webp` | Picture in picture | A playing film over the Lisbon article: Back to Tab, hide, skip 15 s, pause and the scrubber | 2026-11-08 | 202611080811 (P16a isolated build) |
| `picture-in-picture-call.webp` | Picture in picture, call | A call's video floating over another page, with microphone, camera and Leave | 2026-11-07 | 202611070855 (ac85637, with uncommitted changes) |
| `picture-in-picture-meet.webp` | Document picture in picture | A synthetic call page opens its own 640×400 window through its registered site action, with illustrated participants and one site control row below Airc's bar | 2026-11-09 | 202611092210 (b0affccc + PiP changes) |
| `downloads.webp` | Downloads | A film downloading, with its progress in the sidebar | 2026-11-06 | 202611061538 (6312e1a) |
| `downloads-library.webp` | Downloads Library | The Library's Downloads list: finished files and the one still running | 2026-11-06 | 202611061631 (005428d) |
| `call-window.webp` | Call window | A synthetic full call page in the resizable 800×600 fallback; Airc's slim bar sits above the page and its single call-control row | 2026-11-10 | 202611100316 (a733c880 + callcontrols) |
| `multi-select.webp` | Multi-selection | Three selected Today tabs with New Folder with 3 Tabs, Archive Tabs Below and Archive Other Tabs in the complete menu | 2026-11-11 | 202611112331 (0.1.5 cut cabfbaac) |
| `tab-menu.webp` | Tab menus | The Kyoto tab's menu in Personal, as Arc's: Copy Link, Share, Rename, Mute, Customize Page, Add Split View, Move to, Archive | 2026-11-08 | 202611080343 (e9abd05, with this part's own commit) |
| `folder-markdown.webp` | Folder links as Markdown | The Recipes folder's menu: Copy All Links and Copy All Links as Markdown, titles and order kept | 2026-11-08 | 202611080343 (e9abd05, with this part's own commit) |
| `quote-link.webp` | A link to copied text | After ⌘C on a sentence in Wikipedia's Typography article: Share a link directly to this text instead? with Copy Quote Link | 2026-11-17 | 202611172149 (quotecopy, with this part's own commit) |
| `quote-copy.webp` | Share Quote | A sentence selected in Wikipedia's Typography article: Share Quote under the address, and the toast Copied Link · With Quote | 2026-11-17 | 202611172149 (quotecopy, with this part's own commit) |
| `quote-copy-dark.webp` | Share Quote, dark | The same quote link copied in a dark Space | 2026-11-17 | 202611172149 (quotecopy, with this part's own commit) |
| `essential-shortcuts.webp` | Essential Keyboard Shortcuts | Help › Essential Keyboard Shortcuts: tabs, Spaces, pages, Split View and notes, each with the key it has now | 2026-11-08 | 202611080343 (e9abd05, with this part's own commit) |
| `library-media.webp` | Library: Media | Library › Media in the Work Space: downloaded pictures and films and a Capture, newest first, as a grid of thumbnails | 2026-11-13 | 202611130233 (73e9dbfd with the shot code) |
| `library-recent.webp` | Library: recent files | The pointer resting on the Library button: the five newest downloads and Captures in a card above it | 2026-11-07 | 202611070859 (ac85637, with uncommitted changes) |
| `library-folders.webp` | Library: folders | Library › Media showing a Desktop folder the person allowed: pictures and a film from the top of the folder, newest first | 2026-11-08 | 202611080410 (1fe2431) |
| `library-notes.webp` | Library: Notes | Library › Notes: every note in one list, newest first, wherever its row is (two Spaces, a closed folder) | 2026-11-08 | 202611080410 (1fe2431) |
| `easel.webp` | Easels (⌃⇧E) | An Easel in Travel: a Capture of the trip page, a heading, a plan on a coloured card, an arrow, a sketch line and a link card | 2026-11-10 | 202611100504 (e0d8a35b + P19a) |
| `easel-live.webp` | Easels: live Captures | An Easel in Travel with two live Captures (a flight's status, the week's forecast) with their Live chips, a heading and a note | 2026-11-10 | 202611101152 (7cbceb5c + P19b) |
| `easel-share.webp` | Easels: Share Link | Share Link… over the Lisbon weekend Easel in Travel: the read-only page exactly as it would be published, what's never in a link, and Create Link | 2026-11-10 | 202611101650 (8f538420 + P19c) |
| `capture.webp` | Capture (⇧⌘2) | A card on a trip-planning page selected with Capture: the page dimmed around it, and Copy, Save and Share under it | 2026-11-07 | 202611070744 (d7418d4) |
| `capture-full-page.webp` | Capture Full Page | A long trip itinerary taken with Capture Full Page: the whole page shown over the dimmed card, its size above it, Copy, Save and Share under it | 2026-11-08 | 202611080717 (d57ddb2 with Capture Full Page and the shot's own code) |
| `capture-portrait.webp` | Capture in Portrait Mode | The trip page framed in Portrait Mode on a soft cyan gradient with the Airc mark, the background choices under it, then Copy, Save and Share | 2026-11-08 | 202611080833 (1052320 with Portrait Mode and the shot's own code) |
| `notes.webp` | Notes (⌃⇧N) | A note pinned in Travel: a few lines, a checklist with one tick, and a Capture of the trip page pasted into it | 2026-11-10 | 202611100714 (6528de0c + polish4) |
| `notes-split.webp` | New Note in Split | The Lisbon trip page with a packing note beside it in Split View, the note being written | 2026-11-10 | 202611100714 (6528de0c + polish4) |
| `settings-appearance-light.webp` | Settings: Appearance | Translucency, the default look of new Spaces and Show tab previews | 2026-11-10 | 202611100905 (909a26c) |
| `settings-appearance-dark.webp` | Settings: Appearance, dark | The same page in dark mode | 2026-11-14 | 202611150013 (b517491c) |
| `settings-links.webp` | Settings: Links | Air Traffic Control routes links leaving a site before Peek, and external links into Spaces | 2026-11-10 | 202611101039 (7de42be) |
| `settings-privacy.webp` | Settings: Privacy | Anonymous usage data and crash reports, off with one switch | 2026-11-10 | 202611100905 (909a26c) |
| `settings-privacy-events.webp` | See what Airc sends | The sheet listing every event Airc recorded, word for word | 2026-11-10 | 202611100905 (909a26c) |
| `agents-watch.webp` | Follow along | The sidebar's Agents folder (Claude · Mailbox working, Claude · Corner Shop) and Watch over the page: Claude typing in Mailbox's search field, outlined, with its caption, and “✦ Claude is using Airc” under the window's buttons (synthetic sites) | 2026-11-19 | test build (agentux2: ✦ bar) |
| `command-bar-connect-claude.webp` | Connect Claude | ⌘T “connect claude”: Connect Claude and other AI apps…, which opens Settings › Agents with setup first | 2026-11-15 | 202611150942 (f1991861) |
| `agent-panel.webp` | Ask Airc | The Airc Agent panel (⌥⌘A) on a checkout: the task, its steps and “Pay on cornershop…?” with Deny and Allow Once, before anything is paid (synthetic shop, scripted model) | 2026-11-16 | 202611162257 (42813bb1) |
| `agent-pane.webp` | Ask Airc, in the window | The Airc Agent pane beside the page (⌥⌘A): the task, one-line steps with site icons, the live page on top and the composer with the page chip, provider and Quick (synthetic shop, scripted model) | 2026-11-19 | test build (2ca546f4 + Stop glyph) |
| `agent-pane-dark.webp` | Ask Airc, dark | The same agent pane in a dark Space | 2026-11-19 | test build (2ca546f4 + Stop glyph) |
| `agent-pane-approval.webp` | Waiting for your OK | The agent pane pinning “Pay on cornershop…?” above the composer with Deny and Allow once, before anything is paid | 2026-11-19 | test build (2ca546f4 + Stop glyph) |
| `agent-pane-approval-dark.webp` | Waiting for your OK, dark | The same approval in a dark Space | 2026-11-19 | test build (2ca546f4 + Stop glyph) |
| `agent-pane-connect.webp` | Connect your AI | The agent pane's first run: your own Claude Code and Codex and the two API keys, each with its set-up step | 2026-11-19 | test build (agentux2: Install… / Sign in…) |
| `agent-pane-connect-dark.webp` | Connect your AI, dark | The same first-run card in a dark Space | 2026-11-19 | test build (agentux2: Install… / Sign in…) |
| `agents-approval.webp` | Allow ‘Claude’ to use Airc? | The one-time question when a new app connects: the profiles it can use and who started it | 2026-11-15 | 202611150942 (f1991861) |
| `settings-agents.webp` | Settings: Agents | Let AI apps use Airc (on), Show agent pages in front, the apps you answered, the profiles agents may use, Activity, and one-click setup | 2026-11-15 | 202611150942 (f1991861) |
| `settings-agents-activity.webp` | Settings: Agents, Activity | What each app did lately: sites and kinds of actions (Clicked, Typed in a field), never page content or typed text; Clear History; setup | 2026-11-15 | 202611150942 (f1991861) |
| `settings-agents-devices.webp` | Settings: Agents, Other devices | Claude Code on your other computers over Tailscale: on, listening only on the tailnet, a one-time pairing code with the command to paste, and two paired devices with Revoke (made-up names and addresses) | 2026-11-15 | 202611151728 (4fe98c0d+mcpfix) |
| `settings-sync.webp` | Settings: Sync | iCloud sync on, up to date between two Macs, with what syncs and what never leaves the Mac | 2026-11-10 | 202611101312 (6e16efb5) |
| `settings-sync-first.webp` | First sync on another Mac | This Mac's sidebar and iCloud's, the other Mac's Work profile matched to this one's, then merge or replace (a backup first) | 2026-11-10 | 202611102057 (1b604ae5) |
| `settings-shortcuts.webp` | Settings: Shortcuts | Every command by menu with its key and who gets it first: Open Location at Airc first (pages never get ⌘L), and ⌘N typed for New Private Window asking to swap with New Window | 2026-11-10 | 202611101039 (7de42be) |
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
| `settings-app-icon.webp` | Settings: App Icon | Settings › Appearance › App Icon: six of Airc's own icons (Holographic, Outline, Sunset, Ocean, Midnight, Graphite) for the Dock, the app switcher and the Finder | 2026-11-14 | 202611141217 (8fe89be6 + this commit) |
| `ai-settings.webp` | Settings → AI | Tidy tab titles, Ask on Page, Link previews and Tidy downloads, all on this Mac | 2026-11-10 | 202611100905 (909a26c) |
| `archive-library.webp` | Archived Tabs | The searchable Archive and its confirmed Clear Archive action, across all Spaces and profiles | 2026-11-07 | 202611070639 (archive working tree) |
| `copy-quote.webp` | Copy URL as Quote | Command Bar copy commands for a synthetic reading page | 2026-11-07 | 202611070831 (b842c64, with uncommitted changes) |
| `remembered-profiles.webp` | Little Airc profiles | Settings → Links, with remembered profiles and Forget remembered profiles | 2026-11-11 | 202611111621 (7d85d91) |
| `show-toolbar.webp` | Show Toolbar | A full address bar above a synthetic reading page, with back, forward and reload | 2026-11-07 | 202611070831 (b842c64, with uncommitted changes) |

| `video-blocking.webp` | Video ad filtering | Site Controls and original player-response filtering on a synthetic local Field Notes illustration | 2026-11-12 | 202611120307 (e351d8a7 with ytads app changes) |

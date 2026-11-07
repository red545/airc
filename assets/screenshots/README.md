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

Not shown yet: Meet's own Document PiP under Airc's top bar (the demo call opens its Document PiP, which closes at once
in the scripted run; `--script pipcontrols` captures the bar on a test page), and the profile menu itself (a native
menu, which can't be drawn off screen; `profiles.webp` shows profiles through Create Profile instead).

| File | Feature | What it shows | Date | Build |
|---|---|---|---|---|
| `hero-light.webp` | The window | Personal Space in Mint: Favorites, pinned folders, Today tabs and apple.com on the page card | 2026-11-06 | 202611061538 (6312e1a) |
| `hero-dark.webp` | The window, dark | The Work Space (Grape, the Work profile) on linear.app, in dark mode | 2026-11-06 | 202611061538 (6312e1a) |
| `spaces.webp` | Spaces | Four Spaces side by side, each in its own colour and profile: Personal, Travel, Studio, Work | 2026-11-06 | 202611061538 (6312e1a) |
| `command-bar-light.webp` | Command Bar (⌘T) | "lisbon" in Travel: history, open and pinned tabs and live search suggestions, the top hit completed inline | 2026-11-06 | 202611061538 (6312e1a) |
| `command-bar-dark.webp` | Command Bar (⌘T), dark | "linear" in the dark Work Space, from the Work profile's own history | 2026-11-06 | 202611061538 (6312e1a) |
| `command-bar-sites-light.webp` | Command Bar: well-known sites | "spot" with no history of it: Spotify first with its own icon, spotify.com completed inline | 2026-11-06 | 202611061631 (005428d) |
| `profiles.webp` | Profiles | Create Profile, step 2: which Spaces move to the new profile, each in its own colour | 2026-11-06 | 202611061538 (6312e1a) |
| `split-view-2.webp` | Split View | Two panes in Studio: Apple design pages beside Color theory | 2026-11-06 | 202611061538 (6312e1a) |
| `split-view-3.webp` | Split View, three panes | A map, the city and its trams in Travel | 2026-11-06 | 202611061538 (6312e1a) |
| `pinned-split.webp` | Pinned splits | A split pinned as one row in Studio (Bauhaus and Helvetica) | 2026-11-06 | 202611061538 (6312e1a) |
| `favorite-split.webp` | Favorite splits | A split as one Favorite tile in the Work profile (Linear and SwiftUI), dark | 2026-11-06 | 202611061538 (6312e1a) |
| `peek.webp` | Peek | A link from the Lisbon article opens over the page: the map of Belém | 2026-11-06 | 202611061538 (6312e1a) |
| `little-arc.webp` | Little Arc | A link from another app in its own small window, over the Personal Space | 2026-11-06 | 202611062051 (abc32c5) |
| `sidebar-right.webp` | Sidebar on the right | Settings → Appearance → Sidebar position: Right. Travel on the Lisbon article, the traffic lights over the page | 2026-11-07 | 202611070422 (f0ca8c3, with uncommitted changes) |
| `multiple-windows.webp` | Several windows | Two windows on different Spaces, each with its own tab: Travel on the Lisbon article in front, Work on linear.app behind | 2026-11-07 | 202611070055 (9970131) |
| `private-window.webp` | Private windows | A private window (⇧⌘N): dark, its own tabs and New Tab, nothing kept, on Wikipedia's Private browsing | 2026-11-06 | 202611062051 (abc32c5) |
| `private-window-start.webp` | Private windows: a new one | A new private window before its first tab: what it keeps and what it doesn't | 2026-11-06 | 202611062051 (abc32c5) |
| `private-window-find.webp` | Private windows: find | ⌘F in a private window: "cookie" found on Wikipedia's Private browsing, the same find field as the main window's | 2026-11-06 | polish1 copy (4b0791f) |
| `manage-spaces.webp` | Manage Spaces | Every Space in one card: drag to reorder, rename, icon, theme, profile and delete | 2026-11-06 | 202611062051 (abc32c5) |
| `media-controls.webp` | Media controls | A radio tab playing in the background, its artwork and controls in the sidebar, over Kyoto on Wikivoyage | 2026-11-06 | 202611061538 (6312e1a) |
| `calendar.webp` | Live Calendar | The Calendar Favorite counting down to the next meeting, and its card with Join | 2026-11-06 | 202611061538 (6312e1a) |
| `calendar-join.webp` | Live Calendar, Join | A minute before: the meeting and Join under the Favorites | 2026-11-06 | 202611061538 (6312e1a) |
| `site-controls.webp` | Site Controls | Site Controls from the URL field on swift.org: permissions, zoom and site data for that site | 2026-11-06 | 202611061538 (6312e1a) |
| `boosts.webp` | Boosts | Wikipedia boosted into a warm, bookish page (an amber tint, Charter), the Boost editor open on Colors | 2026-11-06 | 202611061646 (2984978) |
| `boosts-font.webp` | Boosts: fonts | The same Boost on Font: the page in Charter, a size step up, the macOS fonts to choose from | 2026-11-06 | 202611061646 (2984978) |
| `boosts-zap.webp` | Boosts: Zap | The same Boost on Zap: Wikipedia's Appearance column zapped away, with its undo | 2026-11-06 | 202611061646 (2984978) |
| `tab-preview.webp` | Tab previews | The pointer resting on the Kyoto tab over apple.com: its card with the page as it was left, and pin, Favorites, split and Peek | 2026-11-06 | 202611062158 (eabcfe2) |
| `tab-preview-dark.webp` | Tab previews, dark | The Work Space in dark mode on linear.app: the card of the swiftlang/swift tab | 2026-11-06 | 202611062158 (eabcfe2) |
| `drm-spotify.webp` | Protected media | Spotify's web player, logged out, in Safari's engine with Apple's FairPlay: the note that says so, with Why? | 2026-11-06 | 202611062002 (fd02319) |
| `drm-site-controls.webp` | Protected media: Site Controls | Site Controls on Spotify: the Safari's engine switch, and what a WebKit page does differently | 2026-11-06 | 202611062002 (fd02319) |
| `picture-in-picture.webp` | Picture in picture | A film floating over the Lisbon article, with Airc's controls: Back to Tab, skip 15 s, play, the scrubber | 2026-11-06 | 202611061551 (089fe21) |
| `picture-in-picture-call.webp` | Picture in picture, call | A call's video floating over another page, with microphone, camera and Leave | 2026-11-06 | 202611061551 (089fe21) |
| — | Picture in picture, Meet | Not taken yet: A call page's own Document PiP (as Meet opens one) under Airc's slim top bar | | |
| `downloads.webp` | Downloads | A film downloading, with its progress in the sidebar | 2026-11-06 | 202611061538 (6312e1a) |
| `downloads-library.webp` | Downloads Library | The Library's Downloads list: finished files and the one still running | 2026-11-06 | 202611061631 (005428d) |
| `call-window.webp` | Call window | A call (illustrated tiles, no camera) in its floating window, its controls in the sidebar | 2026-11-06 | 202611061551 (089fe21) |
| `settings-appearance-light.webp` | Settings: Appearance | Translucency, the default look of new Spaces and Show tab previews | 2026-11-06 | 202611062158 (eabcfe2) |
| `settings-appearance-dark.webp` | Settings: Appearance, dark | The same page in dark mode | 2026-11-06 | 202611062158 (eabcfe2) |
| `settings-privacy.webp` | Settings: Privacy | Anonymous usage data and crash reports, off with one switch | 2026-11-06 | 202611061538 (6312e1a) |
| `settings-privacy-events.webp` | See what Airc sends | The sheet listing every event Airc recorded, word for word | 2026-11-06 | 202611061538 (6312e1a) |
| `settings-shortcuts.webp` | Settings: Shortcuts | Every command by menu with its key and who gets it first: Open Location at Airc first (pages never get ⌘L), and ⌘N typed for New Private Window asking to swap with New Window | 2026-11-07 | 202611070422 (f0ca8c3, with uncommitted changes) |
| `onboarding-welcome.webp` | Onboarding | The first window | 2026-11-06 | 202611061915 (9e1fd56) |
| `onboarding-import.webp` | Onboarding: Arc import | Arc found on the Mac, first among the browsers found: Spaces, pinned tabs, folders and Favorites come over as they are | 2026-11-06 | 202611062324 (importbrowsers copy, 550fc0a) |
| `onboarding-import-browsers.webp` | Onboarding: other browsers | Chrome picked on the same step: each profile with its colour, its bookmarks and folders, and the history for ⌘T | 2026-11-06 | 202611062324 (importbrowsers copy, 550fc0a) |
| `onboarding-profiles.webp` | Onboarding: profiles | Each Arc profile becomes an Airc profile, with its Spaces | 2026-11-06 | 202611061915 (9e1fd56) |
| `onboarding-colours.webp` | Onboarding: Space colours | A colour for each Space before the first window opens | 2026-11-06 | 202611061915 (9e1fd56) |
| `onboarding-default-browser.webp` | Onboarding: default browser | The default-browser step | 2026-11-06 | 202611061915 (9e1fd56) |
| `onboarding-done.webp` | Onboarding: done | The last card before the window opens | 2026-11-06 | 202611061915 (9e1fd56) |
| `update-button.webp` | Update button | A downloaded update waiting in the sidebar (a fake ready update) | 2026-11-06 | 202611061538 (6312e1a) |

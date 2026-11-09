// /features: everything Airc does, grouped. A feature counts as new in a release when it's in that release's source,
// passed the nightly run on it and is visible to normal users, even where the notes don't name it (the lead's rule).
// Sources: docs/user/README.md ("What's in Airc today"), the release notes
// (src/content/changelog) and docs/qa/arc-parity.md. `since` is the first release with the feature as described; the
// page lists a feature once that release is published (preview deployments show them all). "coming" is planned work
// that isn't in a release yet, marked as such. "0.1.3" is in that release's notes (docs/release-notes-beta.md), not yet
// published. "next" is in the repo but not in any release's notes yet: production never shows it, previews mark it Next
// release; give it a version once a release's notes cover it. `until` hides a row once that release is out (a line it
// makes untrue, a Coming row it delivers); `from` shows a row only then. Previews show the state after the newest
// release. `shot` names a file in src/assets/screens (scripts/sync-screenshots.mjs).

export type Since = "0.1.0" | "0.1.2" | "0.1.3" | "next" | "coming";

export interface Feature {
  title: string;
  line: string;
  since: Since;
  shot?: string;
  until?: Since;
  from?: Since;
}

/** Whether `f` is on the site: production shows released and Coming rows, previews (`preview`) everything. */
export function shown(f: Feature, published: Set<string> | Map<string, unknown>, preview: boolean): boolean {
  const out = (v: Since) => published.has(v) || preview;
  if (f.until && out(f.until)) return false;
  if (f.from && !out(f.from)) return false;
  return f.since === "coming" || out(f.since);
}

export interface Group {
  id: string;
  name: string;
  sub: string;
  color: string;
  features: Feature[];
}

// What each shot shows, for its alt text.
export const shotAlt: Record<string, string> = {
  spaces: "Four Airc Spaces side by side, each in its own colour and profile: Personal, Travel, Studio and Work.",
  profiles: "Create Profile in Airc: choosing which Spaces move to the new profile, each in its own colour.",
  "little-arc-menu-window": "Little Airc's Open In menu: Personal, Travel, Studio and Work in their own colours, Work saying Reloads in Work, then Search Spaces, Profile and Copy Link.",
  "favorite-split-icon-card": "The Work profile's Favorites: a Favorite split with its own icon, a hammer and wrench, set with Change Icon…, and a small split mark on its tile.",
  "boosts-share": "Share Boost over a boosted Wikipedia page: its screenshot, a name, the author's name, Copy Link and Save File.",
  "boosts-review": "Add this Boost to Airc? for Night Wikipedia, with Try It On on: the page behind it is already dark, before the Boost is added.",
  "boosts-gallery": "The Boost Gallery: Airc's starter Boosts, each with a sketch of its colours and font and a Get button.",
  "tab-menu-card": "A Today tab's menu, as Arc's: Copy Link, Share (highlighted), Rename, Mute, Customize Page, Add Split View, Duplicate, Move to, Pin Tab, Add to Favorites and Archive.",
  "folder-markdown-card": "The Recipes folder's menu with Copy All Links as Markdown highlighted.",
  "command-bar-site-search": "Site Search in the Command Bar: the Wikipedia pill leads the field, the search for Belém Tower comes first, then the open Wikipedia pages.",
  "settings-site-search": "Settings → Site Search: the Personal profile's sites with their shortcuts and %s addresses.",
  "sidebar-files": "A Lisbon trip folder dropped on the Travel Space: its files as pinned tabs, its Tickets folder inside, the itinerary open, and Added 5 tabs and 2 folders to Travel.",
  "quote-link": "Wikipedia's Typography article after ⌘C on a sentence: Share a link directly to this text instead?, with Copy Link.",
  "essential-shortcuts": "Help › Essential Keyboard Shortcuts: tabs, pages, Spaces and windows, Split View, notes and meetings, and numbers, in two calm columns.",
  "notes-split": "New Note in Split: a Lisbon trip page with a packing note beside it, being written, a checklist and a list from the guide.",
  "theme-palette": "Wikipedia in a light Peach Space, wearing the Space's colours through Arc's palette variables.",
  "theme-palette-dark": "The same Wikipedia page in a dark Grape Space: the page turns dark with the theme.",
  "arc-import-logins": "Logins from Arc: 2 logins and 2 cookies imported, 4 skipped with the reason for each in plain words, one profile's saved passwords unreadable, and Try Again.",
  "capture-full-page": "Capture Full Page: a long Lisbon itinerary taken whole, scaled to fit over the dimmed page, its size above it and Copy, Save and Share under it.",
  "capture-portrait": "Capture in Portrait Mode: a Lisbon trip page framed on a soft cyan gradient with the Airc mark, the background choices under it, then Copy, Save and Share.",
  "developer-mode-site-controls": "Site Controls on a local app, with the Developer Mode row: On automatically for localhost, and its switch.",
  "developer-mode-toolbar-card": "Developer Mode on localhost: the full address, and Inspect, Network, Reload and a console badge of 2 under it.",
  "toolbar-extensions-card": "Two pinned extensions, Focus Timer and Reading List, at the toolbar's top right, and ⌘E's Extensions list under the puzzle button.",
  "update-playing-card": "Restart to update Airc? over the sidebar: music or video is playing and restarting stops it, your Spaces and tabs come back as they are, See What's New, Restart and Not Now.",
  "update-whats-new-card": "New Version Available above the sidebar's footer, its menu open: Restart to Update and See What's New.",
  "settings-app-icon": "Settings › Appearance › App Icon: Holographic, chosen, or Outline, the icon in the Dock and the app switcher while Airc is open.",
  "site-preview-card": "Resting on the Work Space's Linear Favorite: Recents lists the Linear pages visited there, newest first, with + for a new issue.",
  notes: "A note pinned in the Travel Space, Lisbon plan: a heading, a checklist with one item ticked, and a pasted Capture of a sunset over the rooftops.",
  "calendar-card": "The Calendar Favorite's Upcoming card: a design review in five minutes with Join, a 1:1 in fifty minutes and lunch, with + for a new event.",
  "multi-select-menu": "Three Today tabs selected in the sidebar, with their menu: copy links, Share, duplicate, Split View, pin, new folder, move to Space, close and archive.",
  "tab-preview-card": "The pointer resting on a sidebar tab: a card with the Wikivoyage page as it was left, and pin, Favorite, split and Peek.",
  "manage-spaces-card": "Manage Spaces: Personal, Travel, Studio and Work in one card, with their colours and profiles, to reorder, rename or delete.",
  "multiple-windows": "Two Airc windows on different Spaces: Travel on the Lisbon article in front, Work behind.",
  "sidebar-right": "Airc with the sidebar on the right of the window, on the Lisbon article.",
  "command-bar-light": "Airc's Command Bar in the Travel Space: typing lisbon shows history, open and pinned tabs and search suggestions.",
  "copy-quote": "The Command Bar's copy commands on a reading page: Copy URL, Copy URL as Quote and Copy URL as Markdown.",
  "show-toolbar": "A full address bar with back, forward and reload above a reading page, from View › Show Toolbar.",
  "little-arc-window": "Little Airc: a link from another app in its own small window, with Open in Personal at the top.",
  "remembered-profiles": "Settings → Links: links from other apps, the remembered Little Airc profiles, and Peek.",
  "settings-links": "Settings → Links: Air Traffic Control with a rule that sends figma.com to the Studio Space.",
  "split-view-3": "Split View with three panes in the Travel Space: a map, the Lisbon article and its trams.",
  "pinned-split": "A split pinned as one row in the Studio sidebar: Bauhaus beside Helvetica.",
  "favorite-split": "A split kept as one Favorite tile in the dark Work Space: two pages side by side.",
  peek: "Peek: a link from the Lisbon article opens in a card over the page, showing the map of Belém.",
  "picture-in-picture": "Picture in picture: a film floats over the Lisbon article, with Back to Tab, skip, play and a scrubber.",
  "media-controls": "A radio tab playing in the background, its artwork and controls in the sidebar.",
  "drm-site-controls-panel": "Site Controls on open.spotify.com: Safari's engine is on, with Apple's FairPlay.",
  "private-window": "A private window: dark, with its own tabs, on Wikipedia's article on private browsing.",
  "settings-privacy-events": "See what Airc sends: the last events, word for word, as they go out.",
  "site-controls-panel": "Site Controls for swift.org: camera, microphone, location and other permissions, zoom and site data.",
  "onboarding-import": "Airc's onboarding has found Arc on the Mac: Spaces, pinned tabs, folders, Favorites and logins, ready to import.",
  "arc-import-checklist": "The Arc import's last step: each profile's history imported, and a checklist for reinstalling extensions.",
  "onboarding-import-browsers": "Importing from Chrome: each Chrome profile with its bookmarks and folders, and its history for ⌘T.",
  boosts: "A Boost on Wikipedia's Typography article: a warm amber tint, with the Boost editor open on Colors.",
  "boosts-font": "The same Boost on Font: the article set in Charter, a size step up.",
  "boosts-zap": "The same Boost on Zap: a column of the page zapped away, with its undo.",
  "boost-import": "Review Boost: a shared Boost's site, its changes, its CSS and all its JavaScript, before Install.",
  "developer-mode": "Developer Mode on a local app: the full address with its port, Inspect, Reload and the console count, and the code mark on its tab.",
  "developer-mode-dark": "Developer Mode's controls in a dark Space.",
  capture: "Capture on a trip-planning page: a card selected, the page dimmed around it, with Copy, Save and Share.",
  "archive-library-panel": "The Library's Archived Tabs: a search field, Clear Archive and today's archived tabs.",
  "library-media": "Library › Media: downloaded pictures, films and a Capture, newest first.",
  "library-recent": "The pointer resting on the Library button: the five newest downloads and Captures.",
  "downloads-library": "The Library's Downloads: finished files and their sizes.",
  "settings-shortcuts": "Settings → Shortcuts: every command with its key, Websites first or Airc first, and a conflict offering Swap or Replace.",
};

export const groups: Group[] = [
  {
    id: "sidebar",
    name: "Sidebar and Spaces",
    sub: "Arc's sidebar, with a colour and a profile for every Space.",
    color: "#2f9e62",
    features: [
      { title: "Spaces", line: "A colour, an icon and an order for each Space. Swipe between them.", since: "0.1.0", shot: "spaces" },
      { title: "A profile per Space", line: "Each Space can have its own logins, history and passwords. Two Gmail accounts, one window.", since: "0.1.0", shot: "profiles" },
      { title: "Pinned tabs and folders", line: "Pin tabs, nest them in folders, drag to move and ⌥-drag to copy.", since: "0.1.0" },
      { title: "Favorites", line: "Your most-used sites as tiles at the top of the sidebar. One click goes back to where each one started.", since: "0.1.0" },
      { title: "Live Calendar", line: "A Calendar Favorite counts down to your next meeting and offers Join. Turn it on in Settings → General.", since: "0.1.0", shot: "calendar-card" },
      { title: "Site previews", line: "Rest on a pinned Notion, Linear, Figma or Confluence and see the pages you were just on, from your own history, without leaving the one you're on.", since: "next", shot: "site-preview-card" },
      { title: "Calendar options", line: "Right-click the calendar Favorite for Arc's options: the time to your next meeting, its link and when it shows, and the hover preview.", since: "0.1.3" },
      { title: "Light on memory", line: "Tabs you haven't looked at in a while unload. Tabs with typed text, and calls, stay.", since: "0.1.0" },
      { title: "Select several tabs", line: "⌘-click or ⇧-click tabs, then move, pin, duplicate, archive or organize them together, with Undo.", since: "0.1.2", shot: "multi-select-menu" },
      { title: "Tab previews", line: "Rest the pointer on a tab to see its page, with pin, Favorite, split and Peek one click away.", since: "0.1.2", shot: "tab-preview-card" },
      { title: "Manage Spaces", line: "Reorder, rename and restyle every Space in one card.", since: "0.1.2", shot: "manage-spaces-card" },
      { title: "Several windows", line: "⌘N opens another window on the same Spaces and tabs. A tab moves between windows without reloading.", since: "0.1.2", shot: "multiple-windows" },
      { title: "Sidebar on the right", line: "Settings → Appearance → Sidebar position.", since: "0.1.2", shot: "sidebar-right" },
      { title: "Chat and mail stay ready", line: "Pinned tabs and Favorites for chat and mail sites stay loaded when you switch away.", since: "0.1.2" },
      { title: "Set up a new profile", line: "Sign a new profile in to Google and pick suggested Favorites for it.", since: "0.1.2" },
      { title: "Drop files and folders", line: "Files, folders, links and text dropped on the sidebar become tabs and folders, as in Arc.", since: "0.1.3", shot: "sidebar-files" },
      { title: "Back to recent tabs", line: "⌃Tab goes back to your recent tabs, as in Arc.", since: "0.1.3" },
      { title: "Export a Space", line: "Export a Space as Markdown, or as bookmarks any browser imports.", since: "0.1.3" },
      { title: "An icon for any tab", line: "Change Icon… gives a Today tab its own icon, and it keeps it when pinned.", since: "0.1.3" },
    ],
  },
  {
    id: "command",
    name: "Command Bar",
    sub: "One box for everything, on ⌘T.",
    color: "#2f6af0",
    features: [
      { title: "⌘T", line: "Search, open a site, jump to a tab or a Space, or run an action.", since: "0.1.0", shot: "command-bar-light" },
      { title: "⌘L", line: "Edit the current page's address in place.", since: "0.1.0" },
      { title: "Copy links", line: "Copy the page's address, or copy it as Markdown.", since: "0.1.0" },
      { title: "Copy as Quote", line: "⌃⇧⌘C copies the text you selected as a Markdown quote, with the page's title and link.", since: "0.1.2", shot: "copy-quote" },
      { title: "Show Toolbar", line: "View › Show Toolbar adds a classic address bar over the page, if you want one.", since: "0.1.2", shot: "show-toolbar" },
      { title: "Remove a suggestion", line: "⇧⌫ removes a history suggestion you've moved to.", since: "0.1.2" },
      { title: "Site Search", line: "Type a site's shortcut or name (yt, wiki, gh), press Tab, then your search, as in Arc.", since: "0.1.3", shot: "command-bar-site-search" },
      { title: "Your own sites", line: "Each profile has its own: Arc's built in, plus any you add in Settings → Site Search with a %s address.", since: "0.1.3", shot: "settings-site-search" },
      { title: "Share any tab", line: "Share › on every tab's, Favorite's and selection's menu, as in Arc.", since: "0.1.3", shot: "tab-menu-card" },
      { title: "Clean links", line: "Copy Link, ⇧⌘C and Share leave out a link's trackers, as Arc's did.", since: "0.1.3" },
      { title: "A folder as Markdown", line: "Copy All Links as Markdown copies a folder's links with their titles and nesting.", since: "0.1.3", shot: "folder-markdown-card" },
      { title: "A link to the text you copied", line: "After ⌘C on a sentence, Airc offers a link that opens the page at that text, highlighted.", since: "0.1.3", shot: "quote-link" },
      { title: "Every menu command in ⌘T", line: "Anything in the menu bar can be found in the Command Bar: try \"read aloud\".", since: "0.1.3" },
    ],
  },
  {
    id: "little-arc",
    name: "Little Airc",
    sub: "Links from other apps, in a small window of their own.",
    color: "#7a4cf0",
    features: [
      { title: "Little Airc", line: "A link from Mail or Slack opens in a small window, like Arc's Little Arc. ⌘O moves the page into a Space.", since: "0.1.0" },
      { title: "Air Traffic Control", line: "Rules send links from other apps to the right Space, already signed in.", since: "0.1.0" },
      { title: "One click to your browser", line: "A link from an app in full screen opens Little Airc over it, on the same Space. One click moves the page into your window.", since: "0.1.2", shot: "little-arc-window" },
      { title: "It remembers your profile", line: "Little Airc keeps the profile you pick for each site. Settings → Links forgets them.", since: "0.1.2", shot: "remembered-profiles" },
      { title: "Open in any Space", line: "The chip's chevron (⇧⌘O) lists your Spaces in their colours and says which would reload the page in another profile. Search Spaces (⌥⌘O) finds one as you type.", since: "0.1.3", shot: "little-arc-menu-window" },
      { title: "From any app", line: "Turn it on for any app in Settings → Links, then press ⌥⌘N in any app, even one in full screen.", since: "0.1.3" },
      { title: "Rules for Peek too", line: "Air Traffic Control rules also apply to links that would open in Peek.", since: "0.1.2", shot: "settings-links" },
    ],
  },
  {
    id: "split",
    name: "Split View and Peek",
    sub: "Pages side by side, and links in a card over your page.",
    color: "#e8702a",
    features: [
      { title: "Split View", line: "Two to four pages side by side, as one row in the sidebar, each with its own profile.", since: "0.1.0", shot: "split-view-3" },
      { title: "Pinned splits", line: "Pin a split, and it comes back as one row.", since: "0.1.0", shot: "pinned-split" },
      { title: "Favorite splits", line: "Keep a split as one Favorite tile.", since: "0.1.0", shot: "favorite-split" },
      { title: "Drag a pane out", line: "Drag a pane by its handle into the sidebar to make it a tab again.", since: "0.1.0" },
      { title: "Peek", line: "Links from pinned tabs open in a card over your page. ⌘O makes it a tab, or a split.", since: "0.1.0", shot: "peek" },
      { title: "Open Link in Space", line: "Send a link straight to the Space you choose, from its menu.", since: "0.1.2" },
      { title: "⌥-click to split", line: "⌥-click a tab, pinned tab or Favorite to open it beside the page; ⌃⇧[ and ⌃⇧] move between the panes.", since: "0.1.3" },
      { title: "Split View Controls", line: "Each pane's handle opens Arc's Split View Controls: move it, add a pane left, right, top or bottom, separate it or close it.", since: "0.1.3" },
      { title: "Grow a saved split", line: "Drop a tab onto a pinned split's row or a Favorite split's tile to add it, up to four pages.", since: "0.1.3" },
      { title: "Expand and separate", line: "Expand Current Split shows one pane alone and Restore brings the others back; Separate Page from Split View makes a pane its own tab.", since: "0.1.3" },
      { title: "An icon for a Favorite split", line: "Right-click its tile and choose Change Icon…, as in Arc.", since: "0.1.3", shot: "favorite-split-icon-card" },
    ],
  },
  {
    id: "media",
    name: "Media and calls",
    sub: "Films, music and calls keep going while you browse.",
    color: "#e0559f",
    features: [
      { title: "Picture in picture", line: "Leave a playing video and it floats in a small window, with Airc's own controls.", since: "0.1.0", shot: "picture-in-picture" },
      { title: "Media in the sidebar", line: "Audio and video playing in the background show their artwork and controls in the sidebar.", since: "0.1.0", shot: "media-controls" },
      { title: "Calls keep going", line: "A call isn't unloaded when you switch Spaces, and floats when you leave its tab. Tested with simulated calls so far.", since: "0.1.0" },
      { title: "Mini Player pill", line: "Esc collapses the player to a small pill without stopping playback.", since: "0.1.2" },
      { title: "Streaming sites", line: "Spotify, Netflix, Disney+ and others open with Safari's engine inside Airc. Checked logged out; playback with a subscription isn't tested yet.", since: "0.1.2", shot: "drm-site-controls-panel" },
      { title: "Media keys everywhere", line: "Pages in Safari's engine use the sidebar's controls, Now Playing and the media keys too.", since: "0.1.2" },
      { title: "The real song length", line: "Spotify and other pages on Safari's engine show the song's real length and position in the sidebar player, and picture in picture's return button brings you back to the tab.", since: "0.1.3" },
    ],
  },
  {
    id: "privacy",
    name: "Privacy",
    sub: "No account, and usage data you can read word for word.",
    color: "#5b6170",
    features: [
      { title: "No account", line: "Airc doesn't need one. Your Spaces, tabs and history stay on your Mac.", since: "0.1.0" },
      { title: "See what Airc sends", line: "Anonymous usage data and crash reports, never what you browse. Read every event, or turn it off, in Settings → Privacy.", since: "0.1.0", shot: "settings-privacy-events" },
      { title: "Site Controls", line: "Permissions, zoom and site data for each site, from the address field.", since: "0.1.0", shot: "site-controls-panel" },
      { title: "Private windows", line: "⇧⌘N opens a window whose history, cookies and site data go when you close it. Downloads stay on disk.", since: "0.1.2", shot: "private-window" },
    ],
  },
  {
    id: "import",
    name: "Import",
    sub: "Bring Arc, or another browser, with you.",
    color: "#7a4cf0",
    features: [
      { title: "From Arc", line: "Spaces, pinned tabs, folders, Favorites and logins, read from Arc's files on your Mac. Nothing is uploaded.", since: "0.1.0", shot: "onboarding-import" },
      { title: "Arc's history and extensions", line: "History comes over into the right profiles, with a checklist for reinstalling your extensions.", since: "0.1.2", shot: "arc-import-checklist" },
      { title: "From other browsers", line: "Bookmarks and history from Chrome, Brave, Edge, Vivaldi, Opera, Firefox, Zen and others, or from a bookmarks file.", since: "0.1.2", shot: "onboarding-import-browsers" },
      { title: "Passwords from a file", line: "Import passwords from a CSV file you export. Airc never reads another browser's password store.", since: "0.1.2" },
      { title: "Every login, explained", line: "After importing Arc's passwords and cookies, Airc lists what came over and what didn't, and why, in plain words. Try Again redoes only what failed.", since: "0.1.3", shot: "arc-import-logins" },
      { title: "Extensions, checked off", line: "The reinstall checklist marks each extension to go, opened in the Web Store, installed, or not in the Web Store with how to get it back.", since: "0.1.3" },
    ],
  },
  {
    id: "boosts",
    name: "Boosts",
    sub: "Make any site yours. No account, no sync.",
    color: "#e0559f",
    features: [
      { title: "Colours", line: "A tint, brightness and contrast for a site, or Invert for a quick dark mode.", since: "0.1.2", shot: "boosts" },
      { title: "Fonts", line: "A macOS font and a size, with the layout's proportions kept.", since: "0.1.2", shot: "boosts-font" },
      { title: "Zap", line: "Click away the parts of a page you never want to see. One click brings them back.", since: "0.1.2", shot: "boosts-zap" },
      { title: "Your own code", line: "Add CSS and JavaScript for a site, from Site Controls.", since: "0.1.2" },
      { title: "Share a Boost", line: "Share one as a file. Opening it shows its site, its changes and all its code before anything installs.", since: "0.1.2", shot: "boost-import" },
      { title: "Boost links", line: "Copy Link puts the whole Boost after the # of an aircbrowser.com/boost link, which browsers never send anywhere, so nothing is uploaded.", since: "0.1.3", shot: "boosts-share" },
      { title: "Updates from the author", line: "Share a Boost again and everyone who added it is offered the new version. Arc never updated installed copies.", since: "0.1.3" },
      { title: "Try It On", line: "See a shared Boost's colours, font and CSS on the page before you add it. Its JavaScript never runs until you do.", since: "0.1.3", shot: "boosts-review" },
      { title: "Boost Gallery", line: "Airc's starter Boosts, style only: a calmer Wikipedia, a night one, a comfortable Hacker News and more.", since: "0.1.3", shot: "boosts-gallery" },
      { title: "Closer to Arc's", line: "Boosts apply in a page's same-site frames too, and a Boost's size uses page zoom.", since: "0.1.3" },
      { title: "Pages in your Space's colours", line: "Every page gets its Space's theme as Arc's --arc-palette CSS variables, so Boosts and pages written for Arc's colours work in Airc.", since: "0.1.3", shot: "theme-palette" },
      { title: "Following the Space live", line: "Change the Space's colour, go dark or move the tab, and those pages follow at once.", since: "0.1.3", shot: "theme-palette-dark" },
    ],
  },
  {
    id: "developer",
    name: "Developer Mode",
    sub: "For the sites you're building. Off until you turn it on in Settings → General.",
    color: "#2f6af0",
    features: [
      { title: "Your dev server, in full", line: "On localhost and other dev servers: the full address with its port, Inspect, Hard Reload (⇧⌘R) and a console error count.", since: "0.1.2", shot: "developer-mode" },
      // The release after 0.1.3 drops the </> mark: dev-server rows keep the site's favicon, with Developer Mode's outline.
      { title: "A mark on the tab", line: "Dev-server tabs get a </> mark in the sidebar, in light and dark Spaces.", since: "0.1.2", shot: "developer-mode-dark", until: "next" },
      { title: "Per site, as in Arc", line: "It turns on by itself for localhost; ⌃D turns it on for any other site, and private windows never use it.", since: "0.1.3" },
      { title: "A strip of tools", line: "Under the address: Inspect, Hard Reload and a count of console errors.", since: "0.1.3" },
      { title: "Network and clearing data", line: "A Network button opens Developer Tools at that panel, and Control-click Hard Reload clears the site's data and reloads.", since: "next", shot: "developer-mode-toolbar-card" },
    ],
  },
  {
    id: "capture",
    name: "Capture",
    sub: "A picture of the page, from the browser itself.",
    color: "#e8702a",
    features: [
      { title: "⇧⌘2", line: "Drag over part of the page, then Copy, Save or Share. No screen-recording permission needed.", since: "0.1.2", shot: "capture" },
      { title: "The page or one element", line: "Space takes the visible page; ⌘-click picks one element. It doesn't capture a whole long page yet.", since: "0.1.2", until: "0.1.3" },
      { title: "The page or one element", line: "Space takes the visible page; ⌘-click picks one element.", since: "0.1.2", from: "0.1.3" },
      { title: "Capture Full Page", line: "In Capture (⇧⌘2), F or View › Capture Full Page takes the whole length of a page, as Arc's did.", since: "0.1.3", shot: "capture-full-page" },
      { title: "Portrait Mode", line: "P frames the page on its own colour, any colour or your desktop picture, as Arc's did; Copy, Save and Share give the same picture.", since: "next", shot: "capture-portrait" },
    ],
  },
  {
    id: "notes",
    name: "Notes",
    sub: "Arc's Notes, back: a page of your own in the sidebar.",
    color: "#c9a227",
    features: [
      { title: "A note in your Space", line: "⌃⇧N, New Note in the Command Bar or the sidebar's + makes a note, pinned in your Space as in Arc. It saves as you type.", since: "0.1.3", shot: "notes" },
      { title: "A note beside the page", line: "New Note in Split puts a new note next to the page you're on, ready to type, as Arc's New Note (in Split) did.", since: "0.1.3", shot: "notes-split" },
      { title: "Lists, headings and links", line: "Headings, bulleted, numbered and checkbox lists, bold, italic and links, with Markdown as you type: # for a heading, [] for a checkbox.", since: "0.1.3" },
      { title: "Paste a Capture", line: "⌘V puts a Capture, or any picture, into a note, as Arc's notes took them.", since: "0.1.3" },
      { title: "Find and archive", line: "⌘F finds in a note, and ⌘W archives it like a tab.", since: "0.1.3" },
      { title: "Export and import", line: "Export Note… saves Markdown, RTF, PDF or HTML, Export All Notes… saves every note, and Import Notes… brings Markdown, RTF and HTML back, Arc's exports too.", since: "0.1.3" },
      { title: "Or your own notes app", line: "Settings → General → Notes can make New Note open Google Docs, Notion, Word or Confluence instead.", since: "0.1.3" },
      { title: "On this Mac", line: "Notes stay on this Mac for now. They don't sync and can't be shared by link yet.", since: "0.1.3" },
    ],
  },
  {
    id: "library",
    name: "Library",
    sub: "Archived tabs, downloads, media and backups.",
    color: "#2f9e62",
    features: [
      { title: "Auto-archive", line: "Today's tabs archive on a timer you choose, and stay searchable in the Library.", since: "0.1.0" },
      { title: "Downloads", line: "Every profile's downloads in one list, with their progress in the sidebar.", since: "0.1.0", shot: "downloads-library" },
      { title: "Clear Archive", line: "Empty the archive in one step. A backup is saved first.", since: "0.1.2", shot: "archive-library-panel" },
      { title: "Media", line: "Pictures and films you downloaded, and your Captures, in a grid.", since: "0.1.2", shot: "library-media" },
      { title: "Recent files", line: "Rest the pointer on the Library button to see your newest files.", since: "0.1.2", shot: "library-recent" },
      { title: "Restore from Backup", line: "Bring back a saved sidebar from Settings. The current one is saved first.", since: "0.1.2" },
    ],
  },
  {
    id: "shortcuts",
    name: "Shortcuts",
    sub: "Arc's keys, and yours.",
    color: "#5b6170",
    features: [
      { title: "Arc's shortcuts", line: "The keys you know from Arc.", since: "0.1.0" },
      { title: "Change any shortcut", line: "Record a new key in Settings → Shortcuts. A conflict offers Swap or Replace.", since: "0.1.2", shot: "settings-shortcuts" },
      { title: "Websites first or Airc first", line: "Choose who gets a key that a page also uses, as in Arc.", since: "0.1.2" },
      { title: "Essential Keyboard Shortcuts", line: "Help › Essential Keyboard Shortcuts shows the keys that matter most, as you've set them.", since: "0.1.3", shot: "essential-shortcuts" },
    ],
  },
  {
    id: "ai",
    name: "AI",
    sub: "On your Mac, and off until you turn it on.",
    color: "#7a4cf0",
    features: [
      { title: "Tidy Titles", line: "Long tab titles get a short name from Apple's on-device model. Off by default; needs Apple Intelligence.", since: "0.1.2" },
      { title: "Ask on Page", line: "Ask a question about the page you're on, answered from its text. Not in a release yet.", since: "coming" },
      { title: "Link previews", line: "Hold ⇧ over a link for a short summary of the page it opens. Not in a release yet.", since: "coming" },
      { title: "Tidy Downloads", line: "A clear name to choose for a download called \"IMG_2041 (1).pdf\". Not in a release yet.", since: "coming" },
    ],
  },
  {
    id: "browsing",
    name: "Everyday browsing",
    sub: "Chromium underneath, with Chrome's extensions.",
    color: "#2f9e62",
    features: [
      { title: "Chrome extensions", line: "Install from the Chrome Web Store, per profile.", since: "0.1.0" },
      { title: "Extensions in the toolbar", line: "With View › Show Toolbar (⇧⌘D) on, pinned extensions sit at the toolbar's top right, always visible, as in Arc.", since: "0.1.3", shot: "toolbar-extensions-card" },
      { title: "Airc's own prompts", line: "Camera, location, password and sign-in prompts appear in Airc's cards, over the right page.", since: "0.1.0" },
      { title: "Saved logins", line: "Pick a saved login from a list under the field.", since: "0.1.0" },
      { title: "Back and forward history", line: "Right-click or long-press Back or Forward to see where you've been.", since: "0.1.0" },
      { title: "Find in page", line: "⌘F finds, Esc closes.", since: "0.1.0" },
      { title: "Full screen", line: "The sidebar, the traffic lights and the Esc-twice exit behave as they do in Arc.", since: "0.1.0" },
      { title: "Updates", line: "Airc checks for signed updates and offers Restart to Update when one is ready.", since: "0.1.0" },
      { title: "Updates that wait for you", line: "If restarting would stop music, a call, a download or a page you haven't saved, Restart to Update asks first and says what. Not Now keeps the update ready.", since: "next", shot: "update-playing-card" },
      { title: "See What's New", line: "The update's release notes, from the update's right-click menu, its question or the Airc menu. After the restart, Updated! names the new version.", since: "next", shot: "update-whats-new-card" },
      { title: "Automatically update my Airc", line: "As in Arc, Airc can restart into an update by itself while you're away, only when nothing would be lost. Off until you turn it on in Settings › General.", since: "next" },
      { title: "App icon", line: "Settings › Appearance › App Icon: Holographic or Outline, in the Dock and the app switcher.", since: "next", shot: "settings-app-icon" },
      { title: "Sounds and haptics", line: "Arc's two switches in Settings › General: Airc's sound effects, and the trackpad's tap when a dragged tab moves to the next Space.", since: "next" },
      { title: "Save Page As", line: "⇧⌘S saves a page in Chromium's formats.", since: "0.1.2" },
      { title: "Drag from the top of a page", line: "Drag the window from the top of a page, as from a title bar; hold ⌘ to use the page there instead. It can't be turned off yet.", since: "0.1.3" },
      { title: "Arc's Edit menu", line: "Spelling and Grammar, Substitutions, Transformations, Speech, Use Selection to Find and Jump to Selection (⌘J).", since: "0.1.3" },
      { title: "Reduce Motion", line: "With Reduce Motion on, the sidebar and Space switches cross-fade instead of sliding.", since: "0.1.3" },
    ],
  },
  {
    id: "sync",
    name: "Sync",
    sub: "Your sidebar on every Mac.",
    color: "#2f6af0",
    features: [
      { title: "Sync with iCloud", line: "Your Spaces and tabs on every Mac you use. Not in a release yet.", since: "coming", until: "0.1.3" },
      { title: "Sync with iCloud", line: "Settings → Sync keeps your Spaces, pinned tabs, folders and Favorites the same on your Macs, end-to-end encrypted. It's off until you turn it on, and new: so far it's been tested with iCloud on one Mac.", since: "0.1.3" },
      { title: "What stays on this Mac", line: "Today tabs, history, logins, Boosts and notes don't sync. Your sidebar is backed up before the first sync.", since: "0.1.3" },
    ],
  },
];

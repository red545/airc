# Onboarding and importing from Arc/Chrome: research for an Arc-style Chromium fork on macOS (2026-11-03)

Track 4 of 6. Scope: Arc's onboarding, competitors' onboarding, a recommended onboarding of under 2 minutes, import mechanics (Arc and Chrome to the fork), Chromium first-run and default-browser hooks, and legal/safety notes.

Conventions:
- **[I]** marks an inference: my reasoning, not stated by a source.
- **[code]** means I read the source code myself. The code was cloned or fetched into `research/repos/` on 2026-11-03:
  - `helium/` at commit 2f81b9c (2026-10-30), Chromium 156.0.8078.79
  - `helium-onboarding/` at commit 64257c5 (2026-10-16)
  - `cr_import/`: single upstream Chromium files from the GitHub mirror, `main`, 2026-11-03
  - `brave_snips/`: brave-core `master`
  - `zen_snips/`: zen-browser/desktop `HEAD`

Arc's sunset dates come from the earlier research and the Arc Help Center. Arc stops working on **Dec 22, 2026**, and the last day to request account data is **Dec 15** ([Arc Sunset: Key Dates](https://resources.arc.net/hc/en-us/articles/44412972248471-Arc-Sunset-Key-Dates-and-What-to-Expect)). Any import path has to ship, or at least snapshot the user's data, before then.

---

## 0. Key decisions for the spec

1. **Import from Arc in two layers.**
   - Layer 1 is the sidebar, from `StorableSidebar.json`. It needs no secrets, and you already have a parser (`arcImport.ts`).
   - Layer 2 is each Arc Chromium profile under `Arc/User Data/<dir>`.
   - Arc profiles map one-to-one onto fork profiles. Each Space binds to the fork profile that matches its Arc profile, through `space.profile.custom._0.directoryBasename`, or `default` for the main profile.
2. **Logins can carry over, but only with an OS prompt.** Arc encrypts cookies and passwords with a key held in the login Keychain item **"Arc Safe Storage"** (account "Arc"). Zen's Firefox migrator uses exactly that service name. The fork reads the key once, and macOS shows its Keychain access prompt. It then decrypts (v10, AES-128-CBC, PBKDF2-SHA1 with 1003 iterations and salt "saltysalt"), strips the 32-byte SHA-256 domain prefix from cookies, and re-encrypts under its own key. Dia and SigmaOS already carry Arc cookies across ("you're signed in to your sites"). Upstream Chromium does **not** import cookies (`COOKIES = 1 << 2, // Not supported yet`), so this is custom work.
3. **macOS 27 adds a second consent.** Reading another app's data folder now needs a per-app Files & Folders permission. Helium shows a dedicated notice on macOS ≥ 27. The onboarding has to prime the user for this and handle a denial.
4. **Hook point.** Copy Helium's approach. It disables `FirstRunService` (so Chrome's profile-picker FRE, `chrome://intro`, never shows) and opens its own onboarding page when a per-profile pref like `completed_onboarding` is false. Because the experience must feel magical, I recommend a full-window native shell around a WebUI, not a plain tab ([I]).
5. **Default browser.** Use `NSWorkspace setDefaultApplicationAtURL:toOpenURLsWithScheme:`, as Chromium does. macOS always shows its own confirmation dialog. Since macOS 26.4, also registering for the HTML content type triggers a *second* (Finder) dialog, so skip that step.
6. **Target under 2 minutes.** Run the import in the background while the user picks colours and does the hands-on shortcut tutorial. Skip steps the import already answered, as Dia does: "Dia skips the setup steps the import already handled".

---

## 1. Arc's onboarding, screen by screen

### 1.1 What the sources establish

**Design intent.** Input interviewed TBC designers (Matt Wille, June 7, 2022) ([Input/Inverse](https://www.inverse.com/input/design/the-browser-company-arc-design-interview)):
- The "unboxing" replaced manual 1:1 onboarding calls. Kristina Varshavskaya: "Let's let people set up the browser themselves."
- It was designed *after* most of Arc was built, by working backwards from what to teach.
- It borrows from game design: early easy wins (picking a gradient) before harder skills.
- Karla Cole wanted the opening to feel like a movie, with bold colour throughout.
- It ends with a personalised **Arc membership card**, framed as "joining a club".

**Screen sequence.** Pageflows recorded the macOS flow (version "August 2022"): 22 steps over about 4 minutes ([Pageflows](https://pageflows.com/post/mac-os/onboarding/arc/)):

| Time | Screen |
|---|---|
| 00:05 | Splash screen |
| 00:09 | Start screen |
| 00:13 | Sign up |
| 00:32 | Privacy policy |
| 00:40 | Sign up |
| 00:55 | Welcome |
| 00:59 | Import data |
| 01:12 | Select folders |
| 01:19 | Select color |
| 01:47 | Select favorites |
| 02:00 | Connect integration |
| 02:18 | Integration connected |
| 02:20 | Enable ad blocker |
| 02:24 | Set as default |
| 02:40 | Success |
| 02:52 | Welcome guide |
| 03:07–03:52 | New tab / Guide video / Create menu |
| 03:57 | Browser |

The copy on each screen is behind Pageflows' paywall.

**Reviewer descriptions:**
- A "90s-style splash screen" inviting you to "Meet the internet again". Also an ad-blocker invitation, mandatory account creation, and "pick a color during the setup process", which later becomes an organising tool. ([How-To Geek, Tim Brookes, May 1, 2023](https://www.howtogeek.com/887230/arc-browser-review/))
- A welcome screen saying "A browser for you" with a forward arrow. Account creation (free, required for sync), during which Arc previews Spaces on the right. Accept ToS/Privacy, import (Safari/Chrome/Firefox, or skip), search engine, default browser. ([ComputingForGeeks, updated May 28, 2026](https://computingforgeeks.com/install-arc-browser-macos-windows/))
- Setup covers importing, choosing a theme, making Arc default, opting into Arc's ad blocker and "adding some favorite apps", then "Get Started". ([allthings.how, Nov 9, 2023](https://allthings.how/how-to-use-the-arc-browser/))
- You pick an accent colour, then choose web apps you use often (Gmail, Notion…) and sign into them, so Arc puts them "front and center". ([search summary of popsci/computingforgeeks](https://www.popsci.com/diy/arc-browser-tips/))
- A UX write-up says Arc opens by "transforming your screen into a black hole with a fancy animation and sound". This comes from a search-result summary of a CMU UXA Notion page; I could not load the page itself.

**Arc release notes** (local copies in `research/_arcpages/`):
- 2022-07-28: "Arc Membership Cards are now in the Arc Preferences Pane! … view, download, or customize." 2022-06-02: "Updated look to the Arc Membership cards!" ([2022 notes](https://resources.arc.net/hc/en-us/articles/20498417809815-Arc-for-macOS-2022-Release-Notes))
- 2023-01-12: "We now support Dark Mode in our Sign Up flow."
- 2023-08-03: "You can now import multiple Profiles from a previous browser at once during Onboarding."
- 2023-09-14: "For new Arc members, we're automatically suggesting Favorites and Pinned Tabs based on imported navigation history."
- 2023-11-17: "Arc Max … can now be enabled during Arc onboarding."
  ([2023 notes](https://resources.arc.net/hc/en-us/articles/20498377604887-Arc-for-macOS-2023-Release-Notes))
- 2024-02-22: "Membership cards now display stickers to mark each anniversary." 2024-03-21: when importing a profile that had pinned extensions, "we'll be sure to pin those same extensions in Arc too." ([2024–2026 notes](https://resources.arc.net/hc/en-us/articles/20498293324823-Arc-for-macOS-2024-2026-Release-Notes))
- Arc for Windows, 2024-03-14: "Arc Membership cards will be available during onboarding"; "We've decreased the volume on the unboxing startup sound"; ToS/Privacy links added to the "Create an Account" page. ([Windows notes](https://resources.arc.net/hc/en-us/articles/22513842649623-Arc-for-Windows-2023-2026-Release-Notes))
- Import sources over time:
  - Aug 4, 2022: bookmarks from Chrome, Safari, Firefox, Brave and Edge.
  - July 21, 2022: history and logins from Brave and Edge.
  - Feb 23, 2023: Vivaldi and Opera, "your history, cookies, passwords, autocomplete payment info, and bookmarks".
  - So Arc itself imported **cookies** from other Chromium browsers.
- Arc Max onboarding (later) was a roughly 90-second interactive demo using progressive disclosure, with one-click fallback to Google. ([OnboardMe, Feb 7, 2025](https://onboardme.substack.com/p/how-arc-browser-introduces-ai-max-feature))

### 1.2 Reconstructed flow (merged; [I] where sources don't say)

1. **Splash/unboxing.** A full-screen animated colour moment with a startup sound (confirmed by the "unboxing startup sound" note). Its volume was later reduced.
2. **Start → Sign up** (name, email, password). Mandatory until the sunset. Spaces preview on the right as you type. Dark mode was added in Jan 2023.
3. **Welcome → Import data**: pick a browser, and since Aug 2023 several profiles at once. "Select folders" lets you choose which bookmark folders become pinned tabs. "Do this later" skips.
4. **Select color.** A gradient picker that gives an "early win". It themes the Space.
5. **Select favorites.** Pick the apps you use most (Gmail, Notion, …) and sign in. Later, these were auto-suggested from imported history.
6. **Connect integration** (2022 flow; [I] probably calendar/Gmail previews).
7. **Ad blocker** opt-in. **Arc Max** opt-in (Nov 2023+).
8. **Set as default**, which triggers the macOS system dialog.
9. **Success / membership card**: a personalised card, later downloadable and customisable, with anniversary stickers.
10. **Welcome guide in the real browser.** A guide video, the "Create" menu, and a new-tab demo. [I] Teaching the Command Bar (⌘T) and sidebar was here, but no source spells out an interactive "press ⌘T" step.

**Not confirmed:** whether sidebar position (left/right) was offered in onboarding. No source mentions it. Arc's sidebar could be moved to the right later in Settings (from memory, unverified).

---

## 2. How other browsers onboard (and what reviewers liked)

| Browser | Flow (order) | Notable details | Source |
|---|---|---|---|
| **Dia** (TBC, Arc successor) | Download → "which browser would you like to import from?" → choose extensions to install → done | When coming from Arc, it skips setup steps the import already handled (e.g. choosing pinned tabs) and switches to the sidebar layout. Each Space becomes a Profile "in the same order and colors". Favorites become icon-only pinned tabs. Folders become pinned Tab Groups, and nested folders are flattened. Custom names are kept. "bookmarks, history, passwords, cookies (so you stay signed in…), extensions and open tabs" come over. Excluded: payment methods and autofill. "Dia finds your Arc data through the Arc app, so keep Arc installed until your import finishes." On Windows a "Cookies file locked" message offers to close Arc. | [Move from Arc to Dia](https://resources.arc.net/hc/en-us/articles/44413129117591-Move-from-Arc-to-Dia) |
| **Zen** (Firefox fork) [code: `ZenWelcome.mjs`, last commit 2026-10-29] | Video-background title "Welcome to / a calmer internet" → **Import** ("Bring your stuff along.", with "NO, start fresh.") → **Workspace colours** ("Your space, your colors.") → **Search engine** → **Block ads?** (installs uBlock, skippable) → **Essentials** ("Choose the apps you use most."; Obsidian, Discord, Slack, GitHub, Notion, Google Calendar, Figma…) → **Default browser** ("YES, make Zen default." / "NO, still exploring my options.") → **Finish** ("All set? Let's get rolling!" / "Dive in!") | YES/NO buttons with bold copy. On finish, the browser chrome fades in from opacity 0. Chosen essentials are pinned, and the first tab goes into a "zen basics" folder. Reviewers praise the gradient/grain dial ([OMG Ubuntu](https://www.omgubuntu.co.uk/2025/08/zen-browser-is-what-mozilla-firefox-should-be/amp), [SlashGear](https://www.slashgear.com/1957695/why-people-are-switching-to-zen-web-browser)). Zen's Arc importer: Favorites become Essentials, Spaces become workspaces (emoji plus up to 3 colours), Arc profiles become containers (earlier research Q2). | [ZenWelcome.mjs](https://github.com/zen-browser/desktop/blob/HEAD/src/zen/welcome/ZenWelcome.mjs), [zen-welcome.ftl](https://github.com/zen-browser/desktop/blob/HEAD/locales/en-US/browser/browser/zen-welcome.ftl) |
| **Helium** (ungoogled Chromium) [code] | Welcome ("Use defaults" / "Configure") → Helium services consent → Search engine → **Data import** → Password manager (install an extension) → Default browser (skipped if already default or impossible) → Finish ("Let's go!") | Svelte WebUI at `chrome://setup` (`kHeliumSetupURL`). The import page first asks "Allow Helium to look for other browsers on this device", then lists browsers and profiles. On macOS ≥ 27 it shows "Don't see your previous browser? macOS protects some browsers from being automatically detected… allow Helium to access them in System Settings" and deep-links to Privacy & Security → Files & Folders. Imports bookmarks, history and extensions; **passwords and autofill are explicitly removed** (`disable-unsupported-importers.patch`). Arc's sidebar is imported as bookmarks. | `research/repos/helium-onboarding/src/lib/onboarding-flow.ts`, `helium_onboarding_strings.grdp`; `helium/patches/helium/core/onboarding-page.patch` |
| **SigmaOS** | On first install, "an option to migrate from another browser". Later: Lazy Search → "Migrate Browser" | For Arc it brings "spaces, favorites, pinned tabs, daily tabs", history, extensions, "cookies and logins". "You might be asked to enter your device password" (for cookie storage, i.e. Keychain [I]). Saved passwords need a separate CSV import. SigmaOS 1.18+. | [docs.sigmaos.com/arc](https://docs.sigmaos.com/arc) |
| **Comet** (Perplexity) | First launch offers import from Chrome/Edge/Safari/Firefox | A reviewer got "browsing history, cookies, credit cards, bookmarks, saved passwords, and extensions", but not open tabs or their grouping. Extensions can be deselected. eWeek called onboarding short; others report incomplete bookmark import. | [NanoBits](https://nanobits.beehiiv.com/p/i-switched-to-perplexity-comet-browser-for-a-week-is-it-really-worth-the-hype), [eWeek](https://www.eweek.com/news/comet-ai-browser/), [Tabbit review](https://go.tabbit.ai/comet-browser-review) (secondary, some vendor-biased) |
| **Chrome (upstream)** | `FirstRunService` → ProfilePicker in FirstRun mode → `chrome://intro` (welcome, sign-in promo, sign-in celebration, default-browser subpage, finish-or-continue) → search-engine choice in EEA | No import step on macOS by default. Auto-import from initial_preferences runs silently. | [code: `first_run_service.cc`, `webui_url_constants.h`, `chrome/browser/resources/intro/`] |

**What reviewers praise (synthesis):**
- Colour and personalisation early (Arc, Zen).
- Short flows with "start fresh" / "use defaults" escape hatches (Helium, Zen).
- Imports that keep you signed in (Dia, SigmaOS, Comet).
- Being shown rather than told (Arc Max).

**What they criticise:**
- Arc's mandatory account.
- Incomplete imports (Comet bookmarks; Dia flattening nested folders).
- Unclear Keychain prompts ([Mozilla bug 1675448](https://bugzil.la/1675448): "It's not obvious for the user how to respond to the keychain prompts").

---

## 3. Recommended onboarding (under 2 minutes, all skippable)

### 3.1 Principles
- **Show the user's own stuff immediately.** The first meaningful frame is their Arc sidebar rebuilt live, not a marketing slide ([I]; extends Arc's "early win" idea).
- **Import in the background.** Sidebar parsing is instant. History, cookies and extensions run during later screens, with a progress pill in the corner.
- **No account.** There is nothing to sign up for. Google sign-in happens *per Space on the web*, not as browser sign-in. Forks cannot use Chrome Sync or Google's private APIs: Google [limited private API availability in Chromium](https://blog.chromium.org/2021/01/limiting-private-api-availability-in.html) (2021).
- **Explain every OS prompt before it appears** (Keychain, Files & Folders, default browser). Use a short "macOS will ask…" line with a picture of the dialog, as Helium's permission notice does.
- **Adaptive.** Skip or collapse steps already answered by the import (Dia pattern). Skip the default-browser step if the fork is already default (Helium pattern).
- **Every screen** has a primary action and a quiet "Skip". The first screen also has "Use defaults".

### 3.2 Screens

| # | Screen | Purpose / UI | Copy ideas | Time | Skip? |
|---|---|---|---|---|---|
| 0 | **Unboxing** (native, full window) | 2–3 s animation: the wordmark draws on, then a gradient blooms in the user's macOS accent colour. A soft chime plays only if UI sounds are enabled; offer a mute toggle. Any key skips. | — | 3 s | auto |
| 1 | **"Bring your Arc with you"** | Auto-detects `~/Library/Application Support/Arc/StorableSidebar.json`. A miniature sidebar animates in: each Space slides in with its emoji and colour, then the Favorites grid fills. A counter line reads "6 Spaces · 3 profiles · 12 Favorites · 84 pinned tabs". Buttons: **Import everything** (primary), "Choose what to import…", "Start fresh". If Arc is not found, list Chromium browsers found (Chrome, Dia, Brave, Edge, Vivaldi, Comet…) plus Safari and Firefox. | "Arc stops working on Dec 22. Everything you built there comes with you: Spaces, pins, folders, Favorites and logins." | 10 s | yes |
| 1a | *(macOS ≥ 27, only if access is denied)* **Allow access** | Priming card, then the system prompt or a deep link to Privacy & Security → Files & Folders. After that, a "Check again" button. | "macOS keeps each browser's data private. Allow access to Arc once so we can copy it. Nothing leaves this Mac." | 5 s | yes (falls back to sidebar-only import from a user-picked file) |
| 2 | **Spaces & accounts** | A table: each Arc profile becomes a new profile, with its Spaces as chips. For each profile, the Google accounts found in its cookie jar appear as avatars ([I]: query `accounts.google.com/ListAccounts` inside that profile after cookie import; verify). For Spaces that share one Arc profile, a toggle: **"Give this Space its own profile"**. This is the user's "different Google account per Space" goal. A Space without a Google account shows **"Sign in with Google"**, which opens an inline sheet with accounts.google.com in that Space's profile. | "Each Space keeps its own logins. Want Work to use a different Google account? Give it its own profile." | 25 s | yes |
| 2a | **Keychain priming** (right before the import starts reading cookies/passwords) | Shows what the macOS dialog will look like, recommends **Allow** (one-time) rather than Always Allow, and offers a "Skip logins" fallback that imports everything except cookies and passwords. | "To keep you signed in, macOS will ask for your Mac password once to unlock Arc's saved logins. We decrypt them on this Mac and re-lock them with our own key." | 10 s | yes |
| 3 | **Make it yours** | Per-Space colour picker, pre-filled from Arc's `windowTheme` (gradient plus grain/intensity). Light/Dark/Auto. **Sidebar left/right**. The real window behind the sheet re-tints live as you drag (instant gratification). For Arc imports this collapses to a "Looks right?" confirm with an "Edit colours" expander. | "Your Spaces, your colours." | 15 s | yes |
| 4 | **Learn by doing** (coach marks in the real browser, not slides) | Four tasks, each finishing with a small confetti tick and a trackpad haptic ([I] `NSHapticFeedbackManager`): (1) **⌘T** opens the Command Bar, type "gmail". (2) **⌃1/⌃2** or a two-finger swipe switches Space, and the avatar shows the account changing. (3) **⌘S** hides and shows the sidebar. (4) Drag a tab above the divider to pin it. Arc importers also see a "Your Arc shortcuts still work" card listing remaps. | "Try it: press ⌘T." | 30 s | "I know Arc, skip" |
| 5 | **Default browser** | One sentence, then the button triggers the macOS confirm dialog. Skipped if already default. Shows "Not now" without nagging; a single later infobar with "Don't ask again" (Helium adds a reject button to Chrome's infobar). | "Make [Name] your default? Arc goes dark on Dec 22, so links from Mail and Slack should open here. macOS will ask you to confirm." | 10 s | yes |
| 6 | **Finish / card** | A personal card (name, Space emojis, today's date, "#member since"), a nod to Arc's membership card. The browser chrome fades in behind it (Zen-style opacity animation). A background-import summary appears as a toast, with a link to the import report (anything skipped, e.g. Easels or Boosts). | "Welcome home." / "Dive in" | 5 s | — |

**Total** is about 1:50 with everything, about 30 s with "Import everything → Skip → Skip → Done". Import keeps running after Finish if needed. History is usually the slowest part ([I]).

### 3.3 Edge cases
- **Arc still running.** On macOS the SQLite files are usually readable through a copy (Brave's `ScopedCopyFile`). Copy them first. If a copy fails, offer "Quit Arc and continue", as Dia does on Windows.
- **Arc uninstalled.** The data folder may survive. On macOS 27, though, an app apparently cannot even *request* Files & Folders access to another browser's folder unless that browser is installed ([AdGuard KB](https://adguard.com/kb/adguard-for-mac/solving-problems/browser-assistant-macos-27/)). That is a plausible reason Dia says "keep Arc installed until your import finishes" ([I]). Fallback: a file picker for `StorableSidebar.json` and the Arc folder (Zen's migrator has the same "select folder" fallback, `_getPermissionFolder`).
- **Re-run later.** Settings → Import from Arc… Import is idempotent per Space (key on the Arc Space id), so it can be re-run without creating duplicates.
- **Snapshot now.** Offer a one-click "Back up my Arc data" that zips `StorableSidebar.json`, `StorableArchiveItems.json`, `StorableWindows.json` and `User Data/Local State` into `~/Documents` ([I]). This protects against post-Dec-22 surprises.

---

## 4. Import mechanics

### 4.1 Arc's on-disk layout (macOS)

| Path under `~/Library/Application Support/Arc/` | What | Notes |
|---|---|---|
| `StorableSidebar.json` | Spaces, pinned tree, Today, Favorites (`topAppsContainerIDs`, one root per Chromium profile), theme, emoji | Swift-Codable flat key/value arrays. Full schema in earlier research Q1. |
| `StorableArchiveItems.json` | Archived tabs (`reason` auto/manual, `source.space._0`) | Not read by `arcImport.ts`. |
| `StorableWindows.json` | Open windows/tabs | Not read by any parser I checked. |
| `User Data/Local State` | `profile.info_cache`, giving each profile's display name and avatar | Same format as Chrome. Helium, Brave and Zen read the profile list from here [code]. |
| `User Data/<Default \| Profile N>/` | One normal Chromium profile per Arc profile: `History`, `Cookies` (now under `Network/`) [I: standard Chromium layout], `Login Data`, `Web Data`, `Bookmarks` (usually empty for Arc), `Preferences`/`Secure Preferences` (extension list at `extensions.settings`), `Extensions/`, `Local Extension Settings/`, `IndexedDB/`, `Local Storage/`, `Favicons` | Arc profile ⇄ Chromium profile directory is confirmed. The Space→profile link is `space.profile` = `{"default":{}}` or `{"custom":{"_0":{"directoryBasename":"Profile 1"}}}` (earlier research Q1; Zen, Ardia). Helium's `ChromeImporterCanImport` for TYPE_ARC finds `StorableSidebar.json` at `profile.DirName().DirName()` [code]. |
| Keychain: service **"Arc Safe Storage"**, account **"Arc"** | AES key password for cookies, passwords and other encrypted fields | Zen's `ArcProfileMigrator` sets `_keychainServiceName = "Arc Safe Storage"; _keychainAccountName = "Arc"` [code: `zen_snips/arc_browser_migrator.patch`]. Chromium's defaults are "Chrome Safe Storage"/"Chrome" and "Chromium Safe Storage"/"Chromium" [code: `components/os_crypt/common/keychain_password_mac.mm`]. |

**Automatic profile mapping algorithm** ([I], built from the facts above):
1. Read `Local State` → `profile.info_cache` to get a list of `{dir, name, avatar}`.
2. Create one fork profile per Arc profile dir that has at least one Space or Favorite. Name it from `info_cache` (fall back to the Space names). Store `arc_profile_dir` on the profile for idempotent re-import.
3. For each Space in file order, create a fork Space bound to `forkProfile[space.profile]`, with name, emoji, colour/gradient, pinned tree and Today.
4. Favorites: **keep them per profile** (Arc semantics: "Spaces sharing a profile will share the same Favorites"). The existing `applyArcImport` merges them into one global row, which suited the Chrome extension but is wrong for the fork.
5. The optional "split Space into its own profile" toggle creates a fresh profile. It can either copy the shared profile's data (cookies included), after which the user signs out of the unwanted account, or start empty with a Google sign-in. Empty is cleaner; offer copy as an advanced option ([I]).

### 4.2 Sidebar import: what `arcImport.ts` already covers

The prototype extension's `src/shared/arcImport.ts` (not in this repo; 392 lines, read in full) handles:
- Main-container detection: the `global` key, then the first container with `items` that does not follow `littleBrowser`.
- Generic `pairs()` for string or object keys.
- Spaces: name ("Personal"/"Space N" fallbacks), emoji (`emoji_v2`, integer code point, or a named icon mapped to an emoji), colour (`primaryColorPalette.midTone`, else the first colour found), and the profile dir.
- Section roots from both `containerIDs` and `newContainerIDs`.
- The pinned tree with folders. Children are ordered by `childrenIds`, with a fallback to `parentID`.
- Split views and stray containers are flattened in place. Easels are skipped with a warning.
- Today tabs are flattened.
- Favorites per profile, with a fallback to the `sidebarSyncState` mirror.
- Custom title vs page title.
- A cycle/visited guard and a depth cap of 64.

**Gaps to fill for the fork:**
- Per-profile Favorites in `apply`.
- Full gradient fidelity: multiple `baseColors`/`overlayColors`, `intensityFactor`, noise. Zen keeps up to 3 colours.
- Preserving split views as split views, if the fork has them.
- GitHub live-folder flag (`automaticLiveFolderData`).
- `timeLastActiveAt`, for auto-archive and ordering.
- `StorableArchiveItems.json`.
- Profile display names from `Local State`.
- Open windows from `StorableWindows.json`.

Folder collapsed state and custom icons are not known to be stored (earlier research gaps).

**Implementation note** ([I]): the onboarding is a WebUI, so the TypeScript parser can run *as is* in the page. The C++ handler reads the file (respecting TCC) and passes the JSON. Only the "apply" step needs C++/mojo calls into the fork's Space model.

### 4.3 Chromium profile data: two strategies

**A. Importer API** (Brave/Helium style, utility process → `ImporterBridge`). This works for history (Brave's `ChromeImporter::ImportHistory` runs `SELECT … FROM urls JOIN visits` on a copied DB), bookmarks, favicons, search engines, and extensions (re-installed from the Web Store by ID, plus `Local Extension Settings` and extension IndexedDB copied over [code: Brave `extensions_import_helpers.cc`]). It does **not** carry cookies, site storage, permissions or service workers. Upstream `ImportItem` has no working COOKIES bit.

**B. Profile transplant** ([I], recommended for Arc → fork when the Chromium majors are close; Arc 1.171 is on Chromium 156, and Helium today is 156.0.8078.79):
1. Copy the whole Arc profile directory into the new fork profile directory, minus caches.
2. Re-key every encrypted column: Cookies `encrypted_value`, Login Data `password_value`, Web Data card numbers and IBANs (optional; Dia skips them).
3. Delete `Secure Preferences` MACs, or rebuild prefs selectively. Chromium's tracked-preference protection is seeded per install, so foreign MACs would reset prefs [I].

What it buys: localStorage and IndexedDB logins (Slack, Notion, Linear and many SPAs keep tokens there), site permissions, extension state, HSTS and history in one go.

Risks:
- DB schema version skew. Chromium migrates *up* but refuses *newer* schemas, so the fork must be at or above Arc's Chromium.
- Arc-specific prefs.
- A larger blast radius if something goes wrong.

Mitigations: do it only into a fresh profile, and keep strategy A as the fallback.

| Data | Strategy A | Strategy B | Notes |
|---|---|---|---|
| Sidebar (Spaces/pins/folders/Favorites/Today) | custom (`arcImport`) | custom | Not in any Chromium importer. Helium flattens it into bookmarks [code]. |
| History | ✓ (`SetHistoryItems`) | ✓ (copy `History`) | |
| Bookmarks | ✓ | ✓ | Usually empty in Arc. |
| Favicons | ✓ | ✓ | |
| Cookies (stay signed in) | ✗ upstream; custom decrypt/re-encrypt via `network::mojom::CookieManager::SetCanonicalCookie` [I] | ✓ after re-keying | Needs "Arc Safe Storage". See 4.4. |
| Passwords | custom (Brave does it only Brave→Brave Origin, because they share a Keychain entry [code + commit msg]) | ✓ after re-keying | Helium removes PASSWORDS entirely. SigmaOS asks for a CSV. Dia imports them. |
| Payment cards / autofill | optional | optional | Dia excludes them, a sensible default. |
| Extensions | ✓ re-install by ID plus copy settings | ✓ (files) but re-validate | Arc pins → toolbar pins (Arc does this). |
| localStorage / IndexedDB / site settings | ✗ | ✓ | Big part of "still signed in". |
| Open tabs | from `StorableWindows.json` | same | Dia imports open tabs. |
| Archive | `StorableArchiveItems.json` | same | Optional "Archived from Arc" view. |

### 4.4 Encryption details (macOS)

- **Key derivation** [code: Chromium `components/os_crypt/async/browser/keychain_key_provider.mm`]:
  - The Keychain generic password (service "<Brand> Safe Storage") is run through PBKDF2-HMAC-SHA1 with `kIterations = 1003`, salt `"saltysalt"`, and a 16-byte key, giving AES-128-CBC.
  - Ciphertexts are prefixed with tag `"v10"`. The IV is 16 spaces, per third-party decoders such as [HTTP::Cookies::Chrome](https://metacpan.org/pod/HTTP::Cookies::Chrome) and [unjar](https://docs.rs/crate/unjar/0.1.0/source/src/chromium.rs); I did not check the Chromium line.
- **Cookie DB v24** [code: `net/extras/sqlite/sqlite_persistent_cookie_store.cc`]: "Version 24 adds a SHA256 hash of the domain value to front of the" plaintext (2024-08-15). `kCurrentVersionNumber = 24`. Importers must strip and verify the first 32 bytes, and re-add them when writing raw rows (strategy B).
- **App-Bound Encryption (v20)** is Windows-only [I, from general knowledge]. macOS still relies on the Keychain ACL.
- **Prompt.** Reading another app's "Safe Storage" item triggers the standard macOS dialog "<App> wants to use your confidential information stored in '<X> Safe Storage' in your keychain" (Allow / Always Allow / Deny), after the user's login password. "Allow" lasts only the session; "Always Allow" adds the app to the item's ACL ([Opera forum](https://forums.opera.com/post/147472), [Brave support](https://support.brave.app/hc/en-us/articles/360054193112-Why-is-Brave-asking-to-use-the-confidential-information-in-my-Keychain-macOS), [Vivaldi forum](https://forum.vivaldi.net/topic/9115/vivaldi-trying-to-use-confidential-data-form-chrome-safe-storage)). For a one-off import, recommend **Allow**. [I] An "Always Allow" ACL entry is tied to the app's code signature, so unsigned dev builds will be re-prompted after every rebuild.
- **Who already does this:**
  - Firefox's Chrome migrator reads "Chrome Safe Storage" (`ChromeMacOSLoginCrypto`; see [bug 1675448](https://bugzil.la/1675448)).
  - Zen's Arc migrator uses "Arc Safe Storage" for passwords.
  - SigmaOS warns "you might be asked to enter your device password" for cookies.
  - Dia keeps you signed in.
  - Arc imported cookies from Vivaldi and Opera (2023).
  - Comet reportedly imports cookies.
  - Safari's File → Import From → Google Chrome imports passwords into iCloud Keychain and "Chrome must be installed" ([Apple](https://support.apple.com/en-in/guide/safari/ibrw1015/15.1/mac)).

**Will Google sessions survive the move?**
- They mostly should today on macOS ([I]).
- Google's **Device Bound Session Credentials** (DBSC) binds Google session cookies to a device key in secure hardware, so copied cookies stop refreshing.
- DBSC is GA in Chrome on **Windows** (rollout from May 25, 2026) and covers personal and Workspace accounts. Google says it is "expanding to macOS in an upcoming Chrome release" ([Workspace Updates](https://workspaceupdates.googleblog.com/2026/05/prevent-account-takeovers-with-DBSC-now-generally-available-in-the-Chrome-browser-for-Windows.html), [Help Net Security](https://helpnetsecurity.com/2026/04/10/google-chrome-device-bound-session-credentials)).
- Whether Arc (Chromium 156) registers DBSC sessions is unknown. If it does, imported Google cookies will die quickly.
- **Design consequence:** always verify each profile's Google login after import (ListAccounts, [I]) and show "Sign in again" inline if it fails. Plan per-Space Google sign-in as a first-class step, not an afterthought.

### 4.5 macOS 27 Files & Folders protection

- "macOS 27 restricts cross-app folder access by default and requires explicit permission." Access is granted per browser under System Settings → Privacy & Security → Files & Folders. Full Disk Access works but is "a last-resort measure". macOS won't let an app request access to a browser's folder unless that browser is installed ([AdGuard KB](https://adguard.com/kb/adguard-for-mac/solving-problems/browser-assistant-macos-27/)).
- BrowserFairy also needs a per-browser toggle to read profiles on macOS 27, without Full Disk Access ([BrowserFairy](https://www.browserfairy.com/de/blog/macos-27-zugriff-auf-browserordner)).
- Helium shows `showMacImportPermissionNotice` only when `MacOSMajorVersion() >= 27`, and adds `SystemSettingsPane::kPrivacySecurity_FilesAndFolders` with `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders` [code: `onboarding-page.patch`].
- Brave's importer shows a Full Disk Access dialog on macOS (for Safari) [code: `brave_full_disk_access_confirm_dialog_delegate_mac.mm`]. Upstream Chromium's Safari importer only offers bookmarks, and only if `~/Library/Safari/Bookmarks.plist` is readable [code].
- **Gap:** Apple's own documentation of the macOS 27 rule, and the exact wording of the system prompt, which I did not find.

### 4.6 Chrome → fork, and the state of browser importers

**Upstream Chromium on macOS** [code: `chrome/browser/importer/importer_list.cc`, `safari_importer_utils.mm`, `importer_type.h`]:
- Detects **Safari** (bookmarks only; history import was removed) and **Firefox** (history, bookmarks, autofill form data; passwords are disabled on Mac because "Restrictive code signing prevents [loading NSS] from ever working again in modern macOSes").
- Offers **Bookmarks HTML file**.
- Has **no Chrome/Chromium-family importer**. `ImporterType` only has IE, Firefox, Safari, Bookmarks file and Edge (legacy, Windows).
- `ImportItem::COOKIES` is "Not supported yet".
- Upstream also auto-imports on first run from initial_preferences (`first_run::AutoImport`). ungoogled and Helium remove this (`iridium-browser/browser-disable-profile-auto-import-on-first-run.patch`).

**Brave** adds a Chromium-family importer (MPL-2.0) [code: `brave_snips/`]:
- macOS paths for Chrome (Stable/Beta/Dev/Canary), Chromium, Edge, Vivaldi, Opera, Yandex, Whale and Brave. No Arc in upstream brave-core's mac path list as fetched today.
- Imports history, bookmarks, favicons, and extensions with their settings.
- Passwords only Brave→Brave Origin on Mac/Linux, because "Only Brave-to-Brave imports share the OS keychain entry needed to decrypt the source's `Login Data`" (commit 2026-08-08).

**Helium** (GPL-3.0) vendors Brave's importer:
- Adds Arc, Dia and Perplexity Comet as TYPE_ARC/TYPE_DIA/TYPE_PERPLEXITY_COMET.
- Adds `ArcSidebarImporter`, which turns Favorites into toolbar bookmarks and each Space's pinned tree into a bookmark folder. It assumes `containers[1]`, takes only the first topApps root, and does not appear to filter Spaces per Arc profile [code: `add-arc-importer.patch` lines 256–353].
- Adds a Zen importer.
- Strips passwords and autofill.

**Who imports Arc Spaces as Spaces (Nov 2026):**

| Product | Spaces → | Favorites | Pinned folders | Today | Logins/cookies | Profiles |
|---|---|---|---|---|---|---|
| Dia | Profiles (same order, colours) | icon pinned tabs | Tab Groups (nested ones flattened) | open tabs | ✓ | Spaces from one Arc profile share data |
| Zen | Workspaces (emoji, ≤3 colours) | Essentials | ✓ (≤5 subfolder levels) | ✗ | passwords via Keychain; no cookies [I] | Arc profiles → containers |
| SigmaOS | "spaces" (mapping undocumented) | ✓ | ✓ | "daily tabs" ✓ | cookies ✓, passwords via CSV | not documented |
| Helium | bookmark folders | toolbar bookmarks | ✓ | ✗ | ✗ | no |
| Nook / Ardia (open source, GPL) | Spaces | ✓ | ✓ | ✓ | not checked | profile field parsed |
| **This fork (proposed)** | Spaces bound to profiles | per-profile Favorites | full nesting | Today plus archive | ✓ (Keychain) | automatic 1:1, optional split |

Gaps: Vivaldi's and Edge's handling of Arc is not researched. Comet's Arc support is not confirmed.

---

## 5. Chromium first-run hooks and default browser (macOS)

**First run:**
- **Detection:** `first_run::IsChromeFirstRun()` checks for a `First Run` sentinel file in the user-data dir (`CreateSentinel`, `IsFirstRunSentinelPresent`) [code: `chrome/browser/first_run/first_run.cc`]. Switches: `--no-first-run`, `--force-first-run`.
- **Distribution customisation:** `initial_preferences` (formerly master_preferences) with `distribution` keys such as `skip_first_run_ui`, `import_bookmarks` and `make_chrome_default_for_user` ([First Run Customizations](https://www.chromium.org/developers/design-documents/first-run-customizations/)). Useful for MDM or test builds.
- **`FirstRunService`** [code: `chrome/browser/ui/startup/first_run_service.cc`]:
  - `ShouldOpenFirstRun` = `IsFirstRunEligibleProcess() && IsFirstRunEligibleProfile()`.
  - `OpenFirstRunInternal` calls `ProfilePicker::Show(ProfilePicker::Params::ForFirstRun(...))`, which hosts **`chrome://intro`** with subpages `welcome`, `default-browser`, `sign-in-celebration` and `finish-or-continue` [code: `webui_url_constants.h`; `chrome/browser/resources/intro/`].
  - The old standalone `chrome://welcome` host no longer appears in `webui_url_constants.h` ([I]: retired in favour of the intro subpage).

**How Helium hooks its own onboarding** [code: `onboarding-page.patch`]:
1. Make `IsFirstRunEligibleProcess()` return false ("Helium uses its own onboarding").
2. Register profile prefs `helium.completed_onboarding` and `helium.services.user_consented`.
3. In `StartupBrowserCreatorImpl::DetermineStartupTabs`, if the profile is not incognito/guest, `--no-first-run` is absent and onboarding isn't done, open `kHeliumSetupURL` as the only startup tab.
4. The new WebUI `HeliumOnboardingPage` reuses stock handlers: `SearchEnginesHandler`, `DefaultBrowserHandler` and `BraveImportDataHandler`, plus its own `OnboardingMessageHandler` for prefs, profile name, extension install and the Files & Folders pane. The UI is a separately versioned Svelte bundle (`helium-onboarding`, pulled via `deps.ini`).

**Recommendation for this fork** ([I]):
- Use the same pref-gated hook, *per profile*. New profiles created later get a 20-second mini-onboarding (colour, Google sign-in), not the full flow.
- Host the WebUI in a **chromeless, full-size window**: a native `NSWindow` with a `WebView`/`views::WebView` and no toolbar. Then the unboxing animation and the "chrome fades in" finale are possible. A normal tab cannot animate the browser frame.
- Keep `--no-first-run` support for tests.

**Default browser** [code: `chrome/browser/shell_integration_mac.mm`]:
- Chromium calls `[NSWorkspace setDefaultApplicationAtURL:… toOpenURLsWithScheme:@"http" completionHandler:]`, then `https` **only if http succeeded**. If the user declined ("Keep Safari"), asking for https would "result in the user being prompted a second time (https://crbug.com/496408111)".
- On **macOS 26.4+** it skips `toOpenContentType:UTTypeHTML`, because it "triggers a separate Finder confirmation dialog… resulting in duplicate prompts".
- It activates `com.apple.coreservices.uiagent` so the confirmation dialog isn't hidden behind the browser window.
- The OS dialog is mandatory. It is a Launch Services protection that cannot be suppressed by apps ([ctrl.blog](https://www.ctrl.blog/entry/osx-protect-default-browser/)).
- `LSSetDefaultHandlerForURLScheme` is the older, deprecated API. Jamf notes that new APIs arrived in macOS 12 ([Jamf](https://community.jamf.com/tech-thoughts-180/managing-the-default-browser-in-macos-53418)). Use the NSWorkspace path that Chromium already ships.
- The onboarding WebUI can reuse `settings::DefaultBrowserHandler`, as Helium does: `requestDefaultBrowserState` / `setAsDefaultBrowser` and the `browser-default-state-changed` event, for live UI updates when the user confirms.

---

## 6. Legal and safety notes

This is not legal advice. Points marked [I] are reasoning.

1. **Consent and locality.** Every mainstream browser imports a competitor's data, including encrypted passwords and cookies, with user consent: Safari from Chrome, Firefox from Chrome, Arc from Vivaldi and Opera, Dia, SigmaOS and Comet from Arc and Chrome. The OS-level gates (Keychain ACL prompt, macOS 27 Files & Folders) are the consent record. [I] Keep everything on-device. Never transmit imported data or telemetry about its contents. Decrypt in the browser process (Brave moved password decryption there for OSCryptAsync). Write no plaintext to disk, delete temporary DB copies, and zero buffers.
2. **Looks like an infostealer.** The same technique (read "… Safe Storage" from the Keychain, decrypt cookies with PBKDF2/AES-128-CBC) is the core of macOS stealers such as Atomic/AMOS, which explicitly target Arc ([Sophos](https://www.sophos.com/blog/why-amos-matters-the-macos-malware-stealing-data-at-scale), [Cyble](https://cyble.com/blog/uncovering-atomic-stealer-amos-strikes-and-the-rise-of-dead-cookies-restoration/)). [I] Expect EDR/XProtect-style heuristics to be sensitive. Ship notarised, sign consistently, trigger the access only from an explicit user action, and say exactly what is read and why before the OS prompt appears.
3. **Copyright and anti-circumvention** ([I]). Decrypting the user's *own* cookies and passwords with a key the user releases from their own Keychain is interoperability over user data, not access to a copyrighted work. The risk looks low, but it has not been reviewed by counsel. The Browser Company's ToS were not checked (gap).
4. **Google and site terms** ([I]). Moving your own session cookies between your own browsers is routine. Google may still re-challenge or sign out sessions it sees as moved (DBSC on Windows already prevents reuse). Design for re-sign-in.
5. **Licensing of reference code:**
   - Brave's importer files are MPL-2.0 (file-level copyleft). Keep the headers, and publish modifications to those files.
   - Helium's patches and onboarding are **GPL-3.0**. Copying them makes the fork GPL-3.0. Re-implement from the behaviour described here instead.
   - Zen is MPL-2.0. Chromium is BSD.
   - `arcImport.ts` is your own code.
   - Earlier research lists MIT-licensed Arc parsers usable as references (ivnvxd, arcaeologist, rafcabezas, Icesource, arcmark).
6. **Least data.** Default off: payment cards and autofill (Dia excludes them too). Default on: history, bookmarks, extensions, cookies, passwords, each with a visible checkbox in "Choose what to import…".

---

## 7. Gaps and open questions

- **Arc onboarding copy.** I have no verbatim screen copy apart from "A browser for you", "Meet the internet again" and the membership card. I also could not confirm whether the tutorial taught ⌘T/⌘S interactively, or whether sidebar position was offered. The Pageflows flow (Aug 2022) is paywalled. YouTube transcripts were not retrieved.
- **The CMU UXA "black hole animation and sound" description** comes from a search summary only. The sound itself is confirmed by Arc's Windows release note.
- **macOS 27 Files & Folders.** No Apple documentation found. The prompt text, and whether a non-sandboxed Chromium app reading `~/Library/Application Support/Arc` is blocked or prompted, are not verified. Needs a test on macOS 27.
- **DBSC in Arc/Chromium 156 on macOS.** Unknown whether Arc's Google cookies are device-bound. Needs testing.
- **Google ListAccounts in a fork** without Google API keys. Unverified, though it is commonly used by Chromium's `GaiaCookieManagerService`.
- **Profile transplant** (strategy B). Untested. Particular risks: Secure Preferences reset, extension IDs and state, and schema skew if Arc's Chromium is newer than the fork's.
- **Where Arc stores the sidebar-position setting** (left/right) and theme light/dark variants. Unknown.
- **Edge/Vivaldi Arc import** and **Comet's Arc import.** Not researched or confirmed.
- **Dia's exact cookie and password mechanism.** Undocumented beyond "keep Arc installed".

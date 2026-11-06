# Track: what to fork, and how to structure the fork so it stays maintainable

Research date: 2026-11-03. Chrome stable is 156.0.8078.80, beta is 157, and canary is 158.

Conventions: **[inference]** marks my reasoning, not a sourced fact. **[measured]** marks numbers I computed from public APIs or repos during this session. Repos read locally (read-only, nothing built) are in `research/repos/`: `helium`, `helium-macos`, `ungoogled-chromium`, `ardia`, `flecha`.

---

## 0. Summary and recommendation

**Base for v1:** fork upstream Chromium stable tags directly (BSD-3). Put all our code in its own top-level directory, `//arcfork/` (placeholder name), modeled on `//brave/`. Keep a short, strict, quilt-style patch series of hooks, one concern per patch. Do not stack on Helium or ungoogled-chromium for v1. Treat them as references: read their patches, and copy individual BSD-licensed ungoogled-chromium patches only when needed.

**UI for v1:** build the sidebar in native Views C++, not WebUI. It fills the slot Chrome's own vertical tab strip fills today. It reuses Chrome's `TabStripModel`, tab collections, and the collapse, hover-expand and resize machinery that the 2026 vertical tabs added. Use WebUI (Lit, preloaded "top-chrome" pages) only where a few hundred milliseconds of latency doesn't matter: onboarding, settings, the Space editor, and possibly the command bar.

**Hardest design decision, and it is architectural, not cosmetic:** making Spaces real Chromium profiles inside one fullscreen window. A Chrome `Browser`/`BrowserView` belongs to exactly one profile. In macOS native fullscreen every window gets its own Space, so a "one window per profile" design switches with a slow Space-slide animation. Three ways out are covered in §3.6. My v1 pick is profile windows swapped in place under a custom (non-native) fullscreen, prototyped in week 1. If that fails, the fallback is Ardia's "several Browsers in one NSWindow" host.

**Shortcut worth evaluating this week:** two open-source Arc-style Chromium forks for macOS appeared in 2026.
- **Ardia** (GPL-3.0/Apache-2.0): Helium base plus a native React Native macOS shell. It is on Chromium 156 and is maintained by one developer with AI agents in a T3 workflow.
- **Flecha** (MIT): upstream Chromium plus 45 patches and a TypeScript "shell" extension. It already ships Favorites, pinned-with-folders, Today, Spaces and Arc import.

Either could cover the Dec 22 cutoff while ours is built, or become the fork base (§1.9).

Why upstream rather than Helium:
1. The rebase surface is ours alone. We don't have to rebase across Helium's 370 patches, which edit the same `frame/` and `tabs/` files we would.
2. There is no lag on a dependency chain. Helium already takes 1–3 days, and Ardia, which sits on Helium, adds about 2 more.
3. A permissive license keeps later options open (accounts, closed components).
4. Helium's own `AGENTS.md` tells AI agents to refuse all code work in its tree, which is a real obstacle for an agent-maintained fork that vendors it.

Key risks:
- Chrome now ships a milestone every 2 weeks, plus weekly security updates.
- The UI files we must touch churn heavily: `browser_view.cc` had about 387 commits in the last 12 months.
- A macOS build host is required, and a full official build takes hours.
- Widevine/Netflix is effectively out of reach without a commercial VMP certification.
- Google Sync and browser sign-in are unavailable.

---

## 1. Base options

### 1.1 Comparison table

| Base | License (what it forces) | Patch method | Security-update lag (evidence) | Team | macOS | Reusable vertical tabs/sidebar code |
|---|---|---|---|---|---|---|
| **Upstream Chromium** | BSD-3 plus third-party notices; closed additions allowed | We choose | 0 + our build time | Google | Yes | **Chrome's native vertical tabs (Views, BSD)**, see §3.1 |
| **ungoogled-chromium** | BSD-3 | Quilt `patches/series` (110 entries), domain substitution, pruning lists | Patch repo: same day. **macOS binaries: 4–9 days, whole milestones skipped** [measured] | Volunteers | Separate volunteer repo `ungoogled-chromium-macos` | None (flags only) |
| **Helium** (imputnet) | **GPL-3.0** for Helium-original code; inherited u-c parts stay BSD | Quilt-style `patches/series`, 370 entries (256 own, 71 u-c, plus Brave/Bromite/Debian/Inox/Iridium), about 91.6k lines | **About 19–76 h after Chrome, median about 35 h** [measured] | Small core (wukko, dumbmoron) plus u-c alumni | Primary platform | GPL patches on top of Chrome's vertical tabs, a "zen mode" auto-hide, compact layout, an Arc importer |
| **Brave (brave-core model)** | MPL-2.0, file-level: changed MPL files stay MPL, new files can use any license | `//brave` tree plus `chromium_src` overrides (2,099 files) plus `patches/` (1,311 files) | **About 7–13 h** [measured, channel ambiguity] | Company scale | Yes | Own Views vertical tabs and sidebar (MPL) |
| **Thorium** | BSD-3 | Copies modified Chromium files | **Months**: stable stuck on M138 into Feb 2026, then "beta" builds only | 1 developer | Separate repo | None relevant |
| **BrowserOS** | **AGPL-3.0** plus a CLA | Per-file patch tree `chromium_patches/<path>`, a features YAML, u-c series | HEAD is on 155.0.8059.26 while stable is 156.0.8078.80 (≥1 milestone behind) | Startup | Yes | AI-agent features, no Arc sidebar |
| **Supermium** | No license file in repo | Several large `.patch` files | On 150.0.7871.255 while Chrome is on 156 | 1 developer | **Windows only** | N/A |
| **Ardia** | Distributed as GPL-3.0 because of Helium; its own files are Apache-2.0; has a CLA | Helium + 64 own patches (about 9.7k lines) + `//ardia/core` layer, strict `series.py check` | 156.0.8078.79 about 2 days after Chrome; .47 about 5 days | 1 developer + AI agents | **Only** (Apple Silicon, macOS 14+) | **Full Arc-style sidebar**, but in a React Native macOS shell, not Views |
| **Flecha** | MIT | Upstream + 45 patches (about 6.7k lines) + a TS "shell" component extension | Tracks **158.0.8119.0**, a canary/trunk build, not a stable tag | 1 developer | Only (arm64 + x64) | **Arc sidebar in TS** (Favorites, pinned + folders, Today, Spaces), rendered in a WebView frame |

### 1.2 Upstream Chromium

- Chrome's 2026 vertical tabs live upstream, under BSD, as native Views: `chrome/browser/ui/views/frame/vertical_tab_strip_region_view.{h,cc}`, `chrome/browser/ui/views/tabs/vertical/`, and `chrome/browser/ui/views/tabs/common/` — [Gitiles: views/tabs](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/views/tabs/), [views/frame](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/views/frame/). Details are in §3.1.
- Without Google's keys, a Chromium build loses sign-in, Sync and Safe Browsing (§5.3). Branding defaults to "Chromium" (`is_chrome_branded=false`) — [Chromium branded builds doc](https://chromium.googlesource.com/chromium/src/+/86.0.4240.75/docs/google_chrome_branded_builds.md).
- The cost of this option is that we own everything: rebranding, updater (Sparkle), signing and notarization, codecs flags, and any de-Googling we want.

### 1.3 ungoogled-chromium (and its macOS repo)

- Licensed BSD-3 (`LICENSE` in repo). Patches are managed with quilt: "Use `quilt` to refresh all patches: `quilt push -a --refresh`". `devutils/validate_patches.py` checks the series — [developing.md](https://github.com/ungoogled-software/ungoogled-chromium/blob/master/docs/developing.md).
- The core repo updates on Chrome's day [measured from commits]:
  - "Update to Chromium 156.0.8078.79" was committed 2026-10-29 21:55 UTC. Chrome's mac stable for that version started serving at 21:25.
  - Sources: [commits](https://github.com/ungoogled-software/ungoogled-chromium/commits/master), [Chrome VersionHistory API](https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions/all/releases).
- **The macOS binaries lag and skip versions** [measured from releases]:
  - 156.0.8078.47-1.1 was published 10-28, against Chrome's 10-20 (8 days).
  - 155.0.8059.39 took 9 days.
  - No mac release at all for M151 or M153.
  - There was a gap from 2026-07-06 to 2026-08-30.
  - Source: [ungoogled-chromium-macos releases](https://github.com/ungoogled-software/ungoogled-chromium-macos/releases).
  - Its recent fix "Use io.ungoogled-software.ungoogled-chromium as bundle identifier to fix Local Network access" (#370) shows the kind of mac-specific traps a fork hits.
- It doesn't help the UI. Its value to us is as a catalogue of BSD de-Googling patches.

### 1.4 Helium (imputnet)

- **License:** "All code, patches ... unique to Helium ... is licensed under GPL-3.0", while unmodified u-c content stays BSD — [Helium README](https://github.com/imputnet/helium). If we distribute a binary built on Helium, our whole build must be offered under GPL-3.0 with source. Ardia confirms: "Ardia as distributed is licensed under the GNU GPL v3, because its engine is built with GPL-3.0 patches" — [Ardia README](https://github.com/mantrakp04/ardia).
- **Patch layout** (local clone at 156.0.8078.79):
  - `patches/series` has 370 entries: 126 `helium/core`, 104 `helium/ui`, 26 `helium/settings`, 71 ungoogled-chromium, plus a few from Brave, Bromite, Inox, Iridium and Debian.
  - The patch text totals about 91.6k lines.
  - The most-touched directory is `chrome/browser/ui/views/frame` (133 file diffs), followed by `chrome/browser/ui/views/tabs` (49).
  - Largest patches: `helium/ui/layout/zen-mode.patch` (2,479 lines), `native-frame-materials.patch` (1,798), `layout/vertical.patch` (1,696).
- **Per-milestone rebase cost** [measured from commits/PRs]:
  - "patches: refresh for 156.0.8078.47" touched 175 patch files (+2,039/−2,689). The whole 156 merge PR #2749 changed 231 files, opened 10-19 and merged 10-21.
  - The 155.0.8059.39 refresh touched 183 files.
  - A **minor** security bump (156.0.8078.79) touched only 5 files (+15/−15).
  - Sources: [imputnet/helium commits](https://github.com/imputnet/helium/commits/main), [PR #2749](https://github.com/imputnet/helium/pull/2749), [PR #2654](https://github.com/imputnet/helium/pull/2654).
- **Lag** (helium-macos release vs. Chrome mac stable start time, VersionHistory API) [measured]:

  | Chromium | Chrome mac stable | Helium macOS | Lag |
  |---|---|---|---|
  | 153.0.8010.36 (milestone) | 09-08 21:19 | 09-12 01:43 | ~76 h |
  | 153.0.8010.52 | 09-17 18:50 | 09-18 13:54 | ~19 h |
  | 154.0.8037.57 (milestone) | 09-22 18:08 | 09-24 10:27 | ~40 h |
  | 154.0.8037.92 | 09-29 18:30 | 09-30 13:33 | ~19 h |
  | 155.0.8059.39 (milestone) | 10-06 17:12 | 10-08 23:16 | ~54 h |
  | 155.0.8059.84 | 10-15 20:40 | 10-17 05:53 | ~33 h |
  | 156.0.8078.47 (milestone) | 10-20 19:57 | 10-22 08:40 | ~37 h |
  | 156.0.8078.79 | 10-29 21:25 | 10-30 20:01 | ~23 h |

  Caveat: the API returns the start time of the current release record, which may be later than the first rollout. Source: [helium-macos releases](https://github.com/imputnet/helium-macos/releases).
- **Team:** top contributors are Eloston (1,327, the ungoogled-chromium founder, carried over from history), wukko (970), dumbmoron (674) and Ahrotahn (371). The repo has 22.3k stars — [contributors API](https://github.com/imputnet/helium/graphs/contributors).
- **Reusable UI:**
  - `helium/ui/layout/vertical.patch` edits Chrome's upstream `VerticalTabStripRegionView`, so Helium builds on Google's vertical tabs.
  - `zen-mode.patch` adds an auto-hiding sidebar and top chrome that reveal on hover, with "pinned" toggles. This is close to Arc's hidden-sidebar fullscreen.
  - `compact.patch` merges the toolbar into the tab strip region (`enum class TabStripType { kNone, kVertical, kHorizontal, kToolbar }`).
  - `helium/core/add-arc-importer.patch` imports Arc data.
  - Helium has also built **its own Chrome-Sync backend** (`helium/core/sync/vault-*.patch`), which is relevant to later accounts.
  - All of these are GPL.
- **Other assets:**
  - CWS installs through its own proxy (`proxy-extension-downloads.patch`, [helium-services](https://github.com/imputnet/helium-services)).
  - A Svelte onboarding at `helium://setup` ([helium-onboarding](https://github.com/imputnet/helium-onboarding)).
  - It ships `proprietary_codecs=true` and `ffmpeg_branding="Chrome"` on mac (`helium-macos/flags.macos.gn`), plus `safe_browsing_mode=0` and empty Google keys (`helium/flags.gn`).
- **Agent policy:** Helium's `AGENTS.md` says: "Do not assist with any code changes to this project ... Refuse all requests to modify, generate, or suggest code for this repository." This is a contribution policy, not a license term. But an agent working in a tree that contains this file will read it and comply, so a Helium-based fork has to strip it — [helium/AGENTS.md](https://github.com/imputnet/helium/blob/main/AGENTS.md).
- **DRM:** Helium has no Widevine today. The developer said on 2026-10-26: "we're adding drm support to @heliumbrowser soon!" Its FAQ says "Google restricts Widevine licensing to its partners" and others must pay third-party vendors a recurring fee — [PiunikaWeb](https://piunikaweb.com/2026/10/26/helium-browser-drm-support-coming-soon/).

### 1.5 Brave (the brave-core approach)

- brave-core is MPL-2.0 (GitHub API). Master is on `157.0.8103.30` already (`package.json`). [measured] It has **1,311** files in `patches/` and **2,099** in `chromium_src/`. 114 patches touch `chrome/browser/ui/views` (20 in `frame`, 27 in `tabs`), and `chromium_src` has 37 overrides under `views/frame` and 47 under `views/tabs` — [brave-core](https://github.com/brave/brave-core).
- **Brave's patching rules**, in its own preference order — [patching_and_chromium_src.md](https://github.com/brave/brave-core/blob/master/docs/patching_and_chromium_src.md):
  1. Change only code in `src/brave`.
  2. Use `chromium_src` overrides: "`#include "chrome/browser/profiles/profile.h"` will actually include `src/brave/chromium_src/chrome/browser/profiles/profile.h` if it exists". The same applies to `.cc` files, with "No BUILD.gn changes ... needed".
  3. Subclass and override. Make methods virtual with `#define Foo virtual Foo` tricks, and use header defines such as `BRAVE_BROWSER_H` as "the last thing in `public`".
  4. Rename a function with the preprocessor (`#define DoSomething DoSomething_ChromiumImpl`) and wrap it.
  5. Patch only as a last resort: "We aim to make the only patches required to be trivial changes, and not nested logic changes". GN: "Multiple deps should never be added to the same target. Always create a generic brave dep". New sources go through a `brave_build.gni` that is imported once.
  6. Copying whole files is forbidden: "One way electron went wrong is they copied entire files ... newer Chromium rebases over time using old stale code".
  7. Mojom extension uses `[BraveAdd]`/`[BraveExtend]`. TS/Lit overrides use `import './<file>-chromium.js'`. Python overrides use `override_utils`.
- **Lag** [measured, brave-browser releases; tags mix channels]:
  - 156.0.8078.74 shipped about 7 h after Chrome (v1.98.62, 10-28 03:43).
  - 156.0.8078.80 shipped about 8 h after (v1.98.63, 10-30 05:50).
  - 156.0.8078.48 shipped about 13 h after (v1.98.60).
  - Source: [brave-browser releases](https://github.com/brave/brave-browser/releases).
- **Vertical tabs and sidebar** are Brave's own Views code: `browser/ui/views/frame/vertical_tabs/vertical_tab_strip_region_view.{h,cc,_mac.mm}` and `browser/ui/views/sidebar/` (`sidebar_container_view`, `sidebar_items_contents_view`, ...). Brave has had vertical tabs since 1.52 (May 2023) — [Brave blog](https://brave.com/blog/vertical-tabs/). I found no evidence that Brave is moving onto Chrome's upstream vertical tabs (gap).
- **Takeaway:** copy Brave's *structure and rules*, not its code. MPL is file-level and Brave's views depend on Brave's own tab strip subclasses [inference]. Brave also runs an MPL sync server, [brave/go-sync](https://github.com/brave/go-sync), which is a reference for later accounts and sync.

### 1.6 Thorium

- Licensed BSD-3, with about 7.6k stars. Contributors: Alex313031 has 4,905 commits; the next has 18 — [repo](https://github.com/Alex313031/thorium).
- Release history: M130 (2025-02) → M138.0.7204.303 (2026-02-18, when Chrome was on about 145) → "M144 Beta" (2026-06-08, Chrome on 149) → "M156.0.8078.28 Beta" (2026-10-11, a pre-stable build) — [releases](https://github.com/Alex313031/thorium/releases).
- A single developer and a months-long history of lag. **Not suitable.**

### 1.7 BrowserOS

- Licensed AGPL-3.0, with a CLA. HEAD's `packages/browseros/CHROMIUM_VERSION` = 155.0.8059.26 on 2026-11-03 [measured] — [repo](https://github.com/browseros-ai/BrowserOS).
- Interesting patch format: `chromium_patches/` mirrors the Chromium tree file by file, and `.features.yaml` groups files into named features with layers ("LAYER 0: BUILD-OWNED", "LAYER 1: CORE & BRANDING").
- Its focus is AI agents. AGPL plus a lagging base makes it **not suitable**.

### 1.8 Supermium

- "An up-to-date Chromium-based web browser compatible with Windows XP, 2003, Vista, 7, 8.x, and newer". It is on 150.0.7871.255, released 2026-10-21, and claims a "turnaround for major vulnerability patches generally less than one week" — [repo](https://github.com/win32ss/supermium).
- **Windows only, so not applicable.**

### 1.9 Open-source Arc-like Chromium forks (new in 2026)

**Ardia** — [github.com/mantrakp04/ardia](https://github.com/mantrakp04/ardia). GPL-3.0 as distributed, own files Apache-2.0. 1.1k stars, created 2026-06-19, 2,638 commits by its one main developer.

- **Architecture:**
  - "Chrome's own framework (`//chrome:chrome_framework`) built from our Chromium tree, with our layers linked in".
  - The tree is "Chromium 156.0.8078.79 ... plus Helium 0.20.3 ... minus a short skip list, then our patch series".
  - The UI is an Expo + react-native-macos app, with Metal shaders for effects.
  - Source: `docs/engine-build.md`.
- **Key trick (ArdiaCore):**
  - "Each profile shown in the window gets its own Chrome `Browser`, whose `BrowserWindow` is `ACBrowserWindow`: a plain object with no `BrowserView`, frame, tab strip or toolbar. A tab's `WebContentsViewCocoa` goes straight into the host's views. Switching profiles is a view swap".
  - The layer is "about 3,200 lines". Its hooks are `g_ardia_*` function pointers declared once in a shared header, "so a signature that drifts on either side is a compile error, not a crash" (`docs/ardiacore-spike.md`, `docs/engine-build.md`).
  - **This is the only open-source design I found that puts several real profiles in one window, as Arc did.**
- **Cost of this design:** Chrome's top-chrome UI must be re-hosted or replaced. That includes permission prompts, password and extension bubbles, action popups, the find bar ("headless"), fullscreen, PiP, docked DevTools and choosers. Ardia moved off CEF to this design in October 2026.
- **Maintenance process:**
  - `engine/patches/series` plus `series.py` with `apply`, `capture-base`, `check` ("applies the whole series ... strictly (`git apply`: exact context, no fuzz) ... and compares every touched file with the tree, byte for byte"), and `materialize`.
  - A nightly check runs via launchd.
  - "Moving to a new Chromium version ... deletes `out/` and costs a full build (official, ThinLTO, PGO), so it needs the owner's OK".
  - "a full rebuild costs about 5 hours"; the first build takes "about 2 hours" (README).
- **Agent workflow:** `AGENTS.md` describes the T3 orchestration that this user's environment also uses: Opus subagents, Codex review via `delegate_task`, no worktrees, commits straight to main.
- **Gaps in Ardia:**
  - "Netflix and DRM: Streaming sites open in WebKit, where they play. Widevine in Chromium waits on Google".
  - Apple Silicon only.
  - It is styled after Dia, not Arc.
  - React Native macOS is stuck on the legacy architecture ("react-native-macos 0.81's Fabric support is experimental"; "No Reanimated").

**Flecha** — [github.com/lucianodiisouza/flecha-browser](https://github.com/lucianodiisouza/flecha-browser). MIT, 119 stars, created 2026-10-22, about 460 commits by one developer.

- "It is a Chromium 158 fork rather than an Electron app because Google blocks sign-in in Electron ... Flecha started as an Electron app".
- Features: Favorites, pinned tabs with folders, Today tabs with auto-archive, Spaces (per-Space cookie isolation as an option), Peek, split view, a command bar, Arc import, and Sparkle updates.
- **Architecture:**
  - Upstream Chromium plus 45 patches, about 6.7k lines (`chromium/patches/`).
  - The UI is a TypeScript component extension, the "shell".
  - Patch `0002-hide-tab-strip-and-toolbar` adds one switch, `FlechaHidesTopChrome()`, that "every native 'hide top chrome' change asks", with `--flecha-show-top-chrome` as a debug escape hatch.
  - Patch `0011-shell-frame-view-draws-the-window` renders `chrome-extension://<shell>/window.html` "in a transparent view stacked above the page area".
  - Patch `0034-spaces-with-separate-cookies` uses "a persistent StoragePartition per Space ... (`SiteInstance::CreateForFixedStoragePartition`)" instead of profiles. The patch spells out why: "a Chromium window belongs to one profile, so a Space's tabs couldn't share the window with the others".
- **Risk:** it builds from a trunk version (158.0.8119.0), not a stable tag, so it doesn't get Chrome's stable-branch security merges [inference].

---

## 2. Non-fork alternatives

### 2.1 Electron

- **Per-Space cookie jars are cheap:** `WebContentsView` plus `session.fromPartition('persist:<space>')` — [Electron WebContentsView](https://www.electronjs.org/docs/latest/api/web-contents-view), [session](https://www.electronjs.org/docs/latest/api/session).
- **Google sign-in is the blocker.**
  - Google: "Google Account sign-ins from all embedded frameworks will be blocked starting on January 4, 2021". Browsers "must not use another browser's User-Agent string" and must not "proxy or alter network traffic" — [Google Developers Blog](https://developers.googleblog.com/guidance-to-developers-affected-by-our-effort-to-block-less-secure-browsers-and-applications/).
  - Electron browsers report "This browser or app may not be secure". Min's FAQ suggests temporarily spoofing the UA; one app needed a faked `window.chrome` object — [Min FAQ](https://github-redirect.dependabot.com/minbrowser/min/wiki/FAQ), [nativefier #831](https://github.com/nativefier/nativefier/issues/831).
  - Spoofing violates the policy above and is fragile.
  - Flecha abandoned Electron for this reason (§1.9).
- **Extensions:** "Electron does not support the full range of Chrome extensions APIs"; `loadExtension` takes unpacked directories only — [Electron extensions API](https://www.electronjs.org/docs/latest/api/extensions-api). The community packages electron-chrome-extensions and electron-chrome-web-store (MIT) add `chrome.tabs`, popups and a CWS installer, but "Manifest V3 support — pending" — [electron-browser-shell](https://github.com/samuelmaddock/electron-browser-shell).
- **Updates:** Electron 45.0.0 (Chromium 156.0.8078.48) shipped 2026-10-21, a day after Chrome 156 stable. But majors jump milestones (44 = 152 → 45 = 156), with security backports in between (44.10.1 = "152.0.7977.169") [measured] — [releases.json](https://releases.electronjs.org/releases.json).
- **DRM is easier here than in a custom Chromium.** castLabs' ECS fork plus EVS gives Widevine VMP signing: "a free service, but requires signup". Custom Chromium builds need "the Widevine 3PL program, which requires an audit" — [castLabs EVS wiki](https://github.com/castlabs/electron-releases/wiki/EVS).
- **Verdict:** not acceptable as the main browser, because embedded Google sign-in is blocked, the extension story is weak, and it isn't "real Chrome".

### 2.2 CEF

- Google names CEF explicitly in the sign-in block ("Sign-in from CEF or Embedded Internet Explorer is not allowed") — [Google blog](https://developers.googleblog.com/guidance-to-developers-affected-by-our-effort-to-block-less-secure-browsers-and-applications/).
- It has no Chrome Web Store or full extension system by default [inference/pk].
- Ardia started on CEF and left it: "CEF left the tree on 2026-10-09: its 117 patches to Chrome are gone" (`docs/engine-build.md`).
- **Not recommended.**

### 2.3 WebKit Arc-likes (UI reference only)

- **Nook** (GPL-3.0, 2.0k stars) — [repo](https://github.com/nook-browser/Nook).
- **Ora** (GitHub reports GPL-3.0; its website says MIT, so check) — [repo](https://github.com/the-ora/browser).
- **Crest** (Chromium on Mac, with WebKit on iOS) — [repo](https://github.com/pauljoda/Crest).
- All are Swift/SwiftUI. Use them only for interaction ideas: sidebar gestures, Peek, Space swipe. Don't copy GPL code into a BSD-licensed fork.

---

## 3. UI technology inside a Chromium fork

### 3.1 How Chrome's 2026 vertical tabs are built (native Views)

- **Region view:** `chrome/browser/ui/views/frame/vertical_tab_strip_region_view.{h,cc}` ("Container for the vertical tabstrip and the other views sharing space with it, excluding the caption buttons"). It implements:
  - `views::ResizeAreaDelegate` (drag to resize);
  - expand-on-hover locks (`GetExpandOnHoverLock`, `is_expanded_on_hover()`);
  - collapse state via `tabs::VerticalTabStripStateController` (`chrome/browser/ui/tabs/vertical_tab_strip_state_controller.h`);
  - an `OrganizerPanelHost`;
  - top and bottom containers (`chrome/browser/ui/views/tabs/vertical/vertical_tab_strip_{top,bottom}_container.*`).
  - Source: [header](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/views/frame/vertical_tab_strip_region_view.h).
- **Tab rendering:** a model-driven Views tree shared by the horizontal and vertical strips, in `chrome/browser/ui/views/tabs/common/`:
  - `TabStripCollectionController`, `RootTabCollectionNode`/`TabCollectionNode`;
  - `TabCollectionAnimatingLayoutManager`;
  - `PinnedTabContainerView` with `*_vertical_layout.cc`;
  - `TabGroupView`, `TabDragHandler`, `TabView` with `tab_view_vertical_layout.cc`.
  - Source: [Gitiles listing](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/views/tabs/common/).
  - Animations go through `chrome/browser/ui/views/animations/tab_strip_animations.cc` and `BrowserAnimationController` (from the includes in `vertical_tab_strip_region_view.cc`).
- **Layout:** `BrowserView` uses `BrowserViewTabbedLayoutImpl` for normal windows. "The layout should never read browser-... properties directly from the `Browser`", and goes through a `BrowserViewLayoutDelegate` — [layout README](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/views/frame/layout/README.md).
- **Upstream has a Mojo tab-strip API:** `TabStripService` (`chrome/browser/ui/tabs/tab_strip_api/*.mojom`), "a stable, cross-platform interface ... that decouples clients from the browser's `TabStripModel`". `GetTabs()` returns a snapshot plus an observer stream — [tab_strip_api.md](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/tabs/tab_strip_api/tab_strip_api.md), [developer guide](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/tabs/tab_strip_api/tab_strip_api_developer_guide.md). This is the right backend if any tab UI is written in WebUI.

### 3.2 Chrome itself is experimenting with WebUI in the toolbar (and it shows the cost)

- Chrome's `chrome/browser/ui/webui/webui_toolbar/README.md` says: "an experimental effort to transition Top Chrome toolbar controls from native C++ Views to WebUI".
- To make a single reload button feel native, Chrome built "Initial WebUI" infrastructure:
  - a dedicated renderer process spawned at startup (`kWebUIReloadButtonPrewarmWebUI`);
  - a synchronous navigation commit;
  - resources served "synchronously from local memory";
  - skipping the GPU-channel round trip;
  - no extensions or spellcheck in that renderer;
  - "Coordinating compositor deadlines to prevent visual glitches".
  - Source: [README](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/webui/webui_toolbar/README.md).
- There is also a `chrome/browser/ui/webui/tabstrip_ntb/` page (`chrome://tabstrip-ntb.top-chrome/`, the new-tab button). The `top_chrome/` infrastructure includes a `WebUIContentsPreloadManager` and warm-up levels — [top_chrome](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/webui/top_chrome/).
- **[inference]** A WebUI sidebar that you open with each window can be made to feel instant, but only by copying Chrome's preload and warm-up machinery. Out of the box, a WebUI surface's first paint lags a Views surface. Animations *inside* WebUI can be smooth, because CSS transform and opacity run on Blink's compositor thread. Anything that resizes the native page area (collapse/expand, drag-resize) needs cross-process frame sync.

### 3.3 How other browsers do it

| Browser | Sidebar/tab UI tech | Evidence |
|---|---|---|
| Chrome 2026 | Views (C++) | §3.1 |
| Brave | Views (C++): own vertical tabs and own sidebar | [brave-core browser/ui/views/frame/vertical_tabs](https://github.com/brave/brave-core/tree/master/browser/ui/views/frame/vertical_tabs), [sidebar](https://github.com/brave/brave-core/tree/master/browser/ui/views/sidebar) |
| Helium | Patches Chrome's Views vertical tabs | §1.4 |
| Vivaldi | Whole UI in React/HTML/CSS; "it uses the React JavaScript framework for its desktop browser user interface" | [Thurrott](https://www.thurrott.com/?p=287859). Users on its own forum say the custom UI layer is part of the slowness ([Vivaldi forum](https://forum.vivaldi.net/topic/60087/vivaldi-ui-slower-than-chr-ms-edge), anecdotal) |
| Edge | Moved React UI surfaces to "WebUI 2.0" (markup-first, less JS at init), reporting "42% faster" Browser Essentials | [Windows Report](https://windowsreport.com/microsoft-migrates-edges-ui-to-webui-2-0-making-it-dramatically-faster-than-before/). The vertical tabs rebuild targets GA in Dec 2026 (earlier notes); its tech is **unknown** (gap) |
| Flecha | TS extension page in a transparent `views::WebView` over the window | §1.9 |
| Ardia / Arc | Native host app (RN macOS / Swift) around Chromium content views | §1.9. Arc is "written in Swift" — [Wikipedia](https://en.wikipedia.org/wiki/Arc_(web_browser)) |

### 3.4 Hiding the horizontal tab strip and keeping the top compact

- With Chrome's vertical tabs on, the horizontal strip is already gone and the toolbar sits beside the vertical region. On mac the caption buttons (traffic lights) live in the region's top container (`SetCaptionButtonWidthForLayout`). A fork can **force vertical mode** (default pref, hide the toggle) and **replace the region's content** with our sidebar [inference from code].
- To remove the toolbar row (Arc style, with the URL in the sidebar), follow Flecha's pattern: one predicate checked by every "hide top chrome" site, plus a debug switch to bring stock UI back. Helium's `compact`/`zen-mode` and Ardia's "Move the address bar into the sidebar" show the same goal.
- Keep Chrome's `LocationBarView`/omnibox alive, either hidden or moved into the sidebar header. Many bubbles (page info, permissions, extensions, passwords) anchor to toolbar views. Helium's zen-mode patch keeps top chrome visible "while a bubble/popup anchored inside the top container ... is open", which shows this coupling.

### 3.5 Smoothness: 60–120 fps and instant switching

- On macOS 14+, Chromium uses `CADisplayLink` when `kCADisplayLinkInBrowser`/`kCADisplayLinkInGpu` are enabled, and falls back to `CVDisplayLink` — [display_link_mac.mm](https://chromium.googlesource.com/chromium/src/+/main/ui/display/mac/display_link_mac.mm). Whether Views UI animations actually hit 120 Hz on ProMotion has to be **measured** (gap).
- **[inference] Tab switching is instant in any design** because it is a `TabStripModel::ActivateTabAt` plus a native contents swap. Hidden tabs keep their compositor surfaces for a while, so switching to a recently visible tab avoids a re-raster. What feels slow is first paint of a discarded or unloaded tab, which every Chromium browser has to manage.
- **Recommendation:** implement the hot path in Views with layer-backed (`ui::Layer`) transform and opacity animations: tab rows, Favorites tiles, Space switching and the collapse/hover reveal. This is the same technology as Chrome's and Brave's vertical tabs, and it needs no IPC hop or preload. Use WebUI (Lit, per `docs/webui/webui_using_lit.md`) for onboarding, settings and editors.
- If Views development is too slow, the fallback is a preloaded top-chrome WebUI sidebar on `TabStripService`. Keep the native container (resize, collapse, hit-testing) in Views either way.

### 3.6 The Space ↔ profile ↔ fullscreen problem (decide first)

- Arc semantics: Profiles "scope logins, cookies, browsing history, and other settings to one or more Spaces", and switching Space switches cookie jar in the same window (earlier notes, `google_accounts_and_identity.md`).
- Chromium constraints:
  - A `Browser` (and its `BrowserView`, which is the widget) has one profile. Flecha's patch notes say: "a Chromium window belongs to one profile".
  - macOS native fullscreen gives each window its own Space, and Space changes animate slowly. Third-party tools note "no public API for programmatic Space switching" — [WindowPilot](https://github.com/ethannortharc/WindowPilot), [WezTerm non-native fullscreen option](https://wezterm.org/config/lua/config/native_macos_fullscreen_mode.html).
- Options:
  1. **StoragePartition per Space** (Flecha): one window, one profile. Each Space gets its own cookies, storage and service workers; history, passwords and extensions are shared. One patch (about 470 lines). Lowest risk, but **not** Arc's full profile semantics.
  2. **One window per profile, swapped in place** [inference, untested]: each profile has a normal Chrome window with our sidebar, and sidebar state lives in a global model. Implement our own *non-native* fullscreen (a borderless window filling the screen, with menu bar and Dock set to auto-hide) so a cross-profile Space switch is an instant `orderFront` of a window with the same frame, which can crossfade. All Chrome UI (prompts, extensions, autofill) keeps working. Animating the sidebar between profiles needs a snapshot. **Prototype in week 1.**
  3. **Several `Browser`s in one NSWindow** (Ardia's ArdiaCore): true Arc behavior. But you inherit the job of hosting every piece of Chrome UI that assumes a `BrowserView`. Ardia needed about 3.2k lines of layer plus many hooks, built over months with agents.
- **v1 pick:** option 2, with option 1 kept as an alternative for "lightweight" Spaces that share a profile. Move to option 3 only if option 2 fails UX review. This decision belongs with the profiles/identity track too.

---

## 4. Patch hygiene for agent-maintained rebases

### 4.1 Cadence we must keep up with

- Chrome went to a **two-week milestone cycle starting with Chrome 153 (stable 2026-09-08)**: "Starting September 2026, Chrome will move to a two-week release cycle". Dev and Canary are unchanged, Extended Stable stays on 8 weeks, and weekly security updates continue — [Chrome blog](https://developer.chrome.com/blog/chrome-two-week-release), [start post](https://developer.chrome.com/blog/chrome-two-week-start).
- That means about **26 milestone rebases a year plus about 2 security bumps per milestone**. The VersionHistory data shows mac stable releases about every 2–7 days [measured].
- From Helium: a milestone rebase touched about 50% of patch files (mostly context refresh), while a security bump touched about 1% (§1.4). **[inference]** Plan for one "real" rebase every 2 weeks and cheap, mechanical security bumps in between.
- **Extended Stable (8-week)** is an option to cut milestone rebases to 6–7 a year while still getting security fixes. Whether Chrome's Extended Stable gets the same security merges, and how quickly, needs verification (gap).

### 4.2 Churn in the areas we'd touch

Commits in the last 12 months (2025-11-01 → 2026-11-03), from the GitHub mirror `chromium/chromium` [measured]:

| Path | Commits |
|---|---|
| `chrome/browser/ui/views/tabs/` | 1,897 |
| `chrome/browser/ui/views/frame/` | 1,677 |
| `.../frame/browser_view.cc` | 387 |
| `.../frame/layout/` | 284 |
| `.../toolbar/toolbar_view.cc` | 223 |
| `.../frame/vertical_tab_strip_region_view.cc` | 202 (new code, still moving fast) |
| `chrome/browser/ui/tabs/tab_strip_model.cc` | 178 |
| `.../frame/browser_view.h` | 144 |
| `chrome/browser/ui/views/side_panel/` | 336 |
| `chrome/browser/profiles/profile_manager.cc` | 38 |

**[inference]**
- Never carry logic inside `browser_view.cc`, the layout implementation, or `vertical_tab_strip_region_view.cc`. Carry only one-line hooks there.
- Do **not** subclass or patch the upstream vertical tab strip region (it is changing too fast). Own a parallel `ArcSidebarRegionView` in `//arcfork` and swap it in at a single layout hook. Read upstream's code for patterns (expand-on-hover, resize area, mac caption handling) and copy ideas, not files.

### 4.3 Proposed structure

```
arcfork/                         (our git repo, small)
  CHROMIUM_VERSION               (exact stable tag, e.g. 156.0.8078.80)
  src/arcfork/                   (copied/symlinked to //arcfork in the tree)
    BUILD.gn  arcfork.gni        (one dep from chrome/browser, one from chrome/browser/ui)
    browser/                     (Space/Favorites/Pinned models, prefs, profile binding)
    browser/ui/views/sidebar/    (Views sidebar, region view, animations)
    browser/ui/webui/            (onboarding, settings: Lit/TS)
    app/theme/  branding/        (icons, BRANDING, strings overrides)
    chromium_src/                (optional Brave-style overrides, if we add that machinery)
  patches/
    series                       (one concern per patch; ordered)
    0001-build-arcfork-dep.patch
    0002-layout-sidebar-hook.patch
    ...
  scripts/
    sync.sh                      (fetch tag at depth 1 or a prepared tarball)
    apply.py {apply,check,materialize,refresh}
    build.sh  sign_notarize.sh  sparkle_appcast.sh
  tests/                         (browser_tests/interactive_ui_tests for //arcfork, plus a UI smoke script)
  AGENTS.md / docs/rebase.md     (the playbook the agent follows)
```

Rules, adapted from Brave and Ardia:
1. **New code goes only in `//arcfork`.** Chromium files get *hooks*, not logic. Use one header define, one virtual method, or one `g_arcfork_*` function pointer declared in a shared header, so signature drift becomes a compile error. Ardia's `ac_hooks.h` and Brave's `BRAVE_*_H` macros are the patterns.
2. **One BUILD.gn dep** from the Chrome target to `//arcfork:browser`, as in Brave ("Always create a generic brave dep") and Ardia ("`chrome_dll` depends on `//ardia/core` — 1 line").
3. **A feature flag and kill switch per surface** (`BASE_FEATURE(kArcforkSidebar, ...)` plus a `--arcfork-stock-ui` switch, as in Flecha's `--flecha-show-top-chrome`). If a rebase breaks the sidebar, ship with stock Chrome UI rather than delaying a security update.
4. **Prefer composition over overrides:** `BrowserWindowFeatures`/`TabFeatures`-style per-window and per-tab objects, `TabStripModelObserver`, `TabStripService` Mojo, and `ProfileKeyedService`. Only reach for `chromium_src` replacement when there is no seam. Adding Brave's `chromium_src` include-path machinery itself costs build patches, so add it only when there are more than a handful of overrides [inference].
5. **Strict apply:** `git apply` with exact context and no fuzz, then `check` rebuilds the touched files from a recorded base and diffs them byte for byte (Ardia's `series.py check`). Ungoogled-chromium's `quilt push -a --refresh` plus `validate_patches.py` is the lighter alternative.
6. **Never copy whole upstream files** (Brave's Electron warning).
7. **Branding by data, not edits:** BRANDING file, `chromium_strings.grd` substitutions, icons, a unique bundle id, and a unique **Safe Storage keychain name**. Ardia calls its `chromium-safe-storage-name.patch` "load-bearing ... every user's saved passwords and cookies are encrypted with that item's key", so it must never be changed after release.

### 4.4 Agent rebase loop (per Chrome release)

1. **Detect:** poll the VersionHistory API (mac/stable) for new versions. The API returned all 2026 releases in one call during this research.
2. **Sync:** fetch the tag at depth 1, or use prepared source tarballs ([imputnet/chromium-tarballs](https://github.com/imputnet/chromium-tarballs)). Ardia warns that a plain `git fetch` of the shallow `src` "asks for the whole history of every branch: the server builds that pack for an hour", and that deleting dep checkouts before syncing turned a stall into 3.5 minutes (`docs/engine-build.md`).
3. **Apply** the series strictly. On failure, `git apply --3way`. The agent then fixes each failing hook, guided by the upstream commit log for that file, and regenerates the patch.
4. **Build:** incremental for security bumps where possible. A milestone needs a full official build: about 2 h first build, about 5 h full rebuild with ThinLTO+PGO on Ardia's Mac.
5. **Test:** `//arcfork` unit and browser tests, then a scripted smoke run (launch, create Space, switch, pin, drag, fullscreen, extension install, Google sign-in).
6. **Ship:** sign, notarize, publish the Sparkle appcast. Target at most 24 h for security bumps and at most 72 h for milestones. Helium does about 35 h median with humans.

**Build host:** Chromium's mac build instructions require Xcode and the macOS SDK on an APFS volume, and there is no `mac_cross` doc next to `win_cross.md` — [mac_build_instructions.md](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md). **This Linux box cannot produce the mac build.** A dedicated Apple Silicon Mac (or a cloud Mac) is required [inference from docs].

---

## 5. Branding and legal

### 5.1 License consequences by base

| Base | What it forces on us |
|---|---|
| Upstream Chromium | BSD-3 notices plus third-party licenses (about:credits). Our own code can be any license, including closed. |
| ungoogled-chromium | BSD-3. Same as upstream. |
| Helium | **GPL-3.0 for the distributed build**, so source must be offered. |
| brave-core code | MPL-2.0 per file. |
| BrowserOS | AGPL-3.0, plus a CLA to contribute. |
| Ardia | GPL-3.0 as distributed (Apache-2.0 for its own files). |
| Flecha | MIT. |

### 5.2 Name and Google branding

- Default Chromium builds already use Chromium branding, because "the Google Chrome logo and related assets is a trademark which we don't want to release under Chromium's open source license" — [Chromium doc](https://chromium.googlesource.com/chromium/src/+/86.0.4240.75/docs/google_chrome_branded_builds.md).
- Rename the product. Avoid "Chrome", "Chromium" and "Arc" (a Browser Company mark) in the name [inference]. The Web Store guidelines show Google's stance: don't use "Google trademarks or any confusingly similar marks" — [CWS branding](https://developer.chrome.com/webstore/branding).
- Brave forced a fork to rename: "Open source licensing does not grant a trademark license" — [Decrypt](https://kakapo.decrypt.co/35146/brave-forces-rival-browser-braver-change-name). NLnet's guide also recommends renaming forks — [NLnet PDF](https://NLnet.nl/NGI0/bestpractices/Forking_and_Trademarks.pdf).
- Remove the "Google API keys are missing" infobar, as Flecha does with `0036-no-google-api-keys-infobar.patch`.
- No product name was chosen in this track. A trademark and domain check is a gap.

### 5.3 Google API keys: what you lose without them

- Keys can be obtained by chromium-dev members, but are "not for distribution purposes", and since March 2021 Google restricts Chrome-private APIs (Sync, Click to Call, and about 20 others) for third-party Chromium builds — [Chromium API keys](https://www.chromium.org/developers/how-tos/api-keys/), [Computerworld](https://www.computerworld.com/article/3603917/google-to-cut-off-other-chromium-based-browsers-from-access-to-services-such-as-sync.html), [gHacks](https://www.ghacks.net/2021/01/16/sync-and-other-features-may-stop-working-in-some-chromium-browsers-in-march-2021).
- Feature by feature on a keyless macOS build:

| Feature | Status without keys | Source |
|---|---|---|
| **Browser sign-in to the profile ("Sign in to Chromium") and Chrome Sync** | **Gone.** Needs our own sync for the later accounts feature: Helium built a "vault" backend on Chromium's sync engine, and Brave runs MPL `go-sync` | Chromium API keys page: the OAuth token for sign-in "gives access to ... Chrome sync", so sign-in is restricted |
| **Google sign-in on websites** (Gmail, Calendar) | **Works.** It is ordinary web sign-in in a full browser. Keep a Chrome-compatible UA | Flecha README; Google's rules target embedded frameworks |
| **Safe Browsing** | **Off** unless we get a key. The v4 API is "for non-commercial use only"; commercial use goes to Web Risk. Helium ships `safe_browsing_mode=0`. Brave proxies Safe Browsing through its own servers | [Safe Browsing v4](https://developers.google.com/safe-browsing/v4), [Brave help](https://support.brave.app/hc/articles/15222663599629-Safe-Browsing-in-Brave) |
| **Translate** (Google cloud) | **Off** (needs a Translate key). Alternatives: Ardia uses Apple's on-device Translation on macOS 26 ("On your Mac. Nothing leaves it.") | Chromium API keys page lists Cloud Translation; Ardia README |
| **Spellcheck** | **Works.** macOS uses the OS spellchecker (`use_browser_spellchecker = is_android \|\| is_mac \|\| is_win`). Only the optional "enhanced" Google spelling service is lost | [spellcheck_build_features.gni](https://chromium.googlesource.com/chromium/src/+/main/components/spellcheck/spellcheck_build_features.gni) |
| **Geolocation** | **Mostly works.** The macOS default is `kHybridPlatform` (CoreLocation plus network fallback). The network fallback (Google Geolocation API) needs a key | [device_features.cc](https://chromium.googlesource.com/chromium/src/+/main/services/device/public/cpp/device_features.cc), [location_provider_manager.cc](https://chromium.googlesource.com/chromium/src/+/main/services/device/geolocation/location_provider_manager.cc) |
| Drive, Cloud Search, Time Zone API, Click to Call, Google Pay/autofill server features | Off | Chromium API keys page |
| **Component updater** (CRLSet, certificate lists, Widevine CDM download) | Reaches Google without a key. Ardia keeps "the security components still reach Google" | Ardia `docs/engine-build.md` |

### 5.4 Widevine DRM (Netflix, Spotify, Disney+, Prime)

- A Chromium build can fetch the Widevine CDM component (`enable_widevine=true`, set in both Helium's and u-c's `flags.gn`). On macOS and Windows, premium services also require the browser to be **VMP-signed** under a Widevine license. **[inference/pk]** Netflix rejects unsigned builds. Whether Spotify accepts an unsigned build on mac is **unverified (gap)**.
- **Routes to a license:**
  1. A direct Google Widevine partnership, which Brave, Vivaldi and Opera have [pk]. These are business deals; terms are not public (gap). Brave ships Widevine as an opt-in component (Brave community threads).
  2. **castLabs Widevine 3PL program** for "custom Chromium/Electron adaptations", which "requires an audit". Pricing is not public, and Helium's FAQ calls it a "ridiculous recurring fee" — [castLabs EVS wiki](https://github.com/castlabs/electron-releases/wiki/EVS), [PiunikaWeb](https://piunikaweb.com/2026/10/26/helium-browser-drm-support-coming-soon/).
- **What small forks do:**
  - Helium: none today, "coming soon".
  - Ardia: "Streaming sites open in WebKit, where they play" (a `WKWebView` fallback, since Safari's FairPlay works).
  - Community hacks copy Chrome's `WidevineCdm` into the app ([HeliumDRMFixer](https://peerlist.io/vikaskapadiya/project/heliumdrmfixer)). These don't fix VMP, and their redistribution status is questionable.
- **v1 recommendation:** no DRM. Either use a Safari/WebKit fallback for a small allowlist (Netflix, Disney+, Prime), following Ardia, or open DRM sites in Safari via a handoff. Start a castLabs 3PL inquiry if DRM matters.

### 5.5 Codecs

- Set `proprietary_codecs=true` and `ffmpeg_branding="Chrome"` to get H.264, AAC and MP4. Helium-macos and Ardia both ship this ("H.264 decodes through VideoToolbox").
- **[inference]** Patent-pool licensing (H.264/AAC) is a distribution question, not a build question. Personal use is low-risk, and wide distribution should get legal review (gap).

### 5.6 Chrome Web Store in a fork

- Plain Chromium can install from the CWS. Ardia reports "The Chrome Web Store just works, its button says Add to Ardia", and Flecha installs from the CWS as well.
- ungoogled-chromium blocks it by design.
- Helium routes extension downloads through its own proxy and spoofs the update platform (`spoof-extension-downloader-platform.patch` forces `prod=chromecrx`, `os=win`).
- **[inference]** Keep stock CWS behavior and don't add a proxy in v1. MV2 is gone upstream [pk], so MV3 only.

---

## 6. Recommendation for v1 (with rationale)

1. **Base:** upstream Chromium **stable** tags (BSD).
   - We rebase only our own short series, which is the smallest possible conflict surface for an agent.
   - There is no dependency-chain lag.
   - The license is permissive.
   - We can reach Brave-like same-day turnaround, limited mostly by build time.
   - Borrow individual ungoogled-chromium patches (BSD) when a Google ping or prompt bothers us. Read Helium and Ardia for ideas, but don't copy GPL code unless we accept GPL-3.0 for the whole distribution.
2. **Structure:**
   - `//arcfork` tree, one GN dep, function-pointer and define hooks.
   - A quilt-style `series` with an Ardia-style strict `check`.
   - A per-surface feature flag with a stock-UI fallback.
   - Target: **≤40 patches, ≤3k lines of patch text in Chromium files**. Flecha's whole Arc UI needed 45 patches and 6.7k lines; ours should be smaller because logic lives in `//arcfork`.
3. **UI:** a Views sidebar region view we own, swapped in at one layout hook.
   - Force vertical mode and hide the toolbar row, keeping the omnibox and anchor views alive in the sidebar header.
   - Use layer animations for collapse, hover-reveal and Space transitions.
   - Use Lit WebUI for onboarding, settings and the Space editor, built on `TabStripService` Mojo where tab data is needed.
4. **Spaces ↔ profiles:** prototype the "profile windows swapped in place + custom fullscreen" approach in week 1. Keep StoragePartition Spaces as a lighter option. Escalate to multi-Browser hosting only if needed.
5. **Infra:** an Apple Silicon build Mac (at least 64 GB RAM and about 300 GB free SSD is a typical recommendation [pk]); Developer ID signing, notarization and Sparkle; a VersionHistory poller to trigger the agent.

Alternatives, if the owner prefers:
- **(B) Helium base (the Ardia model):** gets de-Googling, uBlock, CWS proxy, zen layout, Arc importer and a sync backend for free. Costs: GPL-3.0, +1–3 days lag, two patch stacks to rebase, and an anti-agent `AGENTS.md`.
- **(C) Fork Ardia or Flecha outright:** the fastest route to an Arc-like browser before 2026-12-22. Ardia is stable-tracking and multi-profile in one window, but GPL with an RN macOS shell and Dia styling. Flecha is MIT and very Arc-like, but trunk-tracking with a TS-extension UI.

---

## 7. Key risks

- **Cadence:** 2-week milestones mean about 26 rebases a year. A missed week leaves a known-vulnerable browser. The kill-switch flag and stock-UI fallback are essential.
- **Upstream UI churn:** `frame/` and `tabs/` average about 32–36 commits a week, and upstream vertical tabs is new and still moving. Chrome's WebUI-toolbar experiment could rewrite the toolbar our hooks attach to.
- **Profile-per-Space in one fullscreen window** is unproven for options 2 and 3, and it may force a larger architecture.
- **Build infrastructure:** you need a Mac. Builds take hours, and disk and RAM needs are large.
- **DRM:** none without a commercial agreement.
- **Sync and accounts:** Google Sync is unavailable, so we have to build our own server (later).
- **Security:** being a small fork means no Safe Browsing unless we get a key or pay for Web Risk.

## 8. Open questions for the owner and other tracks

1. Must Spaces be *full* profiles (separate history, passwords, extensions), or are separate cookie jars per Space enough (StoragePartition)?
2. Is native macOS fullscreen required, or is a custom borderless fullscreen acceptable?
3. Is open-sourcing under GPL-3.0 acceptable? That would unlock Helium or Ardia as a base.
4. How much does Netflix/Spotify in-browser matter? Would a WebKit fallback or a Safari handoff do?
5. Is the plan to distribute to others, which raises codec and trademark questions, or personal use only?
6. Which build Mac and signing identity (Developer ID) will be used?
7. Should the fork track Extended Stable (8-week) to cut rebases, and does that weaken security turnaround?

## 9. Gaps (not verified)

- Edge's vertical tabs implementation technology (Views vs WebUI 2.0).
- Whether Brave plans to adopt upstream vertical tabs.
- Whether Chromium Views animations run at 120 Hz on ProMotion in practice. `CADisplayLink` support exists behind features; it needs measuring.
- Widevine without VMP on macOS: which services still play (Spotify?). Terms and cost of Google's or castLabs' licenses.
- Whether a `TabStripModel` tolerates `WebContents` from another profile. I assume not, from architecture; not tested.
- Ora's license: GitHub says GPL-3.0, the website says MIT.
- Exact first-rollout times for Chrome releases. The VersionHistory API gave the start of the current release record, so lag numbers are approximate. For example, ungoogled-chromium's 156.0.8078.73 commit predates the API's start time.
- Whether Chromium's mac target can be cross-compiled from Linux. I found no doc, so assume it can't.
- Codec patent licensing for distribution.

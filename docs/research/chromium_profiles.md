# Per-Space profiles in a Chromium fork (macOS): research track

Date: 2026-11-03. Chromium source was read at `main` on 2026-11-03 (gitiles HEAD `088031dc7d9c`, plus the GitHub mirror `chromium/chromium@main` for files too large for gitiles). Line numbers in `source.chromium.org` links are from that snapshot and will drift. brave-core was read at `master` `6752d22f5b5b` (2026-11-03). Read-only sparse checkouts are under `research/repos/`.

Labels used below:
- **[src]** I read it in source code.
- **[doc]** It comes from official docs or posts.
- **[2nd]** It comes from a secondary or forum source.
- **[inf]** It is my own inference.

---

## 0. TL;DR and recommendation

**Recommended v1: a Space is a container, meaning a separate `StoragePartition` inside a single Chromium Profile, all in one browser window.** This is the Firefox-containers model. Brave has shipped it in production since 1.92 (July 2026), enabled by default, and its code is open source (MPL-2.0).

What this gives you:
- Each Space gets its own cookie jar, localStorage, IndexedDB, cache and service workers, so a different Google account per Space works.
- Spaces live in the same window and the same tab strip, so switching is only a sidebar filter. It is instant and fullscreen is not a problem.
- Creating a Space just generates a UUID: no profile directory, no KeyedServices, no new window. "Insanely smooth" creation comes free.
- Extensions, passwords, bookmarks and settings are installed and stored once and shared across Spaces. That is probably what the user wants anyway.

The building blocks already exist upstream:
- `StoragePartitionConfig`
- `SiteInstance::CreateForFixedStoragePartition()`, added in 2023 for Isolated Web Apps

Brave's and a Helium contributor's patch sets show the remaining work. Most of it is plumbing in about 10 to 25 Chromium files: navigation, new-tab inheritance, session restore, permissions and zoom.

**Later (v2), optional "hard-isolated" Spaces bound to a real Chromium Profile.** Such a Space gets separate extensions, history and passwords. It is implemented as one `Browser` window per profile, swapped in place:
- Windowed mode: reorder windows at identical bounds.
- Fullscreen: use Chromium's existing `SetCanAppearInExistingFullscreenSpaces()` / `NSWindowCollectionBehaviorFullScreenAuxiliary` path so all profile windows share one macOS fullscreen Space. This is unproven and needs a prototype.

**Not recommended:** a true multi-profile `Browser`, i.e. tabs from different Profiles in one `TabStripModel`. The `Browser` is built around one `const Profile*`, and about 460 files in `chrome/browser` call `browser->GetProfile()`. It is the highest-risk choice for rebasing.

---

## 1. Chromium's object model and the "one profile per window" assumption

### 1.1 The pieces

| Class | What it is | Evidence |
|---|---|---|
| `content::BrowserContext` / `Profile` | One user data set: prefs, history, extensions, passwords, and every `KeyedService`. A `Profile` is a `BrowserContext`. Its directory lives under the user-data-dir. | [src] KeyedServices are tied to the Profile's lifetime and are shut down when it is destroyed ([profiles/README.md](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/profiles/README.md)). [doc] Since M98, Chrome can destroy Profiles separately from browser shutdown, along with keyed services such as Sync and History ([docs/shutdown.md](https://chromium.googlesource.com/chromium/src/+/main/docs/shutdown.md)) |
| `ProfileManager` | Owns loaded Profiles. Has `LoadProfile[ByPath]`, `CreateProfileAsync(path, …)`, static `CreateMultiProfileAsync(name, icon_index, is_hidden, …)`, `GetLoadedProfiles()` and `GetProfileByPath()`. Profiles stay alive through `ScopedProfileKeepAlive` origins such as `kBrowserWindow`, `kProfileCreationFlow` and `kProfilePickerView`. | [src] [profile_manager.h L216-290](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/profiles/profile_manager.h;l=216), [profile_keep_alive_types.h](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/profiles/keep_alive/profile_keep_alive_types.h) |
| `ProfileAttributesStorage` / `ProfileAttributesEntry` | The global profile list (name, avatar index, theme colours, ephemeral/omitted flags). It is stored in **Local State** under `profile.info_cache`. | [src] [pref_names.h L1365](https://source.chromium.org/chromium/chromium/src/+/main:chrome/common/pref_names.h;l=1365), [profile_attributes_entry.h L247-272](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/profiles/profile_attributes_entry.h;l=247) |
| `Browser` (implements `BrowserWindowInterface`) | One desktop browser window. `const raw_ptr<Profile> profile_` is fixed for the window's lifetime, and the Browser holds a `ScopedProfileKeepAlive`. | [src] [browser.h L258-262](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/browser.h;l=258) |
| `BrowserWindow` / `BrowserView` / `BrowserFrame` (views) | The native window. Code finds the `BrowserView` from an `NSWindow` via `BrowserView::GetBrowserViewForNativeWindow()`, about 28 files per GitHub code search. That makes window ↔ BrowserView 1:1. | [src] Used in [tab_drag_controller.cc L3175](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/views/tabs/dragging/tab_drag_controller.cc;l=3175) |
| `TabStripModel` | The ordered tabs of one Browser. Constructed with a `Profile*` and exposes `profile()`. | [src] [tab_strip_model.h L243](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/tabs/tab_strip_model.h;l=243) |
| `tabs::TabModel` / `TabFeatures` | Per-tab features are initialised with **the WebContents' own profile**, not the window's: `tab_features_->Init(*this, Profile::FromBrowserContext(contents_->GetBrowserContext()))`. | [src] [tab_model.cc L67-69](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/tabs/tab_model.cc;l=67) |
| `StoragePartition` / `StoragePartitionConfig` | A per-BrowserContext storage and network bucket: cookies (its own `NetworkContext`), HTTP cache, DOM storage, IndexedDB, service workers and quota. It is keyed by `(partition_domain, partition_name, in_memory)`. The default config has an empty domain. | [src] [storage_partition_config.h L15-50](https://source.chromium.org/chromium/chromium/src/+/main:content/public/browser/storage_partition_config.h;l=15) |
| `SiteInstance` / `BrowsingInstance` | The process-model grouping. Its `SiteInfo` carries a `StoragePartitionConfig`. `CreateForGuest(ctx, config)` is used for `<webview>`. `CreateForFixedStoragePartition(ctx, url, config)` creates "a custom StoragePartition that is preserved across navigations". | [src] [site_instance.h L246-258](https://source.chromium.org/chromium/chromium/src/+/main:content/public/browser/site_instance.h;l=246). The CL that added the "fixed storage partition" bit for isolated PWAs: [crrev 5012192](https://chromium-review.googlesource.com/c/chromium/src/+/5012192) (2023-11) |
| `RenderProcessHost` | Can never be shared across BrowserContexts **or** StoragePartitions: `IsSuitableHost` returns false on a BrowserContext difference and on a StoragePartition difference. | [src] [render_process_host_impl.cc ~L4999-5049](https://source.chromium.org/chromium/chromium/src/+/main:content/browser/renderer_host/render_process_host_impl.cc;l=4999) |

### 1.2 How the partition for a page is chosen today

- `ContentBrowserClient::GetStoragePartitionConfigForSite(BrowserContext*, const GURL& site)` maps a *site URL* to a partition ([content_browser_client.h L1194-1200](https://source.chromium.org/chromium/chromium/src/+/main:content/public/browser/content_browser_client.h;l=1194)). [src]
- Chrome's override returns non-default partitions only for:
  - `chrome-extension://` (Chrome Apps)
  - `isolated-app://` (IWAs)

  Its comment says these "aren't considered part of the user's normal browsing activity" ([chrome_content_browser_client.cc L1805-1845](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/chrome_content_browser_client.cc;l=1805)). [src]
- `<webview partition="persist:foo">` (Chrome Apps, WebUI) uses guest SiteInstances with an explicit partition. Electron's `session.fromPartition('persist:name')` is the same idea one layer up. [doc] [Electron session docs](https://www.electronjs.org/docs/latest/api/session#sessionfrompartitionpartition-options)
- Non-default partitions live on disk under `<profile>/Storage/ext/<domain>/<hash(name)>` ([storage_partition_impl_map.cc L59-65](https://source.chromium.org/chromium/chromium/src/+/main:content/browser/storage_partition_impl_map.cc;l=59)). [src]
- Partitions can be deleted with `BrowserContext::AsyncObliterateStoragePartition(domain, …)` and `GarbageCollectStoragePartitions(active_paths, …)` ([browser_context.h L192-209](https://source.chromium.org/chromium/chromium/src/+/main:content/public/browser/browser_context.h;l=192)). [src]
- **Why a site-keyed hook is not enough for normal tabs.** It cannot express "the same `https://mail.google.com` in two different jars". The partition has to be a property of the *tab or BrowsingInstance*, not of the URL. Upstream's "fixed storage partition" SiteInstance is exactly that primitive; the browser UI layer just never uses it for tabs. [inf, grounded in the src above]

### 1.3 Can WebContents from different Profiles live in one Browser window?

**At the views/NSView layer, yes.** `views::WebView::SetWebContents()` performs no BrowserContext check ([webview.cc L119](https://source.chromium.org/chromium/chromium/src/+/main:ui/views/controls/webview/webview.cc;l=119)) [src]. A native embedder can put any profile's `WebContents` native view anywhere. That is how an SDK-style embedder like Arc can do it (§2b).

**In Chrome's `Browser`/`TabStripModel`, no, by design.**
- `Browser::profile_` is `const` ([browser.h L259](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/browser.h;l=259)). [src]
- Tab dragging refuses cross-profile moves with "Profiles must be the same." ([tab_drag_controller.cc L3180-3183](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/views/tabs/dragging/tab_drag_controller.cc;l=3180)). [src]
- `Navigate()` creates new tabs with `params.browser->GetProfile()` ([browser_navigator.cc ~L600](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/navigator/browser_navigator.cc;l=600)). [src]
- When source and target profiles differ, `Navigate()` strips opener, source contents and referrer ([~L969-975](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/navigator/browser_navigator.cc;l=969)). [src]
- About 460 files under `chrome/browser` contain `browser->GetProfile()` (GitHub code-search count, approximate). [src/approx]

What breaks if you force mixed-profile tabs into one Browser [inf, by reading the components named]:

| Area | Why it breaks |
|---|---|
| Omnibox | `LocationBarView` is constructed with one `Profile*` ([location_bar_view.h L125-129](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/views/location_bar/location_bar_view.h;l=125)). Autocomplete, history suggestions and the search engine would come from the window's profile, and typed navigations would open in the window's profile. |
| Extensions toolbar / action icons | `ExtensionRegistry` is per BrowserContext ([extension_registry.h L33-35](https://source.chromium.org/chromium/chromium/src/+/main:extensions/browser/extension_registry.h;l=33)). The toolbar shows the window profile's extensions, so actions would target the wrong extension instance for a foreign tab. |
| Bookmarks bar, side panel (reading list, bookmarks), tab groups sync, reading list | All are `…Factory::GetForProfile(browser->GetProfile())`. Example: `ReadingListModelFactory::GetForBrowserContext(profile_)` in [tab_strip_model.cc](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/tabs/tab_strip_model.cc). |
| Downloads bubble | Uses `browser_view_->GetProfile()` ([download_toolbar_ui_controller.cc ~L755](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/views/download/bubble/download_toolbar_ui_controller.cc;l=755)). It shows the window profile's DownloadManager, not the tab's. |
| Session restore | `SessionService` is per profile and records windows, so foreign-profile tabs would be written into the wrong profile's session or lost. |
| Permissions / page info | Mostly per WebContents, so these mostly work, but the window-level content-setting icons and the profile menu assume one profile. |
| History, password manager, autofill | Attached per tab via TabFeatures and tab helpers using the WebContents' profile, so mostly OK (see tab_model.cc above). |
| Avatar button, profile menu, theme | Per window profile, so they would show the wrong identity and colour. |

---

## 2. Candidate designs

### (a) Space = real Profile; one `Browser` window per profile; the fork swaps windows in place

**Mechanics**
- Each Space-profile has its own Browser window at identical bounds. On switch, the fork orders the target window above the current one and then orders out the old one. This is a few `NSWindow` calls in `components/remote_cocoa/app_shim/` or `chrome/browser/ui/views/frame/` [inf].
- Chromium already has `profiles::SwitchToProfile(path, always_create, cb)` and `FindOrCreateNewWindowForProfile()` ([profile_window.h L35-76](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/profiles/profile_window.h;l=35)). [src]
- Global sidebar state must be shared across windows (see §4).

**macOS fullscreen is the hard part**
- Cocoa "dynamically creates a space and puts the window into that space" for each fullscreen window ([Apple, Implementing the Full-Screen Experience](https://developer.apple.com/library/mac/documentation/General/Conceptual/MOSXAppProgrammingGuide/FullScreenApp/FullScreenApp.html)). [doc]
- So with N profile windows fullscreen, a switch becomes a Mission-Control Space slide, which is not instant.
- **Possible workaround [inf, needs a prototype]:** Chromium's Mac bridge already has `SetCanAppearInExistingFullscreenSpaces()`. It flips `NSWindowCollectionBehaviorFullScreenAuxiliary`/`FullScreenPrimary` ([native_widget_ns_window_bridge.mm ~L1936-1951](https://source.chromium.org/chromium/chromium/src/+/main:components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm;l=1936)) and is used for things like PiP. [src]
  - One "host" window owns the fullscreen Space.
  - The other profile windows become auxiliary windows sized to the screen with the title bar hidden, layered in the same Space.
  - Edge cases to validate: key-window focus, menu-bar reveal, exiting fullscreen, the host window's profile being closed, and multi-monitor setups.
- **Alternative:** implement a non-native "simple fullscreen", i.e. a borderless screen-sized window plus `NSApplicationPresentationAutoHideMenuBar|AutoHideDock`, so all windows stay in one desktop Space [inf].

**Assessment**

| Criterion | Assessment |
|---|---|
| Feasibility | High in windowed mode; medium in fullscreen. |
| Patch size | Small to medium [inf]: window-swap logic, a sidebar view per window bound to global state, profile keep-alive, and the fullscreen work. |
| Rebase risk | Low to medium: mostly UI-layer and Mac window code; no content/ changes. |
| UX | Full isolation (extensions, history and passwords per Space). Switching is near-instant in windowed mode once windows exist; fullscreen depends on the trick above. A new Space costs profile init plus a first window (not measured, see Gaps). Tabs cannot move between Spaces except by reopening the URL (drag check above). Every Space-profile has its own extension installs, which is a real burden for the user. |

### (b) Space = real Profile; one multi-profile window that re-parents per-profile content (Arc's way)

**What is known about Arc and Dia**
- The Browser Company's own job posting: "we packaged Chromium as an SDK and wrapped our Swift code around it". The Swift codebase is "shared across MacOS, Windows, iOS and Android", and Dia has an "embedded-Chromium architecture" ([Built In: Software Engineer, Chromium](https://www.builtinchicago.org/job/software-engineer-chromium/10194923)). [doc/2nd]
- Arc is Chromium plus Swift UI ([Wikipedia](https://en.wikipedia.org/wiki/Arc_(web_browser)), [TechRadar](https://www.techradar.com/computing/browsers/the-arc-browser-just-launched-and-yes-it-really-is-that-good)). [2nd]
- I found **no public source** for "ADK", "ArcCore" or Arc's internal profile mapping (see Gaps).
- Arc Help: Profiles "scope logins, cookies, browsing history, and other settings to one or more Spaces" (via search summary; see prior research `google_accounts_and_identity.md` §1). [doc via 2nd]
- Forum users disagree on whether Arc extensions were per-profile or mirrored across profiles ([Orion feedback thread](https://orionfeedback.org/d/43-something-like-firefox-multi-account-containers-by-default/60), [MPU Talk](https://talk.macpowerusers.com/t/arc-browser-spaces-and-profiles/35872)). [2nd]
- Dia (same company) added in-place profile switching in v1.22 (Mar 2026) and swipe in Aug 2026 ([Dia changelog](https://www.diabrowser.com/changelog), [Dia release note 2026-08-06](https://diabrowser.com/release-notes/context-switching)). [doc] The mechanism is undocumented.

**Inference.** Arc and Dia do not use Chrome's `Browser`/`BrowserView` UI at all. Their native Swift window hosts `WebContents` native views from whichever Chromium Profile a Space is bound to. Since views and NSViews are profile-agnostic (§1.3), "different cookie jars in one window" falls out naturally. The cost is that they rebuilt the entire browser UI natively: omnibox, downloads, permissions, extension UI and so on. [inf]

**For this fork:** either
- (b1) make `Browser` multi-profile, which is infeasible to maintain (§1.3); or
- (b2) write a separate native window shell over `content/` and `chrome/` services, which is Arc-scale engineering.

**Assessment**

| Criterion | Assessment |
|---|---|
| Feasibility | Low for a small team. |
| Patch size | Very large. |
| Rebase risk | Very high. |
| UX | Best possible, but it is a multi-year project. |

### (c) One Profile; a separate StoragePartition per Space ("containers")

**Upstream primitives (all [src])**
- `StoragePartitionConfig::Create(ctx, domain, name, in_memory)`
- `SiteInstance::CreateForFixedStoragePartition()`, which keeps the partition across cross-site navigations
- `RenderProcessHost` partition isolation
- `AsyncObliterateStoragePartition` / `GarbageCollectStoragePartitions` for deletion

**Brave's shipped implementation (brave-core, MPL-2.0)**
- **Timeline:**
  - Containers umbrella issue opened 2025-05-26 and closed 2026-06-01 ([brave-browser#46349](https://github.com/brave/brave-browser/issues/46349)).
  - "Enable Containers feature by default" merged 2026-06-24 ([brave-core#37493](https://github.com/brave/brave-core/pull/37493)).
  - Public post: [Brave blog: Containers](https://brave.com/blog/containers/) (1.92, July 2026). [doc]
- **Approach, quoting PR [#30150 "Partitioned tabs foundation"](https://github.com/brave/brave-core/pull/30150) (+1890/−30, 54 files)** [doc]:
  1. "Use StoragePartitionConfig to allow new tabs to be opened with a custom storage partition".
  2. Save the container partition info into the session "as part of URL" so unsupported browsers or a disabled feature won't load those pages.
  3. Restore tabs with the right partition (`browser_tabrestore.cc`).
  4. "Allow navigation in new tabs to inherit containers storage partition" (`web_contents_impl.cc`).
- **Code** [src]:
  - `kContainersStoragePartitionDomain = "containers"`, with the container UUID as `partition_name` ([storage_partition_utils.h](https://github.com/brave/brave-core/blob/master/components/containers/content/browser/storage_partition_utils.h)).
  - `SiteInstance::CreateForURLWithOptionalFixedStoragePartition()` is a thin wrapper over upstream `CreateForFixedStoragePartition` ([chromium_src/content/browser/site_instance_impl.cc](https://github.com/brave/brave-core/blob/master/chromium_src/content/browser/site_instance_impl.cc)).
  - A `NavigateParams::storage_partition_config` field, plus `GetStoragePartitionConfigToInherit()` that inherits from `source_site_instance` ([patch](https://github.com/brave/brave-core/blob/master/patches/chrome-browser-ui-navigator-browser_navigator.cc.patch), [override](https://github.com/brave/brave-core/blob/master/chromium_src/chrome/browser/ui/navigator/browser_navigator.cc)).
  - New `ContentBrowserClient::ShouldInheritStoragePartition()` and `ShouldUseDefaultHostZoomMapForStoragePartition()` hooks ([chromium_src/content/public/browser/content_browser_client.h](https://github.com/brave/brave-core/blob/master/chromium_src/content/public/browser/content_browser_client.h)).
  - Overall, about 89 files under `chromium_src/` and `patches/` mention containers. That count includes settings UI, menus and tests. Core touch points:
    - `content/browser/site_instance_impl.cc`
    - `navigation_entry_impl.cc`
    - `worker_host/shared_worker_host.cc`
    - `service_worker/*`
    - `blink/common/page_state/page_state.cc`
    - `components/sessions/content/*`
    - `chrome/browser/sessions/session_restore.cc`
    - `chrome/browser/ui/browser_tabrestore.cc`
    - `chrome/browser/tab_contents/tab_util.cc`
    - `startup_browser_creator_impl.cc`
    - `components/permissions/permission_util.cc`
    - `content_settings_manager_delegate.cc`
    - `render_view_context_menu.cc`
    - bookmarks context menu
- **Follow-up PRs worth porting** [doc]:
  - Session restore and sync ([#33313](https://github.com/brave/brave-core/pull/33313))
  - New-tab and noopener inheritance ([#33464](https://github.com/brave/brave-core/pull/33464))
  - Remove storage on container removal ([#35106](https://github.com/brave/brave-core/pull/35106))
  - Share zoom with the default partition ([#36645](https://github.com/brave/brave-core/pull/36645))
  - Pinned tabs with containers ([#36683](https://github.com/brave/brave-core/pull/36683))
  - Undelegated permissions no longer silently denied ([#37844](https://github.com/brave/brave-core/pull/37844)). Chromium's `IsPermissionBlockedInPartition` silently denies notifications etc. when a page's partition is not the origin's "home" partition. Brave exempts container partitions, and "Permissions remain profile-scoped (shared across containers)".
  - Platform-auth SSO disabled in containers ([#38716](https://github.com/brave/brave-core/pull/38716))
  - Clear container site data on exit ([#40750](https://github.com/brave/brave-core/pull/40750))
  - "Traffic Control" site→container routing ([#39321](https://github.com/brave/brave-core/pull/39321)), which is the analogue of Arc's Air Traffic Control.
- **Data model** [src]: `{id, name, icon (enum), background_color}`, stored in profile prefs `brave.containers.list` ([containers.mojom](https://github.com/brave/brave-core/blob/master/components/containers/core/mojom/containers.mojom), [pref_names.h](https://github.com/brave/brave-core/blob/master/components/containers/core/browser/pref_names.h)).
- **Known open issues, i.e. what the fork will inherit** [doc]:
  - [#57209](https://github.com/brave/brave-browser/issues/57209): `chrome.cookies` targets the default store, not the container.
  - [#54688](https://github.com/brave/brave-browser/issues/54688): an extension's OAuth flow opens in the default (non-contained) tab. A Brave dev says "extensions are not containerized and external links are always opened in a non-contained way".
  - [#59700](https://github.com/brave/brave-browser/issues/59700) (2026-10-05, open): "Google accounts don't seem to respect the boundary", seen with YouTube after using Traffic Control. Cause unknown. **Directly relevant to this user.**
  - [#55380](https://github.com/brave/brave-browser/issues/55380): history and bookmarks are not container-aware.
  - Container data is deleted from disk only once nothing references it, on the next start.

**Helium (ungoogled-chromium based)**
- Feature request [imputnet/helium#199](https://github.com/imputnet/helium/issues/199) is open. A contributor has a working branch [dvjn/helium `feat/containers`](https://github.com/dvjn/helium/tree/feat/containers): 10 patches, about 3,550 added lines. [src]
- Its core patch touches:
  - `browser_navigator{.cc,_params.h}`, `tab_util.{h,cc}`, `startup_browser_creator_impl.cc`
  - `content_browser_client.{h,cc}` and `web_contents_impl.cc` (keep links in container)
  - `chrome_content_browser_client.{h,cc}`
  - `components/permissions/permission_util.cc`
- On 2026-10-24 a Helium maintainer said "it makes sense to just import brave's implementation" instead. [doc]
- This is a useful size estimate for a minimal port onto plain Chromium: about 3.5k lines without session-restore hardening. Brave-grade is roughly 2 to 3 times that [inf].

**What is isolated vs shared in (c)**

Isolated per Space, because they are per StoragePartition:
- cookies, HTTP cache, localStorage, sessionStorage, IndexedDB, CacheStorage, service workers, shared workers
- renderer processes (§1.1)

FedCM / "Sign in with Google" fetches use the frame's partition (`host->GetStoragePartition()->GetURLLoaderFactoryForBrowserProcess()`), so IdP cookies are per Space. The FedCM permission context is per BrowserContext, so "connected accounts" state is shared ([idp_network_request_manager.cc ~L790-803](https://source.chromium.org/chromium/chromium/src/+/main:content/browser/webid/idp_network_request_manager.cc;l=790)). [src]

Shared, because they are per Profile:
- history, bookmarks, passwords, passkeys stored in the Chrome profile, autofill
- extensions, content settings and permissions (Brave keeps them shared), zoom (Brave shares it)
- search engine, omnibox suggestions (fetched with the profile's default network context, which is a minor cross-Space leak [inf])
- downloads list (per-partition download resumption not verified, see Gaps)

**Assessment**

| Criterion | Assessment |
|---|---|
| Feasibility | High. It is proven in Brave on macOS/Windows/Linux. |
| Patch size | Medium: about 3.5k lines minimal, more for production quality. |
| Rebase risk | Medium. It touches `content/` navigation/SiteInstance and session code, which churn. Mitigation: Brave rebases the same changes every Chromium milestone, so their diffs can be diffed against each release [inf]. |
| UX | Same window, instant switch, trivial creation, extensions installed once. Isolation is cookies/storage only, not history, extensions or passwords. |

### (d) What other browsers shipped

| Browser | Per-Space identity? | Mechanism / notes |
|---|---|---|
| **Brave** | Yes: Containers (1.92, July 2026), plus Traffic Control site routing | StoragePartition per container (above). [doc/src] |
| **Arc** | Yes: Profiles bound to Spaces, same window | Native Swift UI over a "Chromium SDK" (above). Sunset 2026-12-22 ([arc.net](https://arc.net/)). [doc] |
| **Dia** | Yes since v1.22 (Mar 2026): profiles "switch in place", swipe since Aug 2026 | Undocumented. Same company and architecture as Arc. [doc] |
| **Edge** | Profiles = separate windows. "Automatic profile switching" prompts to open a link in another profile's window ([MS Learn policy](https://learn.microsoft.com/en-my/deployEdge/microsoft-edge-policies/automaticprofileswitchingsitelist), [LaptopMag](https://www.laptopmag.com/uk/news/microsoft-edge-gets-a-killer-new-update-for-remote-workers)). Workspaces are *shared tab sets* (tabs, favorites, history), not cookie isolation ([MS Learn: Edge Workspaces](https://learn.microsoft.com/en-us/DeployEdge/microsoft-edge-workspaces)). | [doc/2nd] |
| **Vivaldi** | No. Workspaces are UI-only. A team member says containers "would require a significant rework in the backend" ([forum](https://forum.vivaldi.net/topic/25289/multi-account-containers/254)). | [2nd] |
| **Opera** | No. Workspaces share cookies. A moderator says "Workspaces are not made for that" ([forum](https://forums.opera.com/post/249829)). | [2nd] |
| **Helium** | Not yet. FR #199 plus a contributor branch (above). | [doc] |
| **BrowserOS** | Not yet. Open request [browseros-ai/BrowserOS#2342](https://github.com/browseros-ai/BrowserOS/issues/2342) "Add containers…", 2026-08. | [doc] |
| **Thorium** | Nothing found. | gap |
| **SigmaOS** (WebKit, not Chromium) | Yes: per-Workspace "Separate Profiles"/"separate cookies" ([SigmaOS docs](https://docs.sigmaos.com/tutorial/workspaces), [FAQ](https://sigmaos.com/docs/faq)). Likely a `WKWebsiteDataStore` per workspace [inf]. | [doc] |
| **Wavebox** (Chromium) | Yes: per-Space cookie stores ("cookie containers") ([Wavebox Hub](https://hub.wavebox.io/spaces/)). Likely StoragePartitions [inf]. | [doc] |
| **Chrome/Chromium upstream** | No containers. A feature request exists ([crbug 419637126](https://issues.chromium.org/issues/419637126), per prior research; also [crbug 40896879](https://issues.chromium.org/issues/40896879) cited on the Vivaldi forum). No design doc found. | [2nd] |

---

## 3. "Insanely smooth" Space and profile creation

### With design (c), containers (v1)

Creation is a pure data operation [inf from src]:
1. Generate a UUID.
2. Store `{id, name, emoji, color}` (see §4).
3. Open a tab with `NavigateParams.storage_partition_config = StoragePartitionConfig::Create(profile, "containers", uuid, /*in_memory=*/false)`.

The partition and its directory are created lazily on first use, so there is no async profile init and no window. A one-step popover in the sidebar (name + emoji + colour, Enter) can create the Space and switch to it in one frame. A per-Space colour can drive the sidebar tint without touching the profile `ThemeService` [inf].

### With design (a), real profiles (v2)

What Chromium's own local-profile path does today [src] ([profile_picker_view.cc L452-483](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/views/profiles/profile_picker_view.cc;l=452)):
1. `ProfileManager::CreateMultiProfileAsync(name, icon_index, /*is_hidden=*/true, cb)` creates a directory "Profile N".
2. In the callback, `ThemeServiceFactory::GetForProfile(p)->SetUserColorAndBrowserColorVariant(color, kTonalSpot)`.
3. The flow controller then calls `FinalizeNewProfileSetup(profile, name, is_default_name)` ([profile_customization_util.h L21](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/profiles/profile_customization_util.h;l=21)), which un-hides the profile and sets its name.
4. Attributes are set with `ProfileAttributesEntry::SetLocalProfileName`, `SetAvatarIconIndex` and `SetProfileThemeColors`.
5. The window opens via `profiles::OpenBrowserWindowForProfile` / `SwitchToProfile`.

Related code:
- [chrome/browser/ui/views/profiles/](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/views/profiles/): `ProfilePickerView`, `ProfileManagementFlowController`, `profile_customization_bubble_sync_controller`, and the overview doc [profile_management.md](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/ui/views/profiles/profile_management.md).
- The WebUI picker is under `chrome/browser/ui/webui/signin/`.

A sidebar one-step flow can call steps 1 to 5 directly and skip the picker entirely. Emoji avatars are not a Chromium concept, since avatars are an index into a fixed icon set. Store the emoji in the fork's own Space record and optionally render it as a custom avatar [inf].

### Google sign-in in a fork without Google's private API keys

- Google restricted third-party Chromium builds' access to private APIs (Chrome Sync, etc.) from **2021-03-15** ([Chromium Blog, 2021-01-15](https://blog.chromium.org/2021/01/limiting-private-api-availability-in.html)). [doc]
- chromium.org: "Signing in to Chromium is restricted" because the OAuth token "cannot be generated". `chrome.identity.getAuthToken` "will fail outside of Google Chrome as the implementation uses restricted APIs" ([API Keys page](https://www.chromium.org/developers/how-tos/api-keys/)). [doc]

What still works and what doesn't:
- **Doesn't work:** browser-level "Sign in to Chrome" (sync, DICE identity). [doc]
- **Works:** signing into gmail.com, Google Workspace and YouTube *on the web*, because those are ordinary cookies in the Space's partition or profile. Brave, Vivaldi, Arc and Helium all ship without Chrome Sync, and users sign into Google on the web [inf/2nd].
- Google blocks sign-in from *embedded browser frameworks* (CEF etc.) since June 2019 ([Google Security Blog 2019-04](https://security.googleblog.com/2019/04/better-protection-against-man-in-middle.html)). [doc] A full Chromium fork with a standard UA is not an embedded framework [inf], but keep the default Chrome UA and do not advertise CEF/WebView.
- **"Sign in with Google"** (GIS/FedCM): cookies are per partition (§2c), so it works per Space. [src]
- **Passwords:** the local password store is per Profile. In (c) all Spaces share one store, which is convenient. In (a) each Space-profile has its own [inf from Chromium architecture].
- **Passkeys:**
  - Chrome-profile passkeys are local-only and per Profile ([Chrome Developers blog, Chrome 118 iCloud Keychain](https://developer.chrome.com/blog/passkeys-on-icloud-keychain)). [doc]
  - iCloud Keychain passkeys require Apple's restricted `com.apple.developer.web-browser.public-key-credential` entitlement. Third-party Chromium browser developers report trouble getting it provisioned and working ([Apple forum thread 852550](https://developer.apple.com/forums/thread/852550)). [2nd]
  - Google Password Manager passkeys need Chrome sign-in/sync, so they are unavailable in a fork [inf].

---

## 4. Shared vs per-profile data, and where the sidebar's data should live

| Data | (c) containers | (a) real profiles | Note |
|---|---|---|---|
| Cookies / site storage | per Space | per Space | |
| Extensions | **shared** (installed once) | per Space (reinstall each) | `ExtensionRegistry` per BrowserContext [src]. Extensions see container tabs, but their own requests and `chrome.cookies` use the default jar (Brave #57209) |
| History | shared | per Space | Brave's TODO: container-aware history |
| Passwords / autofill | shared | per Space | |
| Permissions / site settings | shared (Brave) | per Space | |
| Bookmarks | shared | per Space | the sidebar should own its pins anyway |
| Session restore | needs patch (Brave #33313) | free (per profile) | |

**Sidebar data (Spaces list, pinned tabs, folders, favorites) should be global** [inf]:
- **Local State pref** (`g_browser_process->local_state()`, registered in `RegisterLocalState()` [browser_prefs.cc L1725](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/prefs/browser_prefs.cc;l=1725)):
  - Suits the *small* Spaces registry (`id`, name, emoji, colour, order, bound container id or profile path). The profile registry itself lives there too (`profile.info_cache`).
  - Downside: Local State is one JSON file shared by everything and rewritten on each commit, so keep high-churn data out of it [inf].
- **Custom file under the user-data-dir**, e.g. `<user-data-dir>/Spaces/sidebar.json` written with `base::ImportantFileWriter`, or SQLite:
  - Suits pinned tabs and folder trees, which change often and may grow.
  - It stays profile-independent, so design (a) in v2 can reuse it unchanged.
- In (c), the per-Space *container id* is the key that binds sidebar items to partitions. Store the container id on each pinned item so reopening a pin uses the right partition.

---

## 5. Memory, performance and instant switching

- **Renderer processes dominate memory** and are never shared across Profiles *or* StoragePartitions (`IsSuitableHost` [src]). So N Spaces with the same sites open costs about the same renderer memory in (a) and (c) [inf].
- **Per-Profile browser-process overhead** comes from KeyedServices: History DB, Sync, extensions (each extension's background or service worker runs per profile), password store, etc. [src/doc]. **Each extension is instantiated once per profile in (a)**: 10 extensions × 5 Spaces gives 50 extension contexts. In (c) it is 10 [inf]. This is the biggest memory difference.
- **I found no published MB-per-profile figure** (gap). Measure with `chrome://memory-internals` / `chrome://histograms/Memory` on a build with 5 profiles vs 5 containers.
- **Keeping things warm:**
  - **(a):** keep each Space-profile loaded with a fork-specific `ProfileKeepAliveOrigin` (e.g. `kSpaceSwitcher`) added to [profile_keep_alive_types.h](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/profiles/keep_alive/profile_keep_alive_types.h). Keep its window alive but ordered-out, so the switch is just window ordering [inf].
    - With `kDestroyProfileOnBrowserClose`, a profile is destroyed when its last keep-alive goes ([profile_manager.cc](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/profiles/profile_manager.cc), `UnloadProfileIfNoKeepAlive`). [src]
  - **(c):** switching only changes which tabs the sidebar shows and activates a tab that is already alive. Cost is one tab activation, the same as a normal tab switch [inf].
  - **Spare renderer caveat:** "the spare renderer is bound to a BrowserContext and its default StoragePartition … Only the default StoragePartition will be able to use a spare renderer" ([spare_render_process_host_manager_impl.h L124-131](https://source.chromium.org/chromium/chromium/src/+/main:content/browser/renderer_host/spare_render_process_host_manager_impl.h;l=124)). [src]
    - So the first navigation in a fresh tab of a non-default Space pays process startup.
    - Optional optimisation: extend the spare manager to warm a spare for the active Space's partition [inf].
  - Background Spaces' tabs can still be discarded by Memory Saver / tab lifecycle. Brave stores container info in `WebContentsUserData` across discards ([storage_partition_utils.h](https://github.com/brave/brave-core/blob/master/components/containers/content/browser/storage_partition_utils.h), `GetContainerIdForWebContents`). [src]

---

## 6. Recommendation and concrete touch points

### v1: Spaces as containers (design c), ported from Brave

1. **Partition plumbing.** Port Brave's changes as direct patches. Brave uses `chromium_src` overrides; a plain fork applies the equivalent edits:
   - `content/public/browser/site_instance.h` and `content/browser/site_instance_impl.cc`: `CreateForURLWithOptionalFixedStoragePartition`.
   - `chrome/browser/tab_contents/tab_util.{h,cc}`: `GetSiteInstanceForNewTab(profile, url, optional partition)`.
   - `chrome/browser/ui/navigator/browser_navigator_params.h`: the `storage_partition_config` field.
   - `chrome/browser/ui/navigator/browser_navigator.cc`: `CreateTargetContents` and inheritance from `source_site_instance`.
   - `content/public/browser/content_browser_client.{h,cc}`, `content/browser/web_contents/web_contents_impl.cc` and `chrome/browser/chrome_content_browser_client.{h,cc}`: `ShouldInheritStoragePartition` for `window.open`, noopener and target=_blank.
   - `components/permissions/permission_util.cc`: exempt the Spaces partition domain in `IsPermissionBlockedInPartition`.
   - HostZoomMap: share zoom with the default partition (Brave #36645).
   - `components/sessions/content/content_serialized_navigation_{builder,driver}.cc`, `chrome/browser/ui/browser_tabrestore.cc`, `chrome/browser/sessions/session_restore.cc`, `content/browser/renderer_host/navigation_entry_impl.cc` and `third_party/blink/common/page_state/page_state.cc`: persist and restore the Space id per tab.
   - `chrome/browser/ui/startup/startup_browser_creator_impl.cc`: `--space=<id>` / open-in-Space.
   - Workers: `content/browser/worker_host/shared_worker_host.cc` and `service_worker/*` per Brave.
2. **Space service.** A small `KeyedService` (or a global object) owns the Space registry (§4) and deletes a Space's data via `BrowserContext::AsyncObliterateStoragePartition` / `GarbageCollectStoragePartitions`.
3. **UI** (another track): the sidebar filters the single `TabStripModel` by Space id and has a one-step "New Space" popover. "Open link in Space…" goes in `render_view_context_menu.cc`. Optional Traffic-Control-like routing rules.
4. **Disable or hide features that assume one identity per profile:** the Chrome sign-in UI (already unusable without keys) and the profile avatar menu.

### v2: optional hard-isolated Spaces (design a)

- A Space can be marked "separate profile" and then binds to a real Chromium Profile.
- The fork keeps that profile's window alive, swaps it in place, and uses `SetCanAppearInExistingFullscreenSpaces` or custom simple-fullscreen for fullscreen.
- Files involved:
  - `chrome/browser/profiles/profile_window.cc`
  - `chrome/browser/profiles/keep_alive/profile_keep_alive_types.h`
  - `components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm`
  - `chrome/browser/ui/views/frame/browser_view.cc`
  - the sidebar view, reading the global Spaces file

### Alternative strategic option (for the base-choice track)

**Fork Brave (brave-core) instead of Chromium.** Containers, vertical tabs and Traffic Control already exist and are maintained per Chromium release. The cost is Brave's larger build and its product surface (Rewards, Wallet, Leo), which would need to be disabled or removed [inf].

### Main risks

1. Google-account bleed across containers ([Brave #59700](https://github.com/brave/brave-browser/issues/59700), open, cause unknown).
2. Extensions are not container-aware: `chrome.cookies` and extension-initiated OAuth use the default jar.
3. Rebase churn in content/ navigation code.
4. Shared history and permissions may surprise a user who expects Arc-style "profile" separation.
5. The macOS fullscreen trick for v2 is unproven.

---

## 7. Gaps and open questions

- **Arc/Dia internals:** no primary source for "ADK", "ArcCore", how Arc maps Profiles to Chromium profiles, or how Dia's "switch in place" works. The only primary statement is "packaged Chromium as an SDK and wrapped our Swift code around it". A look inside `Arc.app/Contents/Frameworks` on the user's Mac would settle the framework names.
- **Arc extensions:** were they per profile? Forum sources conflict.
- **Memory:** no measured MB-per-profile or MB-per-partition numbers found.
- **Creation latency:** time for `CreateMultiProfileAsync` plus the first window was not measured.
- **Brave #59700:** root cause of the Google-account boundary bug unknown. Possibly Traffic Control or a sync/session-state interaction, not partitioning itself.
- **DBSC:** behaviour of Device Bound Session Credentials (`BoundSessionCookieRefreshService`, per Profile) for Google cookies inside non-default partitions was not verified. DBSC may be off anyway in builds without Google keys.
- **Downloads:** whether downloads started in a container tab resume with the right partition was not verified.
- **macOS fullscreen:** whether the `FullScreenAuxiliary` approach works for full browser windows (focus, menu-bar reveal, Stage Manager) needs a prototype.
- **Chromium bugs:** I could not open crbug 419637126 or 40896879 (JS-rendered tracker). Their status is taken from secondary sources.
- **License:** MPL-2.0 (Brave) applies per file. Porting is fine for a fork, but ported files must stay MPL [inf; check with whoever owns licensing].

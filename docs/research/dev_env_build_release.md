# Track: Dev environment, build, test, CI, release and update pipeline

Research date: 2026-11-03. Scope: an Arc-style Chromium fork for macOS, maintained by an AI agent on every Chrome release, by a user who only reaches the Linux dev box ("the Linux build box") over Tailscale.

Legend: **[F]** = fact with source. **[I]** = my inference or estimate. **[V]** = verified on this machine or against a live API today.

---

## 0. TL;DR

- **Release cadence changed. Plan for it.** Since Chrome 153 (2026-09-08), Chrome ships a new **major every 2 weeks**, not every 4 [F][V]. Weekly security respins continue. Extended Stable stays on an **8-week** major cycle [F]. Mac stable has had about 2–3 release events per week since August [V]. A fork that rebases on every Stable major takes about 26 major rebases a year.
  - **Recommendation:** run the AI loop on **Extended Stable** by default (about 6.5 major rebases a year, plus security respins), and offer Stable as an opt-in channel once the loop is reliable. This also gives an 8-week buffer when a major rebase fails. Without that buffer you would have to downgrade, and Chromium profiles cannot be downgraded.
- **Linux box (Threadripper 2950X, 16C/32T, 46 GB, SATA SSD) is good for day-to-day development, unit, browser and interactive tests, and conflict detection.** It cannot produce Mac builds:
  - Cross-compiling for macOS from Linux is not supported for non-Googlers. It needs Google's internal hermetic Xcode.
  - Xcode 27, which M157+ uses, runs only on Apple silicon [F].
- **A Mac is required for release builds.** Best value: a **Mac mini M5 Pro (18-core, 64 GB, 1–2 TB)**, about $2.7–3.2k once [I], on the same LAN as the Linux build box and on the tailnet, registered as a self-hosted GitHub Actions runner or driven over SSH.
  - Rental alternatives: MacStadium M4 Pro at about $349/mo [F], Scaleway M4 Pro at about €335–360/mo [F, unverified], or Depot macOS runners at about $26–36 per arm64 build [F+I].
  - AWS EC2 Mac (mac-m4pro.metal at $1.97/h with a 24 h minimum per allocation) is poor value for this cadence.
- **Build times [I]:**
  - Linux first full `chrome` (release, component build, no symbols): about 3–5 h. With `unit_tests`, `browser_tests` and `interactive_ui_tests`: about 6–9 h.
  - Linux incremental edit-build-run: about 0.5–3 min.
  - Mac M5 Pro official (ThinLTO + PGO) arm64 build: cold about 3–4.5 h. Same-milestone respin with a warm ccache/sccache: about 1–2 h.
- **How the user sees Linux builds:** run the dev build inside a **linuxserver `baseimage-selkies` container**: a web desktop streamed to the browser [F]. Expose it with `tailscale serve --https=8451`, then open `https://<build-box>.<tailnet>.ts.net:8451/` on the MacBook.
- **Releases:** Developer ID ($99/yr), Chromium's own `sign_chrome.py --notarize` (Helium does exactly this [F]), a DMG via Chromium's `pkg-dmg`, and Sparkle 2.10.x with EdDSA plus `generate_appcast` deltas [F].
  - Host the appcast on the tailnet first. It is private, free, and the MacBook is always on the tailnet.
  - Move it to Cloudflare R2 or GitHub Releases when friends join.
- **Monthly cost [I]:**
  - Owned Mac mini: about $10–15/mo cash (Apple Developer Program plus power), plus about $80/mo amortised hardware.
  - Rented Mac: about $350–400/mo.
  - Depot CI: about $150–300/mo, depending on how many respins you ship.
  - Agent LLM costs are not included.

---

## 1. Local Linux dev builds on the Linux build box

### 1.1 Machine facts [V]
- CPU: AMD Ryzen Threadripper 2950X, 16 cores / 32 threads, 3.5 GHz max (Zen+, 2018).
- RAM: 46 GB. About 19 GB is already used by other services, so about 26 GB is available. Swap: 8 GB swapfile.
- Disk: `~` is on a Samsung 860 SATA SSD with 792 GB free. `/` is on the WD HDD (LVM). `/tmp` is a 24 GB tmpfs. Per CLAUDE.md, keep everything under `~`.
- OS: Ubuntu 26.04.1 LTS ("resolute"). Chromium's `install-build-deps.py` explicitly supports `resolute` (Ubuntu 26.04 LTS, EoS May 2031) [F: https://raw.githubusercontent.com/chromium/chromium/main/build/install-build-deps.py lines 193–214].
- Already present: Docker 29.9, git, python3 3.14, node, bun, tmux, Xvfb, tailscale.
- Current upstream versions [V via https://versionhistory.googleapis.com and https://chromiumdash.appspot.com/fetch_milestone_schedule]:
  - Mac Stable: 156.0.8078.80, with 157.0.8103.26 rolling out today. The M157 stable date is 2026-11-03.
  - Extended Stable: 156.0.8078.80.
  - Trunk: 159.0.81xx (`chrome/VERSION` on main = 159.0.8141.0).

### 1.2 Requirements from the docs
- Linux: "x86-64 machine with at least 8GB of RAM. More than 16GB is highly recommended … At least 100GB of free disk space" [F: https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md].
- Siso is now the default build tool. GN generates the build files and `autoninja` wraps Siso [F: same doc]. As of June 2025, Siso "is used by default on non-Google environments" [F: https://chromium.googlesource.com/build/+/refs/heads/main/siso/README.md].
- `fetch --git-cache chromium` seeds from a shared prebuilt snapshot (about 30 GB cache). "Expect the command to take 30 minutes on even a fast connection" [F: Linux build doc].

### 1.3 Disk budget [I]
| Item | Size |
|---|---|
| depot_tools + CIPD/GCS caches | ~5 GB |
| git cache (`$GIT_CACHE_PATH`) | ~30 GB [F] |
| `src/` working tree incl. third_party deps | ~40–60 GB |
| `out/Dev` (release, component, symbol_level=0) incl. test binaries | ~40–80 GB |
| `out/Debug` (optional, symbol_level=2) | 100–150 GB |
| ccache/sccache | 50–100 GB (cap it) |
| 2nd worktree for rebase attempts (shares git cache) | +40–60 GB src + its own out dir |
| **Total recommended reservation** | **~300–400 GB of the 792 GB free** |

### 1.4 RAM and linker memory
Chromium's own scheduler estimates of memory per link job [F: https://raw.githubusercontent.com/chromium/chromium/main/build/toolchain/concurrent_links.gni]:

| Configuration | Estimated GB per link job |
|---|---|
| Linux, `symbol_level=0` | 3 |
| Linux x64, `symbol_level=1` | 20 |
| Linux x64, `symbol_level=2` | 54 |
| Linux x64, `symbol_level=1` with `use_debug_fission` | 11 |
| ThinLTO / official, Linux | 30 |
| ThinLTO / official, other platforms incl. Mac | 20 |
| Mac, non-LTO, no dSYMs | 4 |
| Mac, non-LTO, with dSYMs | 12 |

- **Is 46 GB enough?** Yes for dev configurations (component build, `symbol_level` 0 or 1) [I]. The constraint is compile parallelism, not links: 32 concurrent clang processes at roughly 0.5–1.5 GB each can exceed the about 26 GB that is free while other services run.
- **Recommendations [I]:**
  - Cap local jobs with `autoninja -j 24`, or put `ninja --local_jobs=24` in `build/config/siso/.sisorc` [F: siso_tips.md documents both].
  - Grow swap to 32 GB on the SSD. Chromium recommends ">=16GB of swap" for 16 GB machines [F].
  - Set `vm.max_map_count=262144` if you ever do an official ThinLTO Linux build [F: Linux doc, "Linker Crashes"].
  - A full official Linux ThinLTO link (about 30 GB) is feasible only when other services are idle. You do not need one: Linux is for development and tests only.

### 1.5 Build-time estimates
- **Anchor [F/V]:** Chromium publishes the CPU-hours for a clean `chrome` build with default gn args (debug, component) on a Linux GCE instance [F: https://commondatastorage.googleapis.com/chromium-browser-clang/build-time.html]. I parsed the page's data:
  - Median 2023-01: 51 CPU-h.
  - Median 2025-10: 95 CPU-h.
  - 2026-11-02/03: **76–81 CPU-h**.
  - Build cost has roughly doubled since early 2023.
- **Estimate for this box [I]:**
  - 80 CPU-h across 32 SMT threads is at least 2.5 h ideal. Real throughput is lower: SMT gain is about 1.25x rather than 2x, the CPU is Zen+, the SSD is SATA, and `-j` is capped by RAM.
  - First full `chrome` (release, component, `symbol_level=0`, `blink/v8_symbol_level=0`): **about 3–5 h**.
  - Adding `unit_tests`, `browser_tests` and `interactive_ui_tests` (these share most objects but add large links and test code): **about +2–4 h**.
  - A new major (for example 156→157) touches most of the tree, so expect close to a full rebuild every major. A same-milestone security respin is usually much smaller. The version bump touches `chrome_version.h` and LASTCHANGE, which pulls in a moderate rebuild: **about 15–60 min [I]**.
  - Incremental edit-build-run loop for a single `.cc` file under `chrome/browser/ui/views/...` in a component build with `symbol_level=0`: **about 30 s–3 min**. Editing a widely included header can take tens of minutes.
  - WebUI TypeScript-only changes: about 1–2 min.
- **Caching:**
  - Siso alone keeps only incremental state. It has no local content cache across out dirs or worktrees.
  - Options (a) and (b) are complementary:
    - **(a) `cc_wrapper="ccache"` or `"sccache"` with `use_siso=true`.** Helium's macOS dev and CI do exactly this [F: helium-macos `devutils/shared.sh` `write_gn_args`]. The Chromium Linux doc says ccache gives about 1/3 build time for a second worktree [F]. It also says ccache is "not useful if you're using Siso" [F], which I read as "not useful with Siso remote execution" [I].
    - **(b) A self-hosted REAPI backend (NativeLink, Apache-2.0, supports Siso [F: https://github.com/tracemachina/nativelink]) in Docker on the Linux build box.**
      - It gives a persistent action cache across worktrees and branches.
      - It is also the foundation for offloading **Mac** compiles to this Linux box (see §3.5).
      - Helium ships a `nativelink.star` Siso backend config for this [F: helium `patches/helium/core/rbe-nativelink-config.patch`].
  - Recommendation: start with **ccache on the SSD (cap 80 GB)**, and add NativeLink only when a Mac joins.

### 1.6 Recommended `args.gn`
Notes:
- **`enable_nacl` no longer exists.** NaCl is gone in M157: `components/nacl` and `native_client` are absent from `DEPS` [V]. Do not set it, especially with `--fail-on-unused-args`.
- Default `symbol_level` for a Linux release build is already 0 [F: `build/config/compiler/compiler.gni` @157].

**`out/Dev`: Linux daily iteration**
```gn
is_debug = false
dcheck_always_on = true          # catch DCHECKs without debug-build cost
is_component_build = true        # fast incremental links
symbol_level = 0                 # set 1 when you need line-level stack traces
blink_symbol_level = 0
v8_symbol_level = 0
chrome_pgo_phase = 0             # skip PGO profiles for dev
enable_remoting = false
use_siso = true                  # default; explicit for clarity
cc_wrapper = "ccache"            # or "sccache"; see 1.5
proprietary_codecs = true        # match the Mac release behaviour
ffmpeg_branding = "Chrome"
# treat_warnings_as_errors stays default (true): keep patches warning-clean
```

**`out/Debug`: optional, for lldb/gdb sessions**
```gn
is_debug = true
is_component_build = true
symbol_level = 1                 # 2 only if needed; 54 GB/link estimate at level 2 is non-component
blink_symbol_level = 0
v8_symbol_level = 0
```

**`out/Release-mac`: on the Mac, shippable**
Modelled on Helium's `flags.macos.gn` and `shared.sh` [F: helium-macos repo].
```gn
target_os = "mac"                # implicit on a Mac host
target_cpu = "arm64"
is_official_build = true         # implies ThinLTO when use_lld (compiler.gni) and PGO phase 2
is_debug = false
is_component_build = false       # signing requires a static build [F: chrome/installer/mac/signing/README.md]
symbol_level = 1                 # dSYMs for crash symbolication
blink_symbol_level = 0
v8_symbol_level = 0
chrome_pgo_phase = 2             # needs "checkout_pgo_profiles": True in .gclient custom_vars
proprietary_codecs = true
ffmpeg_branding = "Chrome"
enable_updater = false           # no Omaha 4 updater; Sparkle instead
cc_wrapper = "sccache"           # Helium CI uses sccache
# + fork-specific: enable_sparkle=true, sparkle_ed_key="..." (from your Sparkle patch), branding args
```
Mac dev builds on the Mac: `is_component_build=true`, `symbol_level=0`, and `use_lld=false` to use Apple's ld-prime, which "improves link speed" for local arm64 builds [F: https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md].

### 1.7 Can Linux be used to develop the sidebar and profile logic first?
**Yes, for most of it [I, grounded in the file listing below].**
- Browser UI on both Linux and Mac is **Views** (`chrome/browser/ui/views/**`). The tab-strip model, side panel, profile management (`chrome/browser/profiles`), WebUI pages and the Kombucha interaction-test framework are cross-platform.
- Upstream now has a native vertical tab strip at `chrome/browser/ui/views/tabs/vertical/` (20 files, with interactive UI tests) [V: GitHub mirror @157.0.8103.26]. That is a natural base, and you can develop against it on Linux.
- **Mac-specific code you must still build and test on a Mac [V file listing @157]:**
  - `chrome/browser/ui/views/frame/`: 24 of 220 files are Mac or immersive-mode files. Examples: `browser_frame_view_mac.mm` (title bar and traffic-light placement), `browser_native_widget_mac.mm`, `immersive_mode_controller_mac.mm`, `immersive_mode_overlay_views_mac.mm`.
  - `chrome/browser/ui/cocoa/` (72 entries): main menu builder, accelerators/keyboard shortcuts, fullscreen, dock icon, history swipe overlay, AppleScript, profiles menu.
  - `components/remote_cocoa/`: the NSWindow bridge. Hiding the toolbar or tab strip and moving the traffic lights into a sidebar (Arc-style) happens here [I].
  - Keychain / OSCrypt, TCC permissions, code signing, Sparkle, and trackpad gestures.
  - Helium's Mac-only patch list shows what typically breaks: `helium-immersive-fullscreen.patch`, `disable-chromium-immersive-fullscreen.patch`, `clean-main-menu.patch`, `fix-history-swiper-lifetime.patch`, `change-keychain-name.patch` [F: helium-macos `patches/series`].
- **Rough split [I]:**
  - About 75–85% of sidebar, Spaces and profile work can be developed and tested on Linux.
  - About 15–25% (frame, fullscreen, traffic lights, menus, gestures, keychain and signing) needs a Mac build loop.
  - Schedule Mac validation from week 1 of feature work, not at the end.

---

## 2. How the user sees and tries Linux builds remotely

The user is on a MacBook over Tailscale and never at the box. Options:

| Option | Fidelity / latency | Setup | Tailscale fit | Notes |
|---|---|---|---|---|
| **Selkies via `linuxserver/baseimage-selkies`** (Selkies 2.2.0, 2026-11-01 [V GitHub API]) | High. Default transport is WebSockets; WebRTC is opt-in [F] | Docker image; a Dockerfile plus an autostart file [F] | Plain HTTP or WebSocket behind `tailscale serve` [I: expected; verify] | linuxserver replaced its KasmVNC bases with Selkies "for greatly increased performance, fidelity, and feature set" [F: https://github.com/linuxserver/docker-baseimage-selkies]. Has clipboard, file transfer and session recording, plus a "Computer Use API" (Pelorus) [F]. Ubuntu `ubunturesolute` tag matches the host's glibc [F]. |
| KasmVNC 1.5.2 (2026-10-24 [V]) | Good | Native .deb or container; HTTPS and basic auth by default [F] | Disable its TLS and front it with Serve [I] | linuxserver's KasmVNC base image is stale (last 2025-07) [V]. |
| Xvfb + x11vnc + noVNC 1.7.0 | OK, laggier | Simple apt packages | Works (WebSocket) | Lowest common denominator. |
| Xpra 6.5.5 HTML5 | Good, per-window | apt | Works | Seamless windows; more knobs. |
| Chrome Remote Desktop | Good | Google account, systemd user session | Not via Serve (Google relay) | The Chromium Linux doc has a CRD tip [F]. Leaves the tailnet; needs a Google login on the box. |
| CDP screenshots/recordings only | Static | none | Serve a static review page | **CDP `Page.captureScreenshot` captures only web content, not the native Views sidebar or toolbar [I].** Use X-level capture (xwd/ImageMagick `import`/ffmpeg x11grab) or Kombucha `Screenshot` verbs instead. |

### Recommendation: Selkies container + tailnet HTTPS + a static review page

Setup steps for bring-up; these need user approval because they start long-running services:

1. Build `out/Dev` on the host. Do not install runtime libraries on the host: the container provides them.
2. Write a `Dockerfile`:
   ```dockerfile
   FROM ghcr.io/linuxserver/baseimage-selkies:ubunturesolute
   RUN apt-get update && apt-get install -y --no-install-recommends \
       libnss3 libgbm1 libasound2t64 libatk-bridge2.0-0 libcups2t64 libxkbcommon0 \
       libxcomposite1 libxdamage1 libxrandr2 libpango-1.0-0 fonts-noto fonts-noto-color-emoji \
       x11-apps imagemagick ffmpeg && rm -rf /var/lib/apt/lists/*
   COPY root/ /
   ```
   `root/defaults/autostart` (X11 mode) runs:
   `~/chromium/src/out/Dev/chrome --user-data-dir=/config/fork-profile --no-first-run --remote-debugging-port=9222 --enable-ui-devtools=9223`
   Run with `PIXELFLUX_WAYLAND=false` so agents can grab X screenshots. Package names are [I]; check them against the `ldd` output.
3. Run the container. Mount `out/` **at the same absolute path**, because component-build `.so` files resolve via `$ORIGIN` and the autostart path must match:
   ```sh
   docker run -d --name forkview --shm-size=2g \
     -p 127.0.0.1:3100:3000 -p 127.0.0.1:9322:9222 -p 127.0.0.1:9323:9223 \
     -e PUID=1000 -e PGID=1000 -e PIXELFLUX_WAYLAND=false \
     -v ~/chromium/src/out:~/chromium/src/out:ro \
     -v ~/forkview-config:/config \
     --security-opt seccomp=unconfined forkview:latest
   ```
   Chromium's sandbox inside Docker usually needs `seccomp=unconfined` or user namespaces. Use `--no-sandbox` only as a last resort for dev [I].
4. Expose it on the tailnet only. Ports 8443–8446 and 8448–8450 are already taken on this box [V `tailscale serve status`]:
   ```sh
   tailscale serve --bg --https=8451 http://localhost:3100
   curl -sI https://<build-box>.<tailnet>.ts.net:8451/   # verify before telling the user
   ```
   The user opens **https://<build-box>.<tailnet>.ts.net:8451/**. HTTPS gives a secure context, which the Selkies client needs for clipboard and WebCodecs-type APIs [I].
5. After each build, the agent runs `docker exec forkview pkill -f out/Dev/chrome`. The autostart or a supervisor loop relaunches it. Whether the base image restarts the app automatically is [I], so wrap it in a `while true` loop if needed.
6. **Review page for asynchronous viewing**, for example from the iPhone:
   - The agent writes screenshots, MP4s from `ffmpeg -f x11grab`, test reports and changelogs into `~/forkreview/<build-id>/`.
   - Serve the directory with a tiny static server on port 8790 and `tailscale serve --bg --https=8452 http://localhost:8790`.
   - This is how the agent shows "here is the new sidebar after rebase to 157.0.8103.26" without the user opening a live session.
7. **Native-UI inspection for agents:** `--enable-ui-devtools=9223` exposes the **Views tree** through the DevTools protocol on all desktop platforms [F: https://chromium.googlesource.com/chromium/src/+/main/docs/ui/ui_devtools/index.md]. That lets an agent check the sidebar's view hierarchy and bounds without pixels.

Fallback: Chrome Remote Desktop, if Selkies performance is poor over the user's links. Note that the Mac UI can only be judged on a Mac, using the real Mac build.

---

## 3. macOS builds

### 3.1 Requirements
- "A Mac, Intel or Arm", Xcode with the macOS SDK, and an APFS volume [F: mac_build_instructions.md].
  - `mac_sdk_official_version` in `build/config/mac/mac_sdk.gni` is "guaranteed to work"; newer SDKs usually work [F].
- **Per branch [V: raw `mac_sdk.gni` and `mac_toolchain.py` at the tags]:**
  - **M156** (156.0.8078.80): official SDK **26.5** (build 25F70), from Xcode 26.6 (17F113).
  - **M157** (157.0.8103.26) and main: official SDK **27.0** (build 26A425), i.e. **Xcode 27**. A "universal" Xcode 26.6 / SDK 26.5 path is kept only for Intel hosts, "as Xcode 27+ is ARM-only".
  - `mac_min_system_version = "13.0"`: the built browser runs on macOS 13+.
- **Xcode 27 runs only on Apple silicon and requires macOS Tahoe 26.6 or later** [F: https://developer.apple.com/forums/thread/829619; https://blakecrosley.com/blog/xcode-27-release]. **Buy or rent Apple silicon only.**
- Helium's build doc also requires the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`), Homebrew coreutils, and Python packages [F: helium-macos `docs/building.md`].
- Arm Macs are fully supported, and cross-building x64 from arm64 works. Universal builds are two separate builds merged with `chrome/installer/mac/universalizer.py` [F: https://chromium.googlesource.com/chromium/src/+/main/docs/mac_arm64.md]. For one user on Apple silicon, **build arm64 only**. That halves CI cost.
- Mac tips [F: mac doc]:
  - Exclude the checkout from Spotlight.
  - Use `git config core.fsmonitor true` (git 2.43 or later).
  - Run dev builds with `--use-mock-keychain` to avoid keychain prompts on every build.
  - Reclient/RBE "does not support Mac builds" for external contributors.

### 3.2 Build time on Apple silicon
Data points:
- M2 Max 12-core: about 1 h 30 min, and M1 Ultra about 37 min [F: https://medium.com/@solomonkinard/chromium-compile-time-on-m2-max-291cb154000a]. These are early-2023 numbers, when a clean build cost about 51 CPU-h; today it is about 77–90 CPU-h [V].
- **Depot macOS runners (8 CPU, 24 GB) [F: https://depot.dev/docs/github-actions/runner-types]:**
  - Helium arm64 official build (sccache) on 2026-10-30: **4.7 h + 2.43 h build phases**, plus 0.36 h to fetch resources [V: GitHub Actions API, imputnet/helium-macos run 41038094766].
  - ungoogled-chromium-macos arm64 on 2026-10-27: **0.71 h + 4.78 h** [V: run 40563861370].

Estimates [I]:

| Machine | Dev (component, no symbols) clean | Official ThinLTO+PGO arm64 clean | Same-milestone respin, warm cache |
|---|---|---|---|
| Mac mini M4 Pro 14-core / 48–64 GB | 2–2.5 h | 3.5–5 h | 1–2 h |
| **Mac mini M5 Pro 18-core / 64 GB** | **1.5–2 h** | **3–4.5 h** | **1–1.5 h** |
| Mac Studio M4 Max 16-core / 64–128 GB | 1.5–2 h | 2.5–4 h | ~1 h |
| Depot 8-core runner | — | 5–7 h (measured, with cache) | — |
| GitHub `macos-xlarge` (M2 Pro 5-core, 14 GB RAM) | — | 10–15 h, multi-phase | — |

Hardware guidance [I]:
- 64 GB RAM: ThinLTO links are estimated at 20 GB [F concurrent_links.gni] while compiles run in parallel.
- 2 TB SSD if the Mac keeps two checkouts, for example Stable plus Extended; otherwise 1 TB.
- M5 Pro Mac mini: announced 2026-08-25, from $1,699 (15-core / 24 GB / 512 GB); 18-core and 64 GB are options [F: https://travis.media/blog/new-mac-mini-m6-m5-pro-specs-price-preorder/]. The configured price (18-core / 64 GB / 1–2 TB) is not published in that source, so about $2.7–3.2k is [I].

### 3.3 Cloud Mac options

| Option | Spec | Price | Constraints | Fit |
|---|---|---|---|---|
| AWS EC2 `mac-m4pro.metal` | M4 Pro, 14 vCPU, 48 GiB | **$1.97/h** on-demand [F: https://instances.vantage.sh/aws/ec2/mac-m4pro.metal] | Dedicated host, **24 h minimum allocation** (Apple macOS SLA) [F: https://www.infoq.com/news/2025/10/aws-ec2-m4-mac]. M4 instances only in some US regions [F] | ≥ $47 per allocation. 24/7 is about $1,438/mo. Bursty use (one 24 h host per major plus respins) is about $150–300/mo plus EBS. Poor fit. |
| AWS `mac-m4.metal` | M4, 10 vCPU, 24 GiB | $1.23/h [F: vantage] | same | Too little RAM for official builds [I]. |
| **MacStadium M4.L** | M4 Pro 12-core, 48 GB, 1 TB | **$349/mo** (up from $299 in 2026 Q2) [F: https://pricingsaas.com/companies/macstadium] | Monthly | Good managed fallback if the user won't host hardware. |
| Scaleway M4-XL | M4 Pro 14C, 64 GB, 2 TB | about €0.49/h; about €335/mo listing [F, unverified: https://www.whtop.com/plans/scaleway.com/146130] | 24 h minimum (Apple licence) | EU-hosted alternative. |
| **Depot macOS runners** | 8 CPU, 24 GB, 400 GB disk | **$0.08/min** = $4.80/h [F: depot docs]; plans from $20/mo [F: https://depot.dev/pricing] | Used by Helium and ungoogled-chromium-macos [V] | About $26–36 per arm64 official build. Good for CI without owning hardware. |
| GitHub-hosted standard macOS (arm64) | M1 3-core, 7 GB RAM, **14 GB SSD** | $0.062/min (private repos), free for public [F: https://docs.github.com/en/actions/reference/runners/github-hosted-runners; https://docs.github.com/en/billing/reference/actions-runner-pricing] | **6 h job limit** [F: https://docs.github.com/en/actions/reference/limits] | Not practical. Needs about 5+ checkpointed phases (Helium's workflow scaffolds 28 build phases). |
| GitHub `macos-xlarge` | M2 Pro 5-core, 14 GB RAM, 14 GB SSD | $0.102/min [F] | 6 h job limit | Slow and RAM-starved. Not recommended. |
| Self-hosted runner (own Mac mini) | — | hardware only | **5-day job limit** [F: limits page] | Recommended. |

### 3.4 Cross-compiling macOS from Linux
- **Not supported for non-Googlers [F/I]:**
  - `DEPS` fetches a Mac clang runtime library when `checkout_mac` and the host is not a Mac [V], so Google has some internal Linux→Mac support.
  - But the hermetic Xcode/SDK packages are `infra_internal/ios/xcode/xcode_binaries/...` (Google-internal CIPD) [V: `build/mac_toolchain.py`], and official builds must use the hermetic Xcode [F: `mac_sdk.gni` assert].
  - A 2022 chromium-dev thread says cross-building for Mac on Linux is not supported [F: https://groups.google.com/a/chromium.org/g/chromium-dev/c/ddYGS-_FXR4].
  - The build also needs Apple-only tools (`actool`, `codesign`, `plutil`, Metal compiler) [I].
- A DIY route (osxcross-style SDK extraction plus replacements for the Apple tools) would be a large, fragile project and legally grey under the Xcode licence [I]. **Not practical. Do not plan for it.**
- A macOS VM on this x86 box (Docker-OSX/OSX-KVM) is out: Apple's licence forbids non-Apple hardware, and Xcode 27 is arm64-only [F/I].

### 3.5 Remote build execution for non-Googlers
- Siso speaks REAPI to any compatible backend. Configure it with `reapi_address`, `reapi_instance` and `reapi_backend_config_path` (your own `backend.star`) in `.gclient` `custom_vars`, plus `use_remoteexec=true` [F: Linux build doc, "non Google RBE"]. Google's RBE for externals is invite-only and best-effort [F].
- **Mac host with Linux workers is proven by Helium [F: helium-macos `patches/helium/macos/rbe-linux-clang-wrapper.patch`, `devutils/shared.sh`]:**
  - Helium adds a `clang_remote_wrapper` that swaps in a **Linux** clang build (fetched via `tools/clang/scripts/update.py --host-os=linux`) on the workers.
  - Mac compile actions run on a NativeLink pool of Linux workers.
  - **Links stay local:** upstream `clang_mac.star` says "remote-link is not supported on Mac/iOS yet" [F: same patch context].
  - Implication [I]: a Mac mini **on the same LAN** as the Linux build box can offload compiles to the 32-thread Linux box via self-hosted NativeLink. That could cut cold Mac builds by about 30–50%.
  - Over a WAN or Tailscale DERP link, the input/output transfer volume probably kills the gain. Treat this as a phase-3 optimisation.
- **Hosted RBE:**
  - BuildBuddy free tier: "up to 80 Linux cores", but only 100 GB cache transfer; Team is pay-as-you-go; Mac cores $45/core [F: https://www.buildbuddy.io/pricing]. One Chromium build would likely exceed 100 GB of transfer [I].
  - EngFlow is quote-based. The AWS Marketplace tier for up to 100 vCPUs is $87,629 per 12 months [F: https://aws.amazon.com/marketplace/pp/prodview-nklfrw6pel6vw]. Brave uses EngFlow [F: engflow.com case studies].
  - **Overkill for one user.** Self-hosted NativeLink on owned hardware costs $0.

---

## 4. Testing

### 4.1 Chromium test targets
Find the target for a file with `gn refs out/Dev --testonly=true --type=executable --all <file>` [F: build docs]. Main targets:
- `unit_tests`: model-level code (tab-strip model, Spaces/profile registry, prefs). Fast, headless.
- `browser_tests`: `InProcessBrowserTest` with a full browser. Run under `testing/xvfb.py` on Linux, which starts Xvfb or Xorg plus Openbox/xcompmgr or Weston [F: `testing/xvfb.py` @157].
- `interactive_ui_tests`: required when a test **activates windows or drives the mouse**. Kombucha `CHECK`-fails in `browser_tests` if you do that [F: https://chromium.googlesource.com/chromium/src/+/main/chrome/test/interaction/README.md]. Not shardable in parallel on one display; run serially [I].
- **Kombucha** (`InteractiveBrowserTest`): the preferred way to write UI journey tests, for example "click sidebar Space B → window switches profile → tabs of Space B shown". It uses declarative steps such as `PressButton`, `WaitForShow` and `CheckViewProperty`, keyed by `ElementIdentifier`s [F: same README]. Give every new sidebar view an `ElementIdentifier` from day one.
- **Pixel tests:** Kombucha `Screenshot` / `ScreenshotSurface` verbs, listed in `testing/buildbot/filters/pixel_tests.filter`. Run locally with `--browser-ui-tests-verify-pixels --enable-pixel-output-in-tests`. Comparison uses **Skia Gold, Google's service** [F: https://chromium.googlesource.com/chromium/src/+/main/docs/ui/learn/testing/pixel_tests.md (fetched from docs/testing/pixel_tests.md)].
  - For the fork [I]: use the verbs for rendering, but compare PNGs locally (pixelmatch/odiff with a tolerance) against baselines stored in the fork repo, or upload to a self-hosted Gold-like page on the review server.
- **WebUI tests:** Mocha suites via `WebUIMochaBrowserTest` and `build_webui_tests`, with tests in `chrome/test/data/webui/<dir>` [F: https://chromium.googlesource.com/chromium/src/+/main/docs/webui/testing_webui.md]. They run inside `browser_tests`. Use them if sidebar pieces or a "Spaces settings" page are WebUI.
- Mac-specific tests (`*_mac_interactive_uitest.mm`, `browser_frame_view_mac_browsertest.mm`) must run on the Mac.

### 4.2 Driving the fork end-to-end with Playwright/Puppeteer (CDP)
- Launch: `chromium.launch({ executablePath: '~/chromium/src/out/Dev/chrome', args: ['--user-data-dir=…', '--no-first-run'] })`, or start the browser yourself and use `chromium.connectOverCDP('http://localhost:9222')` [F: https://playwright.dev/docs/api/class-browsertype].
  - Playwright warns that it "works best with the version of Chromium it is bundled with", and there is no guarantee for other versions [F]. CDP is backward-compatible enough in practice [I]. Pin a Playwright version and treat breakage as a smoke-test signal.
  - **Puppeteer** (CDP-native) is the lower-risk choice for a custom build [I].
- **Since Chrome 136, `--remote-debugging-port`/`--remote-debugging-pipe` are ignored for the default user-data dir.** Always pass `--user-data-dir` [F: https://developer.chrome.com/blog/remote-debugging-port].
- `chrome://` WebUI pages (version, settings, a custom `chrome://spaces`) are normal CDP page targets; navigating to them works in Puppeteer and generally in Playwright [I: unverified; test at bring-up]. Assert on `chrome://version` that the fork's version string and patch hash are present.
- **Native Views UI (the sidebar itself) is not in any DOM.** For it, use:
  - (a) Kombucha tests;
  - (b) `--enable-ui-devtools` for the Views tree over the DevTools protocol [F];
  - (c) X-level screenshots or recordings, compared against baselines.
- Build ChromeDriver from the fork (`autoninja -C out/Dev chromedriver`; Helium builds `chrome chromedriver` [F: helium-macos `shared.sh`]) if WebDriver/Selenium tooling is wanted.

### 4.3 Agent smoke suite after each rebase
Suggested; target under 45 min on Linux and under 15 min on Mac after the build [I].
1. **Patch integrity:**
   - All patches apply with `git am -3`, with no `.rej` files.
   - `gn gen --check` passes.
   - A grep finds no leftover conflict markers.
2. **Build:** `autoninja -C out/Dev chrome chromedriver unit_tests browser_tests interactive_ui_tests` (Linux).
3. **Fork-owned tests:** `unit_tests --gtest_filter='Spaces*:ArcSidebar*'`, plus the fork's browser and interactive tests via `testing/xvfb.py`.
4. **Upstream neighbourhood tests** for files the patches touch. Derive the list automatically from `git diff --name-only` → `gn refs`. Examples: `TabStripModelTest.*`, `SidePanel*`, `ProfileManager*`, `VerticalTabStrip*`, `BrowserView*`.
5. **Launch smoke** (Puppeteer):
   - Start with a temporary `--user-data-dir`, wait for `/json/version`, and check `Browser` equals the expected fork version.
   - Open 10 tabs. Create 2 Spaces/profiles and switch between them via the test hooks.
   - Open `chrome://version`, `chrome://settings` and the fork's WebUI.
   - Check for no crash or `CHECK` output in stderr, and zero renderer crashes over a 60 s soak.
6. **Visual check:**
   - `xwd`/`import` full-window screenshots of the default, collapsed-sidebar and fullscreen states.
   - Diff against the baselines and publish to the review page (`https://<build-box>.<tailnet>.ts.net:8452/<build>`).
   - Over the threshold → flag for human review, but do not fail automatically.
7. **Mac-only, after the official build:**
   - `codesign --verify --deep --strict`, `spctl -a -vv -t exec`, `xcrun stapler validate` on app and DMG.
   - Launch the signed app with Puppeteer (same smoke as above).
   - **Sparkle update test:** install build N-1 into a scratch folder, point `SUFeedURL` at the staging appcast (`defaults write <bundle-id> SUFeedURL …`), trigger the update, and assert the version after relaunch [I].
   - Run the fork's Mac interactive tests (traffic lights, fullscreen) if any.

---

## 5. Release pipeline (one user, then friends)

### 5.1 Signing and entitlements
- **Apple Developer Program, $99/yr.** Create a "Developer ID Application" certificate and an **App Store Connect API key** for `notarytool` in CI [F: Apple notarization docs: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution].
- **Even for one user, use Developer ID rather than ad-hoc signing [I]:**
  - Keychain "Safe Storage" ACLs and TCC grants (camera, mic, screen) key on the code-signing identity. Ad-hoc-signed updates re-prompt or lose permissions on every update.
  - Sparkle also checks that the new app's Apple code signature matches the old one.
- Chromium's own signing driver: `out/Release/<App> Packaging/sign_chrome.py --input out/Release --output out/Release/signed --identity "<Developer ID>" --notarize …`.
  - It requires `is_component_build=false` [F: https://chromium.googlesource.com/chromium/src/+/main/chrome/installer/mac/signing/README.md].
  - A self-signed identity is "incompatible with the library validation signing option that Chrome uses" [F: same].
  - Helium invokes it with `--disable-packaging --notarize --notary-arg=--keychain-profile=…` [F: helium-macos `sign_and_package_app.sh`].
- **Entitlements in M157 [V: GitHub mirror @157.0.8103.26]:**
  - `chrome/app/app-entitlements.plist`: audio-input, bluetooth, camera, print, usb, location, photos-library.
  - `helper-renderer-entitlements.plist` and `helper-gpu-entitlements.plist`: `com.apple.security.cs.allow-jit` (hardened runtime plus JIT for V8).
  - `app-entitlements-chrome.plist` (branded only): `keychain-access-groups` with Team ID, `com.apple.developer.web-browser.public-key-credential` (passkeys), associated-domains.
    - These restricted entitlements need a **provisioning profile**. Helium passes one in via `PROD_MACOS_SPECIAL_ENTITLEMENTS_PROFILE_*` and `include_branded_entitlements=true` [F: helium-macos `shared.sh`].
    - The browser passkey entitlement requires an Apple approval request [I: verify with Apple]. Without it, passkeys and platform WebAuthn may be limited.
- Hardened runtime and secure timestamp are mandatory for notarization. `get-task-allow` must be absent (Chromium's `--development` flag injects it; never use that for releases) [F: signing README + Apple docs].

### 5.2 Notarization and DMG
- `xcrun notarytool store-credentials <profile> --key AuthKey.p8 --key-id … --issuer …`, then `notarytool submit <dmg|zip> --wait`, then `xcrun stapler staple` on the `.app` and `.dmg` [F: Apple docs]. Turnaround is usually minutes [F/I].
- Build the DMG with Chromium's `chrome/installer/mac/pkg-dmg` (`--format ULMO`, `/Applications` symlink, background). Then sign the DMG itself with `codesign`. This is exactly Helium's flow [F: `sign_and_package_app.sh`].
- Sparkle recommends APFS DMGs with lzfse compression, or `ditto` zips [F: https://sparkle-project.org/documentation/publishing/].

### 5.3 Auto-update
- **Sparkle 2** (latest 2.10.1, 2026-10-25 [V GitHub API]):
  - EdDSA-signed updates are mandatory. `generate_appcast` signs and **creates delta updates automatically**.
  - Channels (`sparkle:channel`), phased rollouts (`sparkle:phasedRolloutInterval`) and critical updates (`sparkle:criticalUpdate`) are available [F: https://sparkle-project.org/documentation/publishing/].
  - Deltas: format 4 needs Sparkle 2.7+. If a delta fails, Sparkle falls back to the full update. Code-signature data must not live in xattrs. Avoid needless file renames [F: https://sparkle-project.org/documentation/delta-updates/].
  - Chromium's versioned framework directory (`…/Versions/<version>/`) moves every release. Format-3+ move heuristics help, but expect large-ish deltas: roughly 30–100 MB per respin and more per major, versus a full DMG of about 200–250 MB [I].
- **How others do it:**
  - **Helium:** Sparkle 2 via patches (`rebel/macos/sparkle-integration.patch`, `helium/macos/updater/sparkle2-integration.patch`, `disable-default-updater.patch`). CI sets `enable_sparkle=true` and `sparkle_ed_key`, generates `.delta` files with `devutils/generate_sparkle_deltas.py`, and publishes DMG + deltas as GitHub Release assets [F: helium-macos repo].
  - **Brave:** `brave-core/browser/mac/` contains both `sparkle_glue.mm` and `keystone_glue.mm` [V GitHub API], so Brave has Sparkle and Keystone/Omaha-style paths. Whether it has finished migrating to Omaha 4 is unverified [I].
  - **Vivaldi:** uses Sparkle on macOS [I: widely known; not re-verified].
  - **ungoogled-chromium-macos:** no auto-update; GitHub Releases plus Homebrew cask [I].
  - **Chromium's own updater** (Omaha 4, `enable_updater`) needs an Omaha server. Overkill; disable it (Helium sets `enable_updater=false` [F]).
- **License caution [F/I]:** Helium is **GPL-3.0** (its `LICENSE`, and patch headers "Copyright 2026 The Helium Authors … GPL-3.0") and ungoogled-chromium is BSD-3.
  - Reusing Helium's Sparkle or RBE patches verbatim makes the fork GPL-3.0 when distributed to friends.
  - Helium's `AGENTS.md` forbids AI agents from contributing to *their* repos. It does not restrict reading GPL code, but do not send AI-generated PRs upstream to them.
- **Hosting the appcast and binaries:**
  - **Phase A (just the user):** serve `appcast.xml`, DMGs and deltas from the Linux build box via `tailscale serve --bg --https=8453 http://localhost:<static-port>`. The MacBook is on the tailnet, so `SUFeedURL=https://<build-box>.<tailnet>.ts.net:8453/appcast.xml` works whenever Tailscale is up. It is private and costs $0 [I].
  - **Phase B (friends):** public HTTPS hosting, for example Cloudflare R2 (zero egress fees) or GitHub Releases in a public repo with the appcast on GitHub Pages [I].
  - Keep EdDSA signing so the host is untrusted.
- **Channels:** the agent publishes to `beta`. It promotes to the default channel after the Mac smoke passes, after N hours on the user's machine, or after the user taps "approve" on the review page [I].

---

## 6. Upstream tracking automation (AI agent loop)

### 6.1 Cadence (confirmed)
- **2-week majors from Chrome 153 (stable 2026-09-08). Weekly security updates continue. Extended Stable keeps its 8-week cycle. Dev and Canary are unchanged** [F: https://developer.chrome.com/blog/chrome-two-week-release; https://developer.chrome.com/blog/chrome-two-week-start].
- Schedule [V: chromiumdash `fetch_milestone_schedule`]:

  | Milestone | Branch point | Stable date |
  |---|---|---|
  | 156 | 2026-09-28 | 2026-10-20 |
  | 157 | 2026-10-12 | **2026-11-03** |
  | 158 | 2026-10-26 | 2026-11-17 |
  | 159 | 2026-11-09 | 2026-12-08 |
  | 160 | 2026-11-30 | 2027-01-05 |

  The `stable_refresh_first` field shows a respin one week after each stable date.
- Observed Mac Stable release events since 2026-08-01: **77 distinct versions over 13 weeks, about 2–3 publish days per week** [V: versionhistory API]. Many arrive in small groups (e.g. .47/.48/.49 on consecutive days for staged rollouts or early-stable). Extended Stable on Mac went 152.x → 156.x [V].
- **Implication [I]:** "every Chrome release" literally means about 8–12 builds a month. Coalesce them:
  - Build when a new version reaches `fraction >= 0.5` (the filter ungoogled-chromium uses [F: its `new_version_check.yml`]).
  - Debounce for 12–24 h.
  - Always build security respins of the tracked milestone.
  - Realistic: about 4–6 Mac builds a month on Stable, or about 3–5 on Extended.

### 6.2 Detection APIs [V today]
- `https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions/all/releases?filter=endtime%3Dnone%2Cfraction%3E%3D0.5&order_by=version%20desc` returns the currently serving version, for example `156.0.8078.80`. Use `channels/extended/...` for Extended Stable.
- `https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac&num=3` returns version, milestone, `chromium_main_branch_position` and `hashes`. `fetch_milestone_schedule?offset=-1&n=6` returns future dates for planning.
- Every version is a git tag: `git ls-remote https://chromium.googlesource.com/chromium/src.git refs/tags/157.0.8103.26` → `4c20950d…` [V].
- Security context: Chrome Releases blog (chromereleases.googleblog.com) posts CVE lists per respin. The agent can scrape it to set urgency, e.g. "in the wild" exploit → critical update [I].

### 6.3 Patch strategy (makes the agent's job feasible) [I]
- Keep the fork as **a small, ordered series of topic patches** on top of the upstream tag. Store it in a small `fork/` repo: `patches/series`, `patches/*.patch`, `UPSTREAM_VERSION`, `TRACK=extended|stable`, `args/*.gn`, `scripts/`, `tests/` (Puppeteer and baselines).
  - Same shape as ungoogled-chromium and Helium, which use quilt series [F: helium `docs/building.md`, "Updating for a new Chromium release": `quilt push -a --refresh`, fix, `quilt refresh`].
  - Use git-native `git am -3` plus `git rerere` so the agent can use 3-way merges and remember past resolutions.
- Put new code in **new directories** (e.g. `chrome/browser/ui/views/arc_sidebar/`, `chrome/browser/spaces/`) behind a `BUILDFLAG` or `base::Feature`. Hook into upstream with minimal one-line call sites. Most rebase conflicts then land in a handful of hook lines.
- Mark patches **core** (branding, Sparkle, build glue) vs **feature** (sidebar, Spaces). Feature patches must be individually droppable and disableable, so a degraded but secure build can still ship.

### 6.4 Pipeline (per detected version)
1. **Detect.** A systemd user timer on the Linux build box polls hourly, or a GitHub Actions cron. It writes a state file and enqueues the job. Use `flock` to serialise jobs.
2. **Sync.** In a dedicated worktree (`~/chromium-rebase`, sharing the git cache):
   ```sh
   git fetch origin refs/tags/$V:refs/tags/$V
   git checkout -B fork/$V $V
   gclient sync -D --with_branch_heads --with_tags --force
   ```
   Add the `"checkout_pgo_profiles": True` custom var on the Mac.
3. **Apply.** `git am -3 patches/*.patch` with rerere enabled.
   - On conflict: the agent resolves within a budget, for example 3 attempts or 2 h per patch.
   - Context for the agent: the conflicting upstream commits (`git log $OLD..$V -- <file>`), the patch's intent header, and the previous resolution.
   - Then `gn gen --check` and a compile loop. Treat compile errors as part of the rebase.
4. **Linux validation** (§4.3, steps 1–6) on the Linux build box, plus the Selkies container restart and review page update.
5. **Mac build.**
   - Trigger the self-hosted runner (GitHub Actions `workflow_dispatch`), or run `ssh mac-builder 'cd fork && ./ci/build_mac.sh $V'` over Tailscale SSH.
   - Official arm64 build → `sign_chrome.py --notarize` → DMG → staple → `generate_appcast` (with deltas from the last 2–3 versions) → publish to the **beta** channel.
6. **Mac smoke** (§4.3, step 7), then promote to the default channel. Notify the user with version, CVEs fixed, patch diffs that needed manual resolution, and a review-page link.
7. **Record** build and test metrics per version (durations, ccache hit rate, conflicts) to tune the debounce and budget.

### 6.5 Fallback when the rebase or build fails [I]
- **Respin (same milestone) fails:** extremely rare, because conflicts are unlikely. Retry, then page the user. Keep shipping the previous fork build. Show a non-blocking "security update pending" notice in the fork, for example via the about page or an infobar driven by an appcast flag.
- **Major rebase fails:**
  - (a) Retry with more agent budget.
  - (b) Drop failing **feature** patches (keep core) and ship a degraded build with the feature temporarily disabled. Security beats features.
  - (c) If even core fails, stay on the current milestone. **On the Extended track** it keeps getting security respins for up to 8 weeks, which gives time. **On the Stable track**, the old milestone stops getting fixes about 2 weeks later.
  - **Never downgrade the user's profile to an older milestone [I: Chromium profiles are not downgrade-safe].** The Extended fallback only works if you are already on Extended.
- Escalate: GitHub issue plus push notification to the user with the conflict summary and a link to the WIP branch. Optionally fall back to telling the user to use stock Chrome temporarily.
- **Default: track Extended Stable.** Offer Stable later as a channel once the loop has completed about 3 clean major rebases.

---

## 7. Costs (monthly)

Assumptions [I]:
- arm64 only.
- Extended track: about 4 Mac builds a month. Stable track: about 6.
- Linux box and electricity already exist.
- Agent LLM costs excluded.

| Setup | One-time | Monthly | Notes |
|---|---|---|---|
| **A. Recommended: own Mac mini M5 Pro (18C/64 GB/1–2 TB) on the the Linux build box LAN, as a self-hosted runner** | about $2.7–3.2k | **about $10–15** (Apple Dev $99/yr = $8.25, about $5 power) + about $80 amortised over 36 mo | Fastest feedback (about 3–4.5 h cold, 1–1.5 h respin). Enables NativeLink offload to Linux. Needs someone to physically place it on a network; it does not have to be next to the Linux build box if offload is skipped. |
| B. Depot macOS runners + GitHub Actions orchestration | — | about $20 plan + 4–6 × $26–36 = **about $125–240** | Measured 5.5–7.5 h per arm64 build on Helium and ungoogled [V]. No hardware. The checkpointing workflow from Helium/ungoogled is needed only if a job approaches limits. |
| C. MacStadium M4.L (M4 Pro 12C/48 GB) dedicated | — | **about $349** | Managed and always on. 48 GB is fine for arm64 official builds. |
| D. Scaleway M4-XL (M4 Pro 14C/64 GB) | — | about €335–360 | EU. Unverified price. |
| E. AWS EC2 mac-m4pro.metal, bursty | — | about **$150–300** + EBS (about $40 for 500 GB gp3 [I]) | 24 h minimum per allocation; cold caches unless EBS is kept. |
| F. GitHub-hosted macOS | — | $0 public (3-core) to about $60–90 per build (xlarge) | Not recommended (RAM and disk too small, 6 h job limit). |
| Hosting (appcast + DMGs) | — | $0 (tailnet) / about $0–5 (R2 for friends) | — |
| RBE (BuildBuddy/EngFlow) | — | $0 self-hosted NativeLink; hosted is quote-based | Not needed. |

---

## 8. Recommended setup and step-by-step bring-up

### Phase 0: Linux dev environment (days 1–3)
1. Make paths on the SSD: `~/chromium` (checkout), `~/depot_tools`, `GIT_CACHE_PATH=~/.cache/chromium-git`, `CCACHE_DIR=~/.cache/ccache` (`ccache -M 80G`).
2. **System changes (need user approval):**
   - `sudo ./build/install-build-deps.sh`, or use the Docker-based build from the Linux doc to avoid host packages.
   - 32 GB swapfile on `~`.
   - `fs.inotify.max_user_watches`/`instances` [F: Linux doc].
   - Optionally `vm.max_map_count=262144`.
3. `fetch --nohooks --git-cache chromium` in tmux, so it survives agent timeouts. Then `gclient runhooks`.
4. Check out the tracked version (Extended: currently `156.0.8078.80`): `git checkout -b fork/156.0.8078.80 156.0.8078.80 && gclient sync -D --with_branch_heads --with_tags`.
5. `gn gen out/Dev` with the args from §1.6. Then `autoninja -j 24 -C out/Dev chrome` in tmux, and log the time. Then build the test targets.
6. Create the `fork/` repo skeleton: series, scripts, `args/`, `tests/`. Put the first trivial branding patch through the full loop.

### Phase 1: Remote viewing (day 2–3, in parallel with the build)
7. Build the `forkview` Selkies image (§2) and run it with `out/` mounted read-only at the same path.
8. `tailscale serve --bg --https=8451 http://localhost:3100`. Curl-check it, then give the user https://<build-box>.<tailnet>.ts.net:8451/.
9. Review page: a static server on 8790 plus `tailscale serve --bg --https=8452 http://localhost:8790`. Add the agent scripts `capture.sh` (xwd/ffmpeg) and `smoke.mjs` (Puppeteer).

### Phase 2: Mac builder (week 1–2)
10. Decide hardware: buy a Mac mini M5 Pro 18C/64 GB/2 TB (recommended), or rent MacStadium/Depot. Install macOS 26.6+ and Xcode 27 (for M157+). If staying on M156 Extended for now, Xcode 26.6/SDK 26.5 is the official toolchain.
11. Join the tailnet and enable Tailscale SSH. Create a dedicated `builder` user, turn off sleep, exclude the checkout from Spotlight, and set fsmonitor.
12. Run `fetch --git-cache chromium` with `"checkout_pgo_profiles": True`. Install sccache and the GitHub self-hosted runner as a LaunchDaemon.
13. Do a first dev component build, then the first official arm64 build. Record times.

### Phase 3: Signing, notarization, update (week 2–3)
14. Enrol in the Apple Developer Program. Create the Developer ID Application certificate and the App Store Connect API key. Store them in the builder's keychain, not in git.
15. Add a Sparkle 2.10.x integration patch (write your own, or reuse Helium's under GPL-3.0 terms). `generate_keys` puts the EdDSA private key in the builder's keychain; the public key goes in as a gn arg.
16. Pipeline script: `sign_chrome.py --notarize` → `pkg-dmg` → `codesign` DMG → `stapler` → `generate_appcast --channel beta` → copy to the appcast host (tailnet, `:8453`).
17. Install the first build on the user's MacBook manually (DMG link on the review page). Verify Sparkle sees the next beta.

### Phase 4: Automation (week 3–4)
18. Poller (systemd user timer) using the versionhistory API, with debounce and a state file. It triggers the rebase job on Linux, then the Mac job.
19. Agent rebase runner: worktree, `git am -3`, conflict budget, compile loop, the §4.3 tests, review page, notifications.
20. Promotion rules: beta → default after the Mac smoke passes plus N hours or user approval. Mark critical updates when CVEs are "exploited in the wild".
21. Dry-run on history: replay 152 → 156 (Extended) and 155 → 156 → 157 (Stable) to measure conflict rates and timing before going live.

### Phase 5: Optional speed-ups
22. Self-hosted NativeLink on the Linux build box as a REAPI cache and executor. Point the Mac at it for compile offload, following Helium's `rbe-linux-clang-wrapper` and `nativelink.star` approach. Only if the Mac is on the same LAN.
23. Add an x86_64 build plus `universalizer.py` only if Intel-Mac friends appear.

---

## 9. Gaps and open questions
1. **Where does the Mac live?** Can the user place a Mac mini on the Linux build box's LAN, or the user's home network? Or must it be rented? This decides NativeLink offload and the cost row (A vs B/C).
2. **Stable or Extended Stable track?** I recommend Extended by default because of 2-week majors. The user may want the newest features.
3. **No measured build times on this box or on M4/M5 Pro.** All times are estimates scaled from Chromium's CPU-hour data and older Apple-silicon reports. Phase 0 and Phase 2 must measure.
4. **Selkies behind `tailscale serve`:** WebSocket proxying through Serve is expected to work but is not verified here. The exact runtime packages and sandbox flags for the dev build inside the container need a first run.
5. **Playwright with `chrome://` pages and newer-than-bundled Chromium** is not verified. Puppeteer is the safer default.
6. **Restricted entitlements:** passkey (`web-browser.public-key-credential`) and keychain-access-groups need a provisioning profile, possibly Apple approval. The exact process is not verified.
7. **Widevine/DRM:** shipping `enable_widevine=true` on a non-Google-signed Mac build may need Widevine VMP signing from Google for some services. Not researched here; flag for the features/licensing track.
8. **Scaleway and MacStadium prices** come from third-party trackers (Scaleway pages returned 403). AWS prices come from Vantage, not the AWS pricing page.
9. **Brave's current macOS updater** (Sparkle vs Keystone/Omaha 4) is not confirmed. Vivaldi and ungoogled-chromium-macos update behaviour is from general knowledge.
10. **Agent/LLM cost per rebase** is not estimated here. A major rebase with conflicts could be a multi-hour agent session.
11. **Chromium profile downgrade safety** is assumed unsafe (standard Chromium behaviour). Confirm before designing any rollback path.

---

## 10. Key sources
- Chromium Linux build: https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md
- Chromium Mac build: https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md
- Arm Macs / universal: https://chromium.googlesource.com/chromium/src/+/main/docs/mac_arm64.md
- Mac SDK per branch: https://raw.githubusercontent.com/chromium/chromium/157.0.8103.26/build/config/mac/mac_sdk.gni (and `@156.0.8078.80`), `build/mac_toolchain.py`
- Link memory estimates: https://raw.githubusercontent.com/chromium/chromium/main/build/toolchain/concurrent_links.gni
- Symbol-level defaults: https://raw.githubusercontent.com/chromium/chromium/157.0.8103.26/build/config/compiler/compiler.gni
- Siso: https://chromium.googlesource.com/build/+/refs/heads/main/siso/README.md, https://chromium.googlesource.com/chromium/src/+/main/docs/siso_tips.md, https://pkg.go.dev/go.chromium.org/build/siso
- Build-time CPU-hours: https://commondatastorage.googleapis.com/chromium-browser-clang/build-time.html
- Kombucha: https://chromium.googlesource.com/chromium/src/+/main/chrome/test/interaction/README.md
- Pixel tests: https://chromium.googlesource.com/chromium/src/+/main/docs/testing/pixel_tests.md
- WebUI tests: https://chromium.googlesource.com/chromium/src/+/main/docs/webui/testing_webui.md
- UI DevTools: https://chromium.googlesource.com/chromium/src/+/main/docs/ui/ui_devtools/index.md
- Signing scripts: https://chromium.googlesource.com/chromium/src/+/main/chrome/installer/mac/signing/README.md
- Remote debugging change (M136): https://developer.chrome.com/blog/remote-debugging-port
- Two-week cycle: https://developer.chrome.com/blog/chrome-two-week-release, https://developer.chrome.com/blog/chrome-two-week-start
- Version APIs: https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions/all/releases, https://chromiumdash.appspot.com/fetch_milestone_schedule, https://chromiumdash.appspot.com/fetch_releases
- GitHub runners / pricing / limits: https://docs.github.com/en/actions/reference/runners/github-hosted-runners, https://docs.github.com/en/actions/reference/runners/larger-runners, https://docs.github.com/en/billing/reference/actions-runner-pricing, https://docs.github.com/en/actions/reference/limits
- Depot: https://depot.dev/docs/github-actions/runner-types, https://depot.dev/pricing
- AWS EC2 Mac: https://instances.vantage.sh/aws/ec2/mac-m4pro.metal, https://instances.vantage.sh/aws/ec2/mac-m4.metal, https://www.infoq.com/news/2025/10/aws-ec2-m4-mac
- MacStadium: https://pricingsaas.com/companies/macstadium ; Scaleway: https://www.whtop.com/plans/scaleway.com/146130
- Mac mini M5 Pro: https://travis.media/blog/new-mac-mini-m6-m5-pro-specs-price-preorder/
- Xcode 27 requirements: https://developer.apple.com/forums/thread/829619, https://blakecrosley.com/blog/xcode-27-release
- BuildBuddy: https://www.buildbuddy.io/pricing ; EngFlow: https://aws.amazon.com/marketplace/pp/prodview-nklfrw6pel6vw ; NativeLink: https://github.com/tracemachina/nativelink
- Selkies: https://github.com/linuxserver/docker-baseimage-selkies, https://github.com/selkies-project/selkies ; KasmVNC: https://github.com/kasmtech/KasmVNC
- Sparkle: https://sparkle-project.org/documentation/publishing/, https://sparkle-project.org/documentation/delta-updates/
- Apple notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Reference forks (local clones under `research/repos/`): helium-macos (`.github/workflows/*`, `devutils/shared.sh`, `sign_and_package_app.sh`, `flags.macos.gn`, `patches/series`), helium (`patches/helium/core/rbe-nativelink-config.patch`, `AGENTS.md`), ungoogled-chromium (`.github/workflows/new_version_check.yml`); GitHub Actions run data for imputnet/helium-macos and ungoogled-software/ungoogled-chromium-macos.

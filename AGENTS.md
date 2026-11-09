# Airc: agent playbook

Airc is an Arc-style browser for macOS on Chromium. AI agents write and maintain it; this file is how.
Read [docs/spec.md](docs/spec.md) first. It has the product requirements (section 2, IDs like SB-3), the
architecture (section 3) and the task plan (section 6). Arc's measured behaviour (sizes, timings, springs)
is in [docs/research/arc_behavior_spec.md](docs/research/arc_behavior_spec.md). The design language is in
[docs/design.md](docs/design.md).

## The bar

Airc replaces Arc for people who loved it, so "works" is not enough:

- **Smooth.** 120 Hz on ProMotion, no dropped frames when switching Spaces, opening the command bar or
  dragging tabs. Use Core Animation springs, never linear timing. Nothing blocks the main thread.
- **Exact.** Where Arc has a measured size, timing or behaviour, match it. Where the spec says "like Arc",
  check the research note before guessing.
- **Calm.** Few borders, soft materials, generous spacing, no visual noise. See docs/design.md.

## Layout

| Path | What | Language |
|---|---|---|
| `apps/browser/` | Airc.app: window, sidebar, Spaces, command bar, onboarding, settings | Swift (AppKit + SwiftUI) |
| `packages/AircKit/` | Model and SpacesStore. No UI, no engine | Swift package |
| `packages/AircImport/` | Reads Arc's data (Spaces, pinned tabs, Favorites, logins) into an import plan | Swift package |
| `packages/AircDesign/` | Design tokens (colour, type, spacing, radii, motion) and shared views | Swift package |
| `engine/core/` | `//airc/core`: the Chromium engine layer (ArdiaCore port) and its Objective-C API | Objective-C++ |
| `engine/patches/` | One-line hooks into Chromium, one concern per patch | patch files |
| `apps/marketing/` | The homepage | web |
| `scripts/` | Build, sync and release scripts | bash |
| `infra/` | Nightly build on the Mac (`nightly.sh`), status page (`status.py`), first engine build kick-off | bash, python |

The app talks to the browser engine only through the `BrowserEngine` protocol in `apps/browser`. It has
two implementations:

- **`WebKitEngine`** (dev): WKWebView with one `WKWebsiteDataStore` per profile. Builds in seconds, so all
  UI work happens against it.
- **`ChromiumEngine`**: the real engine, `Airc Framework.framework` from `engine/`. Builds overnight.

Keep both working. UI code never imports WebKit or Chromium directly.

## Building

Everything that needs macOS runs on the build Mac, reached from the Linux box with `scripts/mac.sh`:

```bash
scripts/mac.sh -w <your-task> run 'swift test --package-path packages/AircKit'
scripts/mac.sh -w <your-task> run 'scripts/build-app.sh'          # builds apps/browser into build/Airc.app
scripts/mac.sh -w <your-task> get build/screenshots ./artifacts/   # copy results back
```

- Use your own `-w` name so parallel agents don't share build folders.
- The build host is the dedicated Mac (`buildmac`), separate from the owner's laptop. Start all new builds
  and checks there. Keep the laptop idle and leave already-running jobs alone. Use the shared build/UI locks,
  keep at least 15 GiB free, and quit only your own test apps when done.
- Xcode 27 doesn't ship Apple's Metal compiler, which Chromium's ANGLE needs: install it once with
  `xcodebuild -downloadComponent MetalToolchain` (no sudo; already done on the build Mac).
- The Chromium checkout on the Mac is `~/arcfork/chromium/src` at the tag in `CHROMIUM_VERSION`. Only one
  engine build runs at a time (`autoninja -j 8`); it uses most of the machine.
- A read-only Chromium source mirror for searching is on the Linux box at `/home/<user>/arcfork/chromium/src`
  (path set by the operator).

## Rules

- **Secrets never go in the repo**: signing certificates, the Sparkle key, deploy tokens, API keys. Same for
  private hostnames, IPs and personal data.
- **Licences.** Apache-2.0. Copying code from another project means adding it to NOTICE and keeping its
  header. GPL code (Helium, ilo, Ardia's Helium patches) is for reading only, never copying.
- **Chromium changes** go in `engine/core`. Chromium's own files only get one-line hooks in
  `engine/patches`, applied strictly with `engine/apply.sh --check`.
- **Tests.** Logic in AircKit has unit tests. UI changes come with a screenshot from the Mac.
- **Commits.** Small, one concern each, imperative subject line. Don't commit build output.

## Marketing screenshots

The homepage and launch posts use product shots of the real app, in `assets/screenshots/` (README there). They come
from `--script marketing` (`apps/browser/Sources/Airc/Debug/Marketing*.swift`): a synthetic demo setup on real public
sites, never anyone's data, no camera or microphone. **Every new user-visible feature adds its shot to that scenario
(or refreshes the one it changes) and to the list in `scripts/marketing-shots.sh`, then runs the script** and looks at
every image before committing it. The scenario isn't part of the suite: it loads real websites and is slow.

```bash
scripts/marketing-shots.sh                     # build, shoot every part, write PNG originals and the WebP set
scripts/marketing-shots.sh --parts media       # one part: browser, views, media, calls, settings, onboarding
```

## Updating Chromium

Follow [docs/rebase.md](docs/rebase.md). `infra/chromium/watch.py` polls Mac Extended
Stable every six hours and writes local state plus a pending agent brief when a
newer release exists. Stable is informational. Never dispatch from a stale or
failed poll; deduplicate by target and coordinate one engine/build owner.
`infra/chromium/update.sh <version>` prepares a separate Linux candidate, checks
strict hooks and reports included-header drift; it never builds on the Mac or
changes the active version pin. Keep the mirror read-only. No fuzz or unchecked
hash refreshes. Pass Mac build, isolation/acceptance and performance gates before
promotion; never downgrade migrated profiles. Escalate active exploits blocked by
core failures, security regressions, or the playbook's conflict budget.

# Track: what to copy from T3 Code, and the account/sync model

Research date: 2026-11-03. Repo read at `research/repos/t3code` (shallow clone of `github.com/pingdotgg/t3code`, HEAD `cefb544a`, committed 2026-11-02). Read only: no installs, builds, or runs.
Labels: **[fact]** = read in code/docs or a cited source. **[inference]** = my judgement. **[unverified]** = needs checking.

---

## 0. TL;DR

- T3 Code is **MIT** (`LICENSE`, "Copyright (c) 2026 T3 Tools Inc."). You can copy anything if you keep the copyright and permission notice. It does **not** grant trademark rights: drop the T3 name, logos, and icons (`assets/`).
- The user's reading is right. T3 Code works **fully local with no account**. The account (**T3 Connect**, on **Clerk**) is optional. It turns on only when you choose remote access between machines, and it is free for up to 3 machines. Analytics do not need an account and can be switched off.
- Stack: **Electron 44** shell + **React 19** web UI (Vite+, TanStack Router, Tailwind v4, shadcn-style "base-mira" components on **Base UI**, zustand + Effect atoms, React Compiler) + a Node server, with **Effect 4** throughout. Desktop builds use **electron-builder**, signing uses `@electron/osx-sign`, notarization uses an App Store Connect API key, and auto-update uses **electron-updater** with GitHub Releases as the feed (stable and nightly channels). CI runs on GitHub Actions.
- **T3 Code already contains a small browser.** It has a `<webview>` browser panel with per-profile persistent partitions, cookie import from Chrome, Safari, and Firefox, a macOS **passkey bridge** using Apple's managed browser entitlement, favicon capture, a CDP relay, and "set as default browser" Info.plist wiring. For an **Electron** variant this is the most valuable code to copy. For a **Chromium fork**, copy the patterns, not the code.
- React does work in Chromium WebUI pages. **Brave** ships React WebUI (webpack + Mojo), and **Vivaldi's** whole UI is React. Chromium's WebUI enforces Trusted Types; Brave works around it with a narrow `default` policy, and Chromium exposes `DisableTrustedTypesCSP()` and `OverrideContentSecurityPolicy()`. T3 Code's UI primitives, Tailwind setup, sidebar drag and drop, and wizard can be reused inside a WebUI sidebar page. Its Electron, Node-server, and Effect-RPC plumbing cannot.
- A Chromium fork **cannot use Google Chrome Sync** (Google cut off third-party Chromium builds on 2021-03-15). Brave's **go-sync** (MPL-2.0, active, last commit 2026-10-29) is a working self-hostable Chromium-protocol sync server. It needs DynamoDB, plus Brave's client-side patches for auth and encryption, so it is heavy. For Arc-style data, sync only the sidebar model (Spaces, pins, favorites) as a small end-to-end-encrypted operation log. Leave passwords to 1Password, Bitwarden, or iCloud Passwords and passkeys.
- Arc **required an account at first launch**. People objected: on privacy grounds ("why does a browser need my email"), to the pushy onboarding (Deceptive Patterns, 2024-08-24), and to the 2024 Boosts/Firebase RCE (CVE-2024-45489). The decisive lesson: Arc **stops working on 2026-12-22**. Sign-in ends, accounts are deactivated, and data is deleted within 30 days (TechCrunch, 2026-10-22). An account-gated browser dies with its backend. A local-first one does not. Arc's shutdown also makes **"Import from Arc" (`StorableSidebar.json`)** a strong onboarding feature right now.
- Recommendation: **v1 has no account** (local profiles, Arc and Chrome import, signed JSON export and backup). **v1.x adds optional sync** through a narrow sidebar-sync layer: either iCloud/CloudKit (no account, Apple-only, worth a spike) or an optional account using Clerk or Better Auth, with a Cloudflare Worker and Durable Object for an E2EE op log, modelled on T3's relay. **v2** adds an account-backed iPhone companion, shared Spaces, and web access. Passwords stay with password managers throughout.

---

## 1. T3 Code: what it is, as read

### 1.1 Identity and license
- Repo `pingdotgg/t3code`. README: "agent harness control surface", with desktop (Electron), web (`app.t3.codes`), iOS and Android apps, and a `t3` CLI. "We are (mostly) not accepting contributions yet."
- `LICENSE`: MIT, © 2026 T3 Tools Inc. **What copying requires**: include the copyright notice and permission text "in all copies or substantial portions". That is all. Practical steps:
  1. Keep a `LICENSE-t3code` / NOTICE entry for every copied file or directory, and keep the per-file headers if any exist.
  2. Third-party dependencies carry their own licenses. T3 generates notices (`docs/internals/open-source-licenses.md`, `third-party-licenses/`, `scripts/sync-third-party-license-notices.ts`, `third-party-licenses.config.json`). Copy that mechanism too, because a browser ships hundreds of dependencies.
  3. MIT grants no trademark rights **[inference, standard reading]**. Do not reuse "T3", the wordmark (`apps/web/src/components/T3Wordmark.tsx`, `T3AppIcon.tsx`), or `assets/` brand art.
  4. Production Clerk keys in `.env.example` (`pk_live_…`, relay URL `relay.t3.codes`) are public identifiers for **their** instance. Never ship them in your build.

### 1.2 Monorepo layout (pnpm 12 + Vite+ `vp`, Node 26.12.1 pinned in `package.json`)
| Path | What |
|---|---|
| `apps/desktop` | Electron main/preload (`src/main.ts`, `boot.ts`, `preload.ts`), updater (`src/updates/`), Clerk bridge (`src/app/DesktopClerk.ts`, `ClerkTokenStore.ts`), settings (`src/settings/`), **in-app browser** (`src/preview/`), macOS permissions (`src/permissions/`) |
| `apps/web` | React app used by desktop, the hosted web app, and the CLI. `src/components/ui/*` (design system), `src/components/Sidebar.tsx` (3,646 lines), `src/onboarding/`, `src/cloud/` (T3 Connect auth), `src/browser/` (browser panel UI), `src/routes/` (TanStack file routes, ~33 settings pages) |
| `apps/server` | Node server that owns agents, git, terminals, and SQLite event-sourced orchestration (`src/orchestration-v2/`) |
| `apps/mobile` | Expo 58 / React Native 0.88, `@clerk/expo` |
| `apps/marketing` | t3.codes site; also serves `install.sh` |
| `packages/*` | `contracts` (RPC schemas), `client-runtime` (shared connection/state), `shared`, `tailscale`, `ssh`, providers, source-control adapters, `secret-provider-onepassword` |
| `infra/relay` | T3 Connect control plane: Cloudflare Worker + Durable Objects + PlanetScale Postgres (Drizzle) + Clerk backend, deployed with Alchemy (`infra/relay/alchemy.run.ts`, `package.json`) |
| `native/*` | Rust/C helpers (resource monitor, browser-secret, libghostty) |
| `scripts/` | `build-desktop-artifact.ts` (electron-builder config generator, ~4k lines), `sign-macos.ts`, `merge-update-manifests.ts`, `generate-release-notes.ts`, `smoke-desktop-app.ts`, `mock-update-server.ts` |
| `docs/` | Very good internal docs (`docs/internals/*`, `docs/operations/release.md`, `docs/user/*`) |

### 1.3 Tech stack (from `apps/web/package.json`, `apps/desktop/package.json`, `pnpm-workspace.yaml`)
- **Shell**: Electron `44.10.0`, `electron-store`, `electron-updater ^6.8.9`, `electron-builder 26.16.1`, `@napi-rs/keyring`, `electron-webauthn`, `@clerk/electron` 0.1.3, `@clerk/electron-passkeys` 0.0.3.
- **UI**: React 19.3 with React Compiler (lint bans `useMemo`/`useCallback`, `docs/internals/web-ui.md`), Vite+, TanStack Router 1.16x, Tailwind v4 (`@tailwindcss/vite`), `@base-ui/react` 1.9, shadcn config `apps/web/components.json` (style `base-mira`, zinc, lucide, registries `@coss` coss.com/ui and `@spell`), `class-variance-authority`, `tailwind-merge`, `@dnd-kit/*` (sidebar drag), `@legendapp/list` (virtualized lists), Tiptap 3 (composer), `lucide-react`, `morphicons`, Inter variable font.
- **State**: `zustand` 5, `@effect/atom-react` with an Effect runtime (`apps/web/src/rpc/atomRegistry`, `packages/client-runtime/src/state`).
- **Effect**: `effect` 4.1.2 everywhere. Desktop services are `Context.Service` + `Layer` (for example `apps/desktop/src/preview/BrowserSession.ts`, `settings/DesktopAppSettings.ts`). This is a strong house style. Adopting it is a separate decision from adopting the code.

### 1.4 Design system and components
- `apps/web/src/components/ui/`: alert-dialog, autocomplete, badge, button, calendar, checkbox, collapsible, color-picker, combobox, **command** (palette), dialog, empty, input(-group), kbd, menu, number-field, popover, preview-card, qr-code, radio-group, scroll-area, select, sheet, **sidebar** (867 lines), skeleton, spinner, switch, table, textarea, toast, toggle(-group), tooltip, **wizard** (155 lines).
- Rules (`docs/internals/web-ui.md`): Tailwind classes in the owning component, no ad-hoc global CSS, `@variant dark`/`light`, and composition through "slot objects" (`components/chat/ComposerBanner.tsx` is the reference).
- App-level pieces relevant to a browser: `CommandPalette*.tsx` (Arc's Cmd-T/Cmd-L launcher), `Sidebar.tsx` + `Sidebar.drag.ts` + `Sidebar.motion.ts` + `Sidebar.snooze.ts` (drag reorder, pin, snooze, motion), `ProjectPinButton.tsx`, `HistorySwipeNavigation.tsx` (trackpad swipe back), `ReopenClosedViewShortcut.tsx`, `appearance*` (themes and contrast), `browserFaviconStore.ts`, `browserHistoryStore.ts`, `closedViewStore.ts`.

### 1.5 Packaging, signing, notarization, auto-update
- **Workflows**: `.github/workflows/release.yml` (1,481 lines; stable/nightly/preview channels; nightly cron every 30 min, gated at 6 h) calls `.github/workflows/release-desktop.yml` (848 lines) once per platform/arch. Also `desktop-macos-preview.yml` + `desktop-macos-preview-publish.yml`: a PR label produces a signed preview DMG, with a split trust boundary so the Developer ID certificate never shares a job with PR code (documented in `docs/operations/release.md`).
- **electron-builder config** is generated in code (`scripts/build-desktop-artifact.ts` `createBuildConfig`):
  - mac targets `dmg` + `zip` (the zip is the Squirrel.Mac update payload). Branded DMG backgrounds per channel (`apps/desktop/resources/dmg/`).
  - `mac.extendInfo` declares `CFBundleDocumentTypes` for `public.html` and `protocols` `http`/`https` with role Viewer, **which is what makes macOS list the app as a Default web browser** (`docs/user/default-browser.md`). Also `NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac`.
  - `mac.sign` → `scripts/sign-macos.ts` (`@electron/osx-sign`, `batchCodesignCalls`). Entitlements are generated by `renderMacPasskeyEntitlements()`: associated-domains `webcredentials:`, keychain access group `<team>.<app>.webauthn`, **`com.apple.developer.web-browser.public-key-credential`** (managed browser passkey entitlement), JIT, and camera/mic. A provisioning profile is embedded (`MACOS_PROVISIONING_PROFILE` secret).
  - `publish: { provider: "github", releaseType, channel: "nightly" }`. `scripts/merge-update-manifests.ts` merges per-arch `latest-mac.yml`.
- **Secrets** (`docs/operations/release.md` §2): `CSC_LINK`/`CSC_KEY_PASSWORD` (Developer ID .p12), `APPLE_API_KEY`/`_ID`/`_ISSUER` (notarization via App Store Connect API key), `APPLE_TEAM_ID`, `MACOS_PROVISIONING_PROFILE`. Windows uses Azure Trusted Signing. Signing is auto-detected and builds run unsigned without it.
- **Updater UX** (`apps/desktop/src/updates/DesktopUpdates.ts`, `electron/ElectronUpdater.ts`, `updateMachine.ts`): background check, **no automatic download**, a "rocket" button (click to download, click again to restart), stable/nightly track switch in Settings → About, and a managed-policy override (`DesktopUpdatePolicy.ts` fails closed). Release notes are LLM-summarized into the update popover (`scripts/generate-release-notes.ts`).
- Smoke test before publish: `scripts/smoke-desktop-app.ts` opens the packaged DMG/AppImage against an old seeded DB.

### 1.6 First-run / onboarding
- `docs/user/welcome-wizard.md`, `apps/web/src/onboarding/firstRun.logic.ts`, `components/ui/wizard.tsx` (a **modal dialog wizard**, `WizardPopup` in `DialogPopup`).
- Flow: (1) choose or connect computers, (2) check agents (Claude Code/Codex), with one-click install that opens a terminal, (3) import projects found from other tools' history (Claude/Codex/Pi), auto-selecting git repos active in the last 30 days with at least 3 conversations.
- Good principles worth copying:
  - **Every step is skippable**, and setup can be rerun at `/welcome`.
  - It is shown only on a fresh workspace (`isFreshFirstRunWorkspace`).
  - It never overwrites unreadable settings with defaults ("Could not read settings → Retry").
  - **Import from incumbent tools with smart defaults.**
- **Not Arc-grade [inference]**: it is a functional settings-style wizard, not a cinematic full-window onboarding. Copy its logic and gating, not its look.

### 1.7 Accounts and sign-in
- **No account needed for local use [fact]**: the README install path and the FAQ ("There's no way to pay us to use T3 Code"). The desktop app bundles a local server, and the account appears only under **Settings → Sharing & access** (`docs/user/remote-access.md`). `.env.example`: "Remove or comment them out to build with cloud features disabled"; `docs/operations/connect-setup.md`: "T3 Connect is disabled in a fresh clone."
- **What the account adds**: T3 Connect, which reaches your machines from phone, web, or another desktop through a Cloudflare tunnel brokered by the relay (`docs/internals/t3-connect.md`). The relay does **not** proxy traffic. Free for up to 3 machines; linking a paid T3 Chat (WorkOS-based) account raises the cap.
- **Provider: Clerk.**
  - Desktop: `@clerk/electron` `createClerkBridge` (`apps/desktop/src/app/DesktopClerk.ts`). Tokens go to a 0600 file in a 0700 dir (`ClerkTokenStore.ts`). OAuth runs in the system browser with deep links `t3code://app/` (`connect-setup.md`).
  - Passkeys: `@clerk/electron-passkeys`.
  - Web: `@clerk/react` (`apps/web/src/cloud/managedAuth.tsx`).
  - CLI: public OAuth client with PKCE and a loopback `127.0.0.1:34338/callback`, plus the device-authorization grant for SSH.
  - Relay: verifies a Clerk JWT template (`aud: t3-code-relay`).
  - Sessions to environments use DPoP-bound one-time credentials (`docs/internals/environment-auth.md`).
- Relay infrastructure: Cloudflare Workers + Durable Objects (SQLite) + PlanetScale Postgres + Axiom traces, deployed by Alchemy (`infra/relay/README.md`).

### 1.8 Settings storage
- Desktop shell settings: JSON via Effect FileSystem (`apps/desktop/src/settings/DesktopAppSettings.ts`, which holds window bounds, update channel, and similar). Clerk tokens use `electron-store` in a locked directory.
- Client preferences stay per client; environment and project settings live on the owning server ("Settings ownership" in `docs/internals/overview.md`). The server persists an **event log + projections in SQLite** (`apps/server/src/orchestration-v2/EventSink.ts`).
- Secrets: OS keyring (`@napi-rs/keyring`, `linuxSecretStorage.ts`) and a 1Password secret provider (`packages/secret-provider-onepassword`).

### 1.9 Telemetry
- `docs/user/telemetry.md`, `docs/internals/product-analytics.md`, `apps/server/src/telemetry/`.
- The server sends product events to its own `ingest.t3.codes` endpoint, which archives them and forwards to PostHog. **Clients never load the PostHog SDK.** Identifiers are SHA-256 hashed, events are allowlisted, and prompts, paths, and IDs are excluded. Relay traces go to Axiom; mobile crash reports go to Axiom.
- **Opt-out** is `T3CODE_TELEMETRY_ENABLED=false` or a managed policy. **[inference]** For a browser, an env-var-only opt-out is not acceptable UX. Use an onboarding toggle and a Settings switch, and default to **off or minimal**.

### 1.10 The in-app browser (very relevant)
`apps/desktop/src/preview/` (~19k lines incl. tests), `apps/web/src/browser/`, `docs/user/browser-import.md`, `docs/user/default-browser.md`:
- `<webview>` guests (`webviewTag: true` in `window/DesktopWindow.ts:408`, `browser/HostedBrowserWebview.tsx`).
- `BrowserSession.ts`: **per-profile persistent partitions** (`persist:t3code-preview-profile-<hash>`), ephemeral partitions, a **permission allowlist** (clipboard-write, geolocation, fullscreen, pointerLock, loopback; local-fonts and notifications denied), and external-protocol prompts. This is the same shape as "Spaces bound to profiles".
- `BrowserImport/`: one-time **cookie import** from Chromium browsers (decrypts with the Keychain "Safe Storage" key, `ChromiumKeys.ts`/`ChromiumCookies.ts`), Firefox, and Safari (needs Full Disk Access, `SafariPermission.ts`).
- `Passkeys.ts`, `PasskeyBridge.ts`, `PasskeyBackendMac.ts`: bridge WebAuthn from guests to native macOS passkeys via `electron-webauthn`. ES256 only, with a public-suffix guard (tldts). Needs the managed entitlement.
- `FaviconCapture.ts`, `CdpRelay.ts` (DevTools protocol), `GuestInput.ts`, recording, picture-in-picture, crash recovery (`webviewCrashRecovery.ts`), device toolbar.

---

## 2. What is reusable for the browser

### 2a. If the browser is a Chromium fork with a WebUI sidebar

**Can React run in a Chromium WebUI page? Yes. Shipped examples:**
- **Brave**: `brave/brave-core` `package.json` depends on `react`, `react-dom`, `react-redux`, `styled-components`, `webpack 5`, `@brave/leo`. The New Tab Page is `components/brave_new_tab_ui/brave_new_tab.tsx` + `brave_new_tab_page.mojom` + `BUILD.gn`. Trusted Types are handled by `components/common/defaultTrustedTypesPolicy.ts`, a `default` policy with only a same-origin `createScriptURL` (no `createHTML`) so `import()` works. Some untrusted WebUIs call `DisableTrustedTypesCSP()` (`browser/ui/webui/brave_wallet/snap_host/snap_host_ui.cc`). [fact, via GitHub]
- **Chromium API**: `content/public/browser/web_ui_data_source.h` has `OverrideContentSecurityPolicy(directive, value)` and `DisableTrustedTypesCSP()`. [fact]
- **Vivaldi**: the entire browser UI is a React app over Chromium (InfoQ 2016; Vivaldi 6.2 moved windows to React portals). [fact, secondary sources]
- Chromium's own WebUI uses TypeScript + Lit/Polymer, a strict CSP (`script-src chrome://resources 'self'`, no inline or eval), and Trusted Types. A React bundle must be **prebuilt** (no eval, no inline scripts, no runtime CSS-in-JS that injects `<style>` without a nonce; Tailwind's static CSS file is fine) and packed via GRD/`BUILD.gn` (Brave uses webpack; Vite output also works) **[inference]**.

**Reusable from T3 Code inside a WebUI sidebar (`chrome://sidebar` style page):**
| Piece | Reuse | Notes |
|---|---|---|
| `components/ui/*` (Base UI + Tailwind v4 + cva) | **High** | Pure DOM. Check Base UI's portal/floating code and Tailwind for any inline `style` injection under Trusted Types **[unverified]**. Inline `style=""` attributes are not blocked by Trusted Types, only by `style-src` without `'unsafe-inline'`. Chromium WebUI CSP allows `style-src 'self' 'unsafe-inline'` by default **[unverified; check `web_ui_data_source_impl.cc`]**. |
| `Sidebar.drag.ts`, `Sidebar.motion.ts`, dnd-kit setup, `ProjectPinButton`, `CommandPalette*` | **Medium–High** | Logic is coupled to threads, projects, and Effect atoms. Extract patterns and port the code. |
| `HistorySwipeNavigation`, `ReopenClosedViewShortcut`, `closedViewStore`, `browserFaviconStore`, `browserHistoryStore` | **Medium** | The browser-ish UX logic is useful; the data source becomes Mojo instead of Electron IPC. |
| `appearance*`, theme tokens, `index.css` | **High** | Arc-style per-Space themes map onto CSS variables. |
| `onboarding/*` logic (fresh-workspace gate, skip-everything, import with smart defaults) | **Pattern** | The onboarding would be a full-window WebUI (`chrome://welcome`-like). |
| Electron main, preload, IPC, `preview/*`, Clerk Electron bridge, electron-updater, server, Effect RPC | **No** | Replace with C++ browser-side code + Mojo, Sparkle for updates (Helium already does this: `research/repos/helium-macos/patches/rebel/macos/sparkle-integration.patch`, `patches/helium/macos/updater/fixup-sparkle-glue.patch`), and Chromium's signing scripts (`helium-macos/patches/helium/macos/chromium-signing.patch`). |
| Release engineering ideas (channels, signed-preview trust split, smoke test before publish, LLM release notes, mock update server) | **Pattern** | Process is reusable; tooling is not. |

Caveat: Arc and Dia render their chrome natively in Swift/AppKit, not WebUI **[from memory, unverified here]**. A React WebUI sidebar is a proven pattern (Brave, Vivaldi), but expect more work to reach native-feeling scroll, drag, and animation at 120 Hz. Vivaldi has long been criticized for UI sluggishness **[inference]**.

### 2b. If the browser is an Electron shell
Much more is directly reusable:
- **Whole app shell skeleton**: `apps/desktop` structure, `DesktopWindow.ts`, `DesktopAppSettings.ts`, `DesktopLifecycle.ts`, `DesktopStartupRecovery.ts`, single-instance and URL activation (`DesktopAppActivation*.ts`), `DesktopWebLinks.ts`.
- **Browser core**: `preview/BrowserSession.ts` (profile partitions = Spaces↔profiles), `preview/Manager.ts` (3.7k lines; tab/guest management), `FaviconCapture.ts`, `webviewCrashRecovery.ts`, `BrowserImport/*` (Chrome, Safari, and Firefox cookie import for onboarding), `Passkeys*` (passkeys in guests), and default-browser Info.plist config.
- **Release pipeline**: `scripts/build-desktop-artifact.ts` (trim it heavily), `sign-macos.ts`, `merge-update-manifests.ts`, `release.yml` + `release-desktop.yml`, `updates/*`.
- **UI**: everything in §2a, without CSP concerns.
- Caveats **[inference / known Electron limits; other tracks should confirm]**:
  - T3 uses `<webview>`, which Electron discourages in favour of `WebContentsView`.
  - There is no Chrome Web Store extension support (Electron's extension API is partial), so 1Password and Bitwarden extensions won't just work.
  - Widevine DRM needs Castlabs' Electron fork.
  - Google sign-in may block embedded user-agents.
  - There is no built-in password manager or autofill.
  - These are why "copy T3's browser" works for a dev-tool preview pane but not for a daily-driver browser.

---

## 3. Account and sync model for "create an account at some point"

### 3.1 What an account would add (in priority order)
1. Sync of **sidebar data** (Spaces, pinned tabs, folders, favorites, Space themes and profile mapping) across Macs.
2. **Backup and restore** on a new Mac.
3. iPhone companion that shows Spaces and pins and sends tabs (Arc's mobile story; Arc Search later took this over).
4. Later: shared Spaces/folders, web access, cross-platform.

Things it should **not** be required for: browsing, profiles, import, local backups, or updates.

### 3.2 Why not Chrome Sync
Google restricted Chrome Sync and other private APIs to Google Chrome from **2021-03-15** (Chrome eng director Jochen Eisinger; BleepingComputer, Neowin). Forks need their own sync.

### 3.3 Option A: self-hosted Chromium-protocol sync (full browser sync)
- **brave/go-sync** (MPL-2.0, active; last commits 2026-10-28/29): a Go server speaking Chromium `sync.proto` at `POST /v2/command/` (Commit/GetUpdates). It uses DynamoDB (plus Redis), and its README pins protos to **Chromium 116.0.5845.183**, which must be refreshed from current Chromium **and brave-core** protos. Point a client at it with `--sync-url=…/v2`.
- **Catch**: Brave's clients authenticate with **self-generated tokens** (timestamp signed with a key from a BIP39 seed) and **force client-side encryption** (custom passphrase = seed). Stock Chromium sync expects a signed-in Google identity through `IdentityManager`. A fork must port Brave's sync auth and "sync chain" patches (MPL-2.0, file-level copyleft) or write equivalents **[inference from Brave Sync v2 wiki + go-sync README]**.
- **Gain**: bookmarks, history, open tabs, passwords, settings, and extensions through Chromium's mature sync engine. **Cost**: a large patch surface to rebase every Chromium milestone, DynamoDB operations, and a sync-chain UX that Brave's own users find confusing **[inference]**.
- Verdict: **not for v1 or v1.x**. Reconsider only if users demand full history and password sync.

### 3.4 Option B: custom sync of sidebar data only (recommended path)
- Data model: Spaces, folders, pins, favorites, and per-Space theme and profile ID. Small (KB to low MB), and exactly what Arc Sync covered (Spaces, pinned tabs, Today tabs; Arc did **not** sync history, passwords, extensions, profiles, or favorites, per Arc Help Center summaries).
- Mechanics:
  - Each device keeps a local SQLite or JSON store plus an **operation log**: `{id, hlc_timestamp, device_id, op}`.
  - Merge with **last-writer-wins per field**, using hybrid logical clocks.
  - **Fractional indexing** for ordering pins and folders avoids reorder conflicts.
  - Tombstones handle deletes.
  - This is enough for one person on 2–3 Macs **[inference]**. Use a CRDT library (Yjs, Automerge, Loro) only if you add shared Spaces with concurrent editors.
- Encryption: E2EE with a key generated on device. Recovery is a recovery code or a passkey PRF extension, and the key is stored in iCloud Keychain on Apple devices. The server stores only encrypted ops plus minimal metadata.
- Transports:
  - **B1, iCloud/CloudKit (no account of yours)**:
    - Uses the user's Apple ID, with no backend, no auth vendor, and no GDPR controller role for the sync data.
    - The iPhone companion uses the same container natively.
    - `CKSyncEngine` (macOS 14+/iOS 17+) handles fetch, push, and retry.
    - Apple's capability table lists CloudKit for Developer-ID-signed apps (blog walkthrough; Apple page checkmarks not machine-readable, so verify). It needs an iCloud container in a provisioning profile embedded in the signed `.app`, which T3 Code already does for passkeys.
    - Chromium's macOS layer is Objective-C++, so linking CloudKit is feasible **[inference]**.
    - Downsides: Apple-only, opaque debugging, and no web access.
  - **B2, own account + tiny backend**: copy **T3's relay shape**, a Cloudflare Worker + **one Durable Object per user** (SQLite storage) holding the encrypted op log, with WebSocket fan-out to the user's devices. T3 already chose Durable Objects over Queues for per-key ordered storage (`docs/internals/t3-connect.md`). Auth uses one of the providers below. This is cross-platform and enables sharing, web, and Windows later.
- Passwords and passkeys: **do not build sync**.
  - 1Password and Bitwarden ship Chrome extensions; a Chromium fork can install them from the Chrome Web Store.
  - Apple's "iCloud Passwords" Chrome extension uses a native-messaging host. A fork must place the host manifest in its own `NativeMessagingHosts` directory **[unverified]**.
  - For **iCloud Keychain passkeys** in the browser, request Apple's managed **`com.apple.developer.web-browser.public-key-credential`** entitlement. It is issued per team by request form and must be requested by the Account Holder (Apple docs). Apple forum threads from Sept–Oct 2026 show Chromium-based browsers (e.g. "Akari") stuck in "Submitted" and partial functionality, so **apply early**. T3 Code's `scripts/build-desktop-artifact.ts` shows how the entitlement plus provisioning profile are wired.
  - Chromium's built-in password manager can stay as a local-only option.

### 3.5 Auth provider options (small scale)
| Provider | Free tier | Paid entry | Desktop/native fit | Notes |
|---|---|---|---|---|
| **Clerk** (what T3 uses) | Hobby: **50,000 monthly retained users per app**; up to 3 social connections; **passkeys not on Hobby** (clerk.com/pricing, fetched 2026-11-03) | Pro **$25/mo ($20 annual)**, passkeys + unlimited social; $0.02/MRU above 50k | `@clerk/electron` (+ passkeys) is new (0.1.x). For a Chromium fork, use the hosted sign-in in a tab + custom-scheme or loopback PKCE callback, exactly like T3's CLI flow (`connect-setup.md`) | T3 Code shows the whole pattern: JWT template → Worker verifies. "MRU" counts only users returning ≥1 day after signup. |
| **WorkOS AuthKit** | **Free to 1M MAU** (workos.com/pricing) | $2,500/mo per extra 1M; SSO $125/connection | Hosted UI + OAuth/PKCE; fine for native | Generous; T3 Chat uses WorkOS. |
| **Better Auth** | Free, open source, self-hosted (you run the DB) | n/a (optional paid infra) | **Electron integration since v1.5** (`@better-auth/electron`, system-browser OAuth + custom protocol) | No vendor lock-in, so user data stays in your DB. Can run on Workers + D1/Postgres **[unverified for Workers specifics]**. |
| **Supabase Auth** | **50,000 MAU** free; **free projects pause after 1 week inactivity** | Pro from $25/mo, 100k MAU incl., $0.00325/MAU after | Standard OAuth/PKCE | The pause makes free tier unsuitable for a sync backend. |
| **Sign in with Apple / Google** | Free (Apple needs the $99/yr Developer Program, which you already need for notarization) | n/a | Use **through** the provider's web flow | One blog states Sign in with Apple is not available as a native capability to Developer-ID apps **[unverified]**. The web-based flow via Clerk/WorkOS/Better Auth avoids that. |

**[inference]** Pick:
- **Clerk** if you want to lift T3's working code and docs (PKCE loopback, device grant, JWT-template-verified Worker, passkeys) and are fine paying $25/mo when you want passkeys.
- **Better Auth** if you want zero vendor and the user data in your own DB.
- **WorkOS** if you expect large free usage.

For a local-first browser whose account only gates sync, any of them works. Make **passkey + Sign in with Apple** the primary buttons.

---

## 4. How Arc's account worked and what users disliked
- **Account mandatory at first launch** on Mac and later Windows (BGR; Deceptive Patterns 2024-08-24, "Arc Browser requires an account and has quite a pushy approach to onboarding"). Its onboarding made you scroll to find "No, I want to type in all my passwords again" to skip password import. Reviewers called an email signup for a browser a privacy red flag. Defenders said sync needs an account. No confirmed report that Arc ever made it optional.
- **Arc Sync** synced Spaces, pinned tabs, and Today tabs (described as E2EE), but not history, passwords, extensions, favorites, profiles, or shortcuts (Arc Help Center via search summaries). The mobile companion was deprecated in favour of Arc Search sync.
- **Backend risk realized**: Boosts were stored in **Firebase** with misconfigured ACLs, so anyone could reassign a Boost's `creatorID` and inject JS into another user's browser (**CVE-2024-45489**, found by researcher xyz3va, fixed 2024-08-26). The researcher also noted Boost domain matching contradicted Arc's "we don't know what sites you visit" privacy claim. TBC said it would move off Firebase (arc.net/blog/CVE-2024-45489-incident-response).
- **Account dependency at end of life**: TechCrunch (2026-10-22) reports:
  - New Arc accounts closed on 2026-10-22.
  - Arc Search sign-in and sync end on 2026-11-23.
  - **Arc for Mac and Windows stops working on 2026-12-22**: accounts are deactivated and personal data is deleted within 30 days.
  - Migration path: Dia (Spaces → Profiles, Folders → Pinned Tab Groups).
  - Arc has **no built-in export**. Third-party tools parse `~/Library/Application Support/Arc/StorableSidebar.json` (ArcEscape, SupaSidebar, `arc-export` scripts).
- **Lessons**:
  1. Never gate launch on an account.
  2. Keep sidebar data in an open, documented local format with export.
  3. Treat the backend as optional and replaceable.
  4. Don't put executable user content (Boosts) behind a cloud ACL.
  5. Be explicit about what the server can see.

---

## 5. Recommendations

### 5.1 What to copy from T3 Code (MIT; keep notices)
1. **Product stance**: local-first and fully functional with no account. The account is an add-on that appears in Settings at the point you want cross-device features. Cloud features compile out cleanly when no keys are configured (`.env.example` pattern).
2. **UI kit**: `apps/web/src/components/ui/*`, `components.json` (Base UI + Tailwind v4 + cva + lucide), the `web-ui.md` composition rules, the command palette, sidebar drag and drop, motion, and pin patterns, and the appearance/theme system. This holds for both the WebUI and Electron paths.
3. **Onboarding logic**: fresh-install gate, skippable steps, rerunnable `/welcome`, "import from what you already use" with smart defaults, never clobbering unreadable settings. Build an **Arc importer** (`StorableSidebar.json` → Spaces/folders/pins) and a Chrome profile importer as the headline first-run step; Arc refugees have until 2026-12-22. Give it a more cinematic full-window presentation than T3's modal wizard.
4. **Release discipline**: stable/nightly channels, signed-preview trust split, smoke-launching the packaged app against an old DB before publishing, user-initiated update download (no surprise restarts), managed-policy kill switch, and generated release notes. For Electron, take `release.yml`, `release-desktop.yml`, `build-desktop-artifact.ts`, `sign-macos.ts`, `merge-update-manifests.ts`, and `updates/*` almost directly. For a Chromium fork, use Sparkle (as Helium does) and keep T3's process.
5. **macOS browser plumbing** (pattern for a fork, code for Electron): default-browser Info.plist keys, provisioning profile + entitlements generation, the passkey entitlement request, keychain access groups, cookie importers (`BrowserImport/*`), and per-profile session partitions.
6. **Telemetry boundary**: first-party ingest endpoint, hashed IDs, allowlisted events, no URLs or titles ever. Change one thing: **opt-in or visible toggle**, not an env var.
7. **Auth plumbing, when needed**: system-browser OAuth with PKCE loopback or custom scheme, a device-grant fallback, tokens in a locked file or Keychain, and a Worker verifying provider JWTs (`DesktopClerk.ts`, `ClerkTokenStore.ts`, `connect-setup.md`, `infra/relay`).

Don't copy: the Effect-everything architecture (unless you already like Effect), the server/RPC/orchestration, the provider and agent code, branding, or the `<webview>` approach for a daily-driver browser.

### 5.2 Staged account/sync plan
- **v1: no account.**
  - Local profiles bound to Spaces; Arc + Chrome + Safari import.
  - **Export/backup** of sidebar data as a documented JSON file (manual plus automatic to a user-chosen folder; iCloud Drive works with no integration).
  - Passwords stay with 1Password/Bitwarden extensions or the local Chromium password manager.
  - Start the Apple passkey-entitlement request now.
  - Telemetry off by default or opt-in in onboarding.
  - Design the sidebar store as an **op log with HLC timestamps** from day one, so sync can be added without a migration.
- **v1.x: optional sync, still no mandatory account.**
  - Ship sidebar sync behind a transport interface. **Spike CloudKit (B1)** first: "Sync with iCloud" is a toggle with no signup, covering Mac↔Mac and later iPhone.
  - If the spike fails (entitlement or provisioning in the Chromium bundle, or CKSyncEngine friction), go to B2: an **optional account** ("Create an account to sync", passkey + Sign in with Apple) on Clerk, Better Auth, or WorkOS, with a Cloudflare Worker + per-user Durable Object storing an **E2EE** op log.
  - Either way the browser works identically when signed out or offline, and "delete account" deletes server data immediately.
- **v2: account-backed extras.**
  - iPhone companion (Spaces/pins, send-to-Mac); CloudKit or B2.
  - Shared Spaces/folders (move to a CRDT such as Yjs, Loro, or Automerge for the shared docs).
  - Web viewer; Windows if ever.
  - Consider full Chromium sync via a go-sync-derived server only if users demand history, open-tab, and password sync, and budget for per-milestone patch maintenance.

---

## 6. Gaps / unverified
- Whether Chromium's default WebUI CSP allows `style-src 'unsafe-inline'` (affects Base UI/floating-ui inline styles), and whether Vite-built ESM chunks load under WebUI CSP without a Brave-style `default` Trusted Types policy. Check `content/browser/webui/web_ui_data_source_impl.cc` in the target milestone.
- Apple capability table: exact Developer ID support for CloudKit and Sign in with Apple. The live page's checkmarks could not be extracted; verify in a browser.
- Whether CloudKit + provisioning profile embedding works cleanly in a Chromium `.app` (helpers, frameworks, signing order). Needs a spike.
- iCloud Passwords extension / native-messaging host behaviour in a custom Chromium fork.
- go-sync: current proto freshness versus Chromium M14x, and the exact list of brave-core client patches needed for auth and encryption (not read).
- Arc's stated rationale for the mandatory account (the AMA answer was not retrieved). Arc Sync encryption details come from secondary sources only.
- Clerk Hobby → whether Sign in with Apple counts as one of the 3 free social connections (assumed yes). Clerk Electron SDK maturity (0.1.x).
- Better Auth on Cloudflare Workers specifics, and the 1.5 versus 1.8-beta Electron API differences.
- T3 Code's `preview/Manager.ts` (3.7k lines) was skimmed, not read in full. Its reusability for an Electron browser is inferred from structure and docs.

## Sources
- Repo: `research/repos/t3code` (files cited inline), github.com/pingdotgg/t3code
- Brave: github.com/brave/brave-core (`package.json`, `components/brave_new_tab_ui/`, `components/common/defaultTrustedTypesPolicy.ts`); github.com/brave/go-sync; github.com/brave/brave-browser/wiki/Brave-Sync-v2
- Chromium: `content/public/browser/web_ui_data_source.h` (raw.githubusercontent.com/chromium/chromium/main/…)
- Vivaldi React UI: https://www.infoq.com/news/2016/04/vivaldi-1/ ; https://www.thurrott.com/?p=287859
- Chrome Sync cutoff: https://www.bleepingcomputer.com/news/google/google-to-kill-chrome-sync-feature-in-third-party-browsers ; https://www.neowin.net/news/google-to-limit-chrome-sync-api-following-audit
- Arc account: https://bgr.com/tech/i-want-to-try-the-trendy-arc-browser-but-not-if-they-force-me-to-register-an-account/ ; https://www.deceptive.design/articles/arc-browsers-pushy-account-requirements
- Arc Sync: https://resources.arc.net/hc/en-us/articles/20887042551831
- Arc CVE: https://arc.net/blog/CVE-2024-45489-incident-response ; https://www.eva.ac/blog/arc/
- Arc sunset: https://techcrunch.com/2026/10/22/arc-browser-sunsets-december-22-as-the-browser-company-doubles-down-on-dia/
- Arc export: https://supasidebar.com/tools/arc-sidebar-export ; https://addons.mozilla.org/firefox/addon/arcescape/ ; https://contextbolt.com/blog/export-arc-bookmarks/
- Pricing: https://clerk.com/pricing ; https://workos.com/pricing ; https://supabase.com/pricing ; https://better-auth.com/docs/integrations/electron ; https://better-auth.com/blog/1-5
- Apple: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential ; https://developer.apple.com/forums/thread/852550 ; https://developer.apple.com/help/account/reference/supported-capabilities-macos ; https://flaviocopes.com/mac-iphone-sync.md
- Helium Sparkle patches: `research/repos/helium-macos/patches/rebel/macos/sparkle-integration.patch`

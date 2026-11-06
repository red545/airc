<p align="center"><img src="assets/brand/airc-holographic.png" width="128" height="128" alt="Airc app icon"></p>

# Airc

**An Arc-style browser for macOS. Built and maintained by AI.**

Arc stops working on 22 December 2026. Airc keeps what made it great: the sidebar, Spaces, and switching
between work and personal accounts with a swipe, without a second window. It runs on real Chromium, so your
Chrome extensions and Google logins just work.

> Status: pre-alpha. Nothing to download yet. Follow along in [docs/spec.md](docs/spec.md).

## What it does (v1)

- **Arc's sidebar**: Favorites, pinned and today tabs, folders, auto-archive, the command bar.
- **Spaces with real profiles**: every Space can have its own logins, history, passwords and extensions.
  Switch at the bottom of the sidebar or swipe; it's one window, so fullscreen just works.
- **Smooth onboarding**: import your Arc Spaces, pinned tabs and logins in a minute.
- **Chrome extensions** from the Chrome Web Store.

## How it's built

A native Swift app (AppKit + SwiftUI) owns the window and the sidebar. Chromium runs inside it as an engine
framework, one Chromium browser per (window, profile), the way Arc itself works. AI agents write the code
and do the work of tracking Chromium releases, using the playbook in [AGENTS.md](AGENTS.md).

| Folder | What's in it |
|---|---|
| `apps/browser` | Airc.app (Swift) |
| `apps/marketing` | The homepage |
| `packages/AircKit` | Spaces, profiles, tabs, storage and the Arc importer (pure Swift, no UI) |
| `packages/AircDesign` | Design tokens and shared UI components |
| `engine/` | `//airc/core`, the Chromium engine layer, and the patches that hook it in |
| `docs/` | Spec, research and design notes |
| `scripts/` | Build, sync and release scripts |

## Privacy

Airc sends anonymous usage data, which features get used and how fast Airc is, to PostHog in the EU. Never what you
browse, type or name. Turn it off, or see exactly what is sent, in Settings → Privacy
([docs/user/telemetry.md](docs/user/telemetry.md)).

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

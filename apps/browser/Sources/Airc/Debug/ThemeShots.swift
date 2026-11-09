// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The page palette's marketing shots (P07; `scripts/marketing-shots.sh --parts themes`, through BoostsShots.swift's
/// `MarketingExtraShots` hook): Wikipedia's Typography article in the demo's Personal Space, re-coloured by a Boost that
/// uses nothing but Arc's `--arc-palette-*` variables, so the page wears the Space's theme: Grape (dark), then Peach
/// (light). The Space's theme and the Boost are put back afterwards.
extension SnapshotRunner {
    func mkThemeShots(_ d: MarketingDemo) {
        var original: AircKit.SpaceTheme?
        var space = ""
        // Wikipedia's own colour tokens (Codex), pointed at the Space's palette.
        let css = """
            :root {
              --background-color-base: var(--arc-palette-background) !important;
              --background-color-neutral-subtle: var(--arc-palette-backgroundExtra) !important;
              --background-color-interactive-subtle: var(--arc-palette-backgroundExtra) !important;
              --background-color-interactive: var(--arc-palette-backgroundExtra) !important;
              --background-color-interactive--hover: var(--arc-palette-hover) !important;
              --color-progressive--active: var(--arc-palette-foregroundPrimary) !important;
              --color-base: var(--arc-palette-foregroundPrimary) !important;
              --color-emphasized: var(--arc-palette-foregroundPrimary) !important;
              --color-subtle: var(--arc-palette-foregroundSecondary) !important;
              --color-progressive: var(--arc-palette-focus) !important;
              --color-progressive--hover: var(--arc-palette-focus) !important;
              --border-color-base: var(--arc-palette-hover) !important;
              --border-color-subtle: var(--arc-palette-hover) !important;
            }
            html, body { background: var(--arc-palette-background) !important; color: var(--arc-palette-foregroundPrimary) !important; }
            /* Links in the page's ink, underlined in the accent: the accent alone can be faint on a light theme. */
            a, a:visited { color: var(--arc-palette-foregroundPrimary) !important; text-decoration: underline !important;
                           text-decoration-color: var(--arc-palette-focus) !important; text-decoration-thickness: 2px !important; }
            .cdx-button, .vector-pinnable-header-toggle-button { color: var(--arc-palette-foregroundPrimary) !important; }
            """
        mkShow(d, "personal", "natoday")
        mkSettleShown(timeout: 15, extra: 0.8)
        run { [self] in
            space = c.currentSpaceID
            original = c.store.space(space)?.theme
            try? c.store.updateSpace(space) { $0.theme = DesignTheme.preset("grape")!.model }
            BoostCenter.shared?.update(domain: "wikipedia.org") { $0.name = "Space colors"; $0.css = css }
        }
        wait(1.6)
        mkWindowShot("theme-palette-dark", dark: true)
        run { [self] in try? c.store.updateSpace(space) { $0.theme = DesignTheme.preset("peach")!.model } }
        wait(1.4)
        mkWindowShot("theme-palette")
        run { [self] in
            if let original { try? c.store.updateSpace(space) { $0.theme = original } }
            BoostCenter.shared?.remove(domain: "wikipedia.org", page: nil)
        }
    }
}
#endif

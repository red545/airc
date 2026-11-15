// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Site adapters only read DOM state and click the provider's own button. They
/// never synthesize messages, change unread state, or replace the site's panel.
enum CallChat {
    /// Ownership follows the surface, never pixels or guessed DOM geometry.
    enum Surface { case fullPage, documentPiP, tile, sidebar, hiddenTab }

    /// Provider overrides belong beside the chat adapter. Only add an exception
    /// after verifying that provider's document contains tiles without controls.
    private static let documentControlsByHost: [String: Bool] = [
        "meet.google.com": true, "teams.microsoft.com": true, "zoom.us": true
    ]

    static func pageOwnsControls(on surface: Surface, url: URL?) -> Bool {
        switch surface {
        case .fullPage: return true
        case .documentPiP: return documentControlsByHost[url?.host?.lowercased() ?? ""] ?? true
        case .tile, .sidebar, .hiddenTab: return false
        }
    }

    struct State: Equatable {
        var available = false
        var open = false
        var unread = 0
    }

    static func script(url: URL?, toggle: Bool = false, fixture: Bool = false) -> String? {
        let host = url?.host?.lowercased() ?? ""
        let isFixture = fixture && ["127.0.0.1", "localhost", "::1"].contains(host)
        guard (host == "meet.google.com" && url?.scheme == "https") || isFixture else { return nil }
        // A generic adapter seam: add a host-specific selector set here. Missing
        // or ambiguous controls fail closed after a provider changes its DOM.
        let button = isFixture ? "[data-airc-call-chat]" : "button[aria-label^='Chat with everyone'],[role='button'][aria-label^='Chat with everyone'],button[aria-label^='In-call messages'],[role='button'][aria-label^='In-call messages']"
        let panel = isFixture ? "[data-airc-chat-panel]" : "[role='complementary'][aria-label='In-call messages'],[role='region'][aria-label='In-call messages']"
        return """
        (() => {
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const buttons = [...document.querySelectorAll("\(button)")].filter(visible);
          if (buttons.length !== 1 || buttons[0].disabled || buttons[0].getAttribute('aria-disabled') === 'true') return {available:false,open:false,unread:0};
          const b = buttons[0];
          if (\(toggle ? "true" : "false")) b.click();
          const p = document.querySelector("\(panel)");
          const opened = b.getAttribute('aria-pressed') === 'true' || b.getAttribute('aria-expanded') === 'true' || visible(p);
          const badge = b.querySelector('[data-unread-count],[aria-label*="unread"],[aria-label*="new message"]');
          const label = b.getAttribute('aria-label') || '';
          const raw = b.getAttribute('data-unread-count') || badge?.getAttribute('data-unread-count') || badge?.getAttribute('aria-label') || (/unread|new message/i.test(label) ? label : '');
          const count = Number((raw.match(/\\d+/) || [visible(badge) ? '1' : '0'])[0]);
          return {available:true,open:opened,unread:opened ? 0 : Math.min(99,Math.max(0,count))};
        })()
        """
    }

    static func read(_ page: EngineTab, toggle: Bool = false, fixture: Bool = false,
                     completion: @escaping (State) -> Void) {
        guard !page.isClosed, let script = script(url: page.url, toggle: toggle, fixture: fixture) else {
            completion(State()); return
        }
        let url = page.url
        page.evaluate(script) { [weak page] result in
            guard let page, !page.isClosed, page.url == url,
                  let d = result as? [String: Any] else { completion(State()); return }
            completion(State(available: d["available"] as? Bool ?? false,
                             open: d["open"] as? Bool ?? false, unread: d["unread"] as? Int ?? 0))
        }
    }
}

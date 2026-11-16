// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// ChatGPT in the Command Bar (P07b, Arc Max's; docs/user/command-bar.md): "gpt" + Tab asks ChatGPT (or Perplexity or
/// Claude, the profile's choice in Settings → Site Search), and Return opens the question on that site in a new tab of
/// the window's profile. Arc's own "Ask GPT What You Typed" row offers it for a question typed in the plain bar, and
/// Arc's "New ChatGPT Message" command opens the bar ready to ask. It is a web address: no account or API key in Airc,
/// nothing sent until you press Return, and the question kept only where any opened address is (the profile's
/// history; a private window keeps none). Off until a profile picks a site, as Arc Max's was. The bar's side (the
/// scope, its pill and rows) is CommandBar.swift's `CommandBarScope.ask`.
extension WindowController {
    /// The current Space's profile's chat site; nil: off.
    var commandBarAskAI: AskAIProvider? {
        app?.settings.values.askAI.provider(for: store.profile(ofSpace: currentSpaceID).id)
    }

    /// Arc's "New ChatGPT Message": the Command Bar, asking the profile's chat site.
    func askAICommandActions() -> [CommandAction] {
        guard let p = commandBarAskAI else { return [] }
        let title = p == .chatGPT ? "New ChatGPT Message" : "Ask \(p.name)…"
        return [.init(title: title, symbol: "bubble.left.and.text.bubble.right", hint: "",
                      keywords: ["ask", "ai", "chat", "gpt", "chatgpt", p.name.lowercased(), "question", "message"]) { [weak self] in
            self?.startAskAI()
        }]
    }

    /// Opens the bar (⌘T's) already asking the profile's chat site.
    func startAskAI() {
        guard let p = commandBarAskAI else { return }
        // The command ran from the bar, which closes first: open it again on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.commandBar == nil { self.openCommandBar(mode: .newTab) }
            self.commandBar?.enterScope(.ask(p), origin: "")
        }
    }
}

/// The question's address (a scripted check points a provider at a loopback page instead of the real site).
enum AskAIRoute {
    #if AIRC_TESTING
    static var testTemplates: [AskAIProvider: String] = [:]
    #endif

    static func url(_ p: AskAIProvider, _ prompt: String) -> URL? {
        #if AIRC_TESTING
        if let t = testTemplates[p] { return AskAIProvider.url(for: prompt, template: t) }
        #endif
        return p.url(for: prompt)
    }
}

extension PrivateWindowController {
    /// A private window asks with the choice of the profile it was opened from.
    var commandBarAskAI: AskAIProvider? { app?.settings.values.askAI.provider(for: profileID) }
}

/// Settings → Site Search's "Ask AI" (per profile, with the page's profile choice): which chat site "gpt" + Tab asks.
struct AskAISettingsSection: View {
    @ObservedObject var model: SettingsModel
    let profileID: String

    static let help = "Type “gpt” (or the site's name) in the Command Bar and press Tab, then your question and Return: it opens on that site in a new tab, signed in as you are there. Airc needs no account or API key and keeps the question only in this profile's history, like any page you open. Private windows use their profile's choice."

    var body: some View {
        SettingsSection(title: "Ask AI", help: Self.help) {
            SettingsRow(title: "Ask from the Command Bar",
                        subtitle: "Off by default, as Arc's ChatGPT in the Command Bar.") {
                AircPopUp(options: [("Off", AskAIProvider?.none)] + AskAIProvider.allCases.map { ($0.name, Optional($0)) },
                          selection: model.settings.values.askAI.provider(for: profileID), width: 180) { p in
                    model.settings.values.askAI.set(p, for: profileID)
                }
                .testAnchor("sitesearch.askAI")
            }
        }
    }
}

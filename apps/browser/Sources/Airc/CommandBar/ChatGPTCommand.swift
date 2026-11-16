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
    /// The current Space's profile's chat site (Automatic's from the last `AskAIAutomatic.refresh`); nil: off.
    var commandBarAskAI: AskAIProvider? {
        let id = store.profile(ofSpace: currentSpaceID).id
        return app?.settings.values.askAI.resolved(for: id) { AskAIAutomatic.cached(id) }
    }

    func refreshCommandBarAskAI() { AskAIAutomatic.refresh(app, profileID: store.profile(ofSpace: currentSpaceID).id) }

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
    var commandBarAskAI: AskAIProvider? {
        app?.settings.values.askAI.resolved(for: profileID) { AskAIAutomatic.cached(profileID) }
    }

    func refreshCommandBarAskAI() { AskAIAutomatic.refresh(app, profileID: profileID) }
}

/// Settings → AI's "Automatic" (askai): the chat site a profile uses, found from its pinned tabs, Favorites and the
/// last 90 days of its history (`AskAIProvider.automatic`). Found when the bar opens, after its first frame, at most every
/// two minutes per profile: the main thread only lists the profile's pinned addresses (a few dozen); the history is
/// read off the main thread from the history index's published snapshot. Each keystroke only reads the answer.
enum AskAIAutomatic {
    private static var found: [String: (provider: AskAIProvider?, at: Date)] = [:]
    private static var finding: Set<String> = []
    static let lifetime: TimeInterval = 120

    /// The last answer for the profile; nil before the first or when it uses none.
    static func cached(_ profileID: String) -> AskAIProvider? { found[profileID]?.provider }

    /// Finds the answer again if it's older than `lifetime` (or `force`), when the profile is on Automatic. `done` runs
    /// on the main thread once the answer is in (at once when nothing needed finding).
    static func refresh(_ app: AppDelegate?, profileID: String, force: Bool = false, retry: Bool = true, done: (() -> Void)? = nil) {
        guard let app, app.settings.values.askAI.choice(for: profileID) == .automatic, !finding.contains(profileID) else { done?(); return }
        if !force, let f = found[profileID], Date().timeIntervalSince(f.at) < lifetime { done?(); return }
        // The published snapshot. Before the index's first build (opening the bar starts it), once more a second later.
        guard let snapshot = app.history?.indexSnapshot(profileID: profileID) else {
            if retry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak app] in refresh(app, profileID: profileID, force: force, retry: false, done: done) }
            } else {
                done?()
            }
            return
        }
        let pinned = pinnedURLs(app, profileID: profileID)
        finding.insert(profileID)
        DispatchQueue.global(qos: .utility).async {
            let p = AskAIProvider.automatic(pinned: pinned, snapshot: snapshot, now: Date())
            DispatchQueue.main.async {
                finding.remove(profileID)
                found[profileID] = (p, Date())
                done?()
            }
        }
    }

    /// What Automatic picks for the profile now (Settings shows it; not on the Command Bar's path).
    static func find(_ app: AppDelegate, profileID: String) -> AskAIProvider? {
        AskAIProvider.automatic(pinned: pinnedURLs(app, profileID: profileID),
                                history: app.history?.entries(ofProfile: profileID) ?? [], now: Date())
    }

    /// The saved addresses of the profile's Favorites and of the pinned tabs of its Spaces.
    private static func pinnedURLs(_ app: AppDelegate, profileID: String) -> [String] {
        let store = app.store!
        let spaces = Set(store.spaces(usingProfile: profileID).map(\.id))
        return store.state.items.values.compactMap { item in
            switch item.container {
            case .favorites(let p) where p == profileID: item.savedURL
            case .pinned(let s) where spaces.contains(s): item.savedURL
            default: nil
            }
        }
    }

    static func forget() { found = [:] }
}

/// Settings → Site Search's "Ask AI" (per profile, with the page's profile choice): which chat site "gpt" + Tab asks
/// and the plain bar's "Ask ChatGPT" row offers for a prompt.
struct AskAISettingsSection: View {
    @ObservedObject var model: SettingsModel
    let profileID: String

    static let help = "Type “gpt” (or the site's name) in the Command Bar and press Tab, then your question and Return: it opens on that site in a new tab, signed in as you are there. Airc needs no account or API key and keeps the question only in this profile's history, like any page you open. Private windows use their profile's choice."

    var body: some View {
        SettingsSection(title: "Ask AI", help: Self.help) {
            AskAIChoiceRow(model: model, profileID: profileID, anchor: "sitesearch.askAI")
        }
    }
}

/// The chat site the Command Bar asks (askai: Settings → AI → Command Bar, and Site Search's Ask AI): Automatic, a
/// site, or Off. Automatic names what it found for the profile, or says it found none.
struct AskAIChoiceRow: View {
    @ObservedObject var model: SettingsModel
    let profileID: String
    var title = "Ask AI from the Command Bar"
    let anchor: String

    static let subtitle = "When what you type reads like a question or a prompt, a row under the search asks it in a new chat (↓↓, Return), signed in as you are there. Automatic picks the site you keep pinned or visited lately."

    private var automatic: AskAIProvider? { model.app.flatMap { AskAIAutomatic.find($0, profileID: profileID) } }

    var body: some View {
        let choice = model.settings.values.askAI.choice(for: profileID)
        let auto: String = choice == .automatic ? automatic.map { "Automatic (\($0.name))" } ?? "Automatic (Off)" : "Automatic"
        let sites: [(String, AskAIChoice)] = [AskAIProvider.chatGPT, .claude, .perplexity].map { ($0.name, .provider($0)) }
        let options: [(String, AskAIChoice)] = [(auto, .automatic)] + sites + [("Off", .off)]
        SettingsRow(title: title, subtitle: Self.subtitle) {
            AircPopUp(options: options, selection: choice, width: 180) { c in
                model.settings.values.askAI.set(c, for: profileID)
                AskAIAutomatic.forget()
            }
            .testAnchor(anchor)
        }
    }
}

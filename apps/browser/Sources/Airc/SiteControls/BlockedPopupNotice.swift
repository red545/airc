// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// signinfix: a pop-up the engine blocked (a sign-in window a site opens without a fresh click) is shown by the address
/// field's "Pop-up blocked" icon (SiteIndicators.swift), as in Chrome. Where that icon can't be seen (Little Airc, a
/// private window, a page in Peek, a browser window with its sidebar hidden) a press on the site's Sign in did nothing
/// you could see. There a toast says so, with Open, once per blocked pop-up.
final class BlockedPopupNotice {
    static let shared = BlockedPopupNotice()
    private var observer: NSObjectProtocol?
    private final class Seen { weak var tab: EngineTab?; var ids: Set<String> = []; init(_ t: EngineTab) { tab = t } }
    private var seen: [ObjectIdentifier: Seen] = [:]
    /// What the last toast said and where (the checks read it): "<window kind>: <text>".
    private(set) var lastShown: String?

    static let text = "Pop-up blocked"

    private var passkeyObserver: NSObjectProtocol?
    private var lastPasskeyNotice: [ObjectIdentifier: Date] = [:]
    static let passkeyText = "Passkeys aren’t available on this page yet"

    func start() {
        guard observer == nil else { return }
        // signinfix: a WebKit page's passkey request that can't work in this build (WebKitPasskeyNotice).
        passkeyObserver = NotificationCenter.default.addObserver(forName: WebKitPasskeyNotice.didFail, object: nil, queue: .main) {
            [weak self] n in
            guard let self, let tab = n.object as? EngineTab, !tab.isClosed else { return }
            let key = ObjectIdentifier(tab)
            if let last = self.lastPasskeyNotice[key], Date().timeIntervalSince(last) < 10 { return }
            self.lastPasskeyNotice[key] = Date()
            self.show(Self.passkeyText, detail: "Use another way to sign in", action: nil, for: tab, evenWithIndicator: true)
        }
        _ = SiteControlsCenter.shared   // the engine reports blocked pop-ups once the center exists
        observer = NotificationCenter.default.addObserver(forName: SiteControlsCenter.didChange, object: nil, queue: .main) { [weak self] n in
            guard let tab = n.userInfo?["tab"] as? EngineTab else { return }
            self?.changed(tab)
        }
    }

    private func changed(_ tab: EngineTab) {
        guard !tab.isClosed, let center = SiteControlsCenter.shared else { return }
        let popups = center.activity(of: tab).blockedPopups
        seen = seen.filter { $0.value.tab != nil }
        let key = ObjectIdentifier(tab)
        let entry = seen[key].flatMap { $0.tab === tab ? $0 : nil } ?? Seen(tab)
        seen[key] = entry
        guard let popup = popups.last(where: { !entry.ids.contains($0.id) }) else { return }
        popups.forEach { entry.ids.insert($0.id) }
        let open: (title: String, run: () -> Void) = ("Open", { [weak tab] in
            guard let tab, !tab.isClosed else { return }
            center.engine.openBlockedPopup(popup, in: tab, always: false)
        })
        show(Self.text, detail: URL(string: popup.url)?.host, action: open, for: tab, evenWithIndicator: false)
    }

    /// A toast in the window that hosts `tab` (browser window, Little Airc or private window). In the browser window,
    /// unless `evenWithIndicator`, only where the address field's icon can't be seen.
    private func show(_ text: String, detail: String?, action: (title: String, run: () -> Void)?, for tab: EngineTab, evenWithIndicator: Bool) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        if let c = app.controllers.first(where: { $0.hostsPage(tab) }) {
            guard evenWithIndicator || !c.showsSiteIndicators(for: tab) else { return }
            c.toast.show(text, palette: c.currentPalette, in: c.card.frame, duration: Self.duration, action: action, detail: detail)
            lastShown = "browser: \(text)"
        } else if let l = app.littleArcs.first(where: { $0.page === tab }) {
            l.toast.show(text, palette: l.palette, in: l.card.frame, duration: Self.duration, action: action, detail: detail)
            lastShown = "littleArc: \(text)"
        } else if let p = PrivateBrowsing.shared.windows.first(where: { w in w.pages.contains { $0.tab === tab } }) {
            p.toast.show(text, palette: p.palette, in: p.card.frame, duration: Self.duration, action: action, detail: detail)
            lastShown = "private: \(text)"
        }
    }

    /// Long enough to read and reach for Open.
    static let duration: Double = 8
}

extension WindowController {
    /// The page is one of this window's tabs or its Peek.
    func hostsPage(_ page: EngineTab) -> Bool {
        peek?.page === page || tabID(for: page) != nil
    }

    /// The address field's site icons are on screen for `page`: it's shown (alone or in a split) with the sidebar out.
    func showsSiteIndicators(for page: EngineTab) -> Bool {
        guard !sidebarHidden, peek?.page !== page, let id = tabID(for: page) else { return false }
        return id == shownTabID
    }
}

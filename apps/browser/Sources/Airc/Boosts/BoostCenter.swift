// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// Boosts for the whole app (BST-1; AircKit/Boosts.swift): the store, the Boosts part of the engine's page script, and
/// the pages that run it.
///   - Style: every Boost's CSS travels in the page script, so it is there at document start (no flash). An edit
///     regenerates the script for pages loaded from now on, and sends `apply` to the site's open pages at once.
///   - Documents: every top-frame document says `ready` with a token of its own. Its site is taken from the engine's
///     own record of the frame's origin (never from the page). The tab's record is replaced by each new document,
///     website or not (blob:, data:, about:), and a message goes only to the document it was meant for: the engine
///     checks the frame and its committed origin (`callDocument`), the page its token. A document that can't be
///     reached any more is forgotten.
///   - Custom JavaScript: that site's code, if it has some for this host, is run in that frame, once per page load,
///     and only while the document still has the origin the engine reported.
///   - Zap: one tab at a time is in Zap mode; its `zap` messages become the Boost's zaps.
/// Boosts apply to every Space and profile (as in Arc), and nothing here leaves the Mac.
final class BoostCenter {
    /// Posted on the main thread when a Boost or the zap state changes. userInfo: `domain` (String), if one changed.
    static let didChange = Notification.Name("AircBoostsDidChange")

    static private(set) var shared: BoostCenter?

    let store: BoostStore
    private let scripts: PageScripts
    /// Bumped by every change; a page whose style is from another version gets `apply` when it says ready.
    private var version = 1
    private var saveScheduled = false
    private var documents: [ObjectIdentifier: Document] = [:]
    /// The top-frame document a tab shows now, as it said ready.
    struct Document {
        weak var tab: EngineTab?
        var frame: String
        /// The engine's committed origin of the frame ("https://www.example.com"), its host and its site.
        var origin: String
        var host: String
        var domain: String
        /// The token the document made for itself: every message to it carries it back.
        var token: String
        /// This document's run of the site's custom JavaScript, if it ran.
        var scriptToken: String?
    }

    /// The tab in Zap mode, and the site whose Boost its zaps go to.
    private(set) weak var zapTab: EngineTab?
    private(set) var zapDomain: String?
    /// The editor's hooks for Zap (BoostEditor.swift).
    var zapFailed: (() -> Void)?

    #if AIRC_TESTING
    /// Scripted checks: what ran where, and every message sent to a page (BoostsCheck.swift). Kept only in scripted
    /// runs: dev builds are test builds too, and run for days.
    private let recording = LaunchOptions.current.snapshotDir != nil
    private(set) var scriptRuns: [(domain: String, origin: String)] = []
    private(set) var sent: [(kind: String, origin: String, tab: Int, delivered: Bool)] = []
    #endif

    /// Called once the engine exists. Engines without a page script have no Boosts (the UI hides them).
    static func start(engine: BrowserEngine) {
        guard shared == nil, let pageScripts = engine as? EnginePageScripts else { return }
        // The public suffix list is read off the main thread; the main thread waits only if it needs it sooner.
        DispatchQueue.global(qos: .userInitiated).async { _ = PublicSuffixList.shared }
        let store = BoostStore(url: AppPaths.dataDirectory.appendingPathComponent("Boosts.json"))
        let center = BoostCenter(store: store, scripts: PageScripts.start(engine: pageScripts, existing: pageScripts.existingPageScript))
        shared = center
        center.scripts.pushNow()
        if store.isDirty { center.scheduleSave() }
    }

    private init(store: BoostStore, scripts: PageScripts) {
        self.store = store
        self.scripts = scripts
        store.onChange = { [weak self] domain in self?.changed(domain) }
        installPart()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [weak self] _ in self?.store.flush()
        }
    }

    // MARK: Boosts

    func boost(for url: URL?) -> Boost? { BoostDomain.key(for: url).flatMap { store.boost(domain: $0) } }

    /// The Boost that changes the page now: on, not waiting for its site, and not empty.
    func activeBoost(for url: URL?) -> Boost? {
        guard let b = boost(for: url), b.isLive, !b.isEmpty else { return nil }
        return b
    }

    func update(domain: String, _ change: (inout Boost) -> Void) { store.update(domain: domain, change) }

    /// The Site Controls switch. Code that already ran on `page` can't be taken back: that page reloads.
    func setEnabled(_ on: Bool, domain: String, page: EngineTab?) {
        let ranHere = codeRan(on: page, domain: domain)
        store.update(domain: domain) { $0.enabled = on }
        if !on, ranHere, let page { reloadWithNewScript(page) }
    }

    /// The engine takes the new script before the reload, so the reloaded page never paints the old Boost.
    private func reloadWithNewScript(_ page: EngineTab) {
        scripts.pushNow()
        page.reload()
    }

    func remove(domain: String, page: EngineTab?) {
        let ranHere = codeRan(on: page, domain: domain)
        if zapDomain == domain, let t = zapTab { setZapping(false, tab: t, domain: domain) }
        store.remove(domain: domain)
        if ranHere, let page { reloadWithNewScript(page) }
    }

    private func codeRan(on page: EngineTab?, domain: String) -> Bool {
        page.flatMap { document(of: $0) }.map { $0.domain == domain && $0.scriptToken != nil } ?? false
    }

    private func changed(_ domain: String) {
        version += 1
        installPart()
        applyLive(domain)
        scheduleSave()
        NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["domain": domain])
    }

    private func installPart() {
        var trust = false
        #if AIRC_TESTING
        trust = LaunchOptions.current.snapshotDir != nil && LaunchOptions.current.script == "boosts"
        #endif
        let source = BoostPageScript.source(boosts: store.all, version: version, trustSynthetic: trust)
        scripts.set("boost", source: source) { [weak self] tab, message in self?.received(tab, message) }
    }

    /// The site's open pages take the change at once; an enabled Boost's code runs where it hasn't yet. A deleted or
    /// switched-off Boost sends the empty style, which puts the page back.
    private func applyLive(_ domain: String) {
        let boost = store.boost(domain: domain)
        for (key, doc) in documents where doc.domain == domain {
            let message = BoostPageScript.applyMessage(for: boost, domain: domain, token: doc.token, version: version)
            if send("apply", message, to: key) { runScriptIfNeeded(key) }
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if !self.store.flush() { NSLog("Airc: couldn't save Boosts.json") }
        }
    }

    /// The editor's Save for code: the new script runs in a fresh load of the page (once per page load), on the host
    /// `scriptHost` names, or on every page of the site when it's nil.
    func saveCode(domain: String, css: String, js: String, scriptHost: String?, page: EngineTab?) {
        let before = store.boost(domain: domain)
        store.update(domain: domain) {
            $0.css = css
            $0.js = js
            $0.scriptHost = $0.hasScript && !BoostDomain.isExactHost(domain) ? scriptHost : nil
        }
        let jsChanged = (before?.js ?? "") != js
        if jsChanged, codeRan(on: page, domain: domain), let page { reloadWithNewScript(page) }
    }

    /// The JavaScript's host (nil: the whole site). A page where it ran and that it no longer covers reloads.
    func setScriptHost(_ host: String?, domain: String, page: EngineTab?) {
        let ranHere = codeRan(on: page, domain: domain)
        store.update(domain: domain) { $0.scriptHost = BoostDomain.isExactHost(domain) ? nil : host }
        if ranHere, let page, let doc = document(of: page), store.boost(domain: domain)?.scriptRuns(onHost: doc.host) != true {
            reloadWithNewScript(page)
        }
    }

    /// A Boost held since the move to the whole public suffix list (`Boost.needsSite`) goes to the site the person
    /// picked (`site`, the page's), its code on the page's host only. False if that site has a Boost of its own.
    @discardableResult
    func adoptHeld(_ held: String, to site: String, page: EngineTab?) -> Bool {
        guard let host = page.flatMap({ BoostDomain.webHost(of: $0.url) }) else { return false }
        return store.adopt(held: held, to: site, host: host)
    }

    // MARK: Zap

    func setZapping(_ on: Bool, tab: EngineTab, domain: String) {
        if let old = zapTab, old !== tab || !on { sendZap(false, to: old) }
        zapTab = on ? tab : nil
        zapDomain = on ? domain : nil
        if on { sendZap(true, to: tab) }
        NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["domain": domain])
    }

    private func sendZap(_ on: Bool, to tab: EngineTab) {
        let key = ObjectIdentifier(tab)
        guard let doc = documents[key], doc.tab === tab else { return }
        send("zap", BoostPageScript.zapMessage(on, token: doc.token), to: key)
    }

    func isZapping(_ tab: EngineTab?) -> Bool { tab != nil && zapTab === tab }

    // MARK: Pages

    /// Sends a message to the document `key`'s record names, if its tab still shows it. A document that isn't there
    /// any more is forgotten (its tab shows another site, or the engine has another document in the frame).
    @discardableResult
    private func send(_ kind: String, _ json: String, to key: ObjectIdentifier) -> Bool {
        guard let doc = documents[key] else { return false }
        var delivered = false
        if let tab = doc.tab, !tab.isClosed {
            // The address already shows another site: a navigation away began, or a document that never said ready
            // (one without the page script) replaced this one. Nothing goes; once it has loaded, the record goes too.
            if BoostDomain.key(for: tab.url) != doc.domain {
                if !tab.isLoading { documents[key] = nil }
            } else {
                delivered = scripts.callDocument(tab, frame: doc.frame, origin: doc.origin, part: "boost", kind: kind, json: json)
                if !delivered { documents[key] = nil }
            }
        } else {
            documents[key] = nil
        }
        #if AIRC_TESTING
        if recording { sent.append((kind, doc.origin, doc.tab?.tabID ?? -1, delivered)) }
        #endif
        return delivered
    }

    private func received(_ tab: EngineTab, _ m: EnginePageMessage) {
        // v1 is the top frame only; the site always comes from the engine's origin of the frame.
        guard m.isMainFrame, !tab.isClosed else { return }
        let body = (try? JSONSerialization.jsonObject(with: Data(m.json.utf8))) as? [String: Any] ?? [:]
        let key = ObjectIdentifier(tab)
        let host = URL(string: m.origin).flatMap { BoostDomain.webHost(of: $0) }
        let domain = host.flatMap { BoostDomain.key(forHost: $0) }
        switch m.kind {
        case "ready":
            documents = documents.filter { $0.value.tab != nil && $0.value.tab?.isClosed == false }
            // A new document in this tab: the one before it is forgotten, whatever this one is.
            documents[key] = nil
            guard let host, let domain, let token = body["t"] as? String, !token.isEmpty else {
                if zapTab === tab { setZapping(false, tab: tab, domain: zapDomain ?? "") }
                return
            }
            // A page back from the back-forward cache is the same page load: its code doesn't run again.
            let restored = body["restored"] as? Bool == true
            documents[key] = Document(tab: tab, frame: m.frame, origin: m.origin, host: host, domain: domain, token: token,
                                      scriptToken: restored ? "restored" : nil)
            // The page shows the style of another version, or of another site, than the app's: it gets the app's now.
            // That clears a Boost deleted or switched off since (a page from the back-forward cache, or one made from
            // the old script in the moment before the engine had the new one).
            let boost = store.boost(domain: domain)
            let carried = BoostPageScript.carries(boost) ? domain : nil
            if (body["v"] as? Int) != version || (body["d"] as? String) != carried {
                send("apply", BoostPageScript.applyMessage(for: boost, domain: domain, token: token, version: version), to: key)
            }
            runScriptIfNeeded(key)
            // The zapping tab loaded another page: still the same site, it keeps zapping; another site stops it.
            if zapTab === tab {
                if zapDomain == domain { sendZap(true, to: tab) }
                else { setZapping(false, tab: tab, domain: zapDomain ?? domain) }
            }
        case "zap":
            guard let domain, zapTab === tab, zapDomain == domain, let selector = body["s"] as? String,
                  BoostZap.isValidSelector(selector) else { return }
            let label = String((body["l"] as? String ?? "").prefix(80))
            store.update(domain: domain) { b in
                guard !b.zaps.contains(where: { $0.selector == selector }) else { return }
                b.zaps.append(BoostZap(selector: selector, label: label))
            }
        case "zapEnd":
            guard zapTab === tab else { return }
            setZapping(false, tab: tab, domain: domain ?? zapDomain ?? "")
        case "zapFailed":
            guard zapTab === tab else { return }
            zapFailed?()
        default:
            break
        }
    }

    /// Runs the site's own code in the document that said ready, if the Boost is live, covers its host, and it hasn't
    /// run there yet.
    private func runScriptIfNeeded(_ key: ObjectIdentifier) {
        guard var doc = documents[key], let tab = doc.tab, !tab.isClosed, doc.scriptToken == nil,
              let b = store.boost(domain: doc.domain), b.scriptRuns(onHost: doc.host),
              BoostDomain.key(for: tab.url) == doc.domain else { return }
        doc.scriptToken = doc.token
        documents[key] = doc
        scripts.executeScript(BoostPageScript.runner(origin: doc.origin, domain: doc.domain, code: b.js, token: doc.token),
                              in: tab, frame: doc.frame)
        #if AIRC_TESTING
        if recording { scriptRuns.append((doc.domain, URL(string: doc.origin)?.host ?? "")) }
        #endif
    }

    /// The document `tab` shows, as far as Boosts know.
    func document(of tab: EngineTab) -> Document? {
        guard let d = documents[ObjectIdentifier(tab)], d.tab === tab else { return nil }
        return d
    }
}

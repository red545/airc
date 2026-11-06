// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// Boosts for the whole app (BST-1; AircKit/Boosts.swift): the store, the Boosts part of the engine's page script, and
/// the pages that run it.
///   - Style: every Boost's CSS travels in the page script, so it is there at document start (no flash). An edit
///     regenerates the script for pages loaded from now on, and sends `apply` to the site's open pages at once.
///   - Custom JavaScript: when a page says `ready`, the site is taken from the engine's own record of the frame's
///     origin (never from the page), and that site's code, if it has some, is run in that frame, once per page load.
///   - Zap: one tab at a time is in Zap mode; its `zap` messages become the Boost's zaps.
/// Boosts apply to every Space and profile (as in Arc), and nothing here leaves the Mac.
final class BoostCenter {
    /// Posted on the main thread when a Boost or the zap state changes. userInfo: `domain` (String), if one changed.
    static let didChange = Notification.Name("AircBoostsDidChange")

    static private(set) var shared: BoostCenter?

    let store: BoostStore
    private let scripts: PageScripts
    /// Bumped by every change; a page created from an older script gets `apply` when it says ready.
    private var version = 1
    private var saveScheduled = false
    private var documents: [ObjectIdentifier: Document] = [:]
    /// The top-frame document a tab shows now, as it said ready.
    struct Document {
        weak var tab: EngineTab?
        var frame: String
        /// The site, from the engine's origin of the frame.
        var domain: String
        /// This document's run of the site's custom JavaScript, if it ran.
        var scriptToken: String?
    }

    /// The tab in Zap mode, and the site whose Boost its zaps go to.
    private(set) weak var zapTab: EngineTab?
    private(set) var zapDomain: String?
    /// The editor's hooks for Zap (BoostEditor.swift).
    var zapFailed: (() -> Void)?

    #if AIRC_TESTING
    /// Scripted checks: what ran where (BoostsCheck.swift).
    private(set) var scriptRuns: [(domain: String, origin: String)] = []
    #endif

    /// Called once the engine exists. Engines without a page script have no Boosts (the UI hides them).
    static func start(engine: BrowserEngine) {
        guard shared == nil, let pageScripts = engine as? EnginePageScripts else { return }
        let store = BoostStore(url: AppPaths.dataDirectory.appendingPathComponent("Boosts.json"))
        let center = BoostCenter(store: store, scripts: PageScripts.start(engine: pageScripts, existing: pageScripts.existingPageScript))
        shared = center
        center.scripts.pushNow()
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

    /// The Boost that changes the page now: on and not empty.
    func activeBoost(for url: URL?) -> Boost? {
        guard let b = boost(for: url), b.enabled, !b.isEmpty else { return nil }
        return b
    }

    func update(domain: String, _ change: (inout Boost) -> Void) { store.update(domain: domain, change) }

    /// The Site Controls switch. Code that already ran on `page` can't be taken back: that page reloads.
    func setEnabled(_ on: Bool, domain: String, page: EngineTab?) {
        let ranHere = page.flatMap { documents[ObjectIdentifier($0)] }.map { $0.domain == domain && $0.scriptToken != nil } ?? false
        store.update(domain: domain) { $0.enabled = on }
        if !on, ranHere, let page { reloadWithNewScript(page) }
    }

    /// The engine takes the new script before the reload, so the reloaded page never paints the old Boost.
    private func reloadWithNewScript(_ page: EngineTab) {
        scripts.pushNow()
        page.reload()
    }

    func remove(domain: String, page: EngineTab?) {
        let ranHere = page.flatMap { documents[ObjectIdentifier($0)] }.map { $0.domain == domain && $0.scriptToken != nil } ?? false
        if zapDomain == domain, let t = zapTab { setZapping(false, tab: t, domain: domain) }
        store.remove(domain: domain)
        if ranHere, let page { reloadWithNewScript(page) }
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

    /// The site's open pages take the change at once; an enabled Boost's code runs where it hasn't yet.
    private func applyLive(_ domain: String) {
        let message = BoostPageScript.applyMessage(for: store.boost(domain: domain), domain: domain)
        for (key, doc) in documents where doc.domain == domain {
            guard let tab = doc.tab, !tab.isClosed else { documents[key] = nil; continue }
            scripts.callPage(tab, part: "boost", kind: "apply", json: message)
            runScriptIfNeeded(in: tab, key: key)
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

    /// The editor's Save for code: the new script runs in a fresh load of the page (once per page load).
    func saveCode(domain: String, css: String, js: String, page: EngineTab?) {
        let before = store.boost(domain: domain)
        store.update(domain: domain) {
            $0.css = css
            $0.js = js
        }
        let jsChanged = (before?.js ?? "") != js
        if jsChanged, let page, let doc = documents[ObjectIdentifier(page)], doc.domain == domain, doc.scriptToken != nil {
            reloadWithNewScript(page)
        }
    }

    // MARK: Zap

    func setZapping(_ on: Bool, tab: EngineTab, domain: String) {
        if let old = zapTab, old !== tab || !on {
            scripts.callPage(old, part: "boost", kind: "zap", json: #"{"on":false}"#)
        }
        zapTab = on ? tab : nil
        zapDomain = on ? domain : nil
        if on { scripts.callPage(tab, part: "boost", kind: "zap", json: #"{"on":true}"#) }
        NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["domain": domain])
    }

    func isZapping(_ tab: EngineTab?) -> Bool { tab != nil && zapTab === tab }

    // MARK: Pages

    private func received(_ tab: EngineTab, _ m: EnginePageMessage) {
        // v1 is the top frame only; the site always comes from the engine's origin of the frame.
        guard m.isMainFrame, !tab.isClosed, let origin = URL(string: m.origin), let scheme = origin.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = origin.host, let domain = BoostDomain.key(forHost: host) else { return }
        let body = (try? JSONSerialization.jsonObject(with: Data(m.json.utf8))) as? [String: Any] ?? [:]
        let key = ObjectIdentifier(tab)
        switch m.kind {
        case "ready":
            documents = documents.filter { $0.value.tab != nil && $0.value.tab?.isClosed == false }
            // A page back from the back-forward cache is the same page load: its code doesn't run again.
            let restored = body["restored"] as? Bool == true
            documents[key] = Document(tab: tab, frame: m.frame, domain: domain, scriptToken: restored ? "restored" : nil)
            // A page created between an edit and the engine getting the new script.
            if (body["v"] as? Int) != version, store.boost(domain: domain) != nil {
                scripts.callPage(tab, part: "boost", kind: "apply",
                                 json: BoostPageScript.applyMessage(for: store.boost(domain: domain), domain: domain))
            }
            runScriptIfNeeded(in: tab, key: key)
            // The zapping tab loaded another page: still the same site, it keeps zapping; another site stops it.
            if zapTab === tab {
                if zapDomain == domain { scripts.callPage(tab, part: "boost", kind: "zap", json: #"{"on":true}"#) }
                else { setZapping(false, tab: tab, domain: zapDomain ?? domain) }
            }
        case "zap":
            guard zapTab === tab, zapDomain == domain, let selector = body["s"] as? String, BoostZap.isValidSelector(selector) else { return }
            let label = String((body["l"] as? String ?? "").prefix(80))
            store.update(domain: domain) { b in
                guard !b.zaps.contains(where: { $0.selector == selector }) else { return }
                b.zaps.append(BoostZap(selector: selector, label: label))
            }
        case "zapEnd":
            guard zapTab === tab else { return }
            setZapping(false, tab: tab, domain: domain)
        case "zapFailed":
            guard zapTab === tab else { return }
            zapFailed?()
        default:
            break
        }
    }

    /// Runs the site's own code in the document that said ready, if the Boost is on and it hasn't run there yet.
    private func runScriptIfNeeded(in tab: EngineTab, key: ObjectIdentifier) {
        guard var doc = documents[key], doc.tab === tab, doc.scriptToken == nil,
              let b = store.boost(domain: doc.domain), b.enabled, b.hasScript else { return }
        let token = UUID().uuidString
        doc.scriptToken = token
        documents[key] = doc
        scripts.executeScript(BoostPageScript.runner(domain: doc.domain, code: b.js, token: token), in: tab, frame: doc.frame)
        #if AIRC_TESTING
        scriptRuns.append((doc.domain, tab.url?.host ?? ""))
        #endif
    }

    /// The document `tab` shows, as far as Boosts know.
    func document(of tab: EngineTab) -> Document? {
        guard let d = documents[ObjectIdentifier(tab)], d.tab === tab else { return nil }
        return d
    }
}

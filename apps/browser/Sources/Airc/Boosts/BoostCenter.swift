// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

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
///   - Frames (BST-3): a document in a frame of a page on the same site says ready too and gets the site's style for
///     frames (BoostStyle's `frame`); never code. Its record goes with the next document of its tab's page.
///   - Zap in frames (boosts3): Zap mode is on in the zapping tab's frame documents too (those there and those that say
///     ready while it lasts); what's zapped in one is a frame zap (`BoostZap.frame`, the frames' only). A frame's
///     messages are matched to its record by its token: WebKit gives a frame a new ID with each message.
///   - Private windows (boosts3): the engine tells the page script a document is private; it takes nothing and its top
///     frame says only `ready {private}`, with no token, so no style, code or Zap ever reaches it. Chromium's private
///     profile copies the regular one's zoom per host, so a private tab showing a size a Boost set goes back to 100 %,
///     when its document comes and whenever a Boost's size changes (the regular profile's zoom and ledger untouched).
///   - Size: the Boost's size is the page's zoom (BoostZoom), set as a page of the site is shown and taken back when the
///     size or the Boost goes, unless the person zoomed the page themselves.
///   - Try it on: a Boost under review can be shown on its site's pages for a while (`preview`): style and size only,
///     never its code; Cancel puts the stored Boost back.
///   - Links: a page that is a Boost link (BoostLink) opens the review in its window.
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
    /// Documents in frames of each tab's page, by the engine's frame ID.
    private var frameDocuments: [ObjectIdentifier: [String: Document]] = [:]
    /// The zoom the app last gave each tab for a Boost's size, for engines whose zoom is the tab's (WebKit, a split's
    /// panes): the next site's page takes it back.
    private var zoomedTabs: [ObjectIdentifier: Double] = [:]
    private weak var siteControls: EngineSiteControls?
    /// Boosts under review shown on their site for now (Try It On), by site.
    private(set) var previews: [String: Boost] = [:]
    /// `@import`s the pages of each site couldn't load lately (the editor shows them): URL → the page's reason.
    private(set) var importFailures: [String: [String: String]] = [:]
    /// The Boost link each tab's page showed last, so a reload doesn't ask again.
    private var shownLinks: [ObjectIdentifier: String] = [:]
    /// A tab's page is a Boost link (BoostSharing opens the review).
    var linkOpened: ((EngineTab, URL) -> Void)?
    /// The top-frame document a tab shows now, as it said ready.
    struct Document {
        weak var tab: EngineTab?
        var frame: String
        /// A frame below the top one.
        var isFrame = false
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
    /// Private windows' pages on a website, by tab (boosts3).
    private struct PrivatePage { weak var tab: EngineTab?; var host: String }
    private var privatePages: [ObjectIdentifier: PrivatePage] = [:]
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
        center.siteControls = engine as? EngineSiteControls
        center.linkOpened = { tab, url in BoostSharing.openLink(url, from: tab) }
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

    /// What a site's pages show: a Boost being tried on, or the stored one.
    func shownBoost(domain: String) -> Boost? { previews[domain] ?? store.boost(domain: domain) }

    /// Try It On: `boost` (style and size, never code) on its site's pages until it's set again with nil.
    func setPreview(_ boost: Boost?, domain: String) {
        if let boost { var b = boost; b.domain = domain; b.js = ""; previews[domain] = b } else { previews[domain] = nil }
        changed(domain)
    }

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
        trust = LaunchOptions.current.snapshotDir != nil && ["boosts", "boosts2", "boosts3"].contains(LaunchOptions.current.script ?? "")
        #endif
        var shown = store.boosts
        for (d, b) in previews { shown[d] = b }
        let source = BoostPageScript.source(boosts: shown.values.sorted { $0.domain < $1.domain }, version: version, trustSynthetic: trust)
        scripts.set("boost", source: source, frames: true) { [weak self] tab, message in self?.received(tab, message) }
    }

    /// The site's open pages take the change at once, and their frames of the same site; an enabled Boost's code runs
    /// where it hasn't yet. A deleted or switched-off Boost sends the empty style, which puts the page back.
    private func applyLive(_ domain: String) {
        let boost = shownBoost(domain: domain)
        for (key, doc) in documents where doc.domain == domain {
            let message = BoostPageScript.applyMessage(for: boost, domain: domain, token: doc.token, version: version)
            if send("apply", message, to: key) { runScriptIfNeeded(key) }
            if let tab = doc.tab { applyZoom(tab, host: doc.host, domain: domain) }
        }
        for (key, frames) in frameDocuments {
            for (id, doc) in frames where doc.domain == domain {
                let message = BoostPageScript.applyMessage(for: boost, domain: domain, token: doc.token, version: version, frame: true)
                sendToFrame("apply", message, tab: key, frame: id)
            }
        }
    }

    // MARK: Size

    /// The page's zoom for its Boost's size (BoostZoom): set if the page is at 100 % or at a zoom the app gave it, taken
    /// back to 100 % when the size or the Boost went, and left alone when the person zoomed it themselves.
    private func applyZoom(_ tab: EngineTab, host: String, domain: String?) {
        let key = ObjectIdentifier(tab)
        let target = domain.flatMap { shownBoost(domain: $0) }.flatMap { $0.isLive && $0.font.step != 0 ? $0.font.scale : nil }
        let tabScoped = siteControls?.zoomScope(of: tab) == .tab
        var ledger: [Double] = []
        if let z = store.zoomedHosts[host] { ledger.append(z) }
        if tabScoped, let z = zoomedTabs[key] { ledger.append(z) }
        let current = tab.zoomFactor
        guard let next = BoostZoom.plan(current: current, target: target, ledger: ledger) else {
            // The person's own zoom now: the app forgets it set one here.
            if let z = store.zoomedHosts[host], !BoostZoom.near(current, z) { store.noteZoom(nil, host: host); scheduleSave() }
            if target == nil, let z = zoomedTabs[key], !BoostZoom.near(current, z) || !tabScoped { zoomedTabs[key] = nil }
            return
        }
        guard let steps = BoostZoom.steps(to: next) else { return }
        tab.zoom(step: 0)
        for _ in 0..<abs(steps) { tab.zoom(step: steps.signum()) }
        let set = next == 1 ? nil : next
        store.noteZoom(set, host: host)
        zoomedTabs[key] = set
        scheduleSave()
        // Chromium's private profile follows the regular one's zoom for the host: its pages go back to 100 %.
        if set != nil, privatePages.values.contains(where: { $0.host == host }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.resetPrivateZoom(host: host) }
        }
    }

    /// Whether `tab` is a private window's (Chromium's off-the-record profile, WebKit's private session).
    static func isPrivate(_ tab: EngineTab) -> Bool {
        #if canImport(AircCore)
        if let p = tab.profile as? ChromiumProfile { return p.core.offTheRecord }
        #endif
        return (tab.profile as? WebKitProfile)?.privateSession == true
    }

    /// A private window's page said it's there: remembered by its host, and put back to 100 % if it shows a size a
    /// Boost set (the person's own zoom, any other value, is left alone).
    private func privateReady(_ tab: EngineTab, host: String?) {
        let key = ObjectIdentifier(tab)
        privatePages = privatePages.filter { $0.value.tab?.isClosed == false }
        guard let host else { privatePages[key] = nil; return }
        privatePages[key] = PrivatePage(tab: tab, host: host)
        resetPrivateZoom(host: host)
    }

    private func resetPrivateZoom(host: String) {
        guard let z = store.zoomedHosts[host] else { return }
        for p in privatePages.values where p.host == host {
            guard let tab = p.tab, !tab.isClosed, BoostZoom.near(tab.zoomFactor, z) else { continue }
            tab.zoom(step: 0)
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
        // New CSS: its pages say again what its imports did.
        if (before?.css ?? "") != css { importFailures[domain] = nil }
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
        // The page's frames of its own site zap inside themselves.
        for (id, f) in frameDocuments[key] ?? [:] where f.domain == doc.domain {
            sendToFrame("zap", BoostPageScript.zapMessage(on, token: f.token), tab: key, frame: id)
        }
    }

    /// The frame document of `tab` whose token is `token` (WebKit's frame IDs change with each message).
    private func frameDocument(of tab: EngineTab, token: Any?) -> Document? {
        guard let token = token as? String, !token.isEmpty else { return nil }
        return frameDocuments[ObjectIdentifier(tab)]?.values.first { $0.token == token && $0.tab === tab }
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

    /// `send` for a frame's document: while its tab's page is still on the frame's site and the frame is still there.
    @discardableResult
    private func sendToFrame(_ kind: String, _ json: String, tab key: ObjectIdentifier, frame id: String) -> Bool {
        guard let doc = frameDocuments[key]?[id] else { return false }
        var delivered = false
        if let tab = doc.tab, !tab.isClosed, BoostDomain.key(for: tab.url) == doc.domain {
            delivered = scripts.callFrameDocument(tab, frame: doc.frame, origin: doc.origin, part: "boost", kind: kind, json: json)
        }
        if !delivered { frameDocuments[key]?[id] = nil }
        #if AIRC_TESTING
        if recording { sent.append(("frame." + kind, doc.origin, doc.tab?.tabID ?? -1, delivered)) }
        #endif
        return delivered
    }

    /// A document in a frame below the top one: `ready` (on the tab page's own site), and Zap's messages while its tab
    /// zaps (boosts3).
    private func receivedFromFrame(_ tab: EngineTab, _ m: EnginePageMessage, host: String?, domain: String?, body: [String: Any]) {
        let key = ObjectIdentifier(tab)
        if m.kind != "ready" { return receivedZapFromFrame(tab, m, domain: domain, body: body) }
        frameDocuments[key]?[m.frame] = nil
        // The frame's site (the engine's origin of it) must be its page's: a frame of another site gets nothing.
        guard let host, let domain, domain == BoostDomain.key(for: tab.url), let token = body["t"] as? String, !token.isEmpty
        else { return }
        frameDocuments[key, default: [:]][m.frame] = Document(tab: tab, frame: m.frame, isFrame: true, origin: m.origin, host: host,
                                                              domain: domain, token: token, scriptToken: nil)
        let boost = shownBoost(domain: domain)
        let carried = BoostPageScript.carries(boost) ? domain : nil
        if (body["v"] as? Int) != version || (body["d"] as? String) != carried {
            sendToFrame("apply", BoostPageScript.applyMessage(for: boost, domain: domain, token: token, version: version, frame: true),
                        tab: key, frame: m.frame)
        }
        // A frame that comes while its tab zaps (one loading late, or after a navigation inside it) zaps too.
        if zapTab === tab, zapDomain == domain {
            sendToFrame("zap", BoostPageScript.zapMessage(true, token: token), tab: key, frame: m.frame)
        }
    }

    /// Zap's messages from a frame document of the zapping tab, on the site its zaps go to.
    private func receivedZapFromFrame(_ tab: EngineTab, _ m: EnginePageMessage, domain: String?, body: [String: Any]) {
        guard zapTab === tab, let zapDomain, domain == zapDomain, let doc = frameDocument(of: tab, token: body["t"]),
              doc.domain == zapDomain else { return }
        switch m.kind {
        case "zap":
            guard let selector = body["s"] as? String, BoostZap.isValidSelector(selector) else { return }
            let label = String((body["l"] as? String ?? "").prefix(80))
            store.update(domain: zapDomain) { b in
                guard !b.zaps.contains(where: { $0.selector == selector && $0.frame }) else { return }
                b.zaps.append(BoostZap(selector: selector, label: label, frame: true))
            }
        case "zapEnd":
            setZapping(false, tab: tab, domain: zapDomain)
        case "zapFailed":
            zapFailed?()
        default:
            break
        }
    }

    #if AIRC_TESTING
    /// Scripted checks: the frame documents a tab has (BoostsTwoCheck).
    func frameDocumentCount(_ tab: EngineTab) -> Int { frameDocuments[ObjectIdentifier(tab)]?.count ?? 0 }
    #endif

    private func received(_ tab: EngineTab, _ m: EnginePageMessage) {
        // The site always comes from the engine's origin of the frame.
        guard !tab.isClosed else { return }
        let body = (try? JSONSerialization.jsonObject(with: Data(m.json.utf8))) as? [String: Any] ?? [:]
        let key = ObjectIdentifier(tab)
        let host = URL(string: m.origin).flatMap { BoostDomain.webHost(of: $0) }
        let domain = host.flatMap { BoostDomain.key(forHost: $0) }
        guard m.isMainFrame else { return receivedFromFrame(tab, m, host: host, domain: domain, body: body) }
        if m.kind == "ready", body["private"] as? Bool == true {
            guard Self.isPrivate(tab) else { return }
            return privateReady(tab, host: host)
        }
        switch m.kind {
        case "ready":
            documents = documents.filter { $0.value.tab != nil && $0.value.tab?.isClosed == false }
            frameDocuments = frameDocuments.filter { documents[$0.key] != nil || $0.key == key }
            zoomedTabs = zoomedTabs.filter { documents[$0.key] != nil || $0.key == key }
            // A new document in this tab: the one before it is forgotten, whatever this one is, and so are its frames
            // (a frame of the same site is in the page's process, so its ready never comes before its page's).
            documents[key] = nil
            frameDocuments[key] = nil
            if let host { applyZoom(tab, host: host, domain: domain) }
            if let url = tab.url, BoostLink.isLink(url) {
                if shownLinks[key] != url.absoluteString { shownLinks[key] = url.absoluteString; linkOpened?(tab, url) }
            } else { shownLinks[key] = nil }
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
            let boost = shownBoost(domain: domain)
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
                guard !b.zaps.contains(where: { $0.selector == selector && !$0.frame }) else { return }
                b.zaps.append(BoostZap(selector: selector, label: label))
            }
        case "zapEnd":
            guard zapTab === tab else { return }
            setZapping(false, tab: tab, domain: domain ?? zapDomain ?? "")
        case "zapFailed":
            guard zapTab === tab else { return }
            zapFailed?()
        case "importFailed":
            guard let domain, documents[key]?.domain == domain, let url = body["u"] as? String, let why = body["w"] as? String,
                  url.count <= 300, why.count <= 20 else { return }
            if importFailures[domain]?[url] == why { return }
            var list = importFailures[domain] ?? [:]
            if list.count >= 24 { return }
            list[url] = why
            importFailures[domain] = list
            NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["domain": domain])
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

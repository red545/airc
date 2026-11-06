// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

#if canImport(AircCore)
import AircCore

// Engine pass 13 for the app (engine/PASS13.md): downloads with their history, Media Session tabs and actions, and
// the call window's page host. The pass's selectors are called by name (`Pass13`), so the app also builds against a
// framework from before the pass; on one, `downloadsAvailable` and `mediaAvailable` are false and the app shows no
// downloads and no media tray. Once out/AircRelease is qualified with pass 13, these calls can become direct ones.

extension ChromiumEngine: EngineDownloads, EngineMedia, EngineCallHosting {
    var downloadsAvailable: Bool { Pass13.downloads }
    var asksBeforeClosingWithDownloads: Bool { true }
    var mediaAvailable: Bool { Pass13.media }

    // MARK: Downloads

    // A profile's downloads are its Chromium pages' and its WebKit pages' (HybridEngine.swift), in one list.

    func downloadItems(in profile: EngineProfile) -> [EngineDownload] {
        guard let p = core(of: profile) else { return [] }
        let rows = (Pass13.value(p, "downloads") as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(EngineDownload.init) }
        return rows + (loadedWebKitProfile(for: profile).map { webKit.downloadItems(in: $0) } ?? [])
    }

    func observeDownloadItems(in profile: EngineProfile, _ handler: ((EngineDownload) -> Void)?) {
        guard let p = core(of: profile) else { return }
        p.observeDownloads(handler.map { handler in
            { row in if let d = (row as? [String: Any]).flatMap(EngineDownload.init) { handler(d) } }
        })
        (profile as? ChromiumProfile)?.hybrid.downloadsHandler = handler
        if let w = loadedWebKitProfile(for: profile) { webKit.observeDownloadItems(in: w, handler) }
    }

    @discardableResult
    func performDownloadAction(_ action: EngineDownloadAction, id: String, in profile: EngineProfile) -> Bool {
        guard let p = core(of: profile) else { return false }
        if let w = loadedWebKitProfile(for: profile), webKit.downloadItems(in: w).contains(where: { $0.id == id }) {
            return webKit.performDownloadAction(action, id: id, in: w)
        }
        return Pass13.call(p, "performDownloadAction:identifier:", action.rawValue, id)
    }

    func downloadedFile(_ id: String, in profile: EngineProfile) -> URL? {
        if let w = loadedWebKitProfile(for: profile), let file = webKit.downloadedFile(id, in: w) { return file }
        guard let p = core(of: profile), let path = Pass13.string(p, "downloadPath:", id), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    var downloadsCloseConfirmation: ((Int, @escaping (Bool) -> Void) -> Void)? {
        get { ChromiumRuntime.downloadsCloseConfirmation }
        set { ChromiumRuntime.downloadsCloseConfirmation = newValue }
    }

    // MARK: Media Session

    // The media tray lists a profile's Chromium and WebKit pages together; a WebKit page's session comes from its
    // WebKit side (WebKitEngine+Library.swift).

    func observeMediaTabs(in profile: EngineProfile, _ handler: (([EngineTab]) -> Void)?) {
        guard let p = core(of: profile), let state = (profile as? ChromiumProfile)?.hybrid else { return }
        state.mediaHandler = handler
        state.chromiumMediaTabs = []
        state.webKitMediaTabs = []
        // The engine's tabs have their Swift wrapper as delegate; one the app never wrapped isn't one of its pages.
        Pass13.observeList(p, "observeMediaTabs:", handler.map { _ in
            { [weak state] list in
                state?.chromiumMediaTabs = list.compactMap { ($0 as? AircTab)?.delegate as? EngineTab }
                state?.emitMediaTabs()
            }
        })
        if let w = loadedWebKitProfile(for: profile) {
            webKit.observeMediaTabs(in: w, handler.map { _ in
                { [weak state] tabs in
                    state?.webKitMediaTabs = tabs
                    state?.emitMediaTabs()
                }
            })
        }
    }

    func mediaSession(of tab: EngineTab) -> EngineMediaSession {
        if tab is WebKitTab { return webKit.mediaSession(of: tab) }
        guard let t = core(of: tab), let d = Pass13.value(t, "mediaSession") as? [String: Any] else { return EngineMediaSession() }
        return EngineMediaSession(d)
    }

    func observeMediaSession(of tab: EngineTab, _ handler: ((EngineMediaSession) -> Void)?) {
        if tab is WebKitTab { return webKit.observeMediaSession(of: tab, handler) }
        guard let t = core(of: tab) else { return }
        Pass13.observeDictionary(t, "observeMediaSession:", handler.map { handler in
            { d in handler(EngineMediaSession(d as? [String: Any] ?? [:])) }
        })
    }

    @discardableResult
    func performMediaAction(_ action: String, value: Double, in tab: EngineTab) -> Bool {
        if tab is WebKitTab { return webKit.performMediaAction(action, value: value, in: tab) }
        guard let t = core(of: tab) else { return false }
        return Pass13.call(t, "performMediaAction:value:", action, value)
    }
}

extension ChromiumRuntime {
    /// The app's answer to the engine's "close anyway?" for downloads (ChromiumWindow's confirmCloseWithDownloads).
    static var downloadsCloseConfirmation: ((Int, @escaping (Bool) -> Void) -> Void)?
}

/// Engine pass 13's selectors by name. A call to one the framework lacks does nothing (false, nil, empty).
enum Pass13 {
    static let profileSelectors = ["downloads", "performDownloadAction:identifier:", "downloadPath:", "mediaTabs", "observeMediaTabs:"]
    static let tabSelectors = ["mediaSession", "observeMediaSession:", "performMediaAction:value:"]
    /// Selectors the framework in this app lacks (the scripted checks list them).
    static let missing: [String] = profileSelectors.filter { !AircProfile.instancesRespond(to: NSSelectorFromString($0)) }
        + tabSelectors.filter { !AircTab.instancesRespond(to: NSSelectorFromString($0)) }
    static let downloads = !missing.contains { profileSelectors.prefix(3).contains($0) }
    static let media = !missing.contains { !profileSelectors.prefix(3).contains($0) }

    typealias DictionaryBlock = @convention(block) (NSDictionary) -> Void
    typealias ArrayBlock = @convention(block) (NSArray) -> Void

    static func value(_ o: NSObject, _ key: String) -> Any? {
        o.responds(to: NSSelectorFromString(key)) ? o.value(forKey: key) : nil
    }

    static func call(_ o: NSObject, _ name: String, _ a: String, _ b: String) -> Bool {
        let s = NSSelectorFromString(name)
        guard o.responds(to: s) else { return false }
        typealias F = @convention(c) (NSObject, Selector, NSString, NSString) -> ObjCBool
        return unsafeBitCast(o.method(for: s), to: F.self)(o, s, a as NSString, b as NSString).boolValue
    }

    static func call(_ o: NSObject, _ name: String, _ a: String, _ v: Double) -> Bool {
        let s = NSSelectorFromString(name)
        guard o.responds(to: s) else { return false }
        typealias F = @convention(c) (NSObject, Selector, NSString, Double) -> ObjCBool
        return unsafeBitCast(o.method(for: s), to: F.self)(o, s, a as NSString, v).boolValue
    }

    static func string(_ o: NSObject, _ name: String, _ a: String) -> String? {
        let s = NSSelectorFromString(name)
        guard o.responds(to: s) else { return nil }
        return o.perform(s, with: a)?.takeUnretainedValue() as? String
    }

    static func observeDictionary(_ o: NSObject, _ name: String, _ block: ((NSDictionary) -> Void)?) {
        let s = NSSelectorFromString(name)
        guard o.responds(to: s) else { return }
        typealias F = @convention(c) (NSObject, Selector, DictionaryBlock?) -> Void
        // A block made directly (not inside Optional.map: Swift 6.4's SILGen crashed on that conversion).
        var b: DictionaryBlock?
        if let block { b = { block($0) } }
        unsafeBitCast(o.method(for: s), to: F.self)(o, s, b)
    }

    static func observeList(_ o: NSObject, _ name: String, _ block: ((NSArray) -> Void)?) {
        let s = NSSelectorFromString(name)
        guard o.responds(to: s) else { return }
        typealias F = @convention(c) (NSObject, Selector, ArrayBlock?) -> Void
        var b: ArrayBlock?
        if let block { b = { block($0) } }
        unsafeBitCast(o.method(for: s), to: F.self)(o, s, b)
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

#if canImport(AircCore)
import AircCore

// Site Controls on Chromium (engine/PASS13.md "Site Controls"): AircProfile's permission, site-data and host-zoom
// calls, AircTab's securityInfo and blocked pop-ups, and the engine's capture indicator. Everything is per profile, so
// each Space's own Chromium profile has its own settings.
//
extension ChromiumEngine: EngineSiteControls {
    var sitePermissionsAvailable: Bool { SiteCore.available }
    var siteDataAvailable: Bool { SiteCore.available }
    var siteActivityAvailable: Bool { true }

    // MARK: Permissions

    func sitePermissions(for origin: String, in profile: EngineProfile) -> [SitePermission: SitePermissionValue] {
        guard SiteCore.available, let p = core(of: profile) else { return [:] }
        var result: [SitePermission: SitePermissionValue] = [:]
        for (key, value) in p.sitePermissions(origin) {
            guard let name = key as? String, let kind = SitePermission(rawValue: name), let row = value as? [String: Any],
                  let state = SitePermissionState(rawValue: row["state"] as? String ?? "") else { continue }
            let effective = SitePermissionState(rawValue: row["effective"] as? String ?? "") ?? .ask
            result[kind] = SitePermissionValue(state: state, effective: effective,
                                               managed: (row["managed"] as? NSNumber)?.boolValue ?? false)
        }
        return result
    }

    @discardableResult
    func setSitePermission(_ permission: SitePermission, to state: SitePermissionState, origin: String,
                           in profile: EngineProfile) -> Bool {
        guard SiteCore.available, let p = core(of: profile) else { return false }
        return p.setSitePermission(permission.rawValue, state: state.rawValue, origin: origin)
    }

    @discardableResult
    func resetSitePermissions(origin: String, in profile: EngineProfile) -> Bool {
        guard SiteCore.available, let p = core(of: profile) else { return false }
        return p.resetSitePermissions(origin)
    }

    func observeSitePermissions(in profile: EngineProfile, _ handler: ((String) -> Void)?) {
        guard SiteCore.available, let p = core(of: profile) else { return }
        // A block made directly (Swift 6.4's SILGen crashed converting one inside Optional.map; ChromiumEngine+Library).
        if let handler { p.observeSitePermissions { origin in handler(origin) } } else { p.observeSitePermissions(nil) }
    }

    // MARK: Data

    func siteData(origin: String, in profile: EngineProfile, completion: @escaping (SiteDataUsage?) -> Void) {
        // A site that plays in WebKit keeps its data in the profile's WebKit store (HybridEngine.swift).
        if ProtectedMedia.shared.engine(for: URL(string: origin)) == .webKit, let w = loadedWebKitProfile(for: profile) {
            return webKit.siteData(origin: origin, in: w, completion: completion)
        }
        guard SiteCore.available, let p = core(of: profile) else { return completion(nil) }
        p.siteData(origin) { d in
            guard (d["valid"] as? NSNumber)?.boolValue == true else { return completion(nil) }
            let bytes = (d["storageBytes"] as? NSNumber)?.int64Value ?? 0
            completion(SiteDataUsage(cookies: (d["cookies"] as? NSNumber)?.intValue ?? 0, storageBytes: bytes,
                                     hasStorage: bytes > 0))
        }
    }

    func clearSiteData(origin: String, in profile: EngineProfile, page: EngineTab?, completion: @escaping (Bool) -> Void) {
        // A WebKit page's site keeps its data in the profile's WebKit store (HybridEngine.swift).
        if page is WebKitTab, let w = loadedWebKitProfile(for: profile) {
            return webKit.clearSiteData(origin: origin, in: w, page: page, completion: completion)
        }
        guard SiteCore.available, let p = core(of: profile) else { return completion(false) }
        p.clearSiteData(origin) { completion($0) }
    }

    // MARK: Zoom

    func zoomScope(of tab: EngineTab) -> SiteZoomScope {
        if tab is WebKitTab { return .tab }   // WebKit zooms a page, not a site
        return core(of: tab)?.independentZoom == true ? .tab : .site
    }

    func siteZoomFactor(origin: String, in profile: EngineProfile) -> Double? {
        guard SiteCore.available, let p = core(of: profile) else { return nil }
        return p.siteZoomFactor(origin)
    }

    // MARK: Connection

    func siteSecurity(of tab: EngineTab) -> SiteSecurity {
        if tab is WebKitTab { return webKit.siteSecurity(of: tab) }
        guard let t = core(of: tab) else { return SiteSecurity() }
        let d = t.securityInfo
        func date(_ key: String) -> Date? {
            guard let s = (d[key] as? NSNumber)?.doubleValue, s > 0 else { return nil }
            return Date(timeIntervalSince1970: s)
        }
        func text(_ key: String) -> String? { (d[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var s = SiteSecurity()
        switch d["connectionLevel"] as? String {
        case "secure": s.level = .secure
        case "dangerous": s.level = .dangerous
        case "notSecure": s.level = .notSecure
        default: s.level = .none
        }
        // http:, file: and chrome: pages aren't "not secure" in the panel's sense unless they're on the web.
        let scheme = tab.url?.scheme ?? ""
        if s.level == .notSecure, scheme != "http", scheme != "https" { s.level = .none }
        if s.level == .notSecure, SiteSecurity.isLocal(tab.url) { s.level = .local }
        s.subject = text("certificateSubject")
        s.issuer = text("certificateIssuer")
        s.validFrom = date("certificateValidFrom")
        s.validTo = date("certificateValidTo")
        s.protocolName = text("protocol")
        s.hasMixedContent = (d["hasMixedContent"] as? NSNumber)?.boolValue ?? false
        s.insecureForm = (d["insecureForm"] as? NSNumber)?.boolValue ?? false
        return s
    }

    // MARK: Activity

    var siteActivityDidChange: ((EngineTab) -> Void)? {
        get { ChromiumSiteActivity.didChange }
        set {
            ChromiumSiteActivity.didChange = newValue
            webKit.siteActivityDidChange = newValue
        }
    }

    // Chromium's delegate forwarding is installed with every tab; a WebKit page is watched by its side.
    func watchSiteActivity(of tab: EngineTab) {
        if tab is WebKitTab { webKit.watchSiteActivity(of: tab) }
    }

    func siteActivity(of tab: EngineTab) -> SiteActivity {
        if tab is WebKitTab { return webKit.siteActivity(of: tab) }
        guard let t = core(of: tab), !t.closed else { return SiteActivity() }
        var a = SiteActivity()
        let access = ChromiumSiteActivity.access(of: t) ?? ChromiumSiteActivity.seedAccess(of: t)
        a.camera = access["camera"] ?? false
        a.microphone = access["microphone"] ?? false
        a.screen = access["screen"] ?? false
        a.blockedPopups = ChromiumSiteActivity.popups(of: t)
        return a
    }

    func openBlockedPopup(_ popup: BlockedPopup, in tab: EngineTab, always: Bool) {
        guard let t = core(of: tab) else { return }
        ChromiumSiteActivity.removePopup(popup.id, of: t)
        t.openBlockedPopup(popup.id, always: always)
        ChromiumSiteActivity.changed(tab)
    }

    func siteSettingsURL(origin: String) -> URL? {
        var c = URLComponents(string: "chrome://settings/content/siteDetails")
        c?.queryItems = [URLQueryItem(name: "site", value: origin)]
        return c?.url
    }
}

/// The engine objects behind the adapter's wrappers.
private enum SiteCore {
    /// The framework has engine pass 13's Site Controls (out/AircRelease and out/Airc are qualified with it).
    static let available = AircProfile.instancesRespond(to: #selector(AircProfile.sitePermissions(_:)))
        && AircProfile.instancesRespond(to: #selector(AircProfile.clearSiteData(_:completion:)))

}

/// Site activity received through ChromiumTab's delegate callbacks.
enum ChromiumSiteActivity {
    static var didChange: ((EngineTab) -> Void)?
    /// Per engine tab (held weakly, so a new tab at a freed address starts clean): the capture indicator's last word
    /// (camera, microphone, screen) and the pop-ups blocked on the page now, with the page they were blocked on.
    private final class Entry {
        weak var core: AircTab?
        var access: [String: Bool]?
        var page = ""
        var popups: [BlockedPopup] = []
        init(_ core: AircTab) { self.core = core }
    }
    private static var entries: [ObjectIdentifier: Entry] = [:]
    private static func entry(_ core: AircTab) -> Entry {
        let key = ObjectIdentifier(core)
        if let e = entries[key], e.core === core { return e }
        entries = entries.filter { $0.value.core != nil }
        let e = Entry(core)
        entries[key] = e
        return e
    }

    private static func existing(_ core: AircTab) -> Entry? {
        entries[ObjectIdentifier(core)].flatMap { $0.core === core ? $0 : nil }
    }

    static func mediaChanged(_ wrapper: EngineTab, core: AircTab, access: [String: NSNumber]) {
        entry(core).access = access.mapValues { $0.boolValue }
        changed(wrapper)
    }

    static func popupBlocked(_ wrapper: EngineTab, core: AircTab, popup: [String: String]) {
        guard let id = popup["id"] else { return }
        let e = entry(core)
        let page = pageKey(core.url)
        if e.page != page { e.page = page; e.popups = [] }
        if !e.popups.contains(where: { $0.id == id }) {
            e.popups.append(BlockedPopup(id: id, url: popup["url"] ?? ""))
        }
        changed(wrapper)
    }

    /// The engine calls on its own turn; observers run on the next one (PASS13: no structural changes in callbacks).
    static func changed(_ wrapper: AnyObject) {
        guard let tab = wrapper as? EngineTab else { return }
        DispatchQueue.main.async { [weak tab] in
            guard let tab, !tab.isClosed else { return }
            didChange?(tab)
        }
    }

    static func access(of core: AircTab) -> [String: Bool]? { existing(core)?.access }

    /// Before the tab's first change arrives: the media bridge's snapshot (PASS13, read only), read once.
    static func seedAccess(of core: AircTab) -> [String: Bool] {
        let capture = core.mediaSession["capture"] as? [String: Any] ?? [:]
        func on(_ k: String) -> Bool { (capture[k] as? NSNumber)?.boolValue ?? false }
        let a = ["camera": on("camera"), "microphone": on("microphone"), "screen": on("screen") || on("tab")]
        entry(core).access = a
        return a
    }

    static func popups(of core: AircTab) -> [BlockedPopup] {
        guard let e = existing(core), !e.popups.isEmpty else { return [] }
        // Chromium forgets a page's blocked pop-ups when it navigates; so does the list.
        guard e.page == pageKey(core.url) else {
            e.popups = []
            return []
        }
        return e.popups
    }

    static func removePopup(_ id: String, of core: AircTab) {
        existing(core)?.popups.removeAll { $0.id == id }
    }

    /// The page without its fragment (a same-document jump keeps the list).
    static func pageKey(_ url: String) -> String { url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url }
}
#endif

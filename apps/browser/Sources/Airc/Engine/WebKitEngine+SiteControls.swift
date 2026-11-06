// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import Security
import WebKit

// Site Controls on the WebKit dev engine: what WKWebView and WKWebsiteDataStore allow.
//   - Site data: the profile's data store (one per profile): cookies that match the host, and the site's storage
//     records (WebKit groups them by registrable domain, so clearing takes the domain's storage); the page's own
//     localStorage and sessionStorage are cleared in the page too. No byte counts (WebKit doesn't give them).
//   - Zoom: the tab's own (WKWebView.pageZoom); WebKit has no per-site zoom.
//   - Connection: hasOnlySecureContent and the server trust's certificate chain.
//   - Activity: the camera and microphone capture state (KVO, no polling). No screen or pop-up reports.
//   - Permissions: not available. WebKit asks the app per request (WKUIDelegate) and keeps no per-site settings, so
//     the panel says so instead of showing controls that wouldn't stick.
extension WebKitEngine: EngineSiteControls {
    var siteDataAvailable: Bool { true }
    var siteActivityAvailable: Bool { true }

    // MARK: Data

    func siteData(origin: String, in profile: EngineProfile, completion: @escaping (SiteDataUsage?) -> Void) {
        guard let store = (profile as? WebKitProfile)?.dataStore, let host = URL(string: origin)?.host else { return completion(nil) }
        store.httpCookieStore.getAllCookies { cookies in
            let count = cookies.filter { WebKitSiteData.cookie($0.domain, matches: host) }.count
            store.fetchDataRecords(ofTypes: WebKitSiteData.storageTypes) { records in
                let has = records.contains { WebKitSiteData.record($0.displayName, covers: host) }
                completion(SiteDataUsage(cookies: count, storageBytes: nil, hasStorage: has))
            }
        }
    }

    func clearSiteData(origin: String, in profile: EngineProfile, page: EngineTab?, completion: @escaping (Bool) -> Void) {
        guard let store = (profile as? WebKitProfile)?.dataStore, let host = URL(string: origin)?.host else { return completion(false) }
        let group = DispatchGroup()
        // The page's own storage first: WebKit may not have written it to the store yet.
        if let page, SiteOrigin.of(page.url) == origin {
            group.enter()
            page.evaluate("try { localStorage.clear(); sessionStorage.clear() } catch (e) {} true") { _ in group.leave() }
        }
        group.enter()
        store.httpCookieStore.getAllCookies { cookies in
            for c in cookies where WebKitSiteData.cookie(c.domain, matches: host) {
                group.enter()
                store.httpCookieStore.delete(c) { group.leave() }
            }
            group.enter()
            store.fetchDataRecords(ofTypes: WebKitSiteData.storageTypes) { records in
                let mine = records.filter { WebKitSiteData.record($0.displayName, covers: host) }
                store.removeData(ofTypes: WebKitSiteData.storageTypes, for: mine) { group.leave() }
            }
            group.leave()
        }
        group.notify(queue: .main) { completion(true) }
    }

    // MARK: Connection

    func siteSecurity(of tab: EngineTab) -> SiteSecurity {
        guard let web = (tab as? WebKitTab)?.webView, let url = web.url else { return SiteSecurity() }
        var s = SiteSecurity()
        switch url.scheme {
        case "https":
            s.level = web.hasOnlySecureContent ? .secure : .notSecure
            s.hasMixedContent = !web.hasOnlySecureContent
        case "http": s.level = SiteSecurity.isLocal(url) ? .local : .notSecure
        default: s.level = .none
        }
        if let trust = web.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            s.subject = SecCertificateCopySubjectSummary(leaf) as String?
            if chain.count > 1 { s.issuer = SecCertificateCopySubjectSummary(chain[1]) as String? }
            let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
            if let values = SecCertificateCopyValues(leaf, keys, nil) as? [String: [String: Any]] {
                func date(_ oid: CFString) -> Date? {
                    (values[oid as String]?[kSecPropertyKeyValue as String] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
                }
                s.validFrom = date(kSecOIDX509V1ValidityNotBefore)
                s.validTo = date(kSecOIDX509V1ValidityNotAfter)
            }
        }
        return s
    }

    // MARK: Activity

    var siteActivityDidChange: ((EngineTab) -> Void)? {
        get { WebKitSiteData.didChange }
        set { WebKitSiteData.didChange = newValue }
    }

    func watchSiteActivity(of tab: EngineTab) {
        guard let t = tab as? WebKitTab else { return }
        WebKitSiteData.watch(t)
    }

    func siteActivity(of tab: EngineTab) -> SiteActivity {
        guard let web = (tab as? WebKitTab)?.webView else { return SiteActivity() }
        return SiteActivity(camera: web.cameraCaptureState == .active, microphone: web.microphoneCaptureState == .active)
    }
}

private enum WebKitSiteData {
    static var didChange: ((EngineTab) -> Void)?
    /// KVO on each watched web view's capture states and connection (removed with the tab).
    private static var watched: [ObjectIdentifier: (tab: Weak, observations: [NSKeyValueObservation])] = [:]
    final class Weak { weak var tab: WebKitTab?; init(_ t: WebKitTab) { tab = t } }

    /// Everything but cookies and the HTTP caches (Chromium counts DOM storage the same way).
    static let storageTypes: Set<String> = [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                                            WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases,
                                            WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeServiceWorkerRegistrations]

    /// RFC 6265 domain matching: "example.com" and ".example.com" match example.com and its subdomains.
    static func cookie(_ domain: String, matches host: String) -> Bool {
        let d = (domain.hasPrefix(".") ? String(domain.dropFirst()) : domain).lowercased()
        let h = host.lowercased()
        return h == d || h.hasSuffix("." + d)
    }

    /// WebKit names a record by registrable domain ("example.com"), or by the host for IP addresses and localhost.
    static func record(_ name: String, covers host: String) -> Bool { cookie(name, matches: host) }

    static func watch(_ t: WebKitTab) {
        let key = ObjectIdentifier(t)
        if let w = watched[key], w.tab.tab === t { return }
        watched = watched.filter { $0.value.tab.tab != nil }
        let ref = Weak(t)
        let fire = {
            DispatchQueue.main.async {
                guard let tab = ref.tab, !tab.isClosed else { return }
                didChange?(tab)
            }
        }
        let web = t.webView
        watched[key] = (ref, [
            web.observe(\.cameraCaptureState) { _, _ in fire() },
            web.observe(\.microphoneCaptureState) { _, _ in fire() },
            web.observe(\.hasOnlySecureContent) { _, _ in fire() },
            web.observe(\.serverTrust) { _, _ in fire() },
        ])
    }
}

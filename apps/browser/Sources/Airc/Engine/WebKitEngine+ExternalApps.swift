// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import WebKit

// Links that open another app: a desktop app's sign-in callback (`vscode://`, `cursor://`, an IDE's own scheme after
// its https callback page), Zoom, Slack, mailto. Chrome asks first, "Open “App”?", with "Always allow <site> to open
// links of this type in the associated app" for a secure site, and remembers that per profile. Airc asks the same
// way, in its prompt card (PagePrompts.swift, `.externalApp`), on both engines:
//   - Chromium asks through `tab:externalAppRequest:` (engine/core/airc_external_apps.mm) and keeps the remembered
//     choice in the profile (Chrome's protocol_handler.allowed_origin_protocol_pairs), launching by itself after it.
//   - WebKit never opens another app: a WKWebView fails such a navigation ("unsupported URL") and nothing happens. Its
//     tabs hand every scheme WebKit can't load to `WebKitExternalApps`, which asks, remembers (per profile, below) and
//     opens the app with NSWorkspace.
// Before this (feedback, 0.1.50), neither engine asked: Chromium fell back to Chrome's own Views dialog, which an Airc
// tab can't show, and WebKit dropped the link, so a desktop app's sign-in stopped on its callback page.

enum WebKitExternalApps {
    /// The app's prompt center (PagePrompts.swift): shows the card for the page that asked.
    static var request: ((EngineTab, PagePrompt) -> Void)?

    /// Schemes WebKit loads (or refuses) itself; any other one belongs to an app.
    private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript", "ws", "wss",
                                                  "ftp", "webkit-pdfjs-viewer", "x-apple-data-detectors"]

    /// The page asked to go to another app's link.
    static func isExternal(_ url: URL, in webView: WKWebView) -> Bool {
        #if AIRC_TESTING
        if ProcessInfo.processInfo.environment["AIRC_EXTERNAL_APPS_BEFORE"] == "1" { return false }   // oauthapps' before arm
        #endif
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty, !webSchemes.contains(scheme) else { return false }
        if WKWebView.handlesURLScheme(scheme) { return false }
        return webView.configuration.urlSchemeHandler(forURLScheme: scheme) == nil
    }

    private struct Pending {
        let url: URL
        let app: URL
        let profile: String?
        let origin: String?
        let scheme: String
    }
    private static var pending: [String: Pending] = [:]
    private static var lastID = 0

    /// A navigation to `url` that WebKit can't load: open its app if the person said to always allow this site, or ask.
    static func handle(_ tab: WebKitTab, url: URL, source: WKFrameInfo?) {
        let scheme = url.scheme?.lowercased() ?? ""
        let origin = source.flatMap { Self.origin(of: $0.securityOrigin) }
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        let profile = tab.webKitProfile.privateSession ? nil : tab.webKitProfile.directory
        if let app, let profile, let origin, isAllowed(profile: profile, origin: origin, scheme: scheme) {
            return launch(url, with: app, remembered: true)
        }
        let canRemember = app != nil && profile != nil && origin.map(isTrustworthy) == true
        lastID += 1
        let id = "w\(lastID)"
        if let app { pending[id] = Pending(url: url, app: app, profile: profile, origin: origin, scheme: scheme) }
        let name = app.map(appName)
        let prompt = PagePrompt.externalApp(.init(id: id, url: url.absoluteString, scheme: scheme, origin: origin, app: name,
                                                  canRemember: canRemember))
        guard let request else {
            pending[id] = nil
            return
        }
        request(tab, prompt)
    }

    /// The person answered the card: open (and remember the site, if asked and allowed), or not.
    static func resolve(_ id: String, open: Bool, remember: Bool) {
        guard let p = pending.removeValue(forKey: id), open else { return }
        if remember, let profile = p.profile, let origin = p.origin, isTrustworthy(origin) {
            allow(profile: profile, origin: origin, scheme: p.scheme)
        }
        launch(p.url, with: p.app, remembered: false)
    }

    private static func launch(_ url: URL, with app: URL, remembered: Bool) {
        #if AIRC_TESTING
        launches.append((url.absoluteString, remembered))
        #endif
        let c = NSWorkspace.OpenConfiguration()
        c.promptsUserIfNeeded = false
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: c, completionHandler: nil)
    }

    #if AIRC_TESTING
    /// Every app link opened (URL, and whether a remembered choice opened it without asking), for the checks.
    static var launches: [(url: String, remembered: Bool)] = []
    #endif

    static func appName(_ app: URL) -> String {
        let info = Bundle(url: app)?.localizedInfoDictionary ?? Bundle(url: app)?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
        return name?.isEmpty == false ? name! : app.deletingPathExtension().lastPathComponent
    }

    /// "https://app.example" (with a port only when it isn't the scheme's default), or nil for an opaque origin.
    static func origin(of o: WKSecurityOrigin) -> String? {
        guard !o.protocol.isEmpty, !o.host.isEmpty else { return nil }
        return "\(o.protocol)://\(o.host)" + (o.port != 0 ? ":\(o.port)" : "")
    }

    /// Chrome's rule (network::IsOriginPotentiallyTrustworthy): https, or http on this Mac (127.0.0.0/8, ::1,
    /// localhost). Test builds also take Chromium's --unsafely-treat-insecure-origin-as-secure list, so a loopback
    /// fixture under a made-up host name counts the same on both engines.
    static func isTrustworthy(_ origin: String) -> Bool {
        guard let u = URL(string: origin), let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased() else { return false }
        if scheme == "https" || scheme == "wss" { return true }
        guard scheme == "http" || scheme == "ws" else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]" || host.hasPrefix("127.") { return true }
        #if AIRC_TESTING
        let flag = "--unsafely-treat-insecure-origin-as-secure="
        let listed = ProcessInfo.processInfo.arguments.filter { $0.hasPrefix(flag) }
            .flatMap { $0.dropFirst(flag.count).split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if listed.contains(origin.lowercased()) { return true }
        #endif
        return false
    }

    // MARK: Remembered choices (per profile: {profile: {origin: [scheme]}}, in the data folder)

    private static var file: URL { AppPaths.dataDirectory.appendingPathComponent("external-apps.json") }
    private static var cache: [String: [String: [String]]]?

    private static var allowed: [String: [String: [String]]] {
        get {
            if let cache { return cache }
            let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: [String: [String]]].self, from: $0) } ?? [:]
            cache = read
            return read
        }
        set {
            cache = newValue
            if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: file, options: .atomic) }
        }
    }

    static func isAllowed(profile: String, origin: String, scheme: String) -> Bool {
        allowed[profile]?[origin]?.contains(scheme) == true
    }

    private static func allow(profile: String, origin: String, scheme: String) {
        var all = allowed
        var schemes = all[profile]?[origin] ?? []
        if !schemes.contains(scheme) { schemes.append(scheme) }
        all[profile, default: [:]][origin] = schemes
        allowed = all
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

// Site Controls (SB-2, engine/PASS13.md "Site Controls"): a site's permissions, data, zoom and connection in one
// profile, and what its page does right now (camera, microphone, screen, blocked pop-ups). An engine that has them
// adopts `EngineSiteControls` in its own file (ChromiumEngine+SiteControls.swift, WebKitEngine+SiteControls.swift);
// the app asks `engine as? EngineSiteControls`. Every default below is "this engine can't", so another engine still
// compiles and the panel says what it can't do. All of it is main-thread only.

/// The permissions the panel shows, in Arc's order (Chromium's names in engine/PASS13.md). The first eight are always
/// listed; the device ones are under "More".
enum SitePermission: String, CaseIterable {
    case camera, microphone, location, notifications, popups, clipboard, sound, automaticDownloads
    case midi, usb, serial, hid, protectedContent

    var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .notifications: "Notifications"
        case .popups: "Pop-ups and redirects"
        case .clipboard: "Clipboard"
        case .sound: "Sound"
        case .automaticDownloads: "Automatic downloads"
        case .midi: "MIDI devices"
        case .usb: "USB devices"
        case .serial: "Serial ports"
        case .hid: "HID devices"
        case .protectedContent: "Protected content"
        }
    }

    var symbol: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        case .location: "location"
        case .notifications: "bell"
        case .popups: "rectangle.on.rectangle"
        case .clipboard: "doc.on.clipboard"
        case .sound: "speaker.wave.2"
        case .automaticDownloads: "arrow.down.circle"
        case .midi: "pianokeys"
        case .usb: "cable.connector"
        case .serial: "point.3.connected.trianglepath.dotted"
        case .hid: "keyboard"
        case .protectedContent: "lock.rectangle"
        }
    }

    var isPrimary: Bool { ![.midi, .usb, .serial, .hid, .protectedContent].contains(self) }

    /// What the person can choose besides Default. Chromium has no "ask" for pop-ups, sound or protected content, and
    /// for devices only ask/block: they guard the chooser, they never grant a device (PASS13).
    var choices: [SitePermissionState] {
        switch self {
        case .popups, .sound, .protectedContent: [.allow, .block]
        case .usb, .serial, .hid: [.ask, .block]
        default: [.ask, .allow, .block]
        }
    }
}

enum SitePermissionState: String {
    case `default`, ask, allow, block

    var title: String {
        switch self {
        case .default: "Default"
        case .ask: "Ask"
        case .allow: "Allow"
        case .block: "Block"
        }
    }
}

/// One permission for one site: what was chosen (`default` when nothing was), what applies, and whether a policy owns
/// it (then it can't be changed).
struct SitePermissionValue: Equatable {
    var state: SitePermissionState
    var effective: SitePermissionState
    var managed = false

    /// Set for this site (not the profile's default).
    var isCustom: Bool { state != .default }
}

/// Cookies and storage a site has in its profile. `storageBytes` is nil where the engine can't say.
struct SiteDataUsage: Equatable {
    var cookies: Int
    var storageBytes: Int64?
    var hasStorage: Bool

    var isEmpty: Bool { cookies == 0 && !hasStorage && (storageBytes ?? 0) == 0 }
}

/// The page's connection, as the panel says it.
struct SiteSecurity: Equatable {
    enum Level: Equatable { case secure, notSecure, dangerous, local, none }

    var level: Level = .none
    var subject: String?
    var issuer: String?
    var validFrom: Date?
    var validTo: Date?
    var protocolName: String?
    var hasMixedContent = false
    var insecureForm = false

    var hasCertificate: Bool { subject != nil || issuer != nil }

    /// Loopback pages are this Mac's own (a development server), not "not secure".
    static func isLocal(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

/// What the page is doing now. Capture is the devices' real use, not what the page reports; the location is the page
/// script's word (SiteUse.swift), added by SiteControlsCenter.
struct SiteActivity: Equatable {
    var camera = false
    var microphone = false
    var screen = false
    var location = false
    var blockedPopups: [BlockedPopup] = []

    var isCapturing: Bool { camera || microphone || screen }
}

/// A pop-up the engine blocked on the page now (Chromium's PopupBlockerTabHelper id).
struct BlockedPopup: Equatable {
    let id: String
    let url: String
}

/// Whose zoom ⌘+ and the panel change: every page of the site (Chromium's host zoom), or this tab only (a split pane's
/// independent zoom, and the WebKit dev engine).
enum SiteZoomScope { case site, tab }

protocol EngineSiteControls: AnyObject {
    /// Permissions can be read and set (false: the panel shows a note instead of the controls).
    var sitePermissionsAvailable: Bool { get }
    /// "Clear site data" works, and the counts mean something.
    var siteDataAvailable: Bool { get }
    /// The live capture and pop-up indicators come from the engine.
    var siteActivityAvailable: Bool { get }

    /// Unsupported permissions are absent. `origin` is scheme://host[:port].
    func sitePermissions(for origin: String, in profile: EngineProfile) -> [SitePermission: SitePermissionValue]
    /// False when the engine refused (an invalid state, a managed setting).
    @discardableResult func setSitePermission(_ permission: SitePermission, to state: SitePermissionState,
                                              origin: String, in profile: EngineProfile) -> Bool
    @discardableResult func resetSitePermissions(origin: String, in profile: EngineProfile) -> Bool
    /// Each change to the profile's site settings, with its origin ("" means any). One observer per profile; nil stops.
    func observeSitePermissions(in profile: EngineProfile, _ handler: ((String) -> Void)?)

    /// nil when the engine can't count.
    func siteData(origin: String, in profile: EngineProfile, completion: @escaping (SiteDataUsage?) -> Void)
    /// Cookies (including a parent domain's) and storage; the page is reloaded by the app.
    func clearSiteData(origin: String, in profile: EngineProfile, page: EngineTab?, completion: @escaping (Bool) -> Void)

    func zoomScope(of tab: EngineTab) -> SiteZoomScope
    /// The site's own zoom in the profile (Chromium's host zoom), for checks; the shown page's is `tab.zoomFactor`.
    func siteZoomFactor(origin: String, in profile: EngineProfile) -> Double?

    func siteSecurity(of tab: EngineTab) -> SiteSecurity

    /// A page's capture, pop-up, zoom or connection changed (nothing polls). Set once by SiteControlsCenter.
    var siteActivityDidChange: ((EngineTab) -> Void)? { get set }
    /// Starts reporting `tab`'s activity (idempotent).
    func watchSiteActivity(of tab: EngineTab)
    func siteActivity(of tab: EngineTab) -> SiteActivity
    /// Opens a blocked pop-up; `always` also allows the site's pop-ups from now on.
    func openBlockedPopup(_ popup: BlockedPopup, in tab: EngineTab, always: Bool)
    /// The engine's own page for the site's settings (Chromium's site details), if it has one.
    func siteSettingsURL(origin: String) -> URL?
}

extension EngineSiteControls {
    var sitePermissionsAvailable: Bool { false }
    var siteDataAvailable: Bool { false }
    var siteActivityAvailable: Bool { false }
    func sitePermissions(for origin: String, in profile: EngineProfile) -> [SitePermission: SitePermissionValue] { [:] }
    func setSitePermission(_ permission: SitePermission, to state: SitePermissionState, origin: String,
                           in profile: EngineProfile) -> Bool { false }
    func resetSitePermissions(origin: String, in profile: EngineProfile) -> Bool { false }
    func observeSitePermissions(in profile: EngineProfile, _ handler: ((String) -> Void)?) {}
    func siteData(origin: String, in profile: EngineProfile, completion: @escaping (SiteDataUsage?) -> Void) { completion(nil) }
    func clearSiteData(origin: String, in profile: EngineProfile, page: EngineTab?, completion: @escaping (Bool) -> Void) {
        completion(false)
    }
    func zoomScope(of tab: EngineTab) -> SiteZoomScope { .tab }
    func siteZoomFactor(origin: String, in profile: EngineProfile) -> Double? { nil }
    func siteSecurity(of tab: EngineTab) -> SiteSecurity {
        guard let url = tab.url else { return SiteSecurity() }
        if SiteSecurity.isLocal(url) { return SiteSecurity(level: .local) }
        return SiteSecurity(level: url.scheme == "https" ? .secure : url.scheme == "http" ? .notSecure : .none)
    }
    var siteActivityDidChange: ((EngineTab) -> Void)? { get { nil } set {} }
    func watchSiteActivity(of tab: EngineTab) {}
    func siteActivity(of tab: EngineTab) -> SiteActivity { SiteActivity() }
    func openBlockedPopup(_ popup: BlockedPopup, in tab: EngineTab, always: Bool) {}
    func siteSettingsURL(origin: String) -> URL? { nil }
}

enum SiteOrigin {
    /// "https://example.com" (port kept when it isn't the scheme's own); nil for pages that aren't on the web.
    static func of(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if let port = url.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) {
            return "\(scheme)://\(h.lowercased()):\(port)"
        }
        return "\(scheme)://\(h.lowercased())"
    }
}

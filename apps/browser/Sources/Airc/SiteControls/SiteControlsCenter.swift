// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// Site Controls for the whole app (SB-2): the engine's per-profile settings, one permission observer per profile, a
/// cache of each site's permissions (the URL field asks on every redraw), and a notice when something changes, for the
/// URL field's indicators and the open panel. Nothing polls (MEM-6): changes come from the engine's permission
/// observer and its capture, pop-up, zoom and connection notifications.
final class SiteControlsCenter {
    /// Posted on the main thread. userInfo: `profile` (its directory) for settings, `tab` (EngineTab) for activity.
    static let didChange = Notification.Name("AircSiteControlsDidChange")

    let engine: EngineSiteControls
    private var observedProfiles: [String: Weak] = [:]
    private var permissionCache: [String: [SitePermission: SitePermissionValue]] = [:]
    private final class Weak { weak var profile: EngineProfile?; init(_ p: EngineProfile) { profile = p } }

    private static var instance: SiteControlsCenter?
    /// The app's, once its engine exists (nil on an engine without Site Controls).
    static var shared: SiteControlsCenter? {
        if instance == nil, let engine = (NSApp.delegate as? AppDelegate)?.engine as? EngineSiteControls {
            instance = SiteControlsCenter(engine: engine)
        }
        return instance
    }

    init(engine: EngineSiteControls) {
        self.engine = engine
        engine.siteActivityDidChange = { tab in
            NotificationCenter.default.post(name: SiteControlsCenter.didChange, object: nil, userInfo: ["tab": tab])
        }
    }

    /// Starts reporting `tab`'s activity and its profile's settings changes (both idempotent).
    func watch(_ tab: EngineTab) {
        engine.watchSiteActivity(of: tab)
        watch(tab.profile)
    }

    func watch(_ profile: EngineProfile) {
        let dir = profile.directory
        if let w = observedProfiles[dir], w.profile === profile { return }
        observedProfiles[dir] = Weak(profile)
        engine.observeSitePermissions(in: profile) { [weak self] origin in
            // "" is any site (PASS13: the engine reports global invalidation for now).
            DispatchQueue.main.async { self?.settingsChanged(profile: dir, origin: origin) }
        }
    }

    private func settingsChanged(profile dir: String, origin: String) {
        let prefix = dir + "|"
        if origin.isEmpty { permissionCache = permissionCache.filter { !$0.key.hasPrefix(prefix) } }
        else { permissionCache[prefix + origin] = nil }
        NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["profile": dir])
    }

    // MARK: Permissions

    func permissions(origin: String, in profile: EngineProfile) -> [SitePermission: SitePermissionValue] {
        guard engine.sitePermissionsAvailable else { return [:] }
        let key = profile.directory + "|" + origin
        if let cached = permissionCache[key] { return cached }
        watch(profile)
        let p = engine.sitePermissions(for: origin, in: profile)
        permissionCache[key] = p
        return p
    }

    @discardableResult
    func set(_ permission: SitePermission, to state: SitePermissionState, origin: String, in profile: EngineProfile) -> Bool {
        let ok = engine.setSitePermission(permission, to: state, origin: origin, in: profile)
        // The engine's observer says so too; the panel and the field shouldn't wait for it.
        settingsChanged(profile: profile.directory, origin: origin)
        return ok
    }

    @discardableResult
    func resetPermissions(origin: String, in profile: EngineProfile) -> Bool {
        let ok = engine.resetSitePermissions(origin: origin, in: profile)
        settingsChanged(profile: profile.directory, origin: origin)
        return ok
    }

    /// For the panel's "Reset" and the field's indicator: the site has a setting of its own.
    func hasCustomPermissions(origin: String, in profile: EngineProfile) -> Bool {
        permissions(origin: origin, in: profile).values.contains { $0.isCustom }
    }

    /// The app changed a zoom or a page by itself (⌘+, the panel): the panel and the field follow.
    func pageChanged(_ tab: EngineTab) {
        NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["tab": tab])
    }
}

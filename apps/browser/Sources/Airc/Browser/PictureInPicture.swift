// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// SB-55's settings (engine/app-pip.patch): the off switch and per-site exceptions apply to every profile (the engine
/// keeps them per profile, "off" winning over a site's "always"), and the position reset puts the window back at the
/// bottom-right. The engine places, moves and remembers the window itself.
extension WindowController {
    func applyPictureInPictureSettings(to profile: EngineProfile) {
        #if canImport(AircCore)
        guard let chromium = app?.engine as? ChromiumEngine, let values = app?.settings.values else { return }
        chromium.setAutoPictureInPictureEnabled(profile, enabled: values.pipAutomatic)
        for (origin, on) in values.pipSites { chromium.setAutoPictureInPictureException(profile, origin: origin, enabled: on) }
        #endif
    }

    /// After a change in Settings. `cleared`: sites whose exception was removed.
    func applyPictureInPictureSettings(cleared: [String] = []) {
        #if canImport(AircCore)
        guard let chromium = app?.engine as? ChromiumEngine else { return }
        for p in profiles.loadedProfiles {
            for origin in cleared { chromium.setAutoPictureInPictureException(p, origin: origin, enabled: nil) }
            applyPictureInPictureSettings(to: p)
        }
        #endif
    }

    /// "Reset position": the next picture in picture opens at the bottom-right again, in every profile.
    func resetPictureInPicturePosition() {
        #if canImport(AircCore)
        guard let chromium = app?.engine as? ChromiumEngine else { return }
        profiles.loadedProfiles.forEach { chromium.setPictureInPictureFrame($0, frame: .zero) }
        #endif
    }

    /// Whether this engine pops videos and calls out by itself (WebKit's own picture in picture has no such settings).
    var supportsPictureInPictureSettings: Bool {
        #if canImport(AircCore)
        return app?.engine is ChromiumEngine
        #else
        return false
        #endif
    }

    /// "meet.google.com" or a URL → "https://meet.google.com"; nil when it isn't a web address.
    static func pictureInPictureOrigin(_ typed: String) -> String? {
        var t = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let u = URL(string: t), let scheme = u.scheme, ["http", "https"].contains(scheme), let host = u.host, host.contains(".") || host == "localhost"
        else { return nil }
        return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
    }
}

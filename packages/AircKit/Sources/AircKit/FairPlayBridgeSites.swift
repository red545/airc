// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
//
// The origin list and the playlist checks are adapted from Ardia's ArdiaFairPlay.mm (FairPlayOrigins,
// RemoteOnlyPlaylist and the size limits; https://github.com/ardia-browser/ardia, packages/ardiacore/ios), which is
// Copyright 2026 Mantra Patel, licensed under the Apache License, Version 2.0; modified by The Airc Authors.

import Foundation

/// The FairPlay bridge's sites and input rules (docs/design/fairplay-bridge.md): with Settings › Privacy › "Play
/// protected media in Chromium with FairPlay" on, these exact origins stay in Chromium and their players get Apple's
/// FairPlay through the page script, with native AVFoundation playback.
public enum FairPlayBridgeSites {
    /// Exact https origins (scheme, host, default port). The only list: the page script is composed with it, the
    /// routing uses it, and FairPlayBridgeTests checks docs/user/protected-media.md against it.
    /// None: Spotify was the only one, and it plays in WebKit (owner, 2026-11-20). Its web player takes FairPlay only
    /// through Safari's own `WebKitMediaKeys` (in Chromium it asks for Widevine first and treats FairPlay files as
    /// unplayable without it), and offering it would mean impersonating Safari, which the owner ruled out.
    public static let origins: [String] = []

    /// Exact origins whose video plays through the sample-buffer bridge (step 2).
    public static let videoOrigins: [String] = ["https://www.disneyplus.com", "https://www.netflix.com"]

    /// Video origins that serve their FairPlay player only to Safari's user agent (in requests, not just
    /// navigator.userAgent): served only when the engine can give one origin its own user agent
    /// (AircProfile setUserAgent:forOrigin:), and then with Safari's.
    public static let safariUserAgentOrigins: [String] = ["https://www.netflix.com"]

    /// Every origin that stays in Chromium while the setting is on (with an engine that has per-origin user agents).
    public static var routedOrigins: [String] { origins + videoOrigins }

    /// Addresses people type that redirect to a listed origin: they stay in Chromium with it, so the redirect lands
    /// there (a typed netflix.com would otherwise open in WebKit before it reaches www.netflix.com).
    public static let aliases: [String: String] = [
        "https://netflix.com": "https://www.netflix.com",
        "https://disneyplus.com": "https://www.disneyplus.com",
    ]

    /// `origins` plus the aliases of those listed.
    public static func withAliases(_ origins: [String]) -> [String] {
        origins + aliases.filter { origins.contains($0.value) }.map(\.key).sorted()
    }

    /// The key system the page is offered.
    public static let keySystem = "com.apple.fps.1_0"

    public static let maxCertificateBytes = 64 * 1024
    public static let maxLicenseBytes = 64 * 1024
    /// Base64 text sizes (4/3 of the bytes, rounded up).
    public static var maxCertificateText: Int { (maxCertificateBytes + 2) / 3 * 4 }
    public static var maxLicenseText: Int { (maxLicenseBytes + 2) / 3 * 4 }
    public static let maxPlaylistPart = 60 * 1024
    public static let maxPlaylist = 2 * 1024 * 1024
    public static let maxParts = 40

    /// "https://open.spotify.com" for any address on that origin; nil for anything that isn't http(s). The port is
    /// kept only when it isn't the scheme's default.
    public static func origin(of url: String) -> String? {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = c.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let port = c.port.flatMap { (scheme == "https" && $0 == 443) || (scheme == "http" && $0 == 80) ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    /// Whether `origin` (as an engine commits it, "https://open.spotify.com") is one of `origins`.
    public static func serves(origin: String, in origins: [String] = origins) -> Bool {
        guard let o = Self.origin(of: origin) else { return false }
        return origins.contains(o)
    }

    /// A playlist the native player may load: an HLS playlist whose every URI is https (segments, maps, keys' https
    /// URIs) or a FairPlay key (skd://). Nothing local, no other scheme, at most `maxPlaylist` bytes. `allowing` adds
    /// origins whose segments may be plain http (a test's loopback server).
    public static func isRemotePlaylist(_ playlist: String, allowing testOrigins: [String] = []) -> Bool {
        guard playlist.utf8.count <= maxPlaylist, playlist.hasPrefix("#EXTM3U") else { return false }
        func allowed(_ uri: String, key: Bool) -> Bool {
            let lower = uri.lowercased()
            if lower.hasPrefix("https://") { return true }
            if key && lower.hasPrefix("skd://") { return true }
            if let o = origin(of: lower), testOrigins.contains(o), lower.hasPrefix(o + "/") { return true }
            return false
        }
        for raw in playlist.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !line.hasPrefix("#") {
                if !allowed(line, key: false) { return false }
                continue
            }
            // skd:// only as a key's URI.
            let key = line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:")
            var rest = Substring(line)
            while let r = rest.range(of: "URI=\"") {
                let after = rest[r.upperBound...]
                guard let end = after.firstIndex(of: "\"") else { return false }
                if !allowed(String(after[..<end]), key: key) { return false }
                rest = after[after.index(after: end)...]
            }
        }
        return true
    }

    /// The first FairPlay key URI in a playlist ("skd://…"), or nil.
    public static func keyURI(in playlist: String) -> String? {
        guard let r = playlist.range(of: "URI=\"skd://") else { return nil }
        let start = playlist.index(r.upperBound, offsetBy: -"skd://".count)
        guard let end = playlist[start...].firstIndex(of: "\"") else { return nil }
        return String(playlist[start..<end])
    }
}

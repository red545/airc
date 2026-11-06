// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
//
// Adapted from Cra's ProtectedMedia.swift (https://github.com/VictorKildahl/cra, Packages/CraCore), which is:
//
//   MIT License
//
//   Copyright (c) 2026 Victor Kildahl
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy
//   of this software and associated documentation files (the "Software"), to deal
//   in the Software without restriction, including without limitation the rights
//   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//   copies of the Software, and to permit persons to whom the Software is
//   furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all
//   copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//   SOFTWARE.

import Foundation

/// Which engine draws a page in the Chromium build.
public enum PageEngine: String, Codable, Equatable, Sendable {
    /// Chromium: every page, unless a rule below says otherwise.
    case chromium
    /// The Mac's own WebKit (WKWebView), for services whose DRM licence servers turn Airc's Chromium away.
    case webKit
}

/// Sites that play protected media (DRM) only in WebKit (docs/user/protected-media.md).
///
/// Chromium's Widevine CDM installs in Airc (engine/DRM.md), but these services' licence servers also want Widevine's
/// Verified Media Path: signatures over the browser's own binaries, made with a certificate Google licenses through
/// paid partners. WebKit plays them with Apple's FairPlay, which macOS gives every app. So their pages open in a WebKit
/// page inside the Chromium build, with Safari's user agent.
///
/// The rules, as a value so they're tested without a page:
/// - A page Airc opens (typed, restored, a new tab, Little Arc, a pinned tab's reset) gets `engine(for:)`: WebKit for a
///   listed site, Chromium for anything else.
/// - A Chromium page's own navigation to a listed site is stopped before its request and opens again in WebKit, in the
///   same pane (`handoff`). A POST stays in Chromium: its body can't move.
/// - A WebKit page stays WebKit for its own navigations (sign-in goes through other sites and has to come back to the
///   same cookies). Only Airc's URL bar picks again (`engine(forAddressBar:current:)`).
/// - Sign-in hosts (`signInHosts`) finish in the engine they started in: other sites' "Sign in with Spotify" goes
///   through them.
public struct ProtectedMediaSites: Equatable, Sendable {
    /// The services' web players. An entry matches its host and the host's subdomains. "name.*" stands for any
    /// top-level domain ("joyn.de", "music.amazon.co.uk"); "host/path" also needs the address's path to start with that
    /// path (Prime Video on Amazon's stores; the rest of Amazon, shopping and Login with Amazon, stays in Chromium).
    public static let defaultEntries: [String] = [
        "open.spotify.com",
        "netflix.com",
        "disneyplus.com",
        // Max signs in on its own hosts and sends play.max.com on to www.hbomax.com; no other site signs in with Max.
        "max.com", "hbomax.com",
        "primevideo.com",
        "hulu.com",
        "paramountplus.com",
        "peacocktv.com",
        "tv.apple.com", "music.apple.com",
        "listen.tidal.com",
        "deezer.com",
        "crunchyroll.com",
        "joyn.*",
        "rakuten.tv",
        "amazon.*/gp/video",
        "music.amazon.*",
    ]

    /// Sign-in and account hosts under a listed entry that never count as listed: other sites send their "Sign in with
    /// Spotify/Tidal/Deezer" through them, and that has to finish in the engine it started in.
    public static let signInHosts: [String] = [
        "accounts.spotify.com", "login.tidal.com", "connect.deezer.com", "account.deezer.com",
    ]

    /// What the toast and Site Controls call each service.
    public static let serviceNames: [String: String] = [
        "open.spotify.com": "Spotify", "netflix.com": "Netflix", "disneyplus.com": "Disney+", "max.com": "Max",
        "hbomax.com": "HBO Max", "primevideo.com": "Prime Video", "hulu.com": "Hulu", "paramountplus.com": "Paramount+",
        "peacocktv.com": "Peacock", "tv.apple.com": "Apple TV", "music.apple.com": "Apple Music",
        "listen.tidal.com": "Tidal", "deezer.com": "Deezer", "crunchyroll.com": "Crunchyroll", "joyn.*": "Joyn",
        "rakuten.tv": "Rakuten TV", "amazon.*/gp/video": "Prime Video", "music.amazon.*": "Amazon Music",
    ]

    /// Second-level labels that make a two-label top-level domain for "name.*" ("co.uk", "com.au", "co.jp").
    static let secondLevelLabels: Set<String> = ["co", "com", "net", "org", "ac", "gov", "edu", "ne", "or"]

    /// Off: every page is Chromium's.
    public var isEnabled: Bool
    /// Lower-cased entries without a leading dot, some with a path or a "*" top-level domain.
    public private(set) var entries: [String]

    /// `extraHosts` add to the list (a test's loopback host, sites the person sent to WebKit); `removedHosts` take
    /// entries off it.
    public init(isEnabled: Bool = true, extraHosts: [String] = [], removedHosts: [String] = []) {
        self.isEnabled = isEnabled
        let removed = Set(removedHosts.compactMap(Self.normalizedEntry))
        var seen = Set<String>()
        entries = (Self.defaultEntries + extraHosts).compactMap(Self.normalizedEntry)
            .filter { !removed.contains($0) && seen.insert($0).inserted }
    }

    /// The engine a page Airc opens at `url` gets.
    public func engine(for url: String) -> PageEngine {
        entry(for: url) == nil ? .chromium : .webKit
    }

    /// The URL bar's pick for a page now in `current`: the rules, except that a sign-in host stays where it is.
    public func engine(forAddressBar url: String, current: PageEngine) -> PageEngine {
        Self.isSignInHost(url) ? current : engine(for: url)
    }

    /// A navigation a page started itself: the engine it has to move to, or nil to stay. Only Chromium pages move, only
    /// for a GET, only to a listed site. `method` is the request's HTTP method.
    public func handoff(from current: PageEngine, to url: String, method: String = "GET") -> PageEngine? {
        guard current == .chromium, method.uppercased() == "GET", engine(for: url) == .webKit else { return nil }
        return .webKit
    }

    /// The listed entry `url` falls under, or nil (also while off, for a sign-in host, and for every scheme but http(s)).
    public func entry(for url: String) -> String? {
        guard isEnabled, let host = Self.webHost(of: url), !Self.isSignInHost(host: host) else { return nil }
        let path = URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.path.lowercased() ?? ""
        return entries.first { Self.matches($0, host: host, path: path) }
    }

    /// The service's name for a page at `url` ("Spotify"); a host the person added names itself.
    public func serviceName(for url: String) -> String? {
        entry(for: url).map { Self.serviceNames[$0] ?? $0 }
    }

    public static func isSignInHost(_ url: String) -> Bool {
        webHost(of: url).map { isSignInHost(host: $0) } ?? false
    }

    static func isSignInHost(host: String) -> Bool {
        signInHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Whether `entry` covers a page on `host` at `path`.
    static func matches(_ entry: String, host: String, path: String) -> Bool {
        let (pattern, prefix) = split(entry)
        if let prefix, !(path == prefix || path.hasPrefix(prefix + "/")) { return false }
        guard pattern.hasSuffix(".*") else { return host == pattern || host.hasSuffix("." + pattern) }
        // "name.*": the name's labels right before a top-level domain of one label, or of two ("co.uk").
        let name = pattern.dropLast(2).split(separator: ".").map(String.init)
        let labels = host.split(separator: ".").map(String.init)
        for tld in 1...2 {
            guard labels.count >= name.count + tld else { continue }
            if tld == 2, !secondLevelLabels.contains(labels[labels.count - 2]) { continue }
            let end = labels.count - tld
            if Array(labels[(end - name.count)..<end]) == name { return true }
        }
        return false
    }

    /// "amazon.*/gp/video" → ("amazon.*", "/gp/video"); "netflix.com" → ("netflix.com", nil).
    static func split(_ entry: String) -> (host: String, path: String?) {
        guard let slash = entry.firstIndex(of: "/") else { return (entry, nil) }
        return (String(entry[..<slash]), String(entry[slash...]))
    }

    /// The person's own choice for a site (the "Safari's engine" switch): the sites Airc keeps as added to WebKit and
    /// the listed entries taken off, after choosing `engine` for `url`'s site. Choosing WebKit lifts a removal (else adds
    /// the host); choosing Chromium drops an added host and takes off the listed entry the address falls under.
    public static func choosing(_ engine: PageEngine, for url: String, added: [String], removed: [String])
        -> (added: [String], removed: [String]) {
        guard let host = webHost(of: url) else { return (added, removed) }
        var added = added.compactMap(normalizedEntry), removed = removed.compactMap(normalizedEntry)
        switch engine {
        case .webKit:
            if let entry = ProtectedMediaSites().entry(for: url) { removed.removeAll { $0 == entry } }
            if ProtectedMediaSites(extraHosts: added, removedHosts: removed).engine(for: url) == .chromium, !added.contains(host) {
                added.append(host)
            }
        case .chromium:
            added.removeAll { entry in let h = split(entry).host; return host == h || host.hasSuffix("." + h) }
            if let entry = ProtectedMediaSites(removedHosts: removed).entry(for: url), !removed.contains(entry) {
                removed.append(entry)
            }
        }
        return (added, removed)
    }

    /// The host of an http(s) URL, lower-cased; nil for any other scheme (about:, chrome:, file:, data:), which only
    /// Chromium shows.
    static func webHost(of url: String) -> String? {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    /// "Open.Spotify.com", " spotify.com ", ".spotify.com" → "spotify.com"; a URL gives its host; "amazon.com/gp/video/"
    /// keeps its path without the last slash. Nil for something that isn't a host.
    static func normalizedEntry(_ entry: String) -> String? {
        var s = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.contains("://") {
            guard let host = webHost(of: s) else { return nil }
            s = host
        }
        var (host, path) = split(s)
        while host.hasPrefix(".") { host.removeFirst() }
        while host.hasSuffix(".") { host.removeLast() }
        while path?.hasSuffix("/") == true { path?.removeLast() }
        guard !host.isEmpty, !host.contains(" "), path?.contains(" ") != true, path?.contains("?") != true else { return nil }
        return path.map { $0.isEmpty ? host : host + $0 } ?? host
    }
}

/// protected-media.json in the data folder: the person's own choices about which engine plays a site and the services
/// whose "plays with Safari's engine" toast was closed. In the data folder, so each test instance (`--data-dir`) keeps
/// its own.
public struct ProtectedMediaChoices: Codable, Equatable, Sendable {
    /// Sites sent to WebKit.
    public var added: [String]
    /// Listed entries taken back to Chromium.
    public var removed: [String]
    /// Services whose toast was closed with its ✕.
    public var told: [String]

    public init(added: [String] = [], removed: [String] = [], told: [String] = []) {
        self.added = added
        self.removed = removed
        self.told = told
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        added = try c.decodeIfPresent([String].self, forKey: .added) ?? []
        removed = try c.decodeIfPresent([String].self, forKey: .removed) ?? []
        told = try c.decodeIfPresent([String].self, forKey: .told) ?? []
    }

    /// After choosing `engine` for `url`'s site.
    public func choosing(_ engine: PageEngine, for url: String) -> ProtectedMediaChoices {
        let r = ProtectedMediaSites.choosing(engine, for: url, added: added, removed: removed)
        return ProtectedMediaChoices(added: r.added, removed: r.removed, told: told)
    }

    /// After the person closed `service`'s toast.
    public func telling(_ service: String) -> ProtectedMediaChoices {
        told.contains(service) ? self : ProtectedMediaChoices(added: added, removed: removed, told: told + [service])
    }
}

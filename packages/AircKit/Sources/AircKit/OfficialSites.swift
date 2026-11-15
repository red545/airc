// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Command Bar's verified destinations: a short list, bundled and reviewed, of sites Airc vouches for. A row whose
/// address is on it shows a small verified mark and a label ("Supported in Airc" for the Chrome Web Store, where
/// extensions install from; "Official" for the rest), as Raycast marks its own commands.
///
/// The mark comes from this list only, never from a page's content or title. A URL matches only when all of these hold:
/// - it is https (never http, never another scheme), on the default port, with no user name or password in it;
/// - its host equals an entry's host exactly (lowercased; no trailing dot, so "chromewebstore.google.com.evil.example"
///   and "chromewebstore.google.com." don't match), and that host is the entry's registrable domain or under it;
/// - the host is a name, not an IP address, and has no punycode label ("xn--"): none of the entries do, and a
///   confusable host must never look verified;
/// - its path starts with the entry's path, when the entry has one (apple.com/support).
///
/// Changing the list is a reviewed change: OfficialSitesTests pins every entry and the lookalike cases.
public enum OfficialSites {
    public struct Site: Equatable, Sendable {
        /// The exact host ("chromewebstore.google.com").
        public let host: String
        /// The host's registrable domain ("google.com"): the host is it or a name under it.
        public let domain: String
        /// A path prefix the URL must start with ("/support"), or "" for the whole host.
        public let path: String
        /// What the site is ("Chrome Web Store").
        public let name: String
        /// The row's plain-words label: "Supported in Airc" or "Official".
        public let label: String

        public init(host: String, domain: String, path: String = "", name: String, label: String = OfficialSites.official) {
            self.host = host
            self.domain = domain
            self.path = path
            self.name = name
            self.label = label
        }
    }

    public static let official = "Official"
    public static let supported = "Supported in Airc"

    /// The reviewed list. Keep it short: every entry is a promise.
    public static let all: [Site] = [
        Site(host: "chromewebstore.google.com", domain: "google.com", name: "Chrome Web Store", label: supported),
        Site(host: "chrome.google.com", domain: "google.com", path: "/webstore", name: "Chrome Web Store", label: supported),
        Site(host: "accounts.google.com", domain: "google.com", name: "Google Account"),
        Site(host: "myaccount.google.com", domain: "google.com", name: "Google Account"),
        Site(host: "www.google.com", domain: "google.com", name: "Google"),
        Site(host: "mail.google.com", domain: "google.com", name: "Gmail"),
        Site(host: "calendar.google.com", domain: "google.com", name: "Google Calendar"),
        Site(host: "drive.google.com", domain: "google.com", name: "Google Drive"),
        Site(host: "docs.google.com", domain: "google.com", name: "Google Docs"),
        Site(host: "meet.google.com", domain: "google.com", name: "Google Meet"),
        Site(host: "photos.google.com", domain: "google.com", name: "Google Photos"),
        Site(host: "maps.google.com", domain: "google.com", name: "Google Maps"),
        Site(host: "www.youtube.com", domain: "youtube.com", name: "YouTube"),
        Site(host: "support.apple.com", domain: "apple.com", name: "Apple Support"),
        Site(host: "www.apple.com", domain: "apple.com", path: "/support", name: "Apple Support"),
        Site(host: "github.com", domain: "github.com", name: "GitHub"),
        Site(host: "aircbrowser.com", domain: "aircbrowser.com", name: "Airc"),
        Site(host: "www.aircbrowser.com", domain: "aircbrowser.com", name: "Airc"),
    ]

    private static let byHost: [String: [Site]] = Dictionary(grouping: all, by: \.host)

    /// The verified site `url` is on, or nil. Cheap (one URL parse, one dictionary lookup): called for every site row on
    /// every keystroke.
    public static func match(_ url: String) -> Site? {
        // A quick reject before parsing: almost no row is on the list.
        guard url.hasPrefix("https://") || url.hasPrefix("HTTPS://") else { return nil }
        guard let c = URLComponents(string: url), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, c.port == nil || c.port == 443,
              let rawHost = c.host, !rawHost.isEmpty else { return nil }
        let host = rawHost.lowercased()
        guard isPlainName(host), let candidates = byHost[host] else { return nil }
        let path = c.percentEncodedPath
        return candidates.first { s in
            guard host == s.domain || host.hasSuffix("." + s.domain) else { return false }
            if s.path.isEmpty { return true }
            return path == s.path || path.hasPrefix(s.path + "/")
        }
    }

    /// A DNS name of ASCII letters, digits, hyphens and dots, with no punycode label, no empty label (a trailing dot)
    /// and not all digits (an IPv4 address); IPv6 literals fail on their colons.
    static func isPlainName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for l in labels {
            guard !l.isEmpty, !l.hasPrefix("xn--") else { return false }
            guard l.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }) else { return false }
        }
        return !labels.allSatisfy { $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
    }
}

/// A site's stand-in icon when none of its icons is at hand: the first letter of its name on a calm colour picked from
/// its host (the same one every time, as Arc and Raycast do). The app draws it (CommandBar's LetterTile).
public enum SiteMonogram {
    /// The name a site's tile is lettered from: its registrable-looking part ("derstandard" for www.derstandard.at,
    /// "github" for gist.github.com), or the host itself.
    public static func name(forPage url: String) -> String? {
        guard let host = URLComponents(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        var labels = host.split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard !labels.isEmpty else { return host }
        if labels.count == 1 { return labels[0] }
        // "co.uk", "com.au": a short second-to-last label is part of the suffix.
        let n = labels.count
        if n >= 3, labels[n - 2].count <= 3, labels[n - 1].count == 2 { return labels[n - 3] }
        return labels[n - 2]
    }

    /// Which of `count` colours a name gets (FNV-1a, stable across launches).
    public static func colorIndex(for name: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % UInt64(count))
    }

    /// The letter shown: the name's first letter or digit, uppercased; "•" for none.
    public static func letter(for name: String) -> String {
        name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•"
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// AT-1 Air Traffic Control: links from other apps go to a Space by rules ("URL contains / is equal to … → Space"),
/// and otherwise to Little Arc or the most recent Space. A Space carries its profile, so a routed link opens signed in.
public struct LinkRule: Codable, Hashable, Sendable, Identifiable {
    public enum Match: String, Codable, Hashable, Sendable, CaseIterable {
        /// The URL contains the text (any case).
        case contains
        /// The URL is the text (any case in the scheme and host, a missing "https://" and a trailing "/" don't count).
        case equals
    }

    public var id: String
    public var match: Match
    public var pattern: String
    public var spaceID: String

    public init(id: String = UUID().uuidString, match: Match = .contains, pattern: String, spaceID: String) {
        self.id = id
        self.match = match
        self.pattern = pattern
        self.spaceID = spaceID
    }

    /// Whether `url` matches. An empty pattern matches nothing.
    public func matches(_ url: URL) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        switch match {
        case .contains:
            return url.absoluteString.range(of: p, options: [.caseInsensitive]) != nil
        case .equals:
            return Self.normalized(url.absoluteString) == Self.normalized(p)
        }
    }

    /// "HTTPS://Example.com/" and "example.com" alike: scheme and host lowercased, "https://" assumed, one trailing "/"
    /// dropped. Path and query keep their case.
    static func normalized(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains("://") { t = "https://" + t }
        guard var c = URLComponents(string: t) else { return t.lowercased() }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        var out = c.string ?? t
        if out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

/// Where a link from another app goes when no rule matches.
public enum ExternalLinkTarget: String, Codable, Hashable, Sendable {
    /// LA-1: a Little Arc window in the most recent Space's profile.
    case littleArc
    /// A new tab in the most recent Space.
    case recentSpace
}

public enum LinkRouting {
    /// The Space the first matching rule names (rules whose Space is gone are passed over), else nil.
    public static func space(for url: URL, rules: [LinkRule], existingSpaces: Set<String>) -> String? {
        rules.first { existingSpaces.contains($0.spaceID) && $0.matches(url) }?.spaceID
    }
}

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
    /// PSL site identity shared with Boosts, including private suffixes and exact-host fallbacks.
    /// Missing/non-web origins are not a known same site.
    public static func sameSite(_ a: URL?, _ b: URL, suffixes: PublicSuffixList = .shared) -> Bool {
        guard let left = BoostDomain.key(for: a, suffixes: suffixes),
              let right = BoostDomain.key(for: b, suffixes: suffixes) else { return false }
        return left == right
    }

    public enum PageTarget: Equatable { case engine, peek, space(String) }

    /// Air Traffic Control also routes Peek links, as in Arc: a user-followed link leaving its site that would open in
    /// Peek, or one followed inside Peek, goes to the first matching rule's Space instead. Other page links never
    /// consult the rules; same-site links keep the engine's behavior (or an explicitly requested Peek).
    public static func pageTarget(from origin: URL?, to url: URL, userGesture: Bool,
                                  wantsPeek: Bool, fromPeek: Bool = false, rules: [LinkRule], existingSpaces: Set<String>,
                                  suffixes: PublicSuffixList = .shared) -> PageTarget {
        guard userGesture, BoostDomain.webHost(of: url) != nil else { return .engine }
        if wantsPeek || fromPeek, !sameSite(origin, url, suffixes: suffixes),
           let id = space(for: url, rules: rules, existingSpaces: existingSpaces) { return .space(id) }
        return wantsPeek ? .peek : .engine
    }

    /// P06d: Arc's "Open Little Arc when clicking on links with ⌥⌘ held" (optionCommandClickLittleArcEntryPointEnabled,
    /// on by default). A web link a person followed with ⌥⌘ held opens in Little Arc, ahead of Peek and the rules: they
    /// asked for it. Only a link the engine would open in a new tab (⌥⌘ is ⌘'s background tab to both engines), so the
    /// page's own navigations and popups stay. Links from other apps never come here: Arc has no modifier for them.
    public static func opensInLittleArc(url: URL, userGesture: Bool, disposition: String, heldOptionCommand: Bool,
                                        enabled: Bool) -> Bool {
        enabled && heldOptionCommand && userGesture && BoostDomain.webHost(of: url) != nil
            && ["background_tab", "foreground_tab"].contains(disposition)
    }

    /// The Space the first matching rule names (rules whose Space is gone are passed over), else nil.
    public static func space(for url: URL, rules: [LinkRule], existingSpaces: Set<String>) -> String? {
        rules.first { existingSpaces.contains($0.spaceID) && $0.matches(url) }?.spaceID
    }
}

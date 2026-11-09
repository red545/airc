// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// `@import` in a Boost's custom CSS (BST-3), the app's side: the editor says at once which imports load and which
/// don't. The page script's runtime (BoostPageScript) does the loading, with the same rule:
///   - only the leading `@import` rules count, as in CSS (after `@charset`; anything else ends them);
///   - `data:text/css` URLs load at once, from the CSS itself;
///   - other URLs are resolved against the page and load only from the page's own origin (fetched by the page, with
///     its own credentials, `text/css` only);
///   - any other origin, and any other scheme, is refused unfetched: a Boost never makes a page ask another site for
///     anything it didn't already.
/// A URL that names a host decides here: a host of another site is refused everywhere; a host of the Boost's site loads
/// on that host's pages only. A relative URL loads on every page, from that page's origin.
public enum BoostCSSImports {
    public struct Rule: Equatable, Sendable {
        /// The URL as written.
        public var url: String
        /// nil: no layer; "": an anonymous `layer`; otherwise the layer's name.
        public var layer: String?
        public var supports: String?
        public var media: String?

        public init(url: String, layer: String? = nil, supports: String? = nil, media: String? = nil) {
            self.url = url
            self.layer = layer
            self.supports = supports
            self.media = media
        }
    }

    /// Where an import would load from.
    public enum Source: Equatable, Sendable {
        /// The CSS itself (a `data:text/css` URL).
        case inline
        /// Each page's own origin (a relative URL).
        case samePage
        /// One host of the Boost's site: its pages only.
        case host(String)
        /// Refused, with the reason the editor shows.
        case refused(Refusal)
    }

    public enum Refusal: String, Sendable {
        case otherSite = "another site", scheme = "not a web address", data = "not a CSS data: URL", address = "not an address"

        /// The editor's line.
        public var explanation: String {
            switch self {
            case .otherSite: "Skipped: Boosts load CSS only from the site itself. Paste that CSS here instead."
            case .scheme: "Skipped: only web addresses and data:text/css URLs can be imported."
            case .data: "Skipped: a data: import must be text/css."
            case .address: "Skipped: this isn't an address."
            }
        }
    }

    /// The page's reason codes (`importFailed`'s `w`) in words.
    public static func runtimeExplanation(_ code: String) -> String {
        switch code {
        case "origin": "Skipped: it's on another origin than this page."
        case "scheme": Refusal.scheme.explanation
        case "data": Refusal.data.explanation
        case "address": Refusal.address.explanation
        case "status": "Couldn't load it: the site answered with an error."
        case "type": "Couldn't use it: the site didn't send it as CSS."
        case "size": "Skipped: imports can be at most 512 KB."
        case "limit": "Skipped: at most 24 imports, 4 deep."
        default: "Couldn't load it: the page's security policy or the network stopped it."
        }
    }

    /// The leading `@import` rules, and the CSS after them.
    public static func split(_ css: String) -> (rules: [Rule], rest: String) {
        let t = Array(css.unicodeScalars)
        var i = 0
        var rules: [Rule] = []
        func at(_ k: Int) -> Unicode.Scalar? { k < t.count ? t[k] : nil }
        func text(_ a: Int, _ b: Int) -> String {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: t[min(a, t.count)..<min(max(a, b), t.count)])
            return String(s)
        }
        func skipSpace(_ start: Int) -> Int {
            var k = start
            while let c = at(k) {
                if " \n\t\r\u{0C}".unicodeScalars.contains(c) { k += 1; continue }
                if c == "/", at(k + 1) == "*" {
                    var e = k + 2
                    while e < t.count, !(t[e] == "*" && at(e + 1) == "/") { e += 1 }
                    k = e >= t.count ? t.count : e + 2
                    continue
                }
                break
            }
            return k
        }
        func quoted(_ start: Int) -> (String, Int)? {
            guard let q = at(start) else { return nil }
            var v = String.UnicodeScalarView()
            var k = start + 1
            while let c = at(k) {
                if c == "\\" { k += 1; if let n = at(k) { v.append(n) }; k += 1; continue }
                if c == q { return (String(v), k + 1) }
                if c == "\n" { return nil }
                v.append(c)
                k += 1
            }
            return nil
        }
        func balanced(_ s: [Unicode.Scalar], _ start: Int) -> (String, Int)? {
            var depth = 1, k = start
            while k < s.count {
                let c = s[k]
                if c == "\"" || c == "'" {
                    var e = k + 1
                    while e < s.count, s[e] != c { if s[e] == "\\" { e += 1 }; e += 1 }
                    k = e + 1
                    continue
                }
                if c == "(" { depth += 1 } else if c == ")" {
                    depth -= 1
                    if depth == 0 {
                        var v = String.UnicodeScalarView(); v.append(contentsOf: s[start..<k])
                        return (String(v), k + 1)
                    }
                }
                k += 1
            }
            return nil
        }
        func lowered(_ a: Int, _ n: Int) -> String { text(a, a + n).lowercased() }
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

        loop: while true {
            i = skipSpace(i)
            if lowered(i, 8) == "@charset" {
                var k = i
                while k < t.count, t[k] != ";" { k += 1 }
                if k >= t.count { break }
                i = k + 1
                continue
            }
            guard lowered(i, 7) == "@import" else { break }
            var j = skipSpace(i + 7)
            var url: String
            if let c = at(j), c == "\"" || c == "'" {
                guard let q = quoted(j) else { break }
                url = q.0; j = q.1
            } else if lowered(j, 4) == "url(" {
                var k = skipSpace(j + 4)
                if let c = at(k), c == "\"" || c == "'" {
                    guard let q = quoted(k) else { break }
                    url = q.0
                    k = skipSpace(q.1)
                    guard at(k) == ")" else { break }
                    j = k + 1
                } else {
                    var close = k
                    while close < t.count, t[close] != ")" { close += 1 }
                    guard close < t.count else { break }
                    url = trimmed(text(k, close)); j = close + 1
                }
            } else { break }
            var end = j, depth = 0
            while end < t.count {
                let c = t[end]
                if c == "\"" || c == "'" {
                    guard let q = quoted(end) else { end = t.count; break }
                    end = q.1
                    continue
                }
                if c == "(" { depth += 1 } else if c == ")" { depth -= 1 } else if (c == ";" && depth <= 0) || c == "{" { break }
                end += 1
            }
            if at(end) == "{" { break loop }
            var pre = Array(trimmed(text(j, end)).unicodeScalars)
            var layer: String?, supports: String?
            func preText() -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: pre); return String(v) }
            func dropFirst(_ n: Int) { pre = Array(trimmed({ var v = String.UnicodeScalarView(); v.append(contentsOf: pre.dropFirst(n)); return String(v) }()).unicodeScalars) }
            func startsWithCall(_ name: String) -> Int? {
                let s = preText().lowercased()
                guard s.hasPrefix(name) else { return nil }
                var k = name.unicodeScalars.count
                while k < pre.count, pre[k] == " " || pre[k] == "\t" || pre[k] == "\n" { k += 1 }
                return k < pre.count && pre[k] == "(" ? k + 1 : nil
            }
            if let open = startsWithCall("layer") {
                guard let b = balanced(pre, open) else { break }
                layer = trimmed(b.0); dropFirst(b.1)
            } else if preText().lowercased().hasPrefix("layer"),
                      pre.count == 5 || !(CharacterSet.alphanumerics.contains(pre[5]) || pre[5] == "-" || pre[5] == "_") {
                layer = ""; dropFirst(5)
            }
            if let open = startsWithCall("supports") {
                guard let b = balanced(pre, open) else { break }
                supports = trimmed(b.0); dropFirst(b.1)
            }
            let media = preText()
            rules.append(Rule(url: url, layer: layer, supports: supports, media: media.isEmpty ? nil : media))
            i = end + 1
        }
        return (rules, text(i, t.count))
    }

    /// Where `rule` loads from for a Boost of `site`.
    public static func source(of rule: Rule, site: String) -> Source {
        let u = rule.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.lowercased().hasPrefix("data:") { return isCSSData(u) ? .inline : .refused(.data) }
        if u.hasPrefix("//") {
            guard let url = URL(string: "https:" + u), let host = BoostDomain.webHost(of: url) else { return .refused(.address) }
            return BoostDomain.key(forHost: host) == site ? .host(host) : .refused(.otherSite)
        }
        if let colon = u.firstIndex(of: ":"), let slash = u.firstIndex(where: { "/?#".contains($0) }) ?? Optional(u.endIndex),
           colon < slash {
            let scheme = u[..<colon].lowercased()
            guard scheme == "http" || scheme == "https" else { return .refused(.scheme) }
            guard let url = URL(string: u), let host = BoostDomain.webHost(of: url) else { return .refused(.address) }
            return BoostDomain.key(forHost: host) == site ? .host(host) : .refused(.otherSite)
        }
        return .samePage
    }

    /// Each leading import of `css` and where it would load from.
    public static func review(_ css: String, site: String) -> [(rule: Rule, source: Source)] {
        split(css).rules.map { ($0, source(of: $0, site: site)) }
    }

    static func isCSSData(_ u: String) -> Bool {
        guard let comma = u.firstIndex(of: ",") else { return false }
        var meta = u[u.index(u.startIndex, offsetBy: 5)..<comma].lowercased().trimmingCharacters(in: .whitespaces)
        if let r = meta.range(of: #";\s*base64$"#, options: .regularExpression) { meta = String(meta[..<r.lowerBound]) }
        return meta.trimmingCharacters(in: .whitespaces)
            .range(of: #"^text/css(\s*;\s*charset\s*=\s*"?utf-8"?)?$"#, options: .regularExpression) != nil
    }
}

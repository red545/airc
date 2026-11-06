// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Public Suffix List (publicsuffix.org): the parts of a host name under which anyone can register their own site
/// ("com", "co.uk", "github.io", "duckdns.org"), so which hosts belong to one site. Complete: the ICANN and the private
/// sections, wildcards ("*.ck") and their exceptions ("!www.ck"), internationalised names as punycode. The list is the
/// file Chromium builds into the engine (packages/AircKit/Resources, MPL-2.0; scripts/refresh-public-suffix-list.sh),
/// so a site here is the site Chromium isolates.
public final class PublicSuffixList: Sendable {
    private let rules: Set<String>
    /// "*.ck" is kept as "ck": every label under it is a public suffix.
    private let wildcards: Set<String>
    /// "!www.ck" is kept as "www.ck".
    private let exceptions: Set<String>
    /// The rules longer than a name that end in it, as written ("*.x", "!y.x"), by that name: what the page script needs
    /// to tell a site from the sites registered under it (BoostPageScript).
    private let beneath: [String: [String]]
    /// The list's own version line ("2026-11-04_12-00-00_UTC"), if it has one.
    public let version: String?

    /// No rules at all: every host is its own site (BoostDomain), never a shared one.
    public var isEmpty: Bool { rules.isEmpty && wildcards.isEmpty }
    public var ruleCount: Int { rules.count + wildcards.count + exceptions.count }

    public convenience init(text: String) { self.init(data: Data(text.utf8)) }

    /// The list's text, read as bytes: a rule is a line up to its first white space; "//" lines are comments.
    public init(data: Data) {
        var rules = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
        var beneath: [String: [String]] = [:]
        var version: String?
        let bytes = [UInt8](data)
        let newline = UInt8(ascii: "\n"), slash = UInt8(ascii: "/"), bang = UInt8(ascii: "!"), dot = UInt8(ascii: ".")
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D }
        var i = 0
        while i < bytes.count {
            var end = i
            while end < bytes.count, bytes[end] != newline { end += 1 }
            defer { i = end + 1 }
            var a = i
            while a < end, isSpace(bytes[a]) { a += 1 }
            guard a < end else { continue }
            if bytes[a] == slash, a + 1 < end, bytes[a + 1] == slash {
                let line = String(decoding: bytes[a..<end], as: UTF8.self)
                if version == nil, line.hasPrefix("// VERSION: ") { version = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces) }
                continue
            }
            var b = a
            while b < end, !isSpace(bytes[b]) { b += 1 }
            let exception = bytes[a] == bang
            if exception { a += 1 }
            guard a < b else { continue }
            let word = bytes[a..<b]
            let ace: String
            if word.allSatisfy({ $0 < 0x80 }) {
                ace = String(decoding: word.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
            } else {
                guard let converted = Self.ascii(String(decoding: word, as: UTF8.self).lowercased()) else { continue }
                ace = converted
            }
            guard !ace.isEmpty, ace != "*" else { continue }
            let written = exception ? "!" + ace : ace
            if exception {
                exceptions.insert(ace)
            } else if ace.hasPrefix("*.") {
                wildcards.insert(String(ace.dropFirst(2)))
            } else {
                rules.insert(ace)
            }
            let utf8 = Array(ace.utf8)
            for (k, byte) in utf8.enumerated() where byte == dot && k + 1 < utf8.count {
                beneath[String(decoding: utf8[(k + 1)...], as: UTF8.self), default: []].append(written)
            }
        }
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
        self.beneath = beneath
        self.version = version
    }

    // MARK: The list the app uses

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: PublicSuffixList?

    /// Airc.app's copy (build-app.sh puts it in the bundle, deflated), loaded once. Without one every host is its own
    /// site: `isEmpty`, and BoostDomain keys exact hosts.
    public static var shared: PublicSuffixList {
        lock.lock()
        defer { lock.unlock() }
        if let installed { return installed }
        let list = bundled() ?? PublicSuffixList(text: "")
        installed = list
        return list
    }

    /// Tests and tools: the list to use from now on (the source tree's file, a small fixture).
    public static func use(_ list: PublicSuffixList) {
        lock.lock()
        installed = list
        lock.unlock()
    }

    public static let resourceName = "public_suffix_list.dat"

    private static func bundled() -> PublicSuffixList? {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "deflate"),
           let packed = try? Data(contentsOf: url),
           let data = try? (packed as NSData).decompressed(using: .zlib) as Data {
            return PublicSuffixList(data: data)
        }
        if let url = Bundle.main.url(forResource: resourceName, withExtension: nil), let data = try? Data(contentsOf: url) {
            return PublicSuffixList(data: data)
        }
        NSLog("Airc: no public suffix list in the app; Boosts key exact hosts")
        return nil
    }

    // MARK: Lookups (lowercased ASCII hosts, labels without empty ones)

    /// How many of the last labels are the host's public suffix: an exception rule wins, then the longest matching
    /// rule, then the last label alone (the list's default rule "*").
    func suffixLength(_ labels: [Substring]) -> Int {
        guard !labels.isEmpty else { return 0 }
        var best = 1
        var suffix = ""
        var shorter = ""
        for k in 1...labels.count {
            shorter = suffix
            let label = String(labels[labels.count - k])
            suffix = k == 1 ? label : label + "." + suffix
            if exceptions.contains(suffix) { return k - 1 }
            if rules.contains(suffix) || (k > 1 && wildcards.contains(shorter)) { best = k }
        }
        return best
    }

    /// The registrable domain ("eTLD+1"): "bbc.co.uk" for "news.bbc.co.uk", "alice.duckdns.org" for
    /// "x.alice.duckdns.org"; nil when the host is itself a public suffix ("co.uk", "duckdns.org", "localhost").
    public func registrableDomain(_ host: String) -> String? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, !labels.contains(where: \.isEmpty) else { return nil }
        return registrableDomain(labels)
    }

    func registrableDomain(_ labels: [Substring]) -> String? {
        let n = suffixLength(labels)
        guard labels.count > n else { return nil }
        return labels.suffix(n + 1).joined(separator: ".")
    }

    /// The host is a public suffix: listed, under a wildcard, or a lone label (a top-level domain).
    public func isPublicSuffix(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, !labels.contains(where: \.isEmpty) else { return false }
        return suffixLength(labels) >= labels.count
    }

    /// The rules longer than `name` that end in ".name" ("s3.amazonaws.com" and 560 more under "amazonaws.com";
    /// usually none), as written in the list.
    public func rules(beneath name: String) -> [String] { beneath[name] ?? [] }

    // MARK: Internationalised names

    /// A host label by label in ASCII: punycode ("xn--…") for any label that isn't ASCII. Nil for a label punycode
    /// can't carry.
    public static func ascii<S: StringProtocol>(_ host: S) -> String? {
        guard host.contains(where: { !$0.isASCII }) else { return String(host) }
        var out: [String] = []
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            if label.allSatisfy(\.isASCII) { out.append(String(label)); continue }
            guard let p = punycode(label) else { return nil }
            out.append("xn--" + p)
        }
        return out.joined(separator: ".")
    }

    /// RFC 3492's encoder (without the "xn--" prefix): "рф" → "p1ai", "公司" → "55qx5d".
    static func punycode<S: StringProtocol>(_ label: S) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        let input = label.unicodeScalars.map { Int($0.value) }
        func digit(_ d: Int) -> Character { Character(Unicode.Scalar(UInt8(d < 26 ? 97 + d : 22 + d))) }
        func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
            var d = first ? delta / damp : delta / 2
            d += d / points
            var k = 0
            while d > ((base - tMin) * tMax) / 2 {
                d /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * d / (d + skew)
        }
        var out = String(input.filter { $0 < 0x80 }.map { Character(Unicode.Scalar(UInt8($0))) })
        let basic = out.count
        var handled = basic
        if basic > 0 { out.append("-") }
        var n = 0x80, delta = 0, bias = 72
        while handled < input.count {
            guard let m = input.filter({ $0 >= n }).min() else { return nil }
            let (step, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow, delta <= Int(Int32.max) - step else { return nil }
            delta += step
            n = m
            for c in input {
                if c < n { delta += 1 }
                guard c == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                    if q < t { break }
                    out.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                out.append(digit(q))
                bias = adapt(delta, handled + 1, handled == basic)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return out
    }
}

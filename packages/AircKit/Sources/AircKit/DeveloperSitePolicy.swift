// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// DEV-1 Developer Mode per site, as Arc kept it (`DeveloperModeState { enabledHosts, disabledDefaultHosts }`): a site is
/// a host, whatever its port, path or scheme (http and https only). The loopback hosts (localhost, its subdomains and
/// the loopback addresses) are on by themselves, Arc's automatic Dev Tabs, until turned off; any other host is on once
/// turned on. Both lists persist, so a site keeps its mode in every tab, Space, window and profile.
public struct DeveloperSitePolicy: Codable, Equatable, Sendable {
    /// Hosts turned on by hand.
    public var enabledHosts: Set<String> = []
    /// Automatic hosts turned off by hand.
    public var disabledDefaultHosts: Set<String> = []

    public init(enabledHosts: Set<String> = [], disabledDefaultHosts: Set<String> = []) {
        self.enabledHosts = enabledHosts
        self.disabledDefaultHosts = disabledDefaultHosts
    }

    private enum CodingKeys: String, CodingKey { case enabledHosts, disabledDefaultHosts }

    /// Missing or unreadable lists read as empty (a newer Airc may add fields).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledHosts = Set(((try? c.decodeIfPresent([String].self, forKey: .enabledHosts)) ?? []).compactMap(Self.normalize))
        disabledDefaultHosts = Set(((try? c.decodeIfPresent([String].self, forKey: .disabledDefaultHosts)) ?? []).compactMap(Self.normalize))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabledHosts.sorted(), forKey: .enabledHosts)
        try c.encode(disabledDefaultHosts.sorted(), forKey: .disabledDefaultHosts)
    }

    // MARK: Sites

    /// The site of `url`: its host, lowercased, without a trailing dot or IPv6 brackets. nil for anything but an http or
    /// https URL with a host.
    public static func site(of url: String) -> String? {
        guard let u = URLComponents(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), let host = u.host else {
            return nil
        }
        return normalize(host)
    }

    static func normalize(_ host: String) -> String? {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        return h.isEmpty || h.contains("/") || h.contains(" ") ? nil : h
    }

    /// Arc's automatic Dev Tab hosts: localhost and its subdomains, 127.0.0.0/8 and ::1 (also IPv4-mapped).
    public static func isAutomatic(site: String) -> Bool {
        guard let h = normalize(site) else { return false }
        if h == "localhost" || (h.hasSuffix(".localhost") && h.count > ".localhost".count) { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, h, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            if b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
            return b.prefix(10).allSatisfy { $0 == 0 } && b[10] == 255 && b[11] == 255 && b[12] == 127
        }
        return false
    }

    // MARK: On and off

    /// Whether Developer Mode is on for `url`. `automatic`: Settings' "Turn on automatically for localhost" (Arc: always).
    public func isOn(_ url: String, automatic: Bool = true) -> Bool {
        guard let s = Self.site(of: url) else { return false }
        return isOn(site: s, automatic: automatic)
    }

    public func isOn(site s: String, automatic: Bool = true) -> Bool {
        guard let s = Self.normalize(s) else { return false }
        if enabledHosts.contains(s) { return true }
        return automatic && Self.isAutomatic(site: s) && !disabledDefaultHosts.contains(s)
    }

    /// Whether the site of `url` is on only because it's an automatic host (Arc's analytics "isAutomatic").
    public func isAutomaticallyOn(_ url: String, automatic: Bool = true) -> Bool {
        guard let s = Self.site(of: url) else { return false }
        return automatic && Self.isAutomatic(site: s) && !disabledDefaultHosts.contains(s) && !enabledHosts.contains(s)
    }

    /// Turns Developer Mode on or off for the site of `url` (Site Controls, ⌃D, the Command Bar). Returns the site, nil
    /// when the URL has none (nothing changes).
    @discardableResult
    public mutating func set(_ url: String, on: Bool, automatic: Bool = true) -> String? {
        guard let s = Self.site(of: url) else { return nil }
        set(site: s, on: on, automatic: automatic)
        return s
    }

    public mutating func set(site raw: String, on: Bool, automatic: Bool = true) {
        guard let s = Self.normalize(raw) else { return }
        if Self.isAutomatic(site: s) {
            // An automatic host: off is remembered as such while automatic is on (else it just forgets the hand-on);
            // on clears that, and pins it on by hand while automatic is off.
            if on {
                disabledDefaultHosts.remove(s)
                if automatic { enabledHosts.remove(s) } else { enabledHosts.insert(s) }
            } else {
                if automatic { disabledDefaultHosts.insert(s) }
                enabledHosts.remove(s)
            }
        } else if on {
            enabledHosts.insert(s)
        } else {
            enabledHosts.remove(s)
        }
    }

    /// The site toggled: on becomes off and off becomes on. Returns whether it's on now, nil without a site.
    @discardableResult
    public mutating func toggle(_ url: String, automatic: Bool = true) -> Bool? {
        guard let s = Self.site(of: url) else { return nil }
        let on = !isOn(site: s, automatic: automatic)
        set(site: s, on: on, automatic: automatic)
        return on
    }

    /// Settings' list: the sites turned on by hand, in order.
    public var sites: [String] { enabledHosts.sorted() }

    /// Settings' Remove: the site goes back to its default (on for an automatic host, off otherwise).
    public mutating func forget(site raw: String) {
        guard let s = Self.normalize(raw) else { return }
        enabledHosts.remove(s)
        disabledDefaultHosts.remove(s)
    }

    /// Whether no site is on by hand and nothing automatic is turned off: what a new install has.
    public var isEmpty: Bool { enabledHosts.isEmpty && disabledDefaultHosts.isEmpty }
}

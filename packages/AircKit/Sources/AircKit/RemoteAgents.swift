// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

// Other devices on the person's Tailscale network using Airc's agent tools (Settings › Agents › Other devices;
// docs/user/agents.md, "From your other devices"). The app's listener (Agent/AgentRemote.swift) does the sockets;
// the rules live here so they can be tested:
// - `TailnetAddress`: which addresses count as the tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48), for binding and for
//   every accepted peer;
// - `RemoteToken` and `RemoteDeviceRegistry`: per-device bearer tokens, kept only as SHA-256 hashes and compared in
//   constant time;
// - `RemotePairing`: the short one-time code a device trades for its token, with rate limits;
// - `RemoteAgentGate`: what a request gets before any MCP runs (401 for anything unpaired or revoked).

/// Tailscale's address ranges: IPv4 100.64.0.0/10 (CGNAT space, which Tailscale assigns from) and IPv6
/// fd7a:115c:a1e0::/48 (Tailscale's ULA prefix).
public enum TailnetAddress {
    public static let ipv6Prefix: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]

    /// 100.64.0.0/10: first byte 100, top two bits of the second 01.
    public static func isTailnet(ipv4 bytes: [UInt8]) -> Bool {
        bytes.count == 4 && bytes[0] == 100 && (bytes[1] & 0xC0) == 0x40
    }

    public static func isTailnet(ipv6 bytes: [UInt8]) -> Bool {
        bytes.count == 16 && Array(bytes[0..<6]) == ipv6Prefix
    }

    /// A numeric address ("100.101.102.103", "fd7a:115c:a1e0::1", with or without a %scope). Names never count.
    public static func isTailnet(_ text: String) -> Bool {
        guard let bytes = parse(text) else { return false }
        return bytes.count == 4 ? isTailnet(ipv4: bytes) : isTailnet(ipv6: bytes)
    }

    /// An IPv4 (4 bytes) or IPv6 (16 bytes) address, or nil for anything else.
    public static func parse(_ text: String) -> [UInt8]? {
        let plain = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var v4 = in_addr()
        if inet_pton(AF_INET, plain, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, plain, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// A socket address (a peer, an interface's address) as its numeric text, when it's on the tailnet.
    public static func tailnetText(_ sa: UnsafePointer<sockaddr>) -> String? {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let bytes = withUnsafeBytes(of: a) { Array($0) }
            return isTailnet(ipv4: bytes) ? bytes.map(String.init).joined(separator: ".") : nil
        case AF_INET6:
            var a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            guard isTailnet(ipv6: withUnsafeBytes(of: a) { Array($0) }) else { return nil }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil ? String(cString: buf) : nil
        default:
            return nil
        }
    }

    /// One address of one network interface.
    public struct Interface: Equatable, Hashable, Sendable {
        public let name: String
        public let address: String
        public let index: UInt32
        public init(name: String, address: String, index: UInt32) {
            self.name = name; self.address = address; self.index = index
        }
        public var isIPv6: Bool { address.contains(":") }
    }

    /// The addresses Airc may listen on: tailnet addresses only, never a wildcard, loopback or any other network's.
    public static func listenable(_ all: [Interface]) -> [Interface] {
        var seen = Set<String>()
        return all.filter { isTailnet($0.address) && seen.insert($0.address).inserted }
            .sorted { ($0.isIPv6 ? 1 : 0, $0.address) < ($1.isIPv6 ? 1 : 0, $1.address) }
    }

    /// This Mac's tailnet addresses now (empty when Tailscale isn't connected).
    public static func current() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Interface] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            let flags = Int32(i.pointee.ifa_flags)
            guard let sa = i.pointee.ifa_addr, flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  let text = tailnetText(UnsafePointer(sa)) else { continue }
            let name = String(cString: i.pointee.ifa_name)
            out.append(Interface(name: name, address: text, index: if_nametoindex(name)))
        }
        return listenable(out)
    }
}

/// Per-device bearer tokens: 32 random bytes, shown to the device once, kept only as their SHA-256.
public enum RemoteToken {
    public static let prefix = "airc_"

    public static func generate() -> String {
        var g = SystemRandomNumberGenerator()   // arc4random on Apple platforms: a CSPRNG
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &g) }
        return prefix + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func hash(_ token: String) -> [UInt8] { Array(SHA256.hash(data: Data(token.utf8))) }

    public static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    public static func unhex(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    /// Same answer, same time, whatever the bytes (only the lengths may differ in time, and hashes have one length).
    public static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = UInt(bitPattern: a.count ^ b.count)
        for i in 0..<max(a.count, b.count) {
            diff |= UInt((i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0))
        }
        return diff == 0
    }

    /// The token in `Authorization: Bearer <token>`, or nil.
    public static func bearer(_ header: String?) -> String? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.count > 7,
              h.prefix(7).lowercased() == "bearer " else { return nil }
        let t = h.dropFirst(7).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

/// A paired device.
public struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// What the device called itself when it paired ("build-box"), cleaned.
    public var name: String
    public var paired: Date
    public var lastUsed: Date?
    /// Its last tailnet address, for Settings.
    public var lastAddress: String?
    /// SHA-256 of its token, hex. The token itself is never stored.
    public var tokenHash: String

    public init(id: String, name: String, paired: Date, lastUsed: Date? = nil, lastAddress: String? = nil, tokenHash: String) {
        self.id = id; self.name = name; self.paired = paired; self.lastUsed = lastUsed; self.lastAddress = lastAddress
        self.tokenHash = tokenHash
    }
}

/// The paired devices (Airc keeps this in its Keychain item, not in its settings file).
public struct RemoteDeviceRegistry: Codable, Equatable, Sendable {
    public var devices: [RemoteDevice] = []
    public static let maxDevices = 20

    public init(devices: [RemoteDevice] = []) { self.devices = devices }

    /// The device whose token this `Authorization` header carries. Every stored hash is compared, match or not.
    public func authenticate(_ authorization: String?) -> RemoteDevice? {
        guard let token = RemoteToken.bearer(authorization) else { return nil }
        let given = RemoteToken.hash(token)
        var found: RemoteDevice?
        for d in devices {
            let stored = RemoteToken.unhex(d.tokenHash) ?? []
            if RemoteToken.constantTimeEqual(given, stored), !stored.isEmpty, found == nil { found = d }
        }
        return found
    }

    /// A new device and its token (the only time the token exists in Airc). Nil when the list is full.
    public mutating func add(name: String, now: Date = Date(), address: String? = nil) -> (device: RemoteDevice, token: String)? {
        guard devices.count < Self.maxDevices else { return nil }
        let token = RemoteToken.generate()
        let d = RemoteDevice(id: UUID().uuidString, name: RemotePairing.deviceName(name), paired: now, lastAddress: address,
                             tokenHash: RemoteToken.hex(RemoteToken.hash(token)))
        devices.append(d)
        return (d, token)
    }

    @discardableResult
    public mutating func revoke(_ id: String) -> Bool {
        let before = devices.count
        devices.removeAll { $0.id == id }
        return devices.count != before
    }

    /// Remembers when and from where a device was last used. True when that changed what's stored (at most once a
    /// minute, so the Keychain isn't written for every request).
    @discardableResult
    public mutating func touch(_ id: String, now: Date = Date(), address: String?) -> Bool {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return false }
        let stale = devices[i].lastUsed.map { now.timeIntervalSince($0) >= 60 } ?? true
        guard stale || devices[i].lastAddress != address else { return false }
        devices[i].lastUsed = now
        devices[i].lastAddress = address
        return true
    }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }

    public static func decode(_ data: Data?) -> RemoteDeviceRegistry {
        guard let data else { return RemoteDeviceRegistry() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(RemoteDeviceRegistry.self, from: data)) ?? RemoteDeviceRegistry()
    }
}

/// The pairing code Settings shows: 8 characters from 32 unambiguous ones (40 bits), one use, 10 minutes. Wrong
/// guesses are limited per address and in total, and 20 wrong guesses burn the code.
public struct RemotePairing: Sendable {
    public static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    public static let length = 8
    public static let lifetime: TimeInterval = 600
    /// Wrong guesses one address may make per minute.
    public static let perPeerPerMinute = 5
    /// Wrong guesses all addresses together may make per minute.
    public static let allPerMinute = 10
    /// Wrong guesses one code survives.
    public static let perCode = 20

    public private(set) var code: String?
    public private(set) var expires: Date?
    private var failures: [(peer: String, at: Date)] = []
    private var codeFailures = 0

    public init() {}

    public enum Outcome: Equatable, Sendable {
        case paired
        case wrongCode
        /// No code is showing (none made, expired, used or burned).
        case noCode
        case rateLimited(retryAfter: Int)
    }

    /// Makes a new code (replacing any other), for display: "ABCD-EFGH".
    @discardableResult
    public mutating func start(now: Date = Date()) -> String {
        var g = SystemRandomNumberGenerator()
        code = String((0..<Self.length).map { _ in Self.alphabet[Int.random(in: 0..<Self.alphabet.count, using: &g)] })
        expires = now.addingTimeInterval(Self.lifetime)
        codeFailures = 0
        return display!
    }

    public mutating func cancel() { code = nil; expires = nil }

    public var display: String? { code.map { String($0.prefix(4)) + "-" + String($0.dropFirst(4)) } }

    public func isActive(now: Date = Date()) -> Bool { code != nil && (expires.map { now < $0 } ?? false) }

    /// "abcd efgh", "ABCD-EFGH" → "ABCDEFGH".
    public static func normalize(_ s: String) -> String {
        String(s.uppercased().filter { !" -_\t".contains($0) })
    }

    /// One pairing request from `peer` (its tailnet address).
    public mutating func attempt(_ given: String, peer: String, now: Date = Date()) -> Outcome {
        failures.removeAll { now.timeIntervalSince($0.at) >= 60 }
        let mine = failures.filter { $0.peer == peer }
        if mine.count >= Self.perPeerPerMinute || failures.count >= Self.allPerMinute {
            let oldest = (mine.count >= Self.perPeerPerMinute ? mine : failures).map(\.at).min() ?? now
            return .rateLimited(retryAfter: max(1, Int((60 - now.timeIntervalSince(oldest)).rounded(.up))))
        }
        guard let code, let expires, now < expires else {
            cancel()
            failures.append((peer, now))
            return .noCode
        }
        let ok = RemoteToken.constantTimeEqual(Array(Self.normalize(given).utf8), Array(code.utf8))
        if ok {
            cancel()
            return .paired
        }
        failures.append((peer, now))
        codeFailures += 1
        if codeFailures >= Self.perCode { cancel() }
        return .wrongCode
    }

    /// A device's name as it gave it (a host name), cleaned for Settings and the approval: printable, at most 48.
    public static func deviceName(_ raw: String?) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-_'’()"))
        let cleaned = String(String.UnicodeScalarView((raw ?? "").unicodeScalars.filter { allowed.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        let short = String(cleaned.prefix(48))
        return short.isEmpty ? "Another device" : short
    }
}

/// What a request on the tailnet listener gets before any MCP runs.
public enum RemoteAgentGate {
    public enum Decision: Equatable {
        /// POST /pair: trade the pairing code for a token.
        case pair
        /// An MCP request from this paired device.
        case mcp(deviceID: String)
        /// End this MCP session (DELETE /mcp).
        case endSession(deviceID: String)
        case reject(status: Int, reason: String)
    }

    /// `headers` have lower-case names. `peer` is the connection's address (numeric).
    public static func decide(method: String, path: String, headers: [String: String], peer: String,
                              registry: RemoteDeviceRegistry) -> Decision {
        // Belt and braces: the listener binds tailnet addresses only, and refuses any other peer here too.
        guard TailnetAddress.isTailnet(peer) else { return .reject(status: 403, reason: "not on the tailnet") }
        // Web pages always send Origin; MCP clients don't. No page can use this, whatever it resolves.
        guard headers["origin"] == nil else { return .reject(status: 403, reason: "origin") }
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        if route == "/pair" {
            return method == "POST" ? .pair : .reject(status: 405, reason: "method")
        }
        // Everything else needs a paired device's token, before anything about the request is answered.
        guard let device = registry.authenticate(headers["authorization"]) else {
            return .reject(status: 401, reason: "unauthorized")
        }
        guard route == "/mcp" else { return .reject(status: 404, reason: "path") }
        switch method {
        case "POST": return .mcp(deviceID: device.id)
        case "DELETE": return .endSession(deviceID: device.id)
        default: return .reject(status: 405, reason: "method")   // no server-sent event stream: answers are JSON
        }
    }
}

/// What the listener does on each 10 s refresh: keep the sockets that still match an address (same address, same
/// interface), close the ones whose address is gone, and (re)try every address without a socket, so an address that
/// failed to bind gets another try at the next refresh, not only when the address set changes.
public struct RemoteBindPlan: Equatable, Sendable {
    public var keep: [TailnetAddress.Interface]
    public var close: [TailnetAddress.Interface]
    public var open: [TailnetAddress.Interface]

    public init(wanted: [TailnetAddress.Interface], listening: [TailnetAddress.Interface]) {
        let want = Set(wanted)
        keep = listening.filter { want.contains($0) }
        close = listening.filter { !want.contains($0) }
        let have = Set(keep)
        open = wanted.filter { !have.contains($0) }
    }

    /// Nothing to do: every address has its socket and no socket is stale.
    public var isSteady: Bool { close.isEmpty && open.isEmpty }
}

/// The Mac's MagicDNS name, for the pairing command ("my-mac.tailnet.ts.net"), from the Tailscale CLI's
/// `tailscale status --json --peers=false` (documented, the same JSON every Tailscale client prints). nil when Tailscale
/// isn't running, MagicDNS is off, the name doesn't belong to the addresses Airc listens on, or it isn't a plain host
/// name (it goes into a shell command the person pastes).
public enum TailscaleName {
    /// Where the CLI is on a Mac: the app's own binary (Mac App Store and standalone app; it runs as the CLI when given
    /// arguments), the link the app's "Install CLI" makes, and the open-source tailscaled packages.
    public static let cliPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]
    public static let arguments = ["status", "--json", "--peers=false"]

    public static func magicDNSName(statusJSON data: Data, addresses: [String]) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = root["Self"] as? [String: Any], let raw = me["DNSName"] as? String else { return nil }
        if let state = root["BackendState"] as? String, state != "Running" { return nil }
        if let tailnet = root["CurrentTailnet"] as? [String: Any], tailnet["MagicDNSEnabled"] as? Bool == false { return nil }
        // The name must be this Mac's: one of its Tailscale addresses is one Airc listens on.
        let mine = Set(((me["TailscaleIPs"] as? [String]) ?? []).compactMap(TailnetAddress.parse))
        guard addresses.contains(where: { TailnetAddress.parse($0).map(mine.contains) ?? false }) else { return nil }
        var name = raw.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        let suffix = ((root["MagicDNSSuffix"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard isHostName(name), name.hasSuffix(".ts.net") || (!suffix.isEmpty && name.hasSuffix("." + suffix)) else { return nil }
        return name
    }

    /// Letters, digits and hyphens in dot-separated labels (1–63 each, no leading or trailing hyphen), at most 253.
    public static func isHostName(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 253 else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { l in
            !l.isEmpty && l.utf8.count <= 63 && l.first != "-" && l.last != "-"
                && l.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }
}

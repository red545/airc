// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Literal development destinations only: no DNS lookup or public-host inference.
public enum DevelopmentHost {
    public static func matches(_ string: String) -> Bool {
        guard let u = URLComponents(string: string), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              var host = u.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || [".localhost", ".test", ".local"].contains(where: { host.hasSuffix($0) && host.count > $0.count }) { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr)
            if n >> 24 == 127 { return true }
            guard u.port != nil else { return false }
            return n >> 24 == 10 || n >> 20 == 0xac1 || n >> 16 == 0xc0a8
                || n >> 16 == 0xa9fe || n >> 22 == 0x191 // link-local and CGNAT (private overlay networks)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            if b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
            if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 255, b[11] == 255 {
                return matches("http://\(b[12]).\(b[13]).\(b[14]).\(b[15])" + (u.port.map { ":\($0)" } ?? ""))
            }
            return u.port != nil && (b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80))
        }
        // Single-label LAN names with an explicit port; never guess that a public domain resolves privately.
        return u.port != nil && !host.contains(".") && !host.contains(":")
            && host.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil
    }

    /// Credentials, path, query and fragment never enter the compact address label.
    public static func origin(_ string: String) -> String? {
        guard matches(string), var u = URLComponents(string: string) else { return nil }
        u.user = nil; u.password = nil; u.path = ""; u.query = nil; u.fragment = nil
        return u.string
    }
}

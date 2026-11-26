// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// The group key written out for a person to carry to a Mac without iCloud Keychain (docs/sync.md, "Recovery key"):
/// the 32-byte key and a 3-byte checksum, in Crockford base32 (no I, L, O or U), 14 groups of 4.
/// Parsing forgives case, spaces and dashes, and reads O as 0 and I/L as 1.
public enum SyncRecoveryKey {
    public enum ParseError: Error, Equatable, Sendable {
        /// Wrong length, a character that isn't in the alphabet, or a checksum that doesn't fit: a typo.
        case malformed
    }

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let groups = 14
    public static let groupLength = 4

    private static func checksum(_ key: Data) -> Data {
        Data(SHA256.hash(data: Data("Airc sync recovery key|".utf8) + key).prefix(3))
    }

    /// The key as the person sees it: `XXXX-XXXX-…` (14 groups).
    public static func format(_ key: SymmetricKey) -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        let bytes = raw + checksum(raw)   // 35 bytes = 280 bits = 56 characters
        var chars: [Character] = []
        var buffer = 0, bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                chars.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        return stride(from: 0, to: chars.count, by: groupLength)
            .map { String(chars[$0..<min($0 + groupLength, chars.count)]) }
            .joined(separator: "-")
    }

    /// The key from what the person typed or pasted.
    public static func parse(_ text: String) throws -> SymmetricKey {
        var values: [Int] = []
        for c in text.uppercased() {
            if c == "-" || c.isWhitespace { continue }
            let d: Character = switch c { case "O": "0"; case "I", "L": "1"; default: c }
            guard let v = alphabet.firstIndex(of: d) else { throw ParseError.malformed }
            values.append(v)
        }
        guard values.count == groups * groupLength else { throw ParseError.malformed }
        var bytes = Data()
        var buffer = 0, bits = 0
        for v in values {
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xff))
                buffer &= (1 << bits) - 1
            }
        }
        guard bytes.count == 35 else { throw ParseError.malformed }
        let raw = bytes.prefix(32), sum = bytes.suffix(3)
        guard checksum(Data(raw)) == Data(sum) else { throw ParseError.malformed }
        return SymmetricKey(data: raw)
    }
}

/// Why a recovery key wasn't taken (`SyncEngine.useRecoveryKey`). The messages are the Settings sheet's.
public enum SyncRecoveryFailure: Error, Equatable, LocalizedError, Sendable {
    /// A typo: wrong length, a character not in the key's alphabet, or a checksum that doesn't fit.
    case malformed
    /// A real key, but not this sync's (it was started over since, or it's another Apple Account's).
    case otherGroup
    /// This Mac isn't waiting for a key (it has one, sync is off, or there's nothing in iCloud yet).
    case notWaiting
    /// The keychain refused it.
    case keychain
    /// Start over: another Mac started over at the same moment and won; this Mac joins its sync.
    case startedElsewhere

    public var errorDescription: String? {
        switch self {
        case .malformed: "That isn't a recovery key. Check it for typos."
        case .otherGroup: "That's the recovery key of another sync (was it started over since?). Show the key on a Mac that syncs now."
        case .notWaiting: "This Mac isn't waiting for a sync key."
        case .keychain: "Airc couldn't save the key in this Mac's keychain. Unlock the Mac and try again."
        case .startedElsewhere: "Another Mac started sync over just now. This Mac joins it as soon as it has that Mac's key."
        }
    }
}

/// Thrown inside a cycle when the zone's group isn't this Mac's any more (another Mac started over): this Mac has
/// rejoined (`SyncEngine.rejoin`) and the next cycle joins the new group.
struct SyncGroupReplaced: Error {}

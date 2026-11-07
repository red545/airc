// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

public enum SyncError: Error, Equatable {
    case invalidOperation, conflictingOperationID, clockExhausted, invalidOrder
    case wrongGroup, unsupportedVersion, invalidEnvelope
}

/// Total order: physical milliseconds, logical counter, then installation ID.
public struct SyncStamp: Codable, Hashable, Comparable, Sendable {
    public let milliseconds: Int64
    public let counter: UInt64
    public let device: UUID

    public init(milliseconds: Int64, counter: UInt64 = 0, device: UUID) {
        self.milliseconds = milliseconds; self.counter = counter; self.device = device
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.milliseconds != rhs.milliseconds { return lhs.milliseconds < rhs.milliseconds }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.device.uuidString < rhs.device.uuidString
    }
}

/// Persist with the outbox before acknowledging a local edit. Never share a device ID between Macs.
public struct SyncClock: Codable, Sendable {
    public let device: UUID
    public private(set) var milliseconds: Int64 = 0
    public private(set) var counter: UInt64 = 0

    public init(device: UUID = UUID()) { self.device = device }

    public mutating func tick(now: Int64, observing remote: SyncStamp? = nil) throws -> SyncStamp {
        let next = max(now, max(milliseconds, remote?.milliseconds ?? 0))
        let base: UInt64?
        if next == milliseconds && next == remote?.milliseconds { base = max(counter, remote!.counter) }
        else if next == milliseconds { base = counter }
        else if next == remote?.milliseconds { base = remote!.counter }
        else { base = nil }
        if let base {
            guard base < UInt64.max else { throw SyncError.clockExhausted }
            counter = base + 1
        } else { counter = 0 }
        milliseconds = next
        return SyncStamp(milliseconds: next, counter: counter, device: device)
    }
}

/// Variable-length base-65536 fractional digits. No floating point exhaustion or global rebalance.
/// Generated keys end in a nonzero digit; UUID suffixes disambiguate concurrent insertions.
public struct SyncOrder: Codable, Hashable, Comparable, Sendable {
    public let digits: [UInt16]

    public init(digits: [UInt16]) throws {
        guard !digits.isEmpty, digits.last != 0 else { throw SyncError.invalidOrder }
        self.digits = digits
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.digits.lexicographicallyPrecedes(rhs.digits) }

    public static func between(_ lower: Self?, _ upper: Self?, nonce: UUID = UUID()) throws -> Self {
        guard lower == nil || upper == nil || lower! < upper! else { throw SyncError.invalidOrder }
        var result: [UInt16] = []
        var upperIsOpen = upper == nil
        var i = 0
        while true {
            let lo = i < (lower?.digits.count ?? 0) ? lower!.digits[i] : 0
            let hi = !upperIsOpen && i < upper!.digits.count ? upper!.digits[i] : UInt16.max
            if UInt32(hi) > UInt32(lo) + 1 {
                result.append(lo + (hi - lo) / 2)
                result += nonce.uuidString.utf8.map { UInt16($0) + 1 }
                return try Self(digits: result)
            }
            result.append(lo)
            if lo < hi { upperIsOpen = true }
            i += 1
        }
    }
}

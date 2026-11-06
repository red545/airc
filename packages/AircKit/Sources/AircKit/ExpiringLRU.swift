// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// A bounded map whose entries expire (the app's favicon cache keeps its failures in two of these). A lookup drops an
/// expired entry and counts as a use. Inserting past `limit` drops every expired entry, then the least recently used
/// down to seven eighths of the limit, so the sort is paid once per `limit / 8` inserts.
public struct ExpiringLRU<Key: Hashable, Value> {
    public let limit: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    private struct Entry {
        var value: Value
        var expires: Date
        var used: UInt64
    }

    public init(limit: Int) { self.limit = max(1, limit) }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// The value, unless it has expired (then it's dropped).
    public mutating func value(for key: Key, now: Date = Date()) -> Value? {
        guard var e = entries[key] else { return nil }
        guard e.expires > now else {
            entries.removeValue(forKey: key)
            return nil
        }
        clock += 1
        e.used = clock
        entries[key] = e
        return e.value
    }

    /// The value without counting a use, expired or not.
    public func peek(_ key: Key) -> Value? { entries[key]?.value }

    public mutating func set(_ value: Value, for key: Key, expires: Date, now: Date = Date()) {
        clock += 1
        entries[key] = Entry(value: value, expires: expires, used: clock)
        if entries.count > limit { trim(now: now) }
    }

    @discardableResult
    public mutating func remove(_ key: Key) -> Value? { entries.removeValue(forKey: key)?.value }

    /// Drops every expired entry.
    public mutating func prune(now: Date = Date()) {
        entries = entries.filter { $0.value.expires > now }
    }

    private mutating func trim(now: Date) {
        prune(now: now)
        let keep = limit - limit / 8
        guard entries.count > keep else { return }
        let oldest = entries.sorted { $0.value.used < $1.value.used }.prefix(entries.count - keep)
        for (key, _) in oldest { entries.removeValue(forKey: key) }
    }
}

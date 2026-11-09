// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// `profile` records carry only a name, an emoji and whether it's the default profile, so another Mac can map a Space's
/// profile to one of its own (or create an empty one). Never logins, cookies, history or the engine folder.
public enum SyncRecordKind: String, Codable, Hashable, Sendable { case space, row, profile }

public struct SyncRecordID: Codable, Hashable, Sendable {
    public let kind: SyncRecordKind
    public let id: String
    public init(_ kind: SyncRecordKind, _ id: String) { self.kind = kind; self.id = id }
}

public enum SyncLocation: Codable, Hashable, Sendable {
    case pinned(space: String), today(space: String), favorites(profile: String), archived
}

/// An explicit allowlist; no raw StoreEntity payloads or arbitrary JSON fields cross this boundary.
public enum SyncField: String, Codable, Hashable, CaseIterable, Sendable {
    case name, icon, theme, profile, kind, url, title, parent, location, order, deleted
}

public enum SyncValue: Codable, Hashable, Sendable {
    case null, text(String), flag(Bool), theme(SpaceTheme), icon(SpaceIcon)
    case location(SyncLocation), order(SyncOrder)
}

public struct SyncOperation: Codable, Hashable, Sendable {
    public let id: UUID
    public let stamp: SyncStamp
    public let record: SyncRecordID
    public let fields: [SyncField: SyncValue]

    public init(id: UUID = UUID(), stamp: SyncStamp, record: SyncRecordID, fields: [SyncField: SyncValue]) {
        self.id = id; self.stamp = stamp; self.record = record; self.fields = fields
    }

    func validate() throws {
        guard !record.id.isEmpty, !fields.isEmpty, stamp.milliseconds >= 0 else { throw SyncError.invalidOperation }
        let allowed: Set<SyncField> = switch record.kind {
        case .space: [.name, .icon, .theme, .profile, .order, .deleted]
        case .row: [.kind, .url, .title, .icon, .parent, .location, .order, .deleted]
        case .profile: [.name, .icon, .kind, .deleted]
        }
        for (field, value) in fields {
            guard allowed.contains(field) else { throw SyncError.invalidOperation }
            switch (field, value) {
            case (.name, .text), (.profile, .text), (.url, .text), (.title, .text), (.parent, .text),
                 (.icon, .text), (.icon, .icon), (.theme, .theme), (.location, .location): break
            case (.kind, .text(let kind)) where record.kind == .row && (kind == "tab" || kind == "folder"): break
            case (.kind, .text(let kind)) where record.kind == .profile && (kind == "default" || kind == "profile"): break
            case (.url, .null), (.title, .null), (.icon, .null), (.parent, .null): break
            case (.deleted, .flag): break
            case (.order, .order(let key)):
                guard !key.digits.isEmpty, key.digits.last != 0 else { throw SyncError.invalidOrder }
            default: throw SyncError.invalidOperation
            }
        }
    }
}

public struct SyncRegister: Codable, Hashable, Sendable {
    public let operation: UUID
    public let stamp: SyncStamp
    public let value: SyncValue

    func precedes(_ other: Self) -> Bool {
        stamp == other.stamp ? operation.uuidString < other.operation.uuidString : stamp < other.stamp
    }
}

public struct SyncRecord: Codable, Hashable, Sendable {
    public let id: SyncRecordID
    public var fields: [SyncField: SyncRegister] = [:]
    public subscript(_ field: SyncField) -> SyncValue? { fields[field]?.value }
    public var isDeleted: Bool { self[.deleted] == .flag(true) }
    public var order: SyncOrder? { if case .order(let key) = self[.order] { return key }; return nil }
}

/// Pure merge state. Delivery order and duplicates have no effect. The log retains tombstones;
/// garbage collection requires a future all-device acknowledgement protocol.
public struct SyncReplica: Codable, Sendable {
    public private(set) var clock: SyncClock
    public private(set) var operations: [UUID: SyncOperation] = [:]
    public private(set) var records: [SyncRecordID: SyncRecord] = [:]

    public init(device: UUID = UUID()) { clock = SyncClock(device: device) }

    @discardableResult
    public mutating func edit(_ record: SyncRecordID, _ fields: [SyncField: SyncValue], now: Int64) throws -> SyncOperation {
        var next = self
        let op = SyncOperation(stamp: try next.clock.tick(now: now), record: record, fields: fields)
        try next.insert(op)
        self = next
        return op
    }

    /// Atomic batch; reject a reused operation ID with different contents instead of diverging silently.
    public mutating func receive(_ incoming: [SyncOperation], now: Int64) throws {
        var next = self
        for op in incoming {
            if let old = next.operations[op.id] {
                guard old == op else { throw SyncError.conflictingOperationID }
                continue
            }
            try next.insert(op)
            _ = try next.clock.tick(now: now, observing: op.stamp)
        }
        self = next
    }

    private mutating func insert(_ op: SyncOperation) throws {
        try op.validate()
        var record = records[op.record] ?? SyncRecord(id: op.record)
        for (field, value) in op.fields {
            let candidate = SyncRegister(operation: op.id, stamp: op.stamp, value: value)
            if record.fields[field].map({ $0.precedes(candidate) }) ?? true { record.fields[field] = candidate }
        }
        records[op.record] = record
        operations[op.id] = op
    }

    public var log: [SyncOperation] {
        operations.values.sorted {
            $0.stamp == $1.stamp ? $0.id.uuidString < $1.id.uuidString : $0.stamp < $1.stamp
        }
    }

    /// Pure display projection, never a repair operation. Orphans go to their Space root;
    /// a deleted Space hides its rows until explicitly restored. Every member of a parent cycle is rooted.
    public var sidebar: [SyncRecord] {
        let live = records.filter { !$0.value.isDeleted }
        return live.values.compactMap { original -> SyncRecord? in
            var row = original
            if row.id.kind == .row {
                guard case .location(let location) = row[.location] else { return nil }
                switch location {
                case .archived: return nil
                case .pinned(let space), .today(let space):
                    guard live[SyncRecordID(.space, space)] != nil else { return nil }
                case .favorites: break
                }
                if case .text(let parent) = row[.parent] {
                    var seen: Set<String> = [row.id.id]
                    var cursor: String? = parent
                    var invalid = false
                    while let id = cursor {
                        guard seen.insert(id).inserted,
                              let p = live[SyncRecordID(.row, id)], p[.kind] == .text("folder"),
                              p[.location] == row[.location], case .pinned = location else {
                            invalid = true; break
                        }
                        if case .text(let next) = p[.parent] { cursor = next } else { cursor = nil }
                    }
                    if invalid, let register = row.fields[.parent] {
                        row.fields[.parent] = SyncRegister(operation: register.operation, stamp: register.stamp, value: .null)
                    }
                }
            }
            return row
        }.sorted {
            if $0.order != $1.order {
                if let a = $0.order, let b = $1.order { return a < b }
                return $0.order == nil
            }
            return ($0.id.kind.rawValue, $0.id.id) < ($1.id.kind.rawValue, $1.id.id)
        }
    }

    /// Unknown assignments remain unresolved. Never silently load a Space with another profile's cookies.
    public func resolvedProfile(for space: String, localProfiles: Set<String>) -> String? {
        guard let record = records[SyncRecordID(.space, space)], !record.isDeleted,
              case .text(let id) = record[.profile], localProfiles.contains(id) else { return nil }
        return id
    }
}

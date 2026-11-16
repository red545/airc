// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// `profile` records carry only a name, an emoji and whether it's the default profile, so another Mac can map a Space's
/// profile to one of its own (or create an empty one). Never logins, cookies, history or the engine folder.
/// `setting` records are one app setting each (SettingSyncPayload.swift), only in version 4 batches.
public enum SyncRecordKind: String, Codable, Hashable, Sendable { case space, row, profile, setting }

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
    /// A saved split's layout (SplitSyncPayload.swift). Only in version 3 batches.
    case layout
    /// A setting's value (SettingSyncPayload.swift). Only in version 4 batches.
    case value
}

public enum SyncValue: Codable, Hashable, Sendable {
    case null, text(String), flag(Bool), theme(SpaceTheme), icon(SpaceIcon)
    case location(SyncLocation), order(SyncOrder)
    case split(SplitSyncPayload)
    case setting(SettingSyncPayload)
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
        case .row: [.kind, .url, .title, .icon, .parent, .location, .order, .deleted, .layout]
        case .profile: [.name, .icon, .kind, .deleted]
        case .setting: [.value]
        }
        if record.kind == .setting, !SyncSettings.isValidKey(record.id) { throw SyncError.invalidOperation }
        for (field, value) in fields {
            guard allowed.contains(field) else { throw SyncError.invalidOperation }
            switch (field, value) {
            case (.name, .text), (.profile, .text), (.url, .text), (.title, .text), (.parent, .text),
                 (.icon, .text), (.icon, .icon), (.theme, .theme), (.location, .location): break
            case (.kind, .text(let kind)) where record.kind == .row && (kind == "tab" || kind == "folder" || kind == "split"): break
            case (.layout, .split(let payload)) where payload.isValid: break
            case (.layout, .null): break
            case (.value, .setting(let payload)) where record.kind == .setting && payload.isValid: break
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
        // A setting: the later change wins (when it was made on its Mac, so a change made while sync was off still counts
        // from then), then the later stamp. Every Mac orders alike.
        if case .setting(let a) = value, case .setting(let b) = other.value, a.changed != b.changed { return a.changed < b.changed }
        return stamp == other.stamp ? operation.uuidString < other.operation.uuidString : stamp < other.stamp
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

    /// A stamp seen outside the log (a note version, NoteSyncPayload.swift): the next edit's stamp is later, so a row
    /// re-created after a note's removal elsewhere wins over that removal's row tombstone.
    public mutating func observe(_ stamp: SyncStamp, now: Int64) throws {
        _ = try clock.tick(now: now, observing: stamp)
    }

    /// A stamp for something outside the log (a note version) on this replica's clock.
    public mutating func tick(now: Int64) throws -> SyncStamp { try clock.tick(now: now) }

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
    /// Only tabs sit in a split, and a split only at a Space's root, in a folder or in Favorites. A split with fewer than
    /// two live panes isn't one (a pane deleted elsewhere): its pane takes its place. Panes past `Split.maxPanes` (two
    /// Macs adding at once) sit next to it as rows of their own. Every Mac projects alike, so all show the same.
    public var sidebar: [SyncRecord] {
        // Settings aren't in the sidebar (SyncSettings).
        let live = records.filter { !$0.value.isDeleted && $0.key.kind != .setting }
        func isSplit(_ r: SyncRecord?) -> Bool { r?[.kind] == .text("split") }
        func kindOf(_ r: SyncRecord) -> SyncValue { r[.kind] ?? .text("tab") }
        var rows = live.values.compactMap { original -> SyncRecord? in
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
                    var child = kindOf(row)
                    var invalid = false
                    while let id = cursor {
                        guard seen.insert(id).inserted, let p = live[SyncRecordID(.row, id)], p[.location] == row[.location] else {
                            invalid = true; break
                        }
                        if isSplit(p) {
                            // Only a tab sits in a split. Where the split itself sits is checked on its own row: a pane
                            // stays in its split even if the split's folder went.
                            if child != .text("tab") { invalid = true }
                            break
                        } else {
                            guard p[.kind] == .text("folder"), case .pinned = location else { invalid = true; break }
                        }
                        child = kindOf(p)
                        if case .text(let next) = p[.parent] { cursor = next } else { cursor = nil }
                    }
                    if invalid, let register = row.fields[.parent] {
                        row.fields[.parent] = SyncRegister(operation: register.operation, stamp: register.stamp, value: .null)
                    }
                }
            }
            return row
        }
        // Splits: which panes stay, in pane order.
        var panes: [String: [Int]] = [:]
        for (i, row) in rows.enumerated() where row.id.kind == .row {
            if case .text(let parent)? = row[.parent], isSplit(live[SyncRecordID(.row, parent)]) { panes[parent, default: []].append(i) }
        }
        var dropped = Set<SyncRecordID>()
        for (i, split) in rows.enumerated() where split.id.kind == .row && isSplit(split) {
            let mine = (panes[split.id.id] ?? []).sorted { Self.precedes(rows[$0], rows[$1]) }
            let loose = mine.count < 2 ? mine : Array(mine.dropFirst(Split.maxPanes))
            if mine.count < 2 { dropped.insert(split.id) }
            // Rows of their own where the split is: its parent and its order register.
            for k in loose {
                rows[k].fields[.parent] = rows[i].fields[.parent] ?? rows[k].fields[.parent].map {
                    SyncRegister(operation: $0.operation, stamp: $0.stamp, value: .null)
                }
                if let order = rows[i].fields[.order] { rows[k].fields[.order] = order }
            }
        }
        rows.removeAll { dropped.contains($0.id) }
        return rows.sorted(by: Self.precedes)
    }

    private static func precedes(_ a: SyncRecord, _ b: SyncRecord) -> Bool {
        if a.order != b.order {
            if let x = a.order, let y = b.order { return x < y }
            return a.order == nil
        }
        return (a.id.kind.rawValue, a.id.id) < (b.id.kind.rawValue, b.id.id)
    }

    /// Unknown assignments remain unresolved. Never silently load a Space with another profile's cookies.
    public func resolvedProfile(for space: String, localProfiles: Set<String>) -> String? {
        guard let record = records[SyncRecordID(.space, space)], !record.isDeleted,
              case .text(let id) = record[.profile], localProfiles.contains(id) else { return nil }
        return id
    }
}

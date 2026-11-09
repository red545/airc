// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Stand-ins for CloudKit's private database, for unit tests and the app's scripted check (`--sync-mock`, test builds
// only). They keep CloudKit's semantics the transport depends on: per-zone change tokens that resume after the last
// change, pages with `moreComing`, create-only saves that fail on an existing name, missing zones, a zone the user
// deleted, expired tokens and account changes.

/// The database itself, as a value: the in-memory mock holds one, the folder mock reads and writes one per call.
public struct SyncMockCloudState: Codable, Sendable {
    struct Stored: Codable, Sendable { var record: SyncCloudRecord; var seq: Int }
    struct Zone: Codable, Sendable {
        var generation: Int
        var records: [String: Stored] = [:]
        var deletions: [String: Int] = [:]
        /// Tokens from an earlier epoch are expired.
        var epoch = 0
    }
    struct Token: Codable { var generation: Int; var epoch: Int; var seq: Int }

    var zones: [String: Zone] = [:]
    var seq = 0
    var generations = 0
    var userDeleted: Set<String> = []
    var subscriptions: Set<String> = []
    public var account: SyncCloudAccount = .available
    public var identity = "_mock-user"
    public var pageSize = 50

    public init() {}

    public var batchCount: Int { zones.values.reduce(0) { $0 + $1.records.values.filter { $0.record.type == SyncCloudSchema.batch }.count } }
    public func records(zone: String) -> [SyncCloudRecord] { zones[zone].map { $0.records.values.map(\.record) } ?? [] }

    mutating func zone(_ name: String) throws -> Zone {
        if userDeleted.contains(name) { throw SyncCloudFailure.userDeletedZone }
        guard let z = zones[name] else { throw SyncCloudFailure.zoneNotFound }
        return z
    }

    /// Creating the zone again is how an app starts over after the user deleted it (only when the person asks).
    mutating func createZone(_ name: String) throws {
        userDeleted.remove(name)
        guard zones[name] == nil else { return }
        generations += 1
        zones[name] = Zone(generation: generations)
    }

    /// The CloudKit console's "reset", or another Mac deleting the zone.
    public mutating func deleteZone(_ name: String) { zones[name] = nil }
    /// System Settings → Apple Account → iCloud → Manage → Airc → Delete Data.
    public mutating func deleteZoneAsUser(_ name: String) { zones[name] = nil; userDeleted.insert(name) }
    /// The server forgot old history: every token given out so far expires.
    public mutating func expireTokens(_ name: String) { zones[name]?.epoch += 1 }

    mutating func fetchChanges(zone name: String, since token: Data?) throws -> SyncCloudChanges {
        let z = try zone(name)
        var after = 0
        if let token {
            guard let t = try? JSONDecoder().decode(Token.self, from: token) else { throw SyncCloudFailure.other("bad token") }
            guard t.generation == z.generation, t.epoch == z.epoch else { throw SyncCloudFailure.changeTokenExpired }
            after = t.seq
        }
        var events: [(Int, SyncCloudRecord?, String)] = z.records.values.filter { $0.seq > after }.map { ($0.seq, $0.record, $0.record.name) }
        events += z.deletions.filter { $0.value > after }.map { ($0.value, nil, $0.key) }
        events.sort { $0.0 < $1.0 }
        let page = events.prefix(pageSize)
        let last = page.last?.0 ?? max(after, z.records.values.map(\.seq).max() ?? 0)
        let token = try JSONEncoder().encode(Token(generation: z.generation, epoch: z.epoch, seq: last))
        return SyncCloudChanges(changed: page.compactMap(\.1), deleted: page.filter { $0.1 == nil }.map(\.2), token: token,
                                moreComing: events.count > page.count)
    }

    mutating func save(_ records: [SyncCloudRecord], zone name: String, mode: SyncSaveMode) throws -> [String: Result<SyncCloudRecord, SyncCloudFailure>] {
        var z = try zone(name)
        var results: [String: Result<SyncCloudRecord, SyncCloudFailure>] = [:]
        for record in records {
            if mode == .createOnly, z.records[record.name] != nil { results[record.name] = .failure(.serverRecordChanged); continue }
            seq += 1
            z.records[record.name] = Stored(record: record, seq: seq)
            z.deletions[record.name] = nil
            results[record.name] = .success(record)
        }
        zones[name] = z
        return results
    }

    /// Records another device wrote (scripted checks and marketing shots seed "another Mac" this way).
    public mutating func seed(_ records: [SyncCloudRecord], zone name: String) throws {
        try createZone(name)
        _ = try save(records, zone: name, mode: .overwrite)
    }

    mutating func fetch(_ names: [String], zone name: String) throws -> [SyncCloudRecord] {
        let z = try zone(name)
        return names.compactMap { z.records[$0]?.record }
    }

    mutating func subscribe(zone name: String, id: String) throws {
        _ = try zone(name)
        subscriptions.insert(name + "/" + id)
    }
}

/// In-memory mock with injectable failures, for unit tests.
public actor SyncMockCloudDatabase: SyncCloudDatabase {
    public enum Call: String, Sendable { case accountStatus, accountIdentity, createZone, fetchChanges, save, fetch, subscribe }
    public private(set) var state = SyncMockCloudState()
    private var faults: [Call: [SyncCloudFailure]] = [:]
    private var recordFaults: [String: SyncCloudFailure] = [:]
    public private(set) var calls: [Call] = []

    public init() {}

    /// The next calls of `call` fail with these, in order.
    public func fail(_ call: Call, with failures: SyncCloudFailure...) { faults[call, default: []] += failures }
    public func change(_ body: @Sendable (inout SyncMockCloudState) -> Void) { body(&state) }
    /// Until cleared, fetches return these records as failed entries of their page (CloudKit's per-record errors).
    public func failRecords(_ names: Set<String>, with failure: SyncCloudFailure) { for n in names { recordFaults[n] = failure } }
    public func clearRecordFaults() { recordFaults = [:] }
    public func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }

    private func enter(_ call: Call) throws {
        calls.append(call)
        if var queue = faults[call], !queue.isEmpty {
            let failure = queue.removeFirst()
            faults[call] = queue
            throw failure
        }
    }

    public func accountStatus() throws -> SyncCloudAccount { try enter(.accountStatus); return state.account }
    public func accountIdentity() throws -> String { try enter(.accountIdentity); return state.identity }
    public func createZone(_ zone: String) throws { try enter(.createZone); try state.createZone(zone) }
    public func fetchChanges(zone: String, since token: Data?) throws -> SyncCloudChanges {
        try enter(.fetchChanges)
        var changes = try state.fetchChanges(zone: zone, since: token)
        for record in changes.changed { if let f = recordFaults[record.name] { changes.failed[record.name] = f } }
        changes.changed.removeAll { recordFaults[$0.name] != nil }
        return changes
    }
    public func save(_ records: [SyncCloudRecord], zone: String, mode: SyncSaveMode) throws -> [String: Result<SyncCloudRecord, SyncCloudFailure>] {
        try enter(.save); return try state.save(records, zone: zone, mode: mode)
    }
    public func fetch(_ names: [String], zone: String) throws -> [SyncCloudRecord] { try enter(.fetch); return try state.fetch(names, zone: zone) }
    public func subscribe(zone: String, id: String) throws { try enter(.subscribe); try state.subscribe(zone: zone, id: id) }
}

/// The same database in a folder, shared by several app instances (two "Macs" in the scripted check). Each call reads
/// and writes `state.json` under an exclusive lock.
public struct SyncFolderCloudDatabase: SyncCloudDatabase {
    public let folder: URL

    public init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Runs `body` on the stored state while holding the folder's lock; saves it when `body` returns normally.
    @discardableResult
    public func withState<T>(_ body: (inout SyncMockCloudState) throws -> T) throws -> T {
        let lock = open(folder.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw SyncCloudFailure.other("lock") }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }
        let file = folder.appendingPathComponent("state.json")
        var state = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SyncMockCloudState.self, from: $0) } ?? SyncMockCloudState()
        do {
            let result = try body(&state)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            return result
        } catch {
            try? JSONEncoder().encode(state).write(to: file, options: .atomic)
            throw error
        }
    }

    public func accountStatus() throws -> SyncCloudAccount { try withState { $0.account } }
    public func accountIdentity() throws -> String { try withState { $0.identity } }
    public func createZone(_ zone: String) throws { try withState { try $0.createZone(zone) } }
    public func fetchChanges(zone: String, since token: Data?) throws -> SyncCloudChanges { try withState { try $0.fetchChanges(zone: zone, since: token) } }
    public func save(_ records: [SyncCloudRecord], zone: String, mode: SyncSaveMode) throws -> [String: Result<SyncCloudRecord, SyncCloudFailure>] {
        try withState { try $0.save(records, zone: zone, mode: mode) }
    }
    public func fetch(_ names: [String], zone: String) throws -> [SyncCloudRecord] { try withState { try $0.fetch(names, zone: zone) } }
    public func subscribe(zone: String, id: String) throws { try withState { try $0.subscribe(zone: zone, id: id) } }
}

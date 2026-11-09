// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// iCloud sync: the CloudKit transport over a small database protocol, so tests and scripted checks run the same code
// against a mock (SyncCloudMock.swift) and only SyncCloudKit.swift touches CloudKit. Everything stored is ciphertext
// except record names, the group and device UUIDs, a format version and timestamps.

/// One record, without CloudKit types. Field values are the few kinds the schema uses (docs/sync.md).
public struct SyncCloudRecord: Codable, Hashable, Sendable {
    public var name: String
    public var type: String
    public var fields: [String: SyncCloudValue]

    public init(name: String, type: String, fields: [String: SyncCloudValue]) {
        self.name = name; self.type = type; self.fields = fields
    }

    public func string(_ key: String) -> String? { if case .string(let v) = fields[key] { return v }; return nil }
    public func int(_ key: String) -> Int64? { if case .int(let v) = fields[key] { return v }; return nil }
    public func bytes(_ key: String) -> Data? { if case .bytes(let v) = fields[key] { return v }; return nil }
    public func date(_ key: String) -> Date? { if case .date(let v) = fields[key] { return v }; return nil }
}

public enum SyncCloudValue: Codable, Hashable, Sendable {
    case string(String), int(Int64), bytes(Data), date(Date)
}

/// What one incremental fetch returned. `token` resumes after it; `moreComing` asks for another page. `failed`: records
/// of this page CloudKit couldn't return; the transport then keeps the old token, so they come again.
public struct SyncCloudChanges: Sendable {
    public var changed: [SyncCloudRecord]
    public var deleted: [String]
    public var token: Data
    public var moreComing: Bool
    public var failed: [String: SyncCloudFailure]

    public init(changed: [SyncCloudRecord], deleted: [String], token: Data, moreComing: Bool, failed: [String: SyncCloudFailure] = [:]) {
        self.changed = changed; self.deleted = deleted; self.token = token; self.moreComing = moreComing; self.failed = failed
    }
}

/// What the last `read()` saw besides batches, for the engine's recovery and completeness decisions.
public struct SyncReadReport: Equatable, Sendable {
    /// A request recreated the zone since the last report: the server lost everything before that.
    public var zoneRecreated = false
    /// The read started from no token (or its token expired): `own` is every batch of this device on the server.
    public var full = false
    public var own: Set<UUID> = []
    /// Batch records that couldn't be parsed (another format, damage).
    public var malformed: [String] = []
    /// Batch records that parsed, and records deleted: either settles an earlier malformed record of that name.
    public var valid: Set<String> = []
    public var deleted: Set<String> = []

    public init(zoneRecreated: Bool = false, full: Bool = false, own: Set<UUID> = [], malformed: [String] = [],
                valid: Set<String> = [], deleted: Set<String> = []) {
        self.zoneRecreated = zoneRecreated; self.full = full; self.own = own; self.malformed = malformed
        self.valid = valid; self.deleted = deleted
    }
}

public enum SyncCloudAccount: String, Codable, Sendable {
    case available, noAccount, restricted, temporarilyUnavailable, couldNotDetermine
}

/// CloudKit's errors, reduced to what the transport and the Sync page act on (SyncCloudKit.swift maps CKError).
public enum SyncCloudFailure: Error, Equatable, Sendable {
    /// Offline, server busy, rate limited: retry, after `retryAfter` seconds when CloudKit says.
    case network(retryAfter: Double?)
    case notSignedIn
    case restricted
    case quotaExceeded
    case zoneNotFound
    /// The user deleted Airc's data in System Settings → Apple Account → iCloud. Never recreate it by ourselves.
    case userDeletedZone
    case changeTokenExpired
    /// A create-only save found the record already there.
    case serverRecordChanged
    case notFound
    /// The app isn't entitled (a dev build, or the profile is missing): nothing to retry.
    case missingEntitlement
    /// The Mac is signed in to another Apple Account than the one this session started with.
    case accountChanged
    case limitExceeded
    case other(String)

    public var isTransient: Bool {
        switch self {
        case .network: true
        default: false
        }
    }
}

public enum SyncSaveMode: Sendable {
    /// Fails with `serverRecordChanged` if a record of that name exists.
    case createOnly
    /// Replaces this device's own record whatever is on the server.
    case overwrite
}

/// The slice of CKDatabase the transport uses (one private database, one custom zone).
public protocol SyncCloudDatabase: Sendable {
    func accountStatus() async throws -> SyncCloudAccount
    /// Changes when the Mac signs in to another Apple ID.
    func accountIdentity() async throws -> String
    func createZone(_ zone: String) async throws
    func fetchChanges(zone: String, since token: Data?) async throws -> SyncCloudChanges
    /// Per-record outcomes; the whole call throws only when nothing could be tried.
    func save(_ records: [SyncCloudRecord], zone: String, mode: SyncSaveMode) async throws -> [String: Result<SyncCloudRecord, SyncCloudFailure>]
    func fetch(_ names: [String], zone: String) async throws -> [SyncCloudRecord]
    func subscribe(zone: String, id: String) async throws
}

// MARK: - Group and device records

/// The one record the first Mac writes: the group's ID and proof of its key. A second Mac finds it, then waits for the
/// key in iCloud Keychain. Created with a create-only save, so two Macs setting up at once join one group.
public struct SyncGroupRecord: Codable, Hashable, Sendable {
    public var group: UUID
    public var version: Int
    /// AES-GCM over a fixed text with the group key: tells a wrong key from a missing one.
    public var check: Data
    public var created: Date

    public init(group: UUID, version: Int = 1, check: Data, created: Date) {
        self.group = group; self.version = version; self.check = check; self.created = created
    }
}

/// Each Mac's own record: its name sealed with the group key and when it last synced.
public struct SyncDeviceRecord: Codable, Hashable, Sendable {
    public var group: UUID
    public var device: UUID
    public var sealed: Data
    public var seen: Date

    public init(group: UUID, device: UUID, sealed: Data, seen: Date) {
        self.group = group; self.device = device; self.sealed = sealed; self.seen = seen
    }
}

/// What the engine needs beyond batches: the group record, device records and a durable read checkpoint. One transport
/// is one session: `cancel()` (sync off, Cancel, an account change) makes every request not yet started fail.
public protocol SyncGroupTransport: SyncTransport {
    /// Ends the session at once: no further request, retry or page starts; they throw `SyncError.cancelled`.
    func cancel()
    /// From now on every request first checks that the Mac is still signed in to `account` (`accountChanged`).
    func bind(account: String) async
    /// Throws `accountChanged` when the Mac's Apple Account isn't the bound one (no-op before `bind`).
    func verifyAccount() async throws
    /// Account, zone and push subscription. Throws `SyncCloudFailure`.
    func prepare() async throws
    func accountIdentity() async throws -> String?
    func group() async throws -> SyncGroupRecord?
    /// Creates the group record, or returns the one another Mac created first.
    func createGroup(_ record: SyncGroupRecord) async throws -> SyncGroupRecord
    func publish(_ device: SyncDeviceRecord) async throws
    var devices: [SyncDeviceRecord] { get async }
    /// After `read()`, the engine merges and saves, then calls this; until then `read()` returns the same changes again.
    func acknowledge() async
    /// Opaque durable state (change token, known devices). Persist it with the replica after `acknowledge()`.
    var checkpoint: Data? { get async }
    func restore(checkpoint: Data?) async
    /// After a `read()`: whether a zone was recreated (kept until taken, across reads), whether the read was full and
    /// which of this device's batches it saw, and unparseable records. The engine decides recovery from it.
    func takeReadReport() async -> SyncReadReport
}

// MARK: - CloudKit transport

public enum SyncCloudSchema {
    public static let zone = "AircSidebar"
    public static let subscription = "airc-sidebar-changes"
    public static let batch = "SyncBatch"
    public static let device = "SyncDevice"
    public static let group = "SyncGroup"
    public static let groupRecordName = "group"

    /// `<device>.<envelope>`: a device only ever creates names with its own UUID.
    public static func batchName(_ envelope: SyncEnvelope) -> String { envelope.device.uuidString + "." + envelope.id.uuidString }
    public static func deviceName(_ device: UUID) -> String { "device." + device.uuidString }

    public static func record(_ envelope: SyncEnvelope) -> SyncCloudRecord {
        SyncCloudRecord(name: batchName(envelope), type: batch, fields: [
            "group": .string(envelope.group.uuidString), "device": .string(envelope.device.uuidString),
            "envelope": .string(envelope.id.uuidString), "version": .int(Int64(envelope.version)),
            "sealed": .bytes(envelope.sealed),
        ])
    }

    /// nil for anything malformed or written under another device's name.
    public static func envelope(_ record: SyncCloudRecord) -> SyncEnvelope? {
        guard record.type == batch, let group = record.string("group").flatMap(UUID.init(uuidString:)),
              let device = record.string("device").flatMap(UUID.init(uuidString:)),
              let id = record.string("envelope").flatMap(UUID.init(uuidString:)),
              let version = record.int("version"), let sealed = record.bytes("sealed") else { return nil }
        let envelope = SyncEnvelope(version: Int(version), group: group, device: device, id: id, sealed: sealed)
        return record.name == batchName(envelope) ? envelope : nil
    }

    public static func record(_ group: SyncGroupRecord) -> SyncCloudRecord {
        SyncCloudRecord(name: groupRecordName, type: self.group, fields: [
            "group": .string(group.group.uuidString), "version": .int(Int64(group.version)),
            "check": .bytes(group.check), "created": .date(group.created),
        ])
    }

    public static func group(_ record: SyncCloudRecord) -> SyncGroupRecord? {
        guard record.type == group, record.name == groupRecordName,
              let id = record.string("group").flatMap(UUID.init(uuidString:)), let version = record.int("version"),
              let check = record.bytes("check") else { return nil }
        return SyncGroupRecord(group: id, version: Int(version), check: check, created: record.date("created") ?? .distantPast)
    }

    public static func record(_ device: SyncDeviceRecord) -> SyncCloudRecord {
        SyncCloudRecord(name: deviceName(device.device), type: self.device, fields: [
            "group": .string(device.group.uuidString), "device": .string(device.device.uuidString),
            "sealed": .bytes(device.sealed), "seen": .date(device.seen),
        ])
    }

    public static func device(_ record: SyncCloudRecord) -> SyncDeviceRecord? {
        guard record.type == device, let group = record.string("group").flatMap(UUID.init(uuidString:)),
              let id = record.string("device").flatMap(UUID.init(uuidString:)), record.name == deviceName(id),
              let sealed = record.bytes("sealed"), let seen = record.date("seen") else { return nil }
        return SyncDeviceRecord(group: group, device: id, sealed: sealed, seen: seen)
    }
}

/// The CloudKit transport: one record per encrypted batch in a custom zone of the private database, named after the
/// device that wrote it, read incrementally with the zone's change token. Delivery is at least once: the replica
/// ignores operations it has.
public actor CloudKitSyncTransport: SyncGroupTransport {
    /// Set from any thread, read before every request: a session ends without waiting for the actor.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    private struct Checkpoint: Codable, Sendable {
        var token: Data?
        var zoneReady = false
        var subscribed = false
        var devices: [UUID: SyncDeviceRecord] = [:]
    }

    public let database: SyncCloudDatabase
    public let device: UUID
    /// Waits between attempts after a network failure (CloudKit's retry-after wins when longer). Tests use zeros.
    private let backoff: [Double]
    private let sleep: @Sendable (Double) async -> Void
    private var committed = Checkpoint()
    private var pending: Checkpoint?
    private var zoneRecreated = false
    private var lastRead = SyncReadReport()
    private let cancellation = Cancellation()
    private var account: String?
    /// `AircSidebar`; the real-iCloud test uses a zone of its own (docs/sync.md) and deletes it afterwards.
    public let zone: String
    private let subscription: String

    public init(database: SyncCloudDatabase, device: UUID, zone: String = SyncCloudSchema.zone,
                subscription: String = SyncCloudSchema.subscription, backoff: [Double] = [1, 4, 15],
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.database = database; self.device = device; self.zone = zone; self.subscription = subscription
        self.backoff = backoff; self.sleep = sleep
    }

    public var checkpoint: Data? { try? JSONEncoder().encode(committed) }

    nonisolated public func cancel() { cancellation.cancel() }
    public func bind(account: String) { self.account = account }

    public func verifyAccount() async throws {
        guard let account else { return }
        try live()
        let identity = try await database.accountIdentity()
        try live()
        guard identity == account else { throw SyncCloudFailure.accountChanged }
    }

    private func live() throws { if cancellation.isCancelled { throw SyncError.cancelled } }

    public func restore(checkpoint: Data?) {
        committed = checkpoint.flatMap { try? JSONDecoder().decode(Checkpoint.self, from: $0) } ?? Checkpoint()
        pending = nil
    }

    public var devices: [SyncDeviceRecord] { (pending ?? committed).devices.values.sorted { $0.device.uuidString < $1.device.uuidString } }

    public func takeReadReport() -> SyncReadReport {
        var report = lastRead
        report.zoneRecreated = zoneRecreated
        zoneRecreated = false
        lastRead = SyncReadReport()
        return report
    }

    public func accountIdentity() async throws -> String? {
        try await retrying(checkAccount: false) { try await self.database.accountIdentity() }
    }

    public func prepare() async throws {
        switch try await retrying(checkAccount: false, { try await self.database.accountStatus() }) {
        case .available: break
        case .noAccount: throw SyncCloudFailure.notSignedIn
        case .restricted: throw SyncCloudFailure.restricted
        case .temporarilyUnavailable, .couldNotDetermine: throw SyncCloudFailure.network(retryAfter: nil)
        }
        if !committed.zoneReady {
            try await retrying { try await self.database.createZone(self.zone) }
            committed.zoneReady = true
        }
        if !committed.subscribed {
            // Push only speeds things up; the periodic fetch is the fallback, so a failure here is not an error.
            do {
                try await retrying { try await self.database.subscribe(zone: self.zone, id: self.subscription) }
                committed.subscribed = true
            } catch SyncCloudFailure.zoneNotFound {
                committed.zoneReady = false
                throw SyncCloudFailure.zoneNotFound
            } catch let failure as SyncError {
                throw failure
            } catch SyncCloudFailure.accountChanged {
                throw SyncCloudFailure.accountChanged
            } catch {}
        }
    }

    public func append(_ envelope: SyncEnvelope) async throws {
        guard envelope.device == device else { throw SyncError.invalidEnvelope }
        try await save(SyncCloudSchema.record(envelope), mode: .createOnly)
    }

    /// Changes since the last acknowledged checkpoint: batches from other devices, plus the device list.
    public func read() async throws -> [SyncEnvelope] {
        var next = committed
        var envelopes: [SyncEnvelope] = []
        var restarted = false
        var full = next.token == nil
        var own = Set<UUID>()
        // Each batch record's last outcome in this read, in page order: a record malformed on one page and repaired or
        // deleted on a later one ends valid or deleted (one name has at most one event per page).
        enum Outcome { case malformed, valid, deleted }
        var outcome: [String: Outcome] = [:]
        while true {
            let changes: SyncCloudChanges
            do {
                let token = next.token
                changes = try await retrying { try await self.database.fetchChanges(zone: self.zone, since: token) }
            } catch SyncCloudFailure.changeTokenExpired where !restarted {
                // Read everything again; the replica ignores what it already has.
                restarted = true
                full = true
                next.token = nil
                envelopes = []
                own = []
                outcome = [:]
                continue
            } catch SyncCloudFailure.zoneNotFound {
                // The zone is gone (reset in the CloudKit console, or by another Mac's recovery): recreate it empty;
                // every device uploads its own operations again.
                try await retrying { try await self.database.createZone(self.zone) }
                committed = Checkpoint(token: nil, zoneReady: true, subscribed: false, devices: [:])
                pending = nil
                zoneRecreated = true
                lastRead = SyncReadReport(full: true)
                return []
            }
            // A record CloudKit couldn't return: keep the old token (nothing is acknowledged past it) and try again.
            if let failure = changes.failed.values.first(where: { $0.isTransient }) ?? changes.failed.values.first {
                throw failure
            }
            for record in changes.changed {
                switch record.type {
                case SyncCloudSchema.batch:
                    guard let envelope = SyncCloudSchema.envelope(record) else { outcome[record.name] = .malformed; break }
                    outcome[record.name] = .valid
                    if envelope.device == device { own.insert(envelope.id) } else { envelopes.append(envelope) }
                case SyncCloudSchema.device:
                    if let d = SyncCloudSchema.device(record) { next.devices[d.device] = d }
                default: break
                }
            }
            for name in changes.deleted { outcome[name] = .deleted }
            for name in changes.deleted where name.hasPrefix("device.") {
                if let id = UUID(uuidString: String(name.dropFirst(7))) { next.devices[id] = nil }
            }
            next.token = changes.token
            if !changes.moreComing { break }
        }
        lastRead = SyncReadReport(full: full, own: own,
                                  malformed: outcome.filter { $0.value == .malformed }.map(\.key).sorted(),
                                  valid: Set(outcome.filter { $0.value == .valid }.map(\.key)),
                                  deleted: Set(outcome.filter { $0.value == .deleted }.map(\.key)))
        pending = next
        return envelopes
    }

    public func acknowledge() {
        if let pending { committed = pending }
        pending = nil
    }

    public func group() async throws -> SyncGroupRecord? {
        do {
            let found = try await retrying { try await self.database.fetch([SyncCloudSchema.groupRecordName], zone: self.zone) }
            return found.first.flatMap(SyncCloudSchema.group)
        } catch SyncCloudFailure.zoneNotFound {
            // No zone, no group: the first Mac's create-only save makes the zone again.
            committed.zoneReady = false
            return nil
        }
    }

    public func createGroup(_ record: SyncGroupRecord) async throws -> SyncGroupRecord {
        do {
            try await save(SyncCloudSchema.record(record), mode: .createOnly, existingIsSuccess: false)
            return record
        } catch SyncCloudFailure.serverRecordChanged {
            guard let existing = try await group() else { throw SyncCloudFailure.other("group record unreadable") }
            return existing
        }
    }

    public func publish(_ device: SyncDeviceRecord) async throws {
        guard device.device == self.device else { throw SyncError.invalidEnvelope }
        try await save(SyncCloudSchema.record(device), mode: .overwrite)
        committed.devices[device.device] = device
    }

    /// A create-only save of an immutable record that's already there succeeded earlier (a retried upload).
    private func save(_ record: SyncCloudRecord, mode: SyncSaveMode, existingIsSuccess: Bool = true) async throws {
        var recreated = false
        while true {
            do {
                let results = try await retrying { try await self.database.save([record], zone: self.zone, mode: mode) }
                switch results[record.name] {
                case .success?: return
                case .failure(.serverRecordChanged)? where existingIsSuccess && mode == .createOnly: return
                case .failure(let failure)?: throw failure
                case nil: throw SyncCloudFailure.other("no result for \(record.type)")
                }
            } catch SyncCloudFailure.zoneNotFound where !recreated {
                // Gone: recreate it and save, and tell the engine (kept until it takes the report), because everything
                // saved before is gone too.
                recreated = true
                try await retrying { try await self.database.createZone(self.zone) }
                committed.zoneReady = true
                zoneRecreated = true
            }
        }
    }

    /// Retries transient failures with backoff; everything else goes to the caller at once. Before every attempt
    /// (the first, and each after a sleep): the session must still be live, and (`checkAccount`) the Apple Account the
    /// bound one, so nothing reaches an account the session didn't start with.
    private func retrying<T: Sendable>(checkAccount: Bool = true, _ body: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            try live()
            if checkAccount { try await verifyAccount() }
            do { return try await body() }
            catch let failure as SyncCloudFailure {
                guard case .network(let after) = failure, attempt < backoff.count else { throw failure }
                await sleep(max(backoff[attempt], after ?? 0))
                attempt += 1
            }
        }
    }
}

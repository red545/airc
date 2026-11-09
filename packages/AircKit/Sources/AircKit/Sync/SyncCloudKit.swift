// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import Security
@preconcurrency import CloudKit

/// What this process is entitled to. CloudKit raises an Objective-C exception (the app quits) when a container is
/// created without the iCloud entitlement, so nothing may create one unless `container` is non-nil. Dev builds are
/// ad hoc signed without it; release builds have it once the provisioning profile exists (docs/release.md).
public enum SyncCapability {
    /// The CloudKit container this build may use, from its own signature's entitlements.
    public static var container: String? {
        guard let services = entitlement("com.apple.developer.icloud-services") as? [String], services.contains("CloudKit"),
              let containers = entitlement("com.apple.developer.icloud-container-identifiers") as? [String] else { return nil }
        return containers.first
    }

    /// The Keychain access group for the synchronizable group key (`<team>.<bundle id>`).
    public static var keychainAccessGroup: String? {
        (entitlement("keychain-access-groups") as? [String])?.first { !$0.hasSuffix(".*") }
    }

    /// Silent pushes need the push entitlement; without it the app fetches when it becomes active and on a timer.
    public static var receivesPushes: Bool { entitlement("com.apple.developer.aps-environment") is String }

    static func entitlement(_ name: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }
}

/// The private database of one container. Create only after `SyncCapability.container` returned it.
public final class CloudKitSyncDatabase: SyncCloudDatabase, @unchecked Sendable {
    private let container: CKContainer
    private let database: CKDatabase

    public init(container identifier: String) {
        container = CKContainer(identifier: identifier)
        database = container.privateCloudDatabase
    }

    private func zoneID(_ zone: String) -> CKRecordZone.ID { CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName) }

    public func accountStatus() async throws -> SyncCloudAccount {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .couldNotDetermine
            @unknown default: return .couldNotDetermine
            }
        } catch { throw Self.failure(error) }
    }

    public func accountIdentity() async throws -> String {
        do { return try await container.userRecordID().recordName } catch { throw Self.failure(error) }
    }

    public func createZone(_ zone: String) async throws {
        do {
            let result = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID(zone))], deleting: [])
            if case .failure(let error)? = result.saveResults[zoneID(zone)] { throw error }
        } catch { throw Self.failure(error) }
    }

    public func fetchChanges(zone: String, since token: Data?) async throws -> SyncCloudChanges {
        let previous = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        do {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID(zone), since: previous)
            var changed: [SyncCloudRecord] = []
            var failed: [String: SyncCloudFailure] = [:]
            for (id, outcome) in result.modificationResultsByID {
                switch outcome {
                case .success(let modification): if let record = Self.record(modification.record) { changed.append(record) }
                case .failure(let error): failed[id.recordName] = Self.failure(error)
                }
            }
            let data = try NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true)
            return SyncCloudChanges(changed: changed, deleted: result.deletions.map(\.recordID.recordName), token: data,
                                    moreComing: result.moreComing, failed: failed)
        } catch { throw Self.failure(error) }
    }

    public func save(_ records: [SyncCloudRecord], zone: String, mode: SyncSaveMode) async throws -> [String: Result<SyncCloudRecord, SyncCloudFailure>] {
        let cloud = records.map { Self.record($0, zone: zoneID(zone)) }
        do {
            let result = try await database.modifyRecords(saving: cloud, deleting: [],
                                                          savePolicy: mode == .createOnly ? .ifServerRecordUnchanged : .allKeys,
                                                          atomically: false)
            var outcomes: [String: Result<SyncCloudRecord, SyncCloudFailure>] = [:]
            for (id, outcome) in result.saveResults {
                switch outcome {
                case .success(let saved): outcomes[id.recordName] = Self.record(saved).map { .success($0) } ?? .failure(.other("unreadable record"))
                case .failure(let error): outcomes[id.recordName] = .failure(Self.failure(error))
                }
            }
            return outcomes
        } catch { throw Self.failure(error) }
    }

    public func fetch(_ names: [String], zone: String) async throws -> [SyncCloudRecord] {
        do {
            let result = try await database.records(for: names.map { CKRecord.ID(recordName: $0, zoneID: zoneID(zone)) })
            var found: [SyncCloudRecord] = []
            for (_, outcome) in result {
                switch outcome {
                case .success(let record): if let r = Self.record(record) { found.append(r) }
                case .failure(let error):
                    let failure = Self.failure(error)
                    if failure != .notFound { throw failure }
                }
            }
            return found
        } catch let failure as SyncCloudFailure { throw failure } catch { throw Self.failure(error) }
    }

    public func subscribe(zone: String, id: String) async throws {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID(zone), subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent: the app fetches, nothing is shown
        subscription.notificationInfo = info
        do { _ = try await database.save(subscription) } catch { throw Self.failure(error) }
    }

    /// The real-iCloud test's cleanup only (its own zone, never `AircSidebar`): the zone with all its records, and
    /// its subscription.
    public func deleteTestZone(_ zone: String, subscription: String) async throws {
        guard zone != SyncCloudSchema.zone, zone.hasPrefix("AircSidebarTest") else { throw SyncCloudFailure.other("not a test zone") }
        do { _ = try await database.deleteSubscription(withID: subscription) } catch let error as CKError where error.code == .unknownItem {}
        catch { throw Self.failure(error) }
        do {
            let result = try await database.modifyRecordZones(saving: [], deleting: [zoneID(zone)])
            if case .failure(let error)? = result.deleteResults[zoneID(zone)] { throw error }
        } catch let error as CKError where error.code == .zoneNotFound {} catch { throw Self.failure(error) }
    }

    /// The real-iCloud test's cleanup check: whether a subscription with this ID still exists.
    public func hasSubscription(_ id: String) async throws -> Bool {
        do { _ = try await database.subscription(for: id); return true }
        catch let error as CKError where error.code == .unknownItem { return false }
        catch { throw Self.failure(error) }
    }

    // MARK: Mapping

    static func record(_ record: SyncCloudRecord, zone: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: record.type, recordID: CKRecord.ID(recordName: record.name, zoneID: zone))
        for (key, value) in record.fields {
            switch value {
            case .string(let s): r[key] = s as NSString
            case .int(let i): r[key] = NSNumber(value: i)
            case .bytes(let d): r[key] = d as NSData
            case .date(let d): r[key] = d as NSDate
            }
        }
        return r
    }

    static func record(_ record: CKRecord) -> SyncCloudRecord? {
        var fields: [String: SyncCloudValue] = [:]
        for key in record.allKeys() {
            switch record[key] {
            case let s as String: fields[key] = .string(s)
            case let d as Data: fields[key] = .bytes(d)
            case let d as Date: fields[key] = .date(d)
            case let n as NSNumber: fields[key] = .int(n.int64Value)
            default: break
            }
        }
        return SyncCloudRecord(name: record.recordID.recordName, type: record.recordType, fields: fields)
    }

    /// CKError → what the transport and the Sync page act on.
    public static func failure(_ error: Error) -> SyncCloudFailure {
        if let failure = error as? SyncCloudFailure { return failure }
        guard let ck = error as? CKError else { return .other(String(describing: type(of: error))) }
        switch ck.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy,
             .serverResponseLost, .accountTemporarilyUnavailable:
            return .network(retryAfter: ck.retryAfterSeconds)
        case .notAuthenticated: return .notSignedIn
        case .managedAccountRestricted: return .restricted
        case .quotaExceeded: return .quotaExceeded
        case .zoneNotFound: return .zoneNotFound
        case .userDeletedZone: return .userDeletedZone
        case .changeTokenExpired: return .changeTokenExpired
        case .serverRecordChanged: return .serverRecordChanged
        case .unknownItem: return .notFound
        case .missingEntitlement, .permissionFailure, .badContainer: return .missingEntitlement
        case .limitExceeded: return .limitExceeded
        case .partialFailure:
            let parts = (ck.partialErrorsByItemID ?? [:]).values.map(failure)
            for decisive in [SyncCloudFailure.userDeletedZone, .zoneNotFound, .quotaExceeded, .notSignedIn] where parts.contains(decisive) {
                return decisive
            }
            return parts.first { $0.isTransient } ?? parts.first ?? .other("partial failure")
        default: return .other("CKError \(ck.code.rawValue)")
        }
    }
}

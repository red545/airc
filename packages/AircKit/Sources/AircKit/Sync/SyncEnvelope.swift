// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

/// Only ciphertext crosses a transport. Version, group, author and batch ID are authenticated as AAD.
///
/// Version 2 is a batch that changes a note's pinned row (docs/sync.md, "Notes"): the same operations, but builds from
/// before notes synced can't open it, so they keep it unread in their quarantine (and apply it once updated) instead of
/// making note rows they have no note for.
///
/// Version 3 is a batch that touches a pinned or Favorite split or one of its panes (SplitSyncPayload.swift): builds from
/// before splits synced keep it unread the same way, instead of making split rows they don't understand. A version 3
/// reader reads versions 1 and 2 as before.
public struct SyncEnvelope: Codable, Hashable, Sendable {
    public let version: Int
    public let group: UUID
    public let device: UUID
    public let id: UUID
    public let sealed: Data

    public static func newGroupKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    private var authentication: Data {
        Data("Airc-sidebar-sync|\(version)|\(group.uuidString)|\(device.uuidString)|\(id.uuidString)".utf8)
    }

    public static let versions = 1...3

    public static func seal(_ operations: [SyncOperation], group: UUID, device: UUID,
                            key: SymmetricKey, version: Int = 1) throws -> Self {
        guard !operations.isEmpty, operations.allSatisfy({ $0.stamp.device == device }) else {
            throw SyncError.invalidEnvelope
        }
        for op in operations { try op.validate() }
        guard Self.versions.contains(version) else { throw SyncError.unsupportedVersion }
        let header = Self(version: version, group: group, device: device, id: UUID(), sealed: Data())
        let box = try AES.GCM.seal(JSONEncoder().encode(operations), using: key, authenticating: header.authentication)
        guard let combined = box.combined else { throw SyncError.invalidEnvelope }
        return Self(version: header.version, group: group, device: device, id: header.id, sealed: combined)
    }

    /// `accepting`: the versions this build reads; tests pass an older build's range.
    public func open(group expected: UUID, key: SymmetricKey, accepting: ClosedRange<Int> = Self.versions) throws -> [SyncOperation] {
        guard accepting.contains(version) else { throw SyncError.unsupportedVersion }
        guard group == expected else { throw SyncError.wrongGroup }
        let box = try AES.GCM.SealedBox(combined: sealed)
        let data = try AES.GCM.open(box, using: key, authenticating: authentication)
        let operations = try JSONDecoder().decode([SyncOperation].self, from: data)
        guard !operations.isEmpty, operations.allSatisfy({ $0.stamp.device == device }) else {
            throw SyncError.invalidEnvelope
        }
        for op in operations { try op.validate() }
        return operations
    }
}

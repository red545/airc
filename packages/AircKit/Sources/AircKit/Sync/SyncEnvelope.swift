// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

/// Only ciphertext crosses a transport. Version, group, author and batch ID are authenticated as AAD.
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

    public static func seal(_ operations: [SyncOperation], group: UUID, device: UUID,
                            key: SymmetricKey) throws -> Self {
        guard !operations.isEmpty, operations.allSatisfy({ $0.stamp.device == device }) else {
            throw SyncError.invalidEnvelope
        }
        for op in operations { try op.validate() }
        let header = Self(version: 1, group: group, device: device, id: UUID(), sealed: Data())
        let box = try AES.GCM.seal(JSONEncoder().encode(operations), using: key, authenticating: header.authentication)
        guard let combined = box.combined else { throw SyncError.invalidEnvelope }
        return Self(version: header.version, group: group, device: device, id: header.id, sealed: combined)
    }

    public func open(group expected: UUID, key: SymmetricKey) throws -> [SyncOperation] {
        guard version == 1 else { throw SyncError.unsupportedVersion }
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

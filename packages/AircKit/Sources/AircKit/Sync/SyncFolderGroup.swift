// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// The encrypted folder transport as a sync group: `group.json` and `devices/<uuid>.json` beside the batch streams.
/// Reachable only behind the test builds' `--sync-folder` switch (docs/sync.md); every read returns everything, so
/// there is no checkpoint and no zone to lose.
extension FolderSyncTransport: SyncGroupTransport {
    private var groupFile: URL { folder.appendingPathComponent("group.json") }
    private var deviceFolder: URL { folder.appendingPathComponent("devices", isDirectory: true) }

    public func prepare() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    public func accountIdentity() -> String? { nil }

    public func group() throws -> SyncGroupRecord? {
        guard let data = try? Data(contentsOf: groupFile) else { return nil }
        return try JSONDecoder().decode(SyncGroupRecord.self, from: data)
    }

    public func createGroup(_ record: SyncGroupRecord) throws -> SyncGroupRecord {
        do {
            try JSONEncoder().encode(record).write(to: groupFile, options: .withoutOverwriting)
            return record
        } catch CocoaError.fileWriteFileExists {
            return try group() ?? record
        }
    }

    public func publish(_ device: SyncDeviceRecord) throws {
        guard device.device == self.device else { throw SyncError.invalidEnvelope }
        try FileManager.default.createDirectory(at: deviceFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(device).write(to: deviceFolder.appendingPathComponent(device.device.uuidString + ".json"), options: .atomic)
    }

    public var devices: [SyncDeviceRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: deviceFolder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard let d = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(SyncDeviceRecord.self, from: $0) }),
                  file.lastPathComponent == d.device.uuidString + ".json" else { return nil }
            return d
        }.sorted { $0.device.uuidString < $1.device.uuidString }
    }

    /// Test-only transport: no session to end, no account.
    nonisolated public func cancel() {}
    public func bind(account: String) {}
    public func verifyAccount() {}

    public func acknowledge() {}
    public var checkpoint: Data? { nil }
    public func restore(checkpoint: Data?) {}
    /// Every read is full; `own` is this device's batches in the folder.
    public func takeReadReport() -> SyncReadReport {
        SyncReadReport(full: true, own: Set(((try? read()) ?? []).filter { $0.device == device }.map(\.id)))
    }
}

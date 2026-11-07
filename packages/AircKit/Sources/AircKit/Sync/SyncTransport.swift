// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// At-least-once delivery; callers decrypt, validate and merge before advancing their durable checkpoint.
public protocol SyncTransport: Sendable {
    func append(_ envelope: SyncEnvelope) async throws
    func read() async throws -> [SyncEnvelope]
}

public actor InMemorySyncTransport: SyncTransport {
    private var envelopes: [SyncEnvelope] = []
    public init() {}
    public func append(_ envelope: SyncEnvelope) { envelopes.append(envelope) }
    public func read() -> [SyncEnvelope] { envelopes }
}

/// One immutable segment file per append, within a device's append-only stream. A fresh writer UUID per
/// instance avoids two processes or restored installations ever overwriting an existing segment.
/// Files appear as .partial first and are atomically renamed to .jsonl after fsync. Readers also tolerate
/// a provider exposing a truncated final line. No shared manifest, byte-offset checkpoint or file rewrites.
public actor FolderSyncTransport: SyncTransport {
    public let folder: URL
    public let device: UUID
    private let writer = UUID()

    public init(folder: URL, device: UUID) throws {
        self.folder = folder; self.device = device
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public func append(_ envelope: SyncEnvelope) throws {
        guard envelope.device == device else { throw SyncError.invalidEnvelope }
        let directory = folder.appendingPathComponent(device.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = writer.uuidString + "-" + UUID().uuidString
        let partial = directory.appendingPathComponent(base + ".partial")
        let final = directory.appendingPathComponent(base + ".jsonl")
        var bytes = try JSONEncoder().encode(envelope)
        bytes.append(0x0a)
        try bytes.write(to: partial, options: [.withoutOverwriting])
        let handle = try FileHandle(forWritingTo: partial)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try FileManager.default.moveItem(at: partial, to: final)
    }

    public func read() throws -> [SyncEnvelope] {
        let fm = FileManager.default
        var result: [SyncEnvelope] = []
        for directory in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isDirectory == true, properties.isSymbolicLink != true,
                  let author = UUID(uuidString: directory.lastPathComponent) else { continue }
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) where file.pathExtension == "jsonl" {
                let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true else { continue }
                let bytes = try Data(contentsOf: file)
                // Retry partial final lines on the next scan; never permanently checkpoint their offsets.
                var start = bytes.startIndex
                for end in bytes.indices where bytes[end] == 0x0a {
                    let envelope = try JSONDecoder().decode(SyncEnvelope.self, from: bytes[start..<end])
                    guard envelope.device == author else { throw SyncError.invalidEnvelope }
                    result.append(envelope)
                    start = end + 1
                }
            }
        }
        return result.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
import CryptoKit
@testable import AircKit

final class SyncTransportTests: XCTestCase, @unchecked Sendable {
    func testEnvelopeRoundtripTamperingWrongKeyAndGroup() throws {
        var replica = SyncReplica()
        try replica.edit(.init(.space, "work"), [.name: .text("Work")], now: 1)
        let key = SyncEnvelope.newGroupKey(), group = UUID()
        let envelope = try SyncEnvelope.seal(replica.log, group: group, device: replica.clock.device, key: key)
        XCTAssertEqual(try envelope.open(group: group, key: key), replica.log)
        XCTAssertThrowsError(try envelope.open(group: UUID(), key: key))
        XCTAssertThrowsError(try envelope.open(group: group, key: SyncEnvelope.newGroupKey()))
        var bytes = envelope.sealed
        bytes[bytes.count / 2] ^= 1
        let tampered = SyncEnvelope(version: 1, group: group, device: envelope.device, id: envelope.id, sealed: bytes)
        XCTAssertThrowsError(try tampered.open(group: group, key: key))
        let swapped = SyncEnvelope(version: 1, group: group, device: envelope.device, id: UUID(), sealed: envelope.sealed)
        XCTAssertThrowsError(try swapped.open(group: group, key: key))
        let wrongAuthor = SyncEnvelope(version: 1, group: group, device: UUID(), id: envelope.id, sealed: envelope.sealed)
        XCTAssertThrowsError(try wrongAuthor.open(group: group, key: key))
    }

    func testFolderPartialFilesRetryAndSeparateWriters() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sync-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var a = SyncReplica(), b = SyncReplica()
        try a.edit(.init(.space, "work"), [.name: .text("Work")], now: 1)
        try b.edit(.init(.space, "home"), [.name: .text("Home")], now: 1)
        let group = UUID(), key = SyncEnvelope.newGroupKey()
        let ea = try SyncEnvelope.seal(a.log, group: group, device: a.clock.device, key: key)
        let eb = try SyncEnvelope.seal(b.log, group: group, device: b.clock.device, key: key)
        let ta = try FolderSyncTransport(folder: root, device: a.clock.device)
        let tb = try FolderSyncTransport(folder: root, device: b.clock.device)
        try await ta.append(ea); try await tb.append(eb)
        let first = try await ta.read()
        XCTAssertEqual(Set(first), Set([ea, eb]))
        let directory = root.appendingPathComponent(a.clock.device.uuidString)
        let pending = directory.appendingPathComponent("interrupted.partial")
        try Data("{\"sealed\":".utf8).write(to: pending)
        let half = directory.appendingPathComponent("provider.jsonl")
        var complete = try JSONEncoder().encode(ea); complete.append(0x0a)
        try complete.prefix(complete.count / 2).write(to: half)
        let duringPartial = try await ta.read()
        XCTAssertEqual(Set(duringPartial), Set([ea, eb]))
        try complete.write(to: half)
        let afterComplete = try await tb.read()
        XCTAssertEqual(afterComplete.count, 3)
        var merged = SyncReplica()
        for e in afterComplete { try merged.receive(e.open(group: group, key: key), now: 2) }
        XCTAssertEqual(merged.log.count, 2)
        // A valid line followed by a half line is delivered; the tail is retried, never discarded.
        try (complete + complete.prefix(30)).write(to: half)
        let prefix = try await ta.read()
        XCTAssertEqual(prefix.count, 3)
        // Complete corrupt records fail visibly, rather than silently losing edits.
        try Data("invalid\n".utf8).write(to: half)
        do { _ = try await ta.read(); XCTFail("must reject complete corrupt record") } catch {}
        do { try await ta.append(eb); XCTFail("must reject foreign writer") } catch {}
    }

    func testInMemoryTransportRedelivery() async throws {
        let transport = InMemorySyncTransport()
        var replica = SyncReplica()
        try replica.edit(.init(.space, "work"), [.name: .text("Work")], now: 1)
        let group = UUID(), key = SyncEnvelope.newGroupKey()
        let envelope = try SyncEnvelope.seal(replica.log, group: group, device: replica.clock.device, key: key)
        await transport.append(envelope); await transport.append(envelope)
        var receiver = SyncReplica()
        for e in await transport.read() { try receiver.receive(e.open(group: group, key: key), now: 2) }
        XCTAssertEqual(receiver.log, replica.log)
    }
}

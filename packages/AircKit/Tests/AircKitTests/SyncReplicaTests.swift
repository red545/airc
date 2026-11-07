// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

private struct SyncRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

final class SyncReplicaTests: XCTestCase {
    func testRandomizedConcurrentEditsConvergeInAnyDeliveryOrder() throws {
        for seed in 1...24 {
            var rng = SyncRandom(state: UInt64(seed))
            var devices = (0..<(2 + seed % 2)).map { _ in SyncReplica() }
            let space = SyncRecordID(.space, "work")
            let initial = try devices[0].edit(space, [.name: .text("Work"), .profile: .text("profile")], now: 100)
            for i in 1..<devices.count { try devices[i].receive([initial], now: 99) }
            for step in 0..<120 {
                let i = Int(rng.next() % UInt64(devices.count))
                let row = SyncRecordID(.row, "row-\(rng.next() % 12)")
                let fields: [SyncField: SyncValue]
                switch rng.next() % 6 {
                case 0: fields = [.title: .text(step % 2 == 0 ? "Work" : "Home")]
                case 1: fields = [.location: .location(step % 2 == 0 ? .pinned(space: "work") : .archived)]
                case 2: fields = [.deleted: .flag(step % 3 == 0)]
                case 3: fields = [.parent: .text("row-\(rng.next() % 12)"), .kind: .text("folder")]
                case 4: fields = [.order: .order(try SyncOrder.between(nil, nil))]
                default: fields = [.url: .text("https://example.com"), .kind: .text("tab")]
                }
                try devices[i].edit(row, fields, now: Int64(100 + step % 17)) // skew and rollback
                if step % 11 == 0 {
                    let j = (i + 1) % devices.count
                    try devices[j].receive(devices[i].log.shuffled(using: &rng), now: 90)
                }
            }
            let union = devices.flatMap(\.log)
            for i in devices.indices {
                try devices[i].receive(union.shuffled(using: &rng), now: 100)
                try devices[i].receive(union.reversed(), now: 1)
            }
            for device in devices.dropFirst() {
                XCTAssertEqual(device.records, devices[0].records, "seed \(seed)")
                XCTAssertEqual(device.sidebar, devices[0].sidebar)
                XCTAssertEqual(device.log, devices[0].log)
            }
        }
    }

    func testHybridClockSurvivesRollbackRemoteFutureAndPersistence() throws {
        var clock = SyncClock()
        let first = try clock.tick(now: 500)
        let second = try clock.tick(now: 20)
        XCTAssertLessThan(first, second)
        let future = SyncStamp(milliseconds: 800, counter: 50, device: UUID())
        let third = try clock.tick(now: 10, observing: future)
        XCTAssertLessThan(future, third)
        var restored = try JSONDecoder().decode(SyncClock.self, from: JSONEncoder().encode(clock))
        XCTAssertLessThan(third, try restored.tick(now: 0))
    }

    func testIdempotencePerFieldAndConflictingIDRejection() throws {
        var a = SyncReplica(), b = SyncReplica()
        let id = SyncRecordID(.space, "work")
        let name = try a.edit(id, [.name: .text("Work")], now: 10)
        let profile = try b.edit(id, [.profile: .text("home")], now: 10)
        try a.receive([profile, name, profile], now: 10)
        let before = try JSONEncoder().encode(a.clock)
        try a.receive([profile, name], now: 50)
        XCTAssertEqual(a.log.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(SyncClock.self, from: before).counter, a.clock.counter)
        XCTAssertEqual(a.records[id]?[.name], .text("Work"))
        XCTAssertEqual(a.records[id]?[.profile], .text("home"))
        let corrupt = SyncOperation(id: name.id, stamp: name.stamp, record: id, fields: [.name: .text("Home")])
        XCTAssertThrowsError(try a.receive([corrupt], now: 50))
        XCTAssertEqual(a.records[id]?[.name], .text("Work"))
    }

    func testFolderDeleteConcurrentWithChildAddRootsChild() throws {
        var a = SyncReplica(), b = SyncReplica()
        try a.edit(.init(.space, "work"), [.name: .text("Work")], now: 1)
        try a.edit(.init(.row, "folder"), [.kind: .text("folder"), .location: .location(.pinned(space: "work"))], now: 2)
        try b.receive(a.log, now: 2)
        try a.edit(.init(.row, "folder"), [.deleted: .flag(true)], now: 3)
        try b.edit(.init(.row, "tab"), [.kind: .text("tab"), .parent: .text("folder"),
                                      .location: .location(.pinned(space: "work")), .url: .text("https://example.com")], now: 3)
        let log = a.log + b.log
        try a.receive(log.reversed(), now: 4); try b.receive(log, now: 4)
        XCTAssertEqual(a.sidebar, b.sidebar)
        XCTAssertEqual(a.sidebar.first { $0.id.id == "tab" }?[.parent], .null)
        XCTAssertEqual(a.records[.init(.row, "tab")]?[.parent], .text("folder"))
        XCTAssertFalse(a.sidebar.contains { $0.id.id == "folder" })
    }

    func testPinVersusArchiveHasOneLWWLifecycle() throws {
        var a = SyncReplica(), b = SyncReplica()
        try a.edit(.init(.space, "work"), [.name: .text("Work")], now: 1)
        try b.receive(a.log, now: 1)
        let id = SyncRecordID(.row, "tab")
        let pin = try a.edit(id, [.location: .location(.pinned(space: "work"))], now: 2)
        let archive = try b.edit(id, [.location: .location(.archived)], now: 2)
        try a.receive([archive], now: 2); try b.receive([pin], now: 2)
        XCTAssertEqual(a.records, b.records)
        XCTAssertEqual(a.records[id]?[.location], pin.stamp < archive.stamp ? .location(.archived) : .location(.pinned(space: "work")))
        // A later intentional pin wins; archived URL/title payloads are never required.
        try a.edit(id, [.location: .location(.pinned(space: "work"))], now: 2)
        try b.receive(a.log, now: 2)
        XCTAssertEqual(a.sidebar, b.sidebar)
        XCTAssertTrue(a.sidebar.contains { $0.id == id })
    }

    func testConcurrentSpaceReordersAndDenseInsertion() throws {
        var a = SyncReplica(), b = SyncReplica()
        var keys: [SyncOrder] = []
        for id in ["work", "home", "third"] {
            let key = try SyncOrder.between(keys.last, nil)
            keys.append(key)
            try a.edit(.init(.space, id), [.name: .text("Work"), .order: .order(key)], now: 1)
        }
        try b.receive(a.log, now: 1)
        try a.edit(.init(.space, "third"), [.order: .order(try SyncOrder.between(nil, keys[0]))], now: 2)
        try b.edit(.init(.space, "home"), [.order: .order(try SyncOrder.between(nil, keys[0]))], now: 2)
        let log = a.log + b.log
        try a.receive(log, now: 3); try b.receive(log.reversed(), now: 3)
        XCTAssertEqual(a.sidebar, b.sidebar)
        XCTAssertEqual(Set(a.sidebar.compactMap(\.order)).count, 3)
        var upper = keys[1]
        for _ in 0..<2000 {
            let middle = try SyncOrder.between(keys[0], upper)
            XCTAssertLessThan(keys[0], middle); XCTAssertLessThan(middle, upper)
            upper = middle
        }
    }

    func testMissingProfileIsUnresolvedAndCyclesAreRooted() throws {
        var replica = SyncReplica()
        try replica.edit(.init(.space, "work"), [.profile: .text("remote-profile")], now: 1)
        XCTAssertNil(replica.resolvedProfile(for: "work", localProfiles: ["local-profile"]))
        XCTAssertEqual(replica.resolvedProfile(for: "work", localProfiles: ["remote-profile"]), "remote-profile")
        for (id, parent) in [("a", "b"), ("b", "a")] {
            try replica.edit(.init(.row, id), [.kind: .text("folder"), .parent: .text(parent), .location: .location(.pinned(space: "work"))], now: 2)
        }
        XCTAssertTrue(replica.sidebar.filter { $0.id.kind == .row }.allSatisfy { $0[.parent] == .null })
    }

    func testTombstoneSurvivesLateEditsAndExplicitRestore() throws {
        var a = SyncReplica(), b = SyncReplica()
        let id = SyncRecordID(.space, "work")
        try a.edit(id, [.name: .text("Work")], now: 1)
        try b.receive(a.log, now: 1)
        try a.edit(id, [.deleted: .flag(true)], now: 2)
        try b.edit(id, [.name: .text("Home")], now: 3)
        try a.receive(b.log, now: 3)
        XCTAssertTrue(a.sidebar.isEmpty)
        try a.edit(id, [.deleted: .flag(false)], now: 4)
        XCTAssertEqual(a.sidebar.first?[.name], .text("Home"))
        let restored = try JSONDecoder().decode(SyncReplica.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(restored.records, a.records)
        XCTAssertEqual(restored.log, a.log)
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// A store in memory with a controllable clock.
final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ s: TimeInterval) { date = date.addingTimeInterval(s) }
}

func makeStore(_ clock: TestClock = TestClock()) throws -> SpacesStore {
    let s = try SpacesStore(path: nil)
    s.now = { clock.date }
    return s
}

final class StoreBasicsTests: XCTestCase {
    func testFreshStoreHasDefaultProfileAndOneSpace() throws {
        let s = try makeStore()
        XCTAssertEqual(s.state.profiles.count, 1)
        XCTAssertTrue(s.defaultProfile.isDefault)
        XCTAssertEqual(s.defaultProfile.engineDirectory, "Default")
        XCTAssertEqual(s.orderedSpaces.count, 1)
        XCTAssertEqual(s.selectedSpace.profileID, s.defaultProfile.id)
    }

    func testPersistsAcrossReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var spaceID = ""
        var tabID = ""
        do {
            let s = try SpacesStore(path: path)
            let p = try s.createProfile(name: "Work", emoji: "💼")
            let sp = try s.createSpace(name: "Work", icon: .emoji("💼"), theme: .single("7EB6D5"), profileID: p.id)
            spaceID = sp.id
            tabID = try s.openTab(url: "https://example.com", inSpace: sp.id).id
            s.updateTab(tabID, title: "Example")
            try s.flush()
            s.selectSpace(sp.id)
        }
        let s2 = try SpacesStore(path: path)
        XCTAssertEqual(s2.orderedSpaces.count, 2)
        XCTAssertEqual(s2.space(spaceID)?.icon, .emoji("💼"))
        XCTAssertEqual(s2.profile(ofSpace: spaceID).name, "Work")
        XCTAssertEqual(s2.tab(tabID)?.title, "Example")
        XCTAssertEqual(s2.windowState.selectedSpaceID, spaceID)
        XCTAssertEqual(s2.lastActiveTab(ofSpace: spaceID)?.id, tabID)
    }

    func testOperationLogRecordsEveryChangeWithDevice() throws {
        let s = try makeStore()
        let before = try s.operations().count
        let sp = try s.createSpace(name: "A")
        try s.deleteSpace(sp.id)
        let ops = try s.operations().dropFirst(before)
        XCTAssertEqual(ops.map(\.op), ["put", "delete"])
        XCTAssertTrue(ops.allSatisfy { $0.device == s.deviceID && $0.kind == .space && $0.id == sp.id })
    }

    func testDeferredWritesWaitForFlush() throws {
        let s = try makeStore()
        let t = try s.openTab(url: "https://a.com", inSpace: s.selectedSpace.id)
        let n = try s.operations().count
        s.updateTab(t.id, title: "A")
        XCTAssertEqual(try s.operations().count, n)
        XCTAssertTrue(s.hasPendingWrites)
        try s.flush()
        XCTAssertEqual(try s.operations().count, n + 1)
    }

    func testFailedTransactionRollsBack() throws {
        let s = try makeStore()
        let count = s.state.spaces.count
        XCTAssertThrowsError(try s.perform(nil) {
            s.put(Space(name: "Ghost", profileID: s.defaultProfile.id))
            throw StoreError.invalidMove
        })
        XCTAssertEqual(s.state.spaces.count, count)
    }

    func testObserversSeeChangedKinds() throws {
        let s = try makeStore()
        var kinds: [Set<EntityKind>] = []
        s.observe { kinds.append($0.kinds) }
        _ = try s.openTab(url: "https://a.com", inSpace: s.selectedSpace.id)
        XCTAssertEqual(kinds.last, [.tab, .space])
    }

    func testDailyBackupWritesOncePerDayAndPrunes() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-bk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNotNil(try s.backupIfNeeded(to: dir, keep: 3))
        XCTAssertNil(try s.backupIfNeeded(to: dir, keep: 3))
        for _ in 0..<5 {
            clock.advance(86400)
            try s.backupIfNeeded(to: dir, keep: 3)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 3)
        // A backup restores into a fresh store.
        let data = try Data(contentsOf: dir.appendingPathComponent(files.sorted().last!))
        let s2 = try makeStore()
        try s2.restore(fromBackup: data)
        XCTAssertEqual(Set(s2.state.spaces.keys), Set(s.state.spaces.keys))
    }

    func testRepairMovesSpacesOffMissingProfile() throws {
        let s = try makeStore()
        let p = try s.createProfile(name: "Gone")
        let sp = try s.createSpace(name: "X", profileID: p.id)
        try s.perform(nil) { s.remove(Profile.self, p.id) }
        let data = try s.exportJSON()
        let s2 = try makeStore()
        try s2.restore(fromBackup: data)
        XCTAssertEqual(s2.space(sp.id)?.profileID, s2.defaultProfile.id)
    }

    func testCompactingKeepsLatestOpPerEntity() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let t = try s.openTab(url: "https://a.com", inSpace: s.selectedSpace.id)
        for i in 0..<5 { s.updateTab(t.id, title: "T\(i)"); try s.flush() }
        clock.advance(40 * 86400)
        try s.compactOperations(olderThan: 30 * 86400)
        XCTAssertEqual(try s.operations().filter { $0.id == t.id }.count, 1)
    }
}

final class ProfileTests: XCTestCase {
    func testProfileNamesAreUniqueAndValidated() throws {
        let s = try makeStore()
        _ = try s.createProfile(name: "Work")
        XCTAssertThrowsError(try s.createProfile(name: " work ")) { XCTAssertEqual($0 as? StoreError, .profileNameTaken) }
        XCTAssertThrowsError(try s.createProfile(name: "  ")) { XCTAssertEqual($0 as? StoreError, .invalidProfileName) }
        XCTAssertEqual(s.validateProfileName(String(repeating: "x", count: 41)), .tooLong)
        XCTAssertNil(s.validateProfileName("Client"))
    }

    func testEachProfileGetsItsOwnEngineDirectory() throws {
        let s = try makeStore()
        let a = try s.createProfile(name: "A")
        let b = try s.createProfile(name: "B")
        XCTAssertNotEqual(a.engineDirectory, b.engineDirectory)
        XCTAssertNotEqual(a.engineDirectory, "Default")
    }

    func testDeleteRules() throws {
        let s = try makeStore()
        XCTAssertThrowsError(try s.deleteProfile(s.defaultProfile.id)) {
            XCTAssertEqual($0 as? StoreError, .cannotDeleteDefaultProfile)
        }
        let p = try s.createProfile(name: "Work")
        let sp = try s.createSpace(name: "Work", profileID: p.id)
        XCTAssertThrowsError(try s.deleteProfile(p.id)) { XCTAssertEqual($0 as? StoreError, .profileInUse) }
        try s.setProfile(ofSpace: sp.id, to: s.defaultProfile.id)
        try s.deleteProfile(p.id)
        XCTAssertNil(s.profile(p.id))
    }

    func testFavoritesBelongToTheProfile() throws {
        let s = try makeStore()
        let work = try s.createProfile(name: "Work")
        let a = try s.createSpace(name: "A")
        let b = try s.createSpace(name: "B")
        let c = try s.createSpace(name: "C", profileID: work.id)
        let t = try s.openTab(url: "https://mail.google.com/mail/", inSpace: a.id)
        try s.move(.tab(t.id), to: .favorites(profileID: s.defaultProfile.id, index: 0))
        // Same profile: same tile in both Spaces. Other profile: none.
        XCTAssertEqual(s.favorites(ofProfile: s.profile(ofSpace: a.id).id).count, 1)
        XCTAssertEqual(s.favorites(ofProfile: s.profile(ofSpace: b.id).id).count, 1)
        XCTAssertEqual(s.favorites(ofProfile: s.profile(ofSpace: c.id).id).count, 0)
        // The favorite's tab is shared by the profile, not tied to a Space.
        XCTAssertNil(s.tab(t.id)?.spaceID)
        XCTAssertEqual(s.lastActiveTab(ofSpace: a.id)?.id, t.id)
    }

    func testChangingASpacesProfileReloadsItsTabs() throws {
        let s = try makeStore()
        let work = try s.createProfile(name: "Work")
        let sp = s.selectedSpace
        let t1 = try s.openTab(url: "https://a.com", inSpace: sp.id)
        let t2 = try s.openTab(url: "https://b.com", inSpace: sp.id)
        try s.move(.tab(t2.id), to: .pinned(spaceID: sp.id, parentID: nil, index: 0))
        let reload = try s.setProfile(ofSpace: sp.id, to: work.id)
        XCTAssertEqual(Set(reload), [t1.id, t2.id])
        XCTAssertEqual(s.tab(t1.id)?.profileID, work.id)
        XCTAssertEqual(s.pinnedRoots(ofSpace: sp.id).count, 1, "sidebar items stay")
    }
}

final class SpaceTests: XCTestCase {
    func testNewSpaceGoesNextToTheActiveOne() throws {
        let s = try makeStore()
        let first = s.selectedSpace
        let b = try s.createSpace(name: "B")
        let c = try s.createSpace(name: "C", after: first.id)
        XCTAssertEqual(s.orderedSpaces.map(\.id), [first.id, c.id, b.id])
    }

    func testEmptyNameGetsANumber() throws {
        let s = try makeStore()
        XCTAssertEqual(try s.createSpace(name: "  ").name, "Space 2")
    }

    func testMoveSpace() throws {
        let s = try makeStore()
        let a = s.selectedSpace
        let b = try s.createSpace(name: "B")
        let c = try s.createSpace(name: "C")
        try s.moveSpace(c.id, to: 0)
        XCTAssertEqual(s.orderedSpaces.map(\.id), [c.id, a.id, b.id])
        try s.moveSpace(c.id, to: 2)
        XCTAssertEqual(s.orderedSpaces.map(\.id), [a.id, b.id, c.id])
    }

    func testDeleteSpaceArchivesTodayAndUndoes() throws {
        let s = try makeStore()
        let a = s.selectedSpace
        let b = try s.createSpace(name: "B")
        s.selectSpace(b.id)
        let t = try s.openTab(url: "https://a.com", inSpace: b.id)
        let pin = try s.openTab(url: "https://p.com", inSpace: b.id)
        try s.move(.tab(pin.id), to: .pinned(spaceID: b.id, parentID: nil, index: 0))
        try s.deleteSpace(b.id)
        XCTAssertNil(s.space(b.id))
        XCTAssertEqual(s.archivedEntries.first?.url, "https://a.com")
        XCTAssertEqual(s.archivedEntries.first?.reason, .spaceDeleted)
        XCTAssertEqual(s.windowState.selectedSpaceID, a.id)
        XCTAssertEqual(s.undoLabel, "Delete Space")
        try s.undo()
        XCTAssertNotNil(s.space(b.id))
        XCTAssertNotNil(s.tab(t.id))
        XCTAssertEqual(s.pinnedRoots(ofSpace: b.id).count, 1)
        XCTAssertTrue(s.archivedEntries.isEmpty)
    }

    func testLastSpaceCantBeDeleted() throws {
        let s = try makeStore()
        XCTAssertThrowsError(try s.deleteSpace(s.selectedSpace.id)) {
            XCTAssertEqual($0 as? StoreError, .cannotDeleteLastSpace)
        }
    }

    func testAdjacentSpace() throws {
        let s = try makeStore()
        let a = s.selectedSpace
        let b = try s.createSpace(name: "B")
        XCTAssertEqual(s.adjacentSpace(to: a.id, offset: 1)?.id, b.id)
        XCTAssertNil(s.adjacentSpace(to: b.id, offset: 1))
        XCTAssertNil(s.adjacentSpace(to: a.id, offset: -1))
    }
}

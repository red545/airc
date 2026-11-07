// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class SyncStoreTests: XCTestCase {
    func testStoreActionsKeepIdentityThroughPinArchiveAndUnload() throws {
        let store = try makeStore()
        let space = store.selectedSpace.id
        let tab = try store.openTab(url: "https://example.com", inSpace: space)
        var adapter = SyncStoreAdapter(includeToday: true), replica = SyncReplica()
        try adapter.capture(store.state, into: &replica, now: 1)
        let original = replica
        try store.move(.tab(tab.id), to: .pinned(spaceID: space, parentID: nil, index: 0))
        let pinOps = try adapter.capture(store.state, into: &replica, now: 2)
        let id = SyncRecordID(.row, "tab:" + tab.id)
        XCTAssertEqual(replica.records[id]?[.location], .location(.pinned(space: space)))
        XCTAssertEqual(replica.records.keys.filter { $0.kind == .row }.count, 1)
        var other = SyncReplica()
        try other.receive(original.log, now: 1)
        let archive = try other.edit(id, [.location: .location(.archived)], now: 2)
        try replica.receive([archive], now: 3); try other.receive(pinOps, now: 3)
        XCTAssertEqual(replica.records, other.records)
        // Adapter checkpoint keeps aliases after restart and unloading the pinned page.
        adapter = try JSONDecoder().decode(SyncStoreAdapter.self, from: JSONEncoder().encode(adapter))
        _ = try store.closeTab(tab.id)
        XCTAssertTrue(try adapter.capture(store.state, into: &replica, now: 4).isEmpty)
    }

    func testArchiveActionWithTodayOffStillConflictsWithPin() throws {
        let store = try makeStore()
        let tab = try store.openTab(url: "https://example.com", inSpace: store.selectedSpace.id)
        var adapter = SyncStoreAdapter(), replica = SyncReplica()
        try adapter.capture(store.state, into: &replica, now: 1)
        XCTAssertFalse(replica.records.keys.contains { $0.kind == .row })
        _ = try store.closeTab(tab.id)
        let ops = try adapter.capture(store.state, into: &replica, now: 2)
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.record, .init(.row, "tab:" + tab.id))
        XCTAssertEqual(ops.first?.fields, [.location: .location(.archived)])
    }

    func testPrivacyAllowlistAndNoNavigationHistory() throws {
        let store = try makeStore()
        let blank = try store.createBlankWindowSpace()
        _ = try store.openTab(url: "https://example.com/blank", inSpace: blank.id)
        let tab = try store.openTab(url: "https://example.com", inSpace: store.selectedSpace.id)
        var adapter = SyncStoreAdapter(includeToday: true), replica = SyncReplica()
        try adapter.capture(store.state, into: &replica, now: 1)
        store.updateTab(tab.id, url: "https://example.com/navigation", title: "Not exported")
        let changes = try adapter.capture(store.state, into: &replica, now: 2)
        XCTAssertTrue(changes.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(replica.log), as: UTF8.self)
        for forbidden in ["/blank", "/navigation", "Not exported", "engineDirectory", "googleAccount", "lastActiveAt", "faviconURL", "sourceID"] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
        XCTAssertNil(replica.records[.init(.space, blank.id)])
    }

    func testFolderFavoriteAndSpaceActionsProduceOnlyChangedFields() throws {
        let store = try makeStore()
        var adapter = SyncStoreAdapter(), replica = SyncReplica()
        let space = store.selectedSpace.id
        let folder = try store.createFolder(named: "Work", inSpace: space)
        let tab = try store.openTab(url: "https://example.com", inSpace: space)
        try adapter.capture(store.state, into: &replica, now: 1)
        try store.move(.tab(tab.id), to: .pinned(spaceID: space, parentID: folder.id, index: 0))
        try adapter.capture(store.state, into: &replica, now: 2)
        XCTAssertEqual(replica.records[.init(.row, "tab:" + tab.id)]?[.parent], .text("item:" + folder.id))
        try store.renameItem(folder.id, to: "Home")
        let edits = try adapter.capture(store.state, into: &replica, now: 3)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.fields, [.title: .text("Home")])
        try store.move(.tab(tab.id), to: .favorites(profileID: store.defaultProfile.id, index: 0))
        try adapter.capture(store.state, into: &replica, now: 4)
        XCTAssertEqual(replica.records[.init(.row, "tab:" + tab.id)]?[.location], .location(.favorites(profile: store.defaultProfile.id)))
        try store.deleteItem(folder.id)
        try adapter.capture(store.state, into: &replica, now: 5)
        XCTAssertTrue(replica.records[.init(.row, "item:" + folder.id)]!.isDeleted)
        _ = try store.undo()
        try adapter.capture(store.state, into: &replica, now: 6)
        XCTAssertFalse(replica.records[.init(.row, "item:" + folder.id)]!.isDeleted)
    }

    func testStoreReorderChangesOnlyMovedSpaceAndPreservesOrder() throws {
        let store = try makeStore()
        let work = try store.createSpace(name: "Work")
        let home = try store.createSpace(name: "Home")
        var adapter = SyncStoreAdapter(), replica = SyncReplica()
        try adapter.capture(store.state, into: &replica, now: 1)
        try store.moveSpace(home.id, to: 0)
        let edits = try adapter.capture(store.state, into: &replica, now: 2)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.record, .init(.space, home.id))
        XCTAssertEqual(Set(edits.first!.fields.keys), [.order])
        try store.moveSpace(work.id, to: 1)
        try adapter.capture(store.state, into: &replica, now: 3)
        XCTAssertEqual(replica.sidebar.filter { $0.id.kind == .space }.map { $0.id.id }, store.orderedSpaces.map(\.id))
        try store.perform(nil) {
            try store.updateSpace(home.id) { $0.name = "Work" }
            try store.moveSpace(work.id, to: 0)
        }
        try adapter.capture(store.state, into: &replica, now: 4)
        let moved = try XCTUnwrap(replica.records[.init(.space, work.id)]?.order)
        let renamed = try XCTUnwrap(replica.records[.init(.space, home.id)]?.order)
        XCTAssertLessThan(moved, renamed, "renamed neighbours still bound an insertion gap")
    }

}

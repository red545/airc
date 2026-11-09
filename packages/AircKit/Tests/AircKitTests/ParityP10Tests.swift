// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// P10a: Library › Media's sources and folder listing (L04), Archived Tabs' filters (L02).
final class ParityP10Tests: XCTestCase {
    // MARK: Sources

    func testSourceSettingsKeepGrantsDeclinesAndHiddenFiles() throws {
        var s = LibrarySourceSettings()
        XCTAssertTrue(s.showCaptures && s.showDownloads, "Airc's own files show by default")
        XCTAssertFalse(s.shows(.desktop), "no folder without a grant")
        s.declined(.desktop)
        XCTAssertEqual(s.declined, ["desktop"])
        s.setShown(.desktop, true)
        XCTAssertFalse(s.shows(.desktop), "turning on a folder never granted does nothing")
        let g = LibrarySourceSettings.Grant(bookmark: Data([1, 2, 3]), path: "/tmp/x", grantedAt: Date(timeIntervalSince1970: 1))
        s.granted(.desktop, g)
        XCTAssertTrue(s.shows(.desktop))
        XCTAssertTrue(s.declined.isEmpty, "a grant clears the earlier no")
        s.setShown(.desktop, false)
        XCTAssertFalse(s.shows(.desktop))
        XCTAssertNotNil(s.grant(.desktop), "turned off keeps the grant")
        s.hidden.insert("/tmp/x/a.png")
        let back = try JSONDecoder().decode(LibrarySourceSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        s.forget(.desktop)
        XCTAssertNil(s.grant(.desktop))
        XCTAssertFalse(s.paused.contains("desktop"))
        let old = try JSONDecoder().decode(LibrarySourceSettings.self, from: Data(#"{"showCaptures":false}"#.utf8))
        XCTAssertFalse(old.showCaptures)
        XCTAssertTrue(old.showDownloads && old.grants.isEmpty)
    }

    func testFolderListingIsTheTopLevelsPicturesAndVideosNewestFirst() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let entries: [LibraryFolderListing.Entry] = [
            .init(name: "old.png", modified: t),
            .init(name: "new.jpg", modified: t.addingTimeInterval(60)),
            .init(name: "clip.mov", modified: t.addingTimeInterval(30)),
            .init(name: "notes.txt", modified: t.addingTimeInterval(90)),
            .init(name: "Shots", isDirectory: true, modified: t.addingTimeInterval(120)),
            .init(name: "Photos Library.photoslibrary", isDirectory: true, isPackage: true, modified: t),
            .init(name: ".hidden.png", modified: t.addingTimeInterval(200)),
            .init(name: "secret.png", isHidden: true, modified: t.addingTimeInterval(200)),
            .init(name: "empty.png", modified: t.addingTimeInterval(200), size: 0),
            .init(name: "private.png", modified: t.addingTimeInterval(300)),
        ]
        let files = LibraryFolderListing.files(.desktop, at: "/Users/x/Desktop/", entries: entries,
                                               excluded: ["/Users/x/Desktop/private.png"])
        XCTAssertEqual(files.map(\.name), ["new.jpg", "clip.mov", "old.png"])
        XCTAssertEqual(files.first?.path, "/Users/x/Desktop/new.jpg")
        XCTAssertEqual(files.first?.source, .folder)
        XCTAssertEqual(files.first?.id, "folder:desktop:/Users/x/Desktop/new.jpg")
        XCTAssertEqual(LibraryFolderListing.files(.desktop, at: "/d", entries: entries, limit: 2).count, 2)
        // Media and the hover list treat them as any other file.
        XCTAssertEqual(LibraryMedia.media(files, exists: { _ in true }).map(\.name), ["new.jpg", "clip.mov", "old.png"])
    }

    // MARK: Archived Tabs' filters

    func testArchiveFiltersByPlaceAndClosing() throws {
        let s = try makeStore()
        let home = s.selectedSpace.id
        let work = try s.createSpace(name: "Work", profileID: s.defaultProfile.id, after: home).id
        let a = try s.openTab(url: "https://a.example", inSpace: home)
        let b = try s.openTab(url: "https://b.example", inSpace: work)
        let c = try s.openTab(url: "https://c.example", inSpace: home)
        _ = try s.closeTab(a.id)                                                         // manual, Home
        _ = try s.archiveTabs([b.id], reason: .auto, label: "Archive")                   // auto, Work
        _ = try s.archiveTabs([c.id], reason: .auto, label: "Archive Little Arc", origin: ArchiveEntry.littleArcOrigin)
        let entries = Array(s.state.archive.values)
        func urls(_ f: ArchiveFilter) -> Set<String> { Set(entries.filter(f.matches).map(\.url)) }
        XCTAssertEqual(urls(ArchiveFilter()).count, 3)
        XCTAssertFalse(ArchiveFilter().isActive)
        XCTAssertEqual(urls(ArchiveFilter(place: .space(home))), ["https://a.example"], "Little Arc's page isn't the Space's")
        XCTAssertEqual(urls(ArchiveFilter(place: .space(work))), ["https://b.example"])
        XCTAssertEqual(urls(ArchiveFilter(place: .littleArc)), ["https://c.example"])
        XCTAssertEqual(urls(ArchiveFilter(closing: .automatic)), ["https://b.example", "https://c.example"])
        XCTAssertEqual(urls(ArchiveFilter(closing: .manual)), ["https://a.example"])
        XCTAssertEqual(urls(ArchiveFilter(place: .littleArc, closing: .manual)), [])
        // The origin survives the store's encoding; an older entry has none.
        let entry = try XCTUnwrap(entries.first { $0.url == "https://c.example" })
        let back = try JSONDecoder().decode(ArchiveEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(back.origin, ArchiveEntry.littleArcOrigin)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json["origin"] = nil
        let older = try JSONDecoder().decode(ArchiveEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(older.origin)
    }

    /// 0.1.2's ArchiveEntry, field for field (Model.swift before P10a): what an older Airc writes and reads.
    private struct ArchiveEntry012: Codable, Equatable {
        var id: String
        var url: String
        var title: String
        var faviconURL: String?
        var spaceID: String?
        var profileID: String
        var archivedAt: Date
        var reason: ArchiveReason
        var tab: LiveTab
    }

    /// The store's own coding (SpacesStore: sorted keys, dates in seconds).
    private var storeEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
    private var storeDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    /// `origin` is additive: an entry without one is byte for byte what 0.1.2 wrote, and 0.1.2 reads an entry with one.
    /// The store's schema mark stays as it is (no row changes shape).
    func testArchiveOriginKeepsTheOldEncodingAndOldBuildsReadIt() throws {
        let tab = LiveTab(id: "t1", profileID: "p1", spaceID: "s1", url: "https://a.example", title: "A",
                          createdAt: Date(timeIntervalSince1970: 1_800_000_000), lastActiveAt: Date(timeIntervalSince1970: 1_800_000_100))
        let old = ArchiveEntry012(id: "e1", url: tab.url, title: tab.title, faviconURL: nil, spaceID: "s1", profileID: "p1",
                                  archivedAt: Date(timeIntervalSince1970: 1_800_000_200), reason: .manual, tab: tab)
        let written012 = try storeEncoder.encode(old)
        // This build reads 0.1.2's row and writes it back unchanged.
        let read = try storeDecoder.decode(ArchiveEntry.self, from: written012)
        XCTAssertNil(read.origin)
        XCTAssertEqual(try storeEncoder.encode(read), written012, "no origin: the same bytes as 0.1.2")
        XCTAssertFalse(String(decoding: try storeEncoder.encode(read), as: UTF8.self).contains("origin"))
        // A Little Arc entry, read by 0.1.2's decoder: the extra key is ignored.
        var little = read
        little.origin = ArchiveEntry.littleArcOrigin
        let written = try storeEncoder.encode(little)
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains(#""origin":"littleArc""#))
        let seenBy012 = try storeDecoder.decode(ArchiveEntry012.self, from: written)
        XCTAssertEqual(seenBy012, old)
    }
}

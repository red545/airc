// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of folders in Today, the marketing scenario's part "todayfolders"
/// (`scripts/marketing-shots.sh --parts todayfolders`):
///   - today-folders: Personal's Today with a "Japan Trip" folder open (three pages, one of them on screen) and a closed
///     "Reading" folder, below the divider, over the Fushimi Inari page. No sign-in card (the part checks and logs it).
/// Afterwards the folders and the extra tabs go, so later parts see the demo as it was.
extension SnapshotRunner {
    @MainActor func mkTodayFoldersShots(_ d: MarketingDemo) {
        let trip: [(url: String, title: String)] = [
            ("https://www.japan-guide.com/e/e3915.html", "Fushimi Inari Shrine – japan-guide.com"),
            ("https://www.japan-guide.com/railpass/", "Japan Rail Pass – japan-guide.com"),
            ("https://en.wikivoyage.org/wiki/Kyoto", "Kyoto – Travel guide at Wikivoyage"),
        ]
        let reading: [(url: String, title: String)] = [
            ("https://en.wikipedia.org/wiki/Helvetica", "Helvetica – Wikipedia"),
            ("https://en.wikipedia.org/wiki/Bauhaus", "Bauhaus – Wikipedia"),
        ]
        var opened: [String] = []
        var folders: [String] = []
        var space = ""
        run { [self] in
            guard let sid = d.space["personal"] else { return note("marketing: MISSING today-folders: no Personal Space") }
            space = sid
            do {
                var tripIDs: [String] = [], readingIDs: [String] = []
                for t in reading.reversed() { readingIDs.insert(try c.store.openTab(url: t.url, inSpace: sid, activate: false, title: t.title).id, at: 0) }
                for t in trip.reversed() { tripIDs.insert(try c.store.openTab(url: t.url, inSpace: sid, activate: false, title: t.title).id, at: 0) }
                opened = tripIDs + readingIDs
                let r = try c.store.createTodayFolder(named: "Reading", inSpace: sid, containing: readingIDs.map { .tab($0) })
                try c.store.toggleFolder(r.id)
                let j = try c.store.createTodayFolder(named: "Japan Trip", inSpace: sid, containing: tripIDs.map { .tab($0) })
                folders = [j.id, r.id]
                c.switchToSpace(sid, animated: false)
                c.show(tripIDs[0], focus: false)
                c.reloadAll(animated: false)
            } catch {
                note("marketing: MISSING today-folders: \(error)")
            }
        }
        mkSettleShown()
        run { [self] in
            let card = c.store.space(space).map { c.showsSignInCard(space: $0) } ?? true
            note("marketing: today-folders: \(c.store.todayRows(ofSpace: space).count) Today rows, sign-in card \(card ? "SHOWN" : "not shown")")
        }
        mkWindowShot("today-folders")
        run { [self] in
            for f in folders where c.store.item(f) != nil { try? c.store.ungroupTodayFolder(f) }
            for id in opened { _ = try? c.store.closeTab(id) }
        }
    }
}
#endif

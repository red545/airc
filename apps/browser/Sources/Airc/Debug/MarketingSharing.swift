// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shots of sharing (H01, H02), the marketing scenario's part "sharing"
/// (`scripts/marketing-shots.sh --parts sharing`):
///   - share-space: the Travel Space, Share Space… over it: the preview of exactly what the link will hold (its pinned
///     tabs and the "Lisbon, March" folder, in order), what's left out, and Create Link. Nothing is published.
///   - share-import: a link someone sent opened in the Personal Space: the import preview of their "Kyoto, April"
///     Space (a folder, a split, tabs), with the profile to add it to and Add as New Space. Nothing is added.
extension SnapshotRunner {
    func mkSharingShots(_ d: MarketingDemo) {
        mkShow(d, "travel", "lisbon")
        mkSettleShown()
        run { [self] in
            guard let space = d.space["travel"] else { return note("marketing: MISSING share-space: no Travel Space") }
            c.shareSpace(space)
        }
        wait(0.8)
        mkSharingSheetShot("share-space") { [self] in ShareLinkSheet.active[ObjectIdentifier(c.window)]?.sheet }
        run { [self] in ShareLinkSheet.active[ObjectIdentifier(c.window)]?.close() }
        wait(0.4)

        mkShow(d, "personal", "kyoto")
        mkSettleShown()
        run { [self] in
            let wiki = { (page: String, title: String) in ShareNode.tab(ShareTab(url: "https://en.wikivoyage.org/wiki/\(page)", title: title)) }
            let snapshot = ShareSnapshot(.space(name: "Kyoto, April", icon: "⛩️", items: [
                .tab(ShareTab(url: "https://www.google.com/travel/flights", title: "Flights to Osaka")),
                .folder(name: "Days out", items: [
                    wiki("Nara", "Nara – Travel guide at Wikivoyage"),
                    wiki("Arashiyama", "Arashiyama – Travel guide at Wikivoyage"),
                    .tab(ShareTab(url: "https://en.wikipedia.org/wiki/Fushimi_Inari-taisha", title: "Fushimi Inari-taisha – Wikipedia")),
                ]),
                .split(axis: .horizontal, tabs: [
                    ShareTab(url: "https://www.openstreetmap.org/#map=14/35.0037/135.7788", title: "OpenStreetMap"),
                    ShareTab(url: "https://en.wikivoyage.org/wiki/Kyoto/Higashiyama", title: "Kyoto/Higashiyama – Wikivoyage"),
                ]),
                .tab(ShareTab(url: "https://en.wikipedia.org/wiki/Kaiseki", title: "Kaiseki – Wikipedia")),
                .tab(ShareTab(url: "https://www.japan-guide.com/e/e2158.html", title: "Kyoto Travel: Cherry blossoms")),
            ]))
            ShareImportSheet(snapshot: snapshot, controller: c).present()
        }
        wait(0.8)
        mkSharingSheetShot("share-import") { [self] in ShareImportSheet.active[ObjectIdentifier(c.window)]?.sheet }
        run { [self] in ShareImportSheet.active[ObjectIdentifier(c.window)]?.close() }
        wait(0.4)
    }

    /// The browser window with `sheet()` drawn where macOS puts it (under the title bar, centred).
    private func mkSharingSheetShot(_ name: String, _ sheet: @escaping () -> NSWindow?) {
        mkWindowShot(name) { [self] frame in
            guard let s = sheet(), let card = mkContentImage(s) else {
                note("marketing: MISSING \(name): no sheet")
                return []
            }
            let sf = s.frame, wf = c.window.frame
            return [MarketingStudio.Layer(image: card, frame: NSRect(x: frame.minX + sf.minX - wf.minX, y: frame.minY + sf.minY - wf.minY,
                                                                     width: sf.width, height: sf.height), radius: 16, shadow: .panel)]
        }
    }
}
#endif

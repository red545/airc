// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import XCTest
@testable import AircKit

final class WhatsNewTests: XCTestCase {
    private func h(_ t: String, _ i: String = "sparkles") -> WhatsNewHighlight { WhatsNewHighlight(title: t, icon: i) }
    private var catalog: WhatsNewCatalog {
        WhatsNewCatalog(releases: [
            WhatsNewRelease(version: "0.1.12", highlights: [h("A12"), h("B12"), h("C12")]),
            WhatsNewRelease(version: "0.1.10", highlights: [h("A10"), h("B10")]),
            WhatsNewRelease(version: "0.1.11", highlights: [h("A11"), h("B11"), h("A12")]),
            WhatsNewRelease(version: "0.1.9", highlights: [h("A9")]),
        ])
    }

    // MARK: Choosing the versions

    func testVersionsCompareNumerically() {
        XCTAssertLessThan(WhatsNewVersion("0.1.9")!, WhatsNewVersion("0.1.10")!)
        XCTAssertEqual(WhatsNewVersion("0.1.12 (202611131000)")!.description, "0.1.12")
        XCTAssertEqual(WhatsNewVersion("1.0")!, WhatsNewVersion("1.0.0")!)
        XCTAssertEqual(Set([WhatsNewVersion("1.0")!, WhatsNewVersion("1.0.0")!]).count, 1)
        XCTAssertNil(WhatsNewVersion("next"))
        XCTAssertNil(WhatsNewVersion("?"))
    }

    func testChoosesOnlyVersionsAfterLastSeenUpToRunning() {
        let one = WhatsNewContent.merge(catalog, from: "0.1.11 (202611130133)", current: "0.1.12")!
        XCTAssertEqual(one.versions, ["0.1.12"])
        XCTAssertEqual(one.lines.map(\.title), ["A12", "B12", "C12"])
        XCTAssertFalse(one.more)
        XCTAssertEqual(one.changelogURL(base: URL(string: "https://aircbrowser.com/changelog")!).absoluteString,
                       "https://aircbrowser.com/changelog#v0.1.12")
        // Nothing newer than the running version (a catalog from the future, a downgrade) and nothing at or before last seen.
        XCTAssertEqual(WhatsNewContent.merge(catalog, from: "0.1.10", current: "0.1.11")!.versions, ["0.1.11"])
        XCTAssertNil(WhatsNewContent.merge(catalog, from: "0.1.12", current: "0.1.12"))
        XCTAssertNil(WhatsNewContent.merge(catalog, from: "0.1.12", current: "0.1.11"))
        // Versions without entries (an older feed, a dev build): no card.
        XCTAssertNil(WhatsNewContent.merge(catalog, from: "0.1.12", current: "0.1.13"))
        XCTAssertNil(WhatsNewContent.merge(catalog, from: "garbage", current: "0.1.12"))
    }

    // MARK: Merging skipped versions

    func testMergesSkippedVersionsNewestFirstCappedAtFiveWithMore() {
        let m = WhatsNewContent.merge(catalog, from: "0.1.9", current: "0.1.12")!
        XCTAssertEqual(m.version, "0.1.12")
        XCTAssertEqual(m.versions, ["0.1.12", "0.1.11", "0.1.10"])
        // A12 repeated in 0.1.11 shows once, at its newest place.
        XCTAssertEqual(m.lines.map(\.title), ["A12", "B12", "C12", "A11", "B11"])
        XCTAssertTrue(m.more)
        XCTAssertNil(m.lines[0].anchor)
        XCTAssertEqual(m.lines[3].anchor, "v0.1.11")
        let exact = WhatsNewContent.merge(catalog, from: "0.1.10", current: "0.1.12")!
        XCTAssertEqual(exact.lines.count, 5)
        XCTAssertFalse(exact.more)
    }

    // MARK: The launch rules

    func testNeverOnAFreshInstall() {
        var s = WhatsNewState()
        XCTAssertNil(s.launch(previous: nil, current: "0.1.12", enabled: true))
        XCTAssertEqual(s.offered, ["0.1.12"])
        XCTAssertNil(s.launch(previous: "0.1.12", current: "0.1.12", enabled: true))
        // …and a later reinstall of the same version over it doesn't either.
        XCTAssertNil(s.launch(previous: "0.1.11", current: "0.1.12", enabled: true))
    }

    func testShownForThreeLaunchesThenGone() {
        var s = WhatsNewState()
        XCTAssertEqual(s.launch(previous: "0.1.10 (1)", current: "0.1.12", enabled: true)?.from, "0.1.10")
        XCTAssertNotNil(s.launch(previous: "0.1.12 (2)", current: "0.1.12", enabled: true))
        XCTAssertNotNil(s.launch(previous: "0.1.12 (2)", current: "0.1.12", enabled: true))
        XCTAssertNil(s.launch(previous: "0.1.12 (2)", current: "0.1.12", enabled: true))
        XCTAssertEqual(s.shownLaunches, 3)
    }

    func testShownOnceDismissedStaysGoneAndNeverTwicePerVersion() {
        var s = WhatsNewState()
        XCTAssertNotNil(s.launch(previous: "0.1.11", current: "0.1.12", enabled: true))
        s.dismiss()
        XCTAssertNil(s.launch(previous: "0.1.12", current: "0.1.12", enabled: true))
        // A step back and forward again (Nightly → Stable, a reinstall): still not again for 0.1.12.
        XCTAssertNil(s.launch(previous: "0.1.12", current: "0.1.11", enabled: true))
        XCTAssertNil(s.launch(previous: "0.1.11", current: "0.1.12", enabled: true))
        // The next version is offered.
        XCTAssertEqual(s.launch(previous: "0.1.12", current: "0.1.13", enabled: true)?.from, "0.1.12")
        // Round trip through the file.
        let back = try! JSONDecoder().decode(WhatsNewState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testAPendingCardCoversTheNextUpdateToo() {
        var s = WhatsNewState()
        XCTAssertNotNil(s.launch(previous: "0.1.10", current: "0.1.11", enabled: true))
        let r = s.launch(previous: "0.1.11", current: "0.1.12", enabled: true)
        XCTAssertEqual(r?.from, "0.1.10")
        XCTAssertEqual(r?.current, "0.1.12")
        XCTAssertEqual(s.shownLaunches, 1)
    }

    func testTurnedOffMeansNoCardAndNoLaterSurprise() {
        var s = WhatsNewState()
        XCTAssertNil(s.launch(previous: "0.1.11", current: "0.1.12", enabled: false))
        XCTAssertNil(s.launch(previous: "0.1.12", current: "0.1.12", enabled: true))
        XCTAssertEqual(s.offered, ["0.1.12"])
    }

    // MARK: The JSON schema

    func testSchemaValidation() throws {
        XCTAssertNoThrow(try catalog.validate())
        func bad(_ json: String) -> Bool { (try? WhatsNewCatalog.decode(Data(json.utf8))) == nil }
        XCTAssertTrue(bad(#"{"schema":2,"releases":[]}"#))
        XCTAssertTrue(bad(#"{"schema":1,"releases":[{"version":"next","highlights":[{"title":"A","icon":"star"}]}]}"#))
        XCTAssertTrue(bad(#"{"schema":1,"releases":[{"version":"0.1.1","highlights":[]}]}"#))
        XCTAssertTrue(bad(#"{"schema":1,"releases":[{"version":"0.1.1","highlights":[{"title":"A","icon":"Not An Icon"}]}]}"#))
        XCTAssertTrue(bad(#"{"schema":1,"releases":[{"version":"0.1.1","highlights":[{"title":"A"}]}]}"#))
        XCTAssertTrue(bad(#"{"schema":1,"releases":[{"version":"0.1.1","highlights":[{"title":"A","icon":"a"}]},{"version":"0.1.1","highlights":[{"title":"A","icon":"a"}]}]}"#))
        XCTAssertFalse(bad(#"{"schema":1,"releases":[{"version":"0.1.1","highlights":[{"title":"A","icon":"star.fill","anchor":"v0.1.1"}]}]}"#))
        XCTAssertFalse(bad(#"{"schema":1,"releases":[{"version":"0.1.1","highlights":[{"title":"Spaces saved on quit","detail":"Your Spaces are saved as soon as you quit","icon":"star"}]}]}"#))
        // 27 characters: too long for the card.
        XCTAssertTrue(bad(#"{"schema":1,"releases":[{"version":"0.1.1","highlights":[{"title":"Every extension to reinstal","icon":"star"}]}]}"#))
    }

    /// The bundled file (apps/browser/Resources/WhatsNew.json): valid, backfilled for 0.1.10–0.1.12, every icon a real
    /// SF Symbol on this Mac.
    func testBundledResource() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../apps/browser/Resources/WhatsNew.json")
        let c = try WhatsNewCatalog.decode(Data(contentsOf: url))
        for v in ["0.1.10", "0.1.11", "0.1.12", "0.1.13", "0.1.14", "0.1.15"] { XCTAssertNotNil(c.release(v), v) }
        for r in c.releases {
            XCTAssertTrue((1...WhatsNewCatalog.maxPerRelease).contains(r.highlights.count), r.version)
            for h in r.highlights {
                XCTAssertLessThanOrEqual(h.title.count, WhatsNewCatalog.titleMax, h.title)
                XCTAssertNotNil(h.lead, h.title)
                XCTAssertNotNil(NSImage(systemSymbolName: h.icon, accessibilityDescription: nil), "\(r.version): \(h.icon)")
                // whatsnew2: from 0.1.13 every line explains itself (the What's new tab).
                if WhatsNewVersion(r.version)! >= WhatsNewVersion("0.1.13")! {
                    let d = try XCTUnwrap(h.detail, "\(r.version) \(h.title): no detail")
                    XCTAssertGreaterThan(d.count, 60, "\(h.title): a sentence or two, not a title")
                    XCTAssertNotEqual(d, h.lead)
                }
                if let a = h.actionName { XCTAssertNotNil(WhatsNewAction(rawValue: a), a) }
                if let i = h.image {
                    let pic = url.deletingLastPathComponent().appendingPathComponent("WhatsNew/\(i).heic")
                    XCTAssertTrue(FileManager.default.fileExists(atPath: pic.path), "\(h.title): \(pic.lastPathComponent)")
                    XCTAssertNotNil(NSImage(contentsOf: pic), pic.lastPathComponent)
                }
            }
        }
        let merged = WhatsNewContent.merge(c, from: "0.1.10", current: "0.1.12")!
        XCTAssertEqual(merged.versions, ["0.1.12", "0.1.11"])
        XCTAssertEqual(merged.lines.count, 5)
        XCTAssertTrue(merged.more)
        // The owner's case: from 0.1.13 the tab explains 0.1.15 and 0.1.14 in full, with their Show me buttons.
        let page = try XCTUnwrap(WhatsNewPageContent.make(c, from: "0.1.13", current: "0.1.15"))
        XCTAssertEqual(page.sections.map(\.version), ["0.1.15", "0.1.14"])
        let actions = page.sections.flatMap(\.highlights).compactMap(\.action)
        for a in [WhatsNewAction.commandBar, .settingsAppIcon, .settingsSitePreviews] { XCTAssertTrue(actions.contains(a), a.rawValue) }
        let pics = Set(page.sections.flatMap(\.highlights).compactMap(\.image))
        XCTAssertTrue(pics.isSuperset(of: ["command-bar", "settings-app-icon"]), "\(pics)")
    }

    // MARK: whatsnew2: the What's new tab

    func testPageContentGroupsEveryLineByVersionNewestFirst() {
        let p = WhatsNewPageContent.make(catalog, from: "0.1.9", current: "0.1.12")!
        XCTAssertEqual(p.version, "0.1.12")
        XCTAssertEqual(p.from, "0.1.9")
        XCTAssertEqual(p.sections.map(\.version), ["0.1.12", "0.1.11", "0.1.10"])
        // No cap at five on the page; a line two versions carry shows once, in the newer one.
        XCTAssertEqual(p.sections.flatMap(\.highlights).map(\.title), ["A12", "B12", "C12", "A11", "B11", "A10", "B10"])
        XCTAssertNil(WhatsNewPageContent.make(catalog, from: "0.1.12", current: "0.1.12"))
        XCTAssertNil(WhatsNewPageContent.make(catalog, from: "0.1.12", current: "0.1.13"))
        // No range: the running version's own release, else the newest one before it.
        XCTAssertEqual(WhatsNewPageContent.make(catalog, from: nil, current: "0.1.11")?.sections.map(\.version), ["0.1.11"])
        XCTAssertEqual(WhatsNewPageContent.latest(catalog, current: "0.1.13 (1)")?.sections.map(\.version), ["0.1.12"])
        XCTAssertNil(WhatsNewPageContent.latest(catalog, current: "0.1.8"))
    }

    func testPageAddress() {
        let u = WhatsNewURL.make(from: "0.1.13", to: "0.1.15")
        XCTAssertEqual(u, "airc://whats-new?from=0.1.13&to=0.1.15")
        XCTAssertTrue(WhatsNewURL.isPage(u))
        XCTAssertTrue(WhatsNewURL.isPage(WhatsNewURL.prefix))
        XCTAssertTrue(LocalDocumentURL.isLocal(u))   // no engine page, not synced
        XCTAssertFalse(WhatsNewURL.isPage("airc://whats-newer"))
        XCTAssertFalse(WhatsNewURL.isPage("https://aircbrowser.com/changelog"))
        XCTAssertFalse(WhatsNewURL.isPage(nil))
        XCTAssertEqual(WhatsNewURL.range(u)?.from, "0.1.13")
        XCTAssertEqual(WhatsNewURL.range(u)?.to, "0.1.15")
        XCTAssertNil(WhatsNewURL.range(WhatsNewURL.prefix))
        XCTAssertNil(WhatsNewURL.range("airc://whats-new?from=next&to=0.1.15"))
    }

    func testNewActionsAndSevenLineCap() throws {
        // wnactions: Settings › AI (at Downloads) and Settings › Shortcuts.
        XCTAssertEqual(WhatsNewAction(rawValue: "settingsAI")?.place, "Settings › AI › Downloads")
        XCTAssertEqual(WhatsNewAction(rawValue: "settingsShortcuts")?.place, "Settings › Shortcuts")
        XCTAssertEqual(WhatsNewAction.settingsAI.buttonTitle, "Show me")
        XCTAssertEqual(WhatsNewAction.settingsShortcuts.buttonTitle, "Show me")
        // "none" is whatsnew.py's word for a deliberate no-button line; it never reaches the file, and if it did the
        // line would read without a button.
        XCTAssertNil(WhatsNewAction(rawValue: "none"))
        // A release may carry 7 lines; the 8th is refused.
        XCTAssertEqual(WhatsNewCatalog.maxPerRelease, 7)
        func release(_ n: Int) -> WhatsNewCatalog {
            WhatsNewCatalog(releases: [WhatsNewRelease(version: "0.1.20", highlights: (0..<n).map {
                WhatsNewHighlight(title: "Line \($0)", icon: "star", detail: "A sentence.", action: $0 == 0 ? .settingsAI : $0 == 1 ? .settingsShortcuts : nil)
            })])
        }
        XCTAssertNoThrow(try release(7).validate())
        XCTAssertThrowsError(try release(8).validate()) { XCTAssertEqual($0 as? WhatsNewCatalog.Invalid, .tooMany("0.1.20")) }
        // The tab lists all seven; the sidebar card keeps five and says "and more".
        let seven = release(7)
        XCTAssertEqual(WhatsNewPageContent.make(seven, from: "0.1.19", current: "0.1.20")?.sections.first?.highlights.count, 7)
        let card = try XCTUnwrap(WhatsNewContent.merge(seven, from: "0.1.19", current: "0.1.20"))
        XCTAssertEqual(card.lines.count, WhatsNewContent.maxLines)
        XCTAssertEqual(card.lines.map(\.title), (0..<5).map { "Line \($0)" })
        XCTAssertTrue(card.more)
        let roundTrip = try WhatsNewCatalog.decode(JSONEncoder().encode(seven))
        XCTAssertEqual(roundTrip.releases[0].highlights.prefix(2).compactMap(\.action), [.settingsAI, .settingsShortcuts])
    }

    func testActionWhitelist() throws {
        // The closed list (scripts/release/whatsnew.py's ACTIONS is the same; test_whatsnew pins that).
        XCTAssertEqual(WhatsNewAction.allCases.map(\.rawValue),
                       ["commandBar", "settingsAppIcon", "settingsSitePreviews", "settingsAgents", "settingsSync", "settingsImport",
                        "settingsBoosts", "settingsGeneral", "settingsUpdates", "libraryArchive", "libraryNotes", "sendFeedback",
                        "settingsAI", "settingsShortcuts"])
        for a in WhatsNewAction.allCases { XCTAssertFalse(a.buttonTitle.isEmpty || a.place.isEmpty, a.rawValue) }
        func bad(_ json: String) -> Bool { (try? WhatsNewCatalog.decode(Data(json.utf8))) == nil }
        XCTAssertTrue(bad(#"{"schema":1,"releases":[{"version":"0.1.1","highlights":[{"title":"A","icon":"star","action":"openURL"}]}]}"#))
        XCTAssertTrue(bad(#"{"schema":1,"releases":[{"version":"0.1.1","highlights":[{"title":"A","icon":"star","image":"../etc/x"}]}]}"#))
        XCTAssertTrue(bad(#"{"schema":1,"releases":[{"version":"0.1.1","highlights":[{"title":"A","icon":"star","detail":"\#(String(repeating: "x", count: 281))"}]}]}"#))
        XCTAssertFalse(bad(#"{"schema":1,"releases":[{"version":"0.1.1","highlights":[{"title":"A","icon":"star","detail":"Two sentences. Here.","action":"commandBar","image":"command-bar"}]}]}"#))
        // A feed from a newer build with an action this one doesn't know: the line still reads, without a button.
        let lines = WhatsNewAppcast.highlights(#"[{"title":"A","icon":"star","action":"teleport"}]"#)
        XCTAssertEqual(lines.count, 1)
        XCTAssertNil(lines[0].action)
        // Round trip keeps the action's name under "action".
        let h = WhatsNewHighlight(title: "A", icon: "star", detail: "D.", lead: "L", action: .settingsAgents, image: "x")
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(h), encoding: .utf8))
        XCTAssertTrue(json.contains(#""action":"settingsAgents""#), json)
        XCTAssertEqual(try JSONDecoder().decode(WhatsNewHighlight.self, from: Data(json.utf8)), h)
        XCTAssertEqual(h.spoken, "L")
    }

    func testStyleChoices() throws {
        XCTAssertEqual(WhatsNewStyle.allCases, [.tab, .card, .off])
        XCTAssertEqual(try JSONDecoder().decode(WhatsNewStyle.self, from: Data(#""card""#.utf8)), .card)
    }

    // MARK: The appcast's lines

    func testAppcastHighlights() {
        let text = #"[{"title":"One","icon":"star"},{"title":"Two","icon":"bolt"},{"title":"Three","icon":"key"},{"title":"Four","icon":"clock"}]"#
        XCTAssertEqual(WhatsNewAppcast.highlights(text).map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(WhatsNewAppcast.highlights(properties: ["airc:highlights": text]).count, 3)
        // Republished through a tool that renamed the prefix.
        XCTAssertEqual(WhatsNewAppcast.highlights(properties: ["ns0:highlights": text]).count, 3)
        XCTAssertEqual(WhatsNewAppcast.highlights(properties: ["title": "Airc 0.1.12"]), [])
        XCTAssertEqual(WhatsNewAppcast.highlights(nil), [])
        XCTAssertEqual(WhatsNewAppcast.highlights("<p>html notes</p>"), [])
    }
}

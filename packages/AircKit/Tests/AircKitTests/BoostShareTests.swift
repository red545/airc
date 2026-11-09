// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import JavaScriptCore
import XCTest
@testable import AircKit

/// BST-3: frames, `@import`, the size as page zoom, sharing (files, links, updates) and the gallery.
final class BoostShareTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestSuffixes.install()
    }

    // MARK: Frames

    func testASameSiteFrameTakesTheFramesStyleAndAnotherSitesFrameNothing() throws {
        var b = Boost(domain: "example.com", css: "h1 { color: red }")
        b.colors = BoostColors(brightness: 0.8, invert: true)
        b.font = BoostFont(family: .georgia)
        let script = try BoostTests.composed([b, Boost(domain: "other.org", css: "p { color: blue }")])

        // A frame of the same site (another host): the frame's style, and it says ready.
        let same = try BoostTests.page(script, protocol: "https:", hostname: "cdn.example.com", origin: "https://cdn.example.com",
                                       frameIn: "https://www.example.com")
        let style = try XCTUnwrap(same.evaluateScript("styles()")?.toString())
        XCTAssertTrue(style.contains("invert(1)") && style.contains("Georgia") && style.contains("h1 { color: red }"), style)
        XCTAssertFalse(style.contains("brightness"), "the page's filter already covers its frames")
        XCTAssertEqual(same.evaluateScript("ready().d")?.toString(), "example.com")

        // A frame of another site inside the boosted page: nothing, not even its own site's Boost, and no message.
        let other = try BoostTests.page(script, protocol: "https:", hostname: "www.other.org", origin: "https://www.other.org",
                                        frameIn: "https://www.example.com")
        XCTAssertEqual(other.evaluateScript("styles()")?.toString(), "")
        XCTAssertEqual(other.evaluateScript("posted.length")?.toInt32(), 0)
        // The boosted site framed by another site: its Boost stays on its own pages.
        let framed = try BoostTests.page(script, protocol: "https:", hostname: "www.example.com", origin: "https://www.example.com",
                                         frameIn: "https://evil.test")
        XCTAssertEqual(framed.evaluateScript("styles()")?.toString(), "")
        XCTAssertEqual(framed.evaluateScript("posted.length")?.toInt32(), 0)
        // No ancestorOrigins (an engine without it): no frame is boosted.
        let unknown = try BoostTests.page(script, protocol: "https:", hostname: "www.example.com", origin: "https://www.example.com",
                                          frameIn: "")
        XCTAssertEqual(unknown.evaluateScript("styles()")?.toString(), "")

        // A frame of the page's own origin on a site without a Boost says ready (one made now can reach it).
        let plain = try BoostTests.page(script, protocol: "https:", hostname: "news.test", origin: "https://news.test",
                                        frameIn: "https://news.test")
        XCTAssertEqual(plain.evaluateScript("posted.length")?.toInt32(), 1)
        XCTAssertTrue(plain.evaluateScript("ready().d")?.isNull == true)
        let token = try XCTUnwrap(plain.evaluateScript("ready().t")?.toString())
        plain.objectForKeyedSubscript("receive").call(withArguments: [
            "boost.apply", BoostPageScript.applyMessage(for: b, domain: "news.test", token: token, version: 2, frame: true),
        ])
        XCTAssertTrue(plain.evaluateScript("styles()")?.toString().contains("Georgia") == true)
        // Zap runs in frames of the page's own site too since boosts3 (its overlay needs a real document: the app's
        // --script boosts3 checks it on both engines; BoostsThreeTests the frames-only zaps).
    }

    // MARK: @import

    static let importVectors: [(String, [BoostCSSImports.Rule], String)] = [
        ("@import url(/a.css);\nh1{}", [.init(url: "/a.css")], "h1{}"),
        ("@charset \"utf-8\"; @import 'b.css' screen and (max-width: 600px); p{}",
         [.init(url: "b.css", media: "screen and (max-width: 600px)")], "p{}"),
        ("/* c */ @IMPORT url( \"c.css\" ) layer(base) supports(display: grid) print;",
         [.init(url: "c.css", layer: "base", supports: "display: grid", media: "print")], ""),
        ("@import url(d.css) layer; @import \"e;f.css\";", [.init(url: "d.css", layer: ""), .init(url: "e;f.css")], ""),
        ("@import url(data:text/css,h1%7Bcolor:red%7D);", [.init(url: "data:text/css,h1%7Bcolor:red%7D")], ""),
        ("h1 {} @import url(late.css);", [], "h1 {} @import url(late.css);"),
        ("@import url(x.css) { }", [], "@import url(x.css) { }"),
        ("@import layers.css;", [], "@import layers.css;"),
        ("@import url(g.css) layered;", [.init(url: "g.css", media: "layered")], ""),
    ]

    func testImportsSplitAsCSSHasThem() {
        for (css, rules, rest) in Self.importVectors {
            let got = BoostCSSImports.split(css)
            XCTAssertEqual(got.rules, rules, css)
            XCTAssertEqual(got.rest, rest, css)
        }
    }

    func testImportsLoadFromTheSiteOrDataOnly() {
        func source(_ u: String) -> BoostCSSImports.Source { BoostCSSImports.source(of: .init(url: u), site: "example.com") }
        XCTAssertEqual(source("/a.css"), .samePage)
        XCTAssertEqual(source("a.css?v=2"), .samePage)
        XCTAssertEqual(source("https://cdn.example.com/a.css"), .host("cdn.example.com"))
        XCTAssertEqual(source("//static.example.com/a.css"), .host("static.example.com"))
        XCTAssertEqual(source("https://fonts.googleapis.com/css2?family=Inter"), .refused(.otherSite))
        XCTAssertEqual(source("https://example.com.evil.test/a.css"), .refused(.otherSite))
        XCTAssertEqual(source("//evil.test/a.css"), .refused(.otherSite))
        XCTAssertEqual(source("javascript:alert(1)"), .refused(.scheme))
        XCTAssertEqual(source("file:///etc/passwd"), .refused(.scheme))
        XCTAssertEqual(source("data:text/css;base64,aDF7fQ=="), .inline)
        XCTAssertEqual(source("data:text/css;charset=utf-8,h1{}"), .inline)
        XCTAssertEqual(source("data:text/html,<script>"), .refused(.data))
        XCTAssertEqual(source("data:,h1{}"), .refused(.data))
    }

    /// The page runtime splits the same way and loads only what the app's rule allows: data: at once, the page's own
    /// origin by fetch (its credentials, same-origin mode), nothing else, and says what it skipped.
    func testThePageLoadsImportsByTheSameRule() throws {
        // The runtime's splitter agrees with the app's on every vector (what it leaves is the custom sheet).
        for (css, _, rest) in Self.importVectors {
            let script = try BoostTests.composed([Boost(domain: "example.com", css: css)])
            let page = try BoostTests.page(script, protocol: "https:", hostname: "www.example.com", origin: "https://www.example.com")
            let custom = try XCTUnwrap(page.evaluateScript("adopted[1] ? adopted[adopted.length - 1].text : ''")?.toString())
            XCTAssertEqual(custom, rest, css)
        }

        let css = """
            @import url(data:text/css,h1%7Bcolor:red%7D) print;
            @import url(data:text/css;base64,aDJ7Y29sb3I6Ymx1ZX0=);
            @import "/site.css" layer(site);
            @import url(https://cdn.example.com/cdn.css);
            @import url(https://evil.test/steal.css);
            @import url("javascript:alert(1)");
            @import "/missing.css";
            @import "/html.css";
            p { margin: 0 }
            """
        let script = try BoostTests.composed([Boost(domain: "example.com", css: css)])
        let page = try BoostTests.page(script, protocol: "https:", hostname: "www.example.com", origin: "https://www.example.com",
                                       href: "https://www.example.com/news/today",
                                       served: ["https://www.example.com/site.css": ("@import 'nested.css'; .site { color: green }", "text/css; charset=utf-8"),
                                                "https://www.example.com/nested.css": (".nested {}", "text/css"),
                                                "https://www.example.com/html.css": ("<html>", "text/html")])
        let sheets = try XCTUnwrap(page.evaluateScript("JSON.stringify(adopted.map(function (s) { return s.text; }))")?.toString())
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sheets.utf8)) as? [String])
        XCTAssertTrue(list.contains("@media print {\nh1{color:red}\n}"), "\(list)")
        XCTAssertTrue(list.contains("h2{color:blue}"), "base64 data: \(list)")
        XCTAssertTrue(list.contains("@layer site {\n.nested {}\n}"), "a nested import keeps its outer layer: \(list)")
        XCTAssertTrue(list.contains("@layer site {\n.site { color: green }\n}"), "\(list)")
        // Order: the generated sheet, the imports in order (a nested one before its parent), then the custom CSS.
        let nested = list.firstIndex(of: "@layer site {\n.nested {}\n}") ?? -1, site = list.firstIndex(of: "@layer site {\n.site { color: green }\n}") ?? -1
        XCTAssertLessThan(nested, site)
        XCTAssertEqual(list.last?.trimmingCharacters(in: .whitespacesAndNewlines), "p { margin: 0 }")

        let fetched = try XCTUnwrap(page.evaluateScript("fetched.join('|')")?.toString())
        XCTAssertTrue(fetched.contains("https://www.example.com/site.css same-origin same-origin"), fetched)
        XCTAssertTrue(fetched.contains("https://www.example.com/nested.css"), "resolved against its own sheet: \(fetched)")
        XCTAssertFalse(fetched.contains("evil.test") || fetched.contains("cdn.example.com") || fetched.contains("javascript"),
                       "never fetched: \(fetched)")
        let failed = try XCTUnwrap(page.evaluateScript("JSON.stringify(failures().map(function (f) { return f.u + '=' + f.w; }))")?.toString())
        XCTAssertTrue(failed.contains("https://evil.test/steal.css=origin"), failed)
        XCTAssertTrue(failed.contains("https://cdn.example.com/cdn.css=origin"), "another host is another origin here: \(failed)")
        XCTAssertTrue(failed.contains("javascript:alert(1)=scheme"), failed)
        XCTAssertTrue(failed.contains("/missing.css=blocked"), failed)
        XCTAssertTrue(failed.contains("/html.css=type"), failed)
    }

    // MARK: The size

    func testTheSizeIsThePagesZoomAndNeverFightsThePerson() {
        XCTAssertEqual(BoostZoom.steps(to: 1.25), 2)
        XCTAssertEqual(BoostZoom.steps(to: 0.8), -2)
        XCTAssertEqual(BoostZoom.steps(to: 1), 0)
        XCTAssertNil(BoostZoom.steps(to: 1.3))
        // A page at 100 % takes the Boost's size; one already there stays.
        XCTAssertEqual(BoostZoom.plan(current: 1, target: 1.25, ledger: []), 1.25)
        XCTAssertNil(BoostZoom.plan(current: 1.25, target: 1.25, ledger: []))
        // The size changed: from what the app set, to the new one.
        XCTAssertEqual(BoostZoom.plan(current: 1.25, target: 1.5, ledger: [1.25]), 1.5)
        // The person zoomed the page themselves: theirs stays, with the Boost or without it.
        XCTAssertNil(BoostZoom.plan(current: 1.75, target: 1.25, ledger: [1.25]))
        XCTAssertNil(BoostZoom.plan(current: 1.75, target: nil, ledger: [1.25]))
        // The size (or the Boost) went: the app's zoom goes back to 100 %, nobody else's.
        XCTAssertEqual(BoostZoom.plan(current: 1.25, target: nil, ledger: [1.25]), 1)
        XCTAssertNil(BoostZoom.plan(current: 1.25, target: nil, ledger: []))
        XCTAssertNil(BoostZoom.plan(current: 1, target: nil, ledger: [1.25]))
    }

    func testTheStoreKeepsTheZoomsItSet() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("boosts-zoom-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BoostStore(url: url)
        store.noteZoom(1.25, host: "www.example.com")
        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(store.flush())
        XCTAssertEqual(BoostStore(url: url).zoomedHosts, ["www.example.com": 1.25])
        let again = BoostStore(url: url)
        again.noteZoom(nil, host: "www.example.com")
        XCTAssertTrue(again.flush())
        XCTAssertEqual(BoostStore(url: url).zoomedHosts, [:])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("zoomedHosts"))
    }

    // MARK: Files

    func fixture() -> BoostFile {
        var f = BoostFile(boost: Boost(domain: "example.com", colors: .init(tint: 0.2, saturation: 0.5),
                                       font: .init(family: .charter, size: 1, textCase: .capitalize), css: "h1 { color: red }",
                                       created: Date(timeIntervalSince1970: 1_700_000_000)), name: "Quiet")
        f.id = "6f2c5a52-6a52-4f55-9a9b-0e7b8a0f6d11"
        f.revision = 3
        f.author = "Sam"
        f.about = "A quieter example."
        return f
    }

    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    func testVersionTwoFilesRoundTripAndVersionOneStillOpens() throws {
        var f = fixture()
        f.preview = Self.png.base64EncodedString()
        let data = try f.encoded()
        let back = try BoostFile.decode(data)
        XCTAssertEqual(back, f)
        XCTAssertEqual(back.version, 2)
        XCTAssertEqual(back.previewData, Self.png)
        XCTAssertEqual(back.boost.font.knownCase, .capitalize)

        // A version 1 file (boostsplus's format) opens as it did.
        let v1 = #"{"version":1,"name":"Old","site":"example.com","createdAt":"2026-11-06T10:00:00Z","colors":{"hue":0.5,"tint":0.1,"brightness":1,"contrast":1,"invert":false},"font":{"size":0},"zaps":[],"css":"","js":""}"#
        let old = try BoostFile.decode(Data(v1.utf8))
        XCTAssertEqual(old.name, "Old")
        XCTAssertNil(old.id)
        // ...with version 1's keys only.
        for extra in [#","id":"6f2c5a52-6a52-4f55-9a9b-0e7b8a0f6d11","revision":1"#, #","author":"x""#] {
            let bad = v1.replacingOccurrences(of: #","js":"""#, with: #","js":"""# + extra)
            XCTAssertThrowsError(try BoostFile.decode(Data(bad.utf8)), extra)
        }
        XCTAssertThrowsError(try BoostFile.decode(Data(v1.replacingOccurrences(of: #""invert":false"#, with: #""invert":false,"saturation":1"#).utf8)))
        let three = v1.replacingOccurrences(of: #""version":1"#, with: #""version":3"#)
        XCTAssertThrowsError(try BoostFile.decode(Data(three.utf8))) { XCTAssertEqual($0 as? BoostFile.Invalid, .version) }
    }

    func testVersionTwoRejects() throws {
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture().encoded()) as? [String: Any])
        func rejects(_ what: String, _ edit: (inout [String: Any]) -> Void) {
            var object = base; edit(&object)
            XCTAssertThrowsError(try BoostFile.decode(JSONSerialization.data(withJSONObject: object)), what)
        }
        rejects("an id that isn't a UUID") { $0["id"] = "not-a-uuid" }
        rejects("an uppercase id") { $0["id"] = "6F2C5A52-6A52-4F55-9A9B-0E7B8A0F6D11" }
        rejects("a revision without an id") { $0["id"] = nil }
        rejects("revision 0") { $0["revision"] = 0 }
        rejects("a long author") { $0["author"] = String(repeating: "a", count: 61) }
        rejects("an author with a line break") { $0["author"] = "Sam\nAdmin" }
        rejects("a reordering author") { $0["author"] = "\u{202E}maS" }
        rejects("a long description") { $0["about"] = String(repeating: "a", count: 281) }
        rejects("a preview that isn't a picture") { $0["preview"] = Data("<svg onload=x>".utf8).base64EncodedString() }
        rejects("a huge preview") { $0["preview"] = Data([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0, count: 310 * 1024)).base64EncodedString() }
        rejects("saturation above 1") { $0["colors"] = ["hue": 0, "tint": 0, "brightness": 1, "contrast": 1, "invert": false, "saturation": 2] }
        rejects("an unknown case") { $0["font"] = ["size": 0, "case": "smallcaps"] }
        rejects("an unknown key") { $0["installs"] = 10 }
    }

    // MARK: Links

    func testLinksCarryTheWholeBoostAndNothingLeavesTheAddress() throws {
        var f = fixture()
        f.preview = Self.png.base64EncodedString()
        let url = try BoostLink.url(for: f)
        XCTAssertEqual(url.host, "aircbrowser.com")
        XCTAssertEqual(url.path, "/boost")
        XCTAssertNil(url.query, "the Boost is in the fragment, which the browser never sends")
        XCTAssertTrue(url.fragment?.hasPrefix("1.") == true)
        XCTAssertLessThan(url.absoluteString.count, 600, url.absoluteString)
        XCTAssertTrue(BoostLink.isLink(url))
        let back = try BoostLink.file(from: url)
        XCTAssertEqual(back, f.withoutPreview, "everything but the picture")
        XCTAssertTrue(BoostLink.isLink(URL(string: url.absoluteString.replacingOccurrences(of: "https://", with: "https://www."))))

        for other in ["http://aircbrowser.com/boost#1.x", "https://aircbrowser.com/boosts#1.x", "https://aircbrowser.com.evil.test/boost#1.x",
                      "https://aircbrowser.com/boost?1.x", "https://aircbrowser.com/boost#2.x", "https://aircbrowser.com/"] {
            XCTAssertFalse(BoostLink.isLink(URL(string: other)), other)
        }
        XCTAssertThrowsError(try BoostLink.file(from: URL(string: "https://aircbrowser.com/boost#1.!!!")!))
        XCTAssertThrowsError(try BoostLink.file(from: URL(string: "https://aircbrowser.com/boost#1.AAAA")!))

        // A bomb: a small link that would unpack past the file limit is refused without the big allocation.
        let zeros = Data(count: 4 * 1024 * 1024)
        let packed = try XCTUnwrap(BoostLink.deflate(zeros))
        XCTAssertLessThan(packed.count, 8 * 1024)
        XCTAssertNil(BoostLink.inflate(packed, limit: BoostFile.maximumBytes))
        let bomb = URL(string: "https://aircbrowser.com/boost#1." + BoostLink.base64url(packed))!
        XCTAssertThrowsError(try BoostLink.file(from: bomb))

        // Too big for a link: share the file.
        var big = fixture()
        big.css = (0..<2000).map { "#id\($0) { color: rgb(\($0 % 255), \(($0 * 7) % 255), \(($0 * 13) % 255)); }" }.joined(separator: "\n")
        XCTAssertThrowsError(try BoostLink.url(for: big)) { XCTAssertEqual($0 as? BoostFile.Invalid, .linkSize) }
    }

    // MARK: Updates

    func testSharingKeepsAnIdAndRevisionsAndInstallingUpdatesACopy() throws {
        let author = BoostStore(url: nil)
        author.update(domain: "example.com") { $0.colors.tint = 0.3 }
        let first = try XCTUnwrap(author.shareFile(domain: "example.com", name: "Warm", author: " Sam "))
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.author, "Sam")
        XCTAssertEqual(author.boost(domain: "example.com")?.origin, nil, "nothing is kept until it's shared")
        author.noteShared(first)
        XCTAssertEqual(author.boost(domain: "example.com")?.origin?.kind, .shared)
        XCTAssertEqual(author.boost(domain: "example.com")?.name, "Warm")
        // Shared again unchanged: the same revision; changed: the next one, same id.
        XCTAssertEqual(author.shareFile(domain: "example.com", name: "Warm", author: "Sam")?.revision, 1)
        author.update(domain: "example.com") { $0.enabled = false }
        XCTAssertFalse(author.boost(domain: "example.com")!.origin!.edited(author.boost(domain: "example.com")!),
                       "switching it off isn't an edit")
        XCTAssertEqual(author.shareFile(domain: "example.com", name: "Warm", author: "Sam")?.revision, 1)
        author.update(domain: "example.com") { $0.font.family = "georgia" }
        let second = try XCTUnwrap(author.shareFile(domain: "example.com", name: "Warm", author: "Sam"))
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.revision, 2)

        // Someone installs revision 1, then opens revision 2: an update.
        let reader = BoostStore(url: nil)
        XCTAssertEqual(BoostInstall.relation(of: first, to: nil), .new)
        try reader.install(first)
        let installed = try XCTUnwrap(reader.boost(domain: "example.com"))
        XCTAssertEqual(installed.origin?.kind, .installed)
        XCTAssertEqual(installed.origin?.author, "Sam")
        XCTAssertFalse(installed.origin!.edited(installed))
        XCTAssertEqual(BoostInstall.relation(of: second, to: installed), .update(from: 1, to: 2))
        XCTAssertEqual(BoostInstall.relation(of: first, to: installed), .reinstall(1))
        reader.update(domain: "example.com") { $0.css = "p { color: green }" }
        XCTAssertTrue(reader.boost(domain: "example.com")!.origin!.edited(reader.boost(domain: "example.com")!), "edited since")
        try reader.install(second, replacing: true)
        XCTAssertEqual(reader.boost(domain: "example.com")?.origin?.revision, 2)
        XCTAssertEqual(reader.boost(domain: "example.com")?.font.knownFamily, .georgia)
        XCTAssertEqual(reader.boost(domain: "example.com")?.css, "", "an update replaces the copy")
        XCTAssertEqual(BoostInstall.relation(of: first, to: reader.boost(domain: "example.com")), .older(have: 2, file: 1))

        // The author opens their own link: their own Boost.
        XCTAssertEqual(BoostInstall.relation(of: second, to: author.boost(domain: "example.com")), .own)
        // Another Boost for the site, or a file without an id: replace.
        var unrelated = second; unrelated.id = UUID().uuidString.lowercased()
        XCTAssertEqual(BoostInstall.relation(of: unrelated, to: installed), .replace)
        var anonymous = second; anonymous.id = nil; anonymous.revision = nil
        XCTAssertEqual(BoostInstall.relation(of: anonymous, to: installed), .replace)

        // An installed Boost shared on is a new Boost of the sharer's (Arc's forks).
        let fork = try XCTUnwrap(reader.shareFile(domain: "example.com", name: "Mine now", author: nil))
        XCTAssertNotEqual(fork.id, first.id)
        XCTAssertEqual(fork.revision, 1)
        XCTAssertNil(fork.author)

        reader.rename(domain: "example.com", to: "  Reading  ")
        XCTAssertEqual(reader.boost(domain: "example.com")?.name, "Reading")
        reader.rename(domain: "example.com", to: "example.com")
        XCTAssertNil(reader.boost(domain: "example.com")?.name)
    }

    func testTheDigestFollowsWhatTheBoostDoes() {
        var b = Boost(domain: "example.com", css: "a{}")
        let d = b.contentDigest
        b.name = "Renamed"; b.enabled = false; b.modified = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(b.contentDigest, d)
        b.zaps = [BoostZap(selector: ".x", label: "X")]
        XCTAssertNotEqual(b.contentDigest, d)
        var c = b; c.zaps[0].id = "another id"; c.zaps[0].created = Date(timeIntervalSince1970: 5)
        XCTAssertEqual(c.contentDigest, b.contentDigest, "a zap's id and date don't count")
    }

    // MARK: Gallery

    func testTheGalleryHoldsValidStyleOnlyBoosts() throws {
        XCTAssertGreaterThanOrEqual(BoostGallery.entries.count, 6)
        XCTAssertEqual(Set(BoostGallery.entries.map(\.id)).count, BoostGallery.entries.count, "ids are unique")
        for e in BoostGallery.entries {
            let f = try e.file.validated()
            XCTAssertTrue(f.js.isEmpty, "\(f.name): no JavaScript in the gallery")
            XCTAssertEqual(f.author, BoostGallery.author)
            XCTAssertNotNil(f.about)
            XCTAssertEqual(BoostDomain.key(for: e.page), f.site, "\(f.name): its page is on its site")
            XCTAssertFalse(f.boost.isEmpty, f.name)
            XCTAssertNoThrow(try BoostLink.url(for: f), "\(f.name) fits in a link")
            for (rule, source) in BoostCSSImports.review(f.css, site: f.site) {
                XCTFail("\(f.name): no imports in the gallery (\(rule.url): \(source))")
            }
            XCTAssertEqual(try BoostFile.decode(f.encoded()), f)
        }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
@testable import AircKit
import XCTest

/// easelall: Export All Easels' archive (names, collisions, pictures, the list page and README, many Easels) and the
/// streaming ZIP under it (ZIP64 past 65,535 entries).
final class EaselArchiveTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("easel-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // A real 1×1 PNG.
    let png = Data(hex: "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360f8cf00000301010018dd8db40000000049454e44ae426082")

    func easel(_ title: String, text: String = "Hello", picture: Data? = nil) throws -> (EaselPublic, [String: Data]) {
        var d = EaselDocument(id: newTestID(), title: title)
        d.add(EaselBlock(frame: EaselRect(x: 0, y: 0, width: 200, height: 60), content: .text(EaselText(plain: text))))
        let local = String(repeating: "c", count: 64) + ".png"
        if picture != nil {
            d.add(EaselBlock(frame: EaselRect(x: 0, y: 80, width: 100, height: 100),
                             content: .image(EaselImage(asset: local, pixelWidth: 1, pixelHeight: 1))))
        }
        var (p, report) = EaselPublic.make(d)
        var pictures: [String: Data] = [:]
        if let picture {
            let name = try XCTUnwrap(EaselPublic.pictureName(picture))
            p = p.settingPictures([local: .init(name: name, size: picture.count)], report: &report)
            pictures[name] = picture
        }
        return (p, pictures)
    }

    var counter = 0
    func newTestID() -> String {
        counter += 1
        return String(format: "%08d-0000-4000-8000-000000000000", counter)
    }

    func read(_ url: URL) throws -> [String: Data] {
        let entries = try XCTUnwrap(ZipReader.entries(try Data(contentsOf: url)), "the archive reads back")
        XCTAssertEqual(Set(entries.map(\.name)).count, entries.count, "no entry twice")
        return Dictionary(entries.map { ($0.name, $0.data) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Names

    func testArchiveNameIsArcsWithAircsName() {
        let d = Date(timeIntervalSince1970: 1_794_693_300) // 2026-11-14 21:55 UTC
        XCTAssertEqual(EaselArchive.name(date: d, timeZone: TimeZone(identifier: "UTC")!), "Airc Easels - 2026-11-14 21.55")
    }

    func testFolderNamesAreUniqueTheWayAMacComparesThem() {
        var n = EaselArchive.Names()
        XCTAssertEqual(n.take("Trip"), "Trip")
        XCTAssertEqual(n.take("trip"), "trip 2", "case doesn't make another name on a Mac")
        XCTAssertEqual(n.take("TRIP"), "TRIP 3")
        XCTAssertEqual(n.take("Trip 2"), "Trip 2 2", "a title that looks like a numbered one gets its own number")
        XCTAssertEqual(n.take("Caf\u{E9}"), "Café")
        XCTAssertEqual(n.take("Cafe\u{301}"), "Café 2", "decomposed é is the same name")
        XCTAssertEqual(n.take(""), "Untitled Easel")
        XCTAssertEqual(n.take("   "), "Untitled Easel 2")
        XCTAssertEqual(n.take("index.html"), "index.html 2", "never the list page's name")
        XCTAssertEqual(n.take("readme.md"), "readme.md 2", "never the README's name")
        XCTAssertEqual(n.take("a/b:c"), "a-b-c")
        XCTAssertEqual(n.take("../x"), "x", "no way out of the archive's folder")
    }

    // MARK: The archive

    func testEveryEaselHasItsFolderWithPagesDataAndPictures() throws {
        let url = dir.appendingPathComponent("all.zip")
        let w = try EaselArchive.Writer(url: url, root: "Airc Easels - 2026-11-14 21.55")
        let (a, ap) = try easel("Trip", text: "Lisbon", picture: png)
        let (b, bp) = try easel("Trip", text: "Porto")
        let (c, cp) = try easel("Moodboard / v2", text: "Colours")
        try w.add(a, pictures: ap, shared: true)
        try w.add(b, pictures: bp)
        try w.add(c, pictures: cp)
        w.skip(title: "Broken")
        var empty = EaselPublic.make(EaselDocument(id: newTestID(), title: "Blank")).0
        empty.blocks = []
        try w.add(empty, pictures: [:])
        try w.finish(dateText: "14 November 2026")
        let files = try read(url)
        let root = "Airc Easels - 2026-11-14 21.55"
        let pic = try XCTUnwrap(EaselPublic.pictureName(png))
        XCTAssertEqual(Set(files.keys), [
            "\(root)/index.html", "\(root)/README.md",
            "\(root)/Trip/index.html", "\(root)/Trip/easel.json", "\(root)/Trip/assets/\(pic)",
            "\(root)/Trip 2/index.html", "\(root)/Trip 2/easel.json",
            "\(root)/Moodboard - v2/index.html", "\(root)/Moodboard - v2/easel.json",
        ])
        XCTAssertEqual(files["\(root)/Trip/assets/\(pic)"], png, "the picture's bytes")
        // Each Easel's page is exactly the one Export as Web Page… writes.
        XCTAssertEqual(files["\(root)/Trip/index.html"], Data(EaselHTML.page(a, asset: { "assets/\($0)" }).utf8))
        XCTAssertEqual(try JSONDecoder().decode(EaselPublic.self, from: try XCTUnwrap(files["\(root)/Trip 2/easel.json"])), b)
        let porto = String(decoding: try XCTUnwrap(files["\(root)/Trip 2/index.html"]), as: UTF8.self)
        XCTAssertTrue(porto.contains("Porto") && !porto.contains("Lisbon"), "the second Trip is its own page")
        // The list page links each saved Easel's page, escaped, and nothing from the web.
        let list = String(decoding: try XCTUnwrap(files["\(root)/index.html"]), as: UTF8.self)
        XCTAssertTrue(list.contains("href=\"Trip/index.html\""))
        XCTAssertTrue(list.contains("href=\"Trip%202/index.html\""))
        XCTAssertTrue(list.contains("href=\"Moodboard%20-%20v2/index.html\""))
        XCTAssertTrue(list.contains("3 Easels, saved from Airc on 14 November 2026"))
        XCTAssertTrue(list.contains("<span class=\"badge\">Shared</span>"))
        XCTAssertEqual(list.components(separatedBy: "class=\"badge\"").count - 1, 1, "one Shared badge")
        XCTAssertFalse(list.contains("Broken") || list.contains("Blank"), "only Easels in the archive are listed")
        XCTAssertFalse(list.contains("http://") || list.contains("https://") || list.contains("<script"))
        // The README's log says what happened to each.
        let readme = String(decoding: try XCTUnwrap(files["\(root)/README.md"]), as: UTF8.self)
        XCTAssertTrue(readme.contains("- ✅ Trip: saved (`Trip/`)"))
        XCTAssertTrue(readme.contains("- ✅ Trip: saved (`Trip 2/`)"))
        XCTAssertTrue(readme.contains("- ❌ Broken: couldn’t be read, so it isn’t in this archive"))
        XCTAssertTrue(readme.contains("- Blank: empty, so it isn’t in this archive"))
        XCTAssertEqual(w.entries.filter(\.isSaved).count, 3)
    }

    func testAMissingPictureFailsOnlyThatEaselAndWritesNothingOfIt() throws {
        let url = dir.appendingPathComponent("all.zip")
        let w = try EaselArchive.Writer(url: url, root: "R")
        let (a, _) = try easel("Lost", picture: png)
        XCTAssertThrowsError(try w.add(a, pictures: [:]))
        let (b, bp) = try easel("Kept")
        try w.add(b, pictures: bp)
        try w.finish(dateText: "today")
        let names = Set(try read(url).keys)
        XCTAssertFalse(names.contains { $0.hasPrefix("R/Lost") }, "nothing of the failed Easel")
        XCTAssertTrue(names.contains("R/Kept/index.html"))
    }

    func testPartlySavedEaselsSaySoInTheLog() throws {
        let url = dir.appendingPathComponent("all.zip")
        let w = try EaselArchive.Writer(url: url, root: "R")
        let (a, ap) = try easel("Half")
        var report = EaselPublic.Report()
        report.picturesMissing = 2
        report.leftOut = 1
        try w.add(a, pictures: ap, report: report)
        try w.finish(dateText: "today")
        let readme = String(decoding: try XCTUnwrap(try read(url)["R/README.md"]), as: UTF8.self)
        XCTAssertTrue(readme.contains("- ⚠️ Half: saved (`Half/`), but 2 pictures couldn’t be read and are left out and 1 item made by a newer Airc is left out"), readme)
    }

    func testTitlesAreEscapedOnTheListPage() throws {
        let entries = [EaselArchive.Entry(title: "<script>x</script> & \"q\"", folder: "a&b#c%d", items: 1, pictures: 0, shared: false,
                                          outcome: .saved(missing: 0, leftOut: 0))]
        let page = EaselArchive.listPage(entries, dateText: "<now>")
        XCTAssertFalse(page.contains("<script>"))
        XCTAssertTrue(page.contains("&lt;script&gt;x&lt;/script&gt; &amp; &quot;q&quot;"))
        XCTAssertTrue(page.contains("href=\"a&amp;b%23c%25d/index.html\""), page)
        XCTAssertTrue(page.contains("&lt;now&gt;"))
    }

    func testAThousandEaselsWithPicturesMakeOneArchive() throws {
        let url = dir.appendingPathComponent("many.zip")
        let w = try EaselArchive.Writer(url: url, root: "Many")
        for i in 0..<1_000 {
            // Every tenth has a picture; every Easel's title is one of 50, so most need a number.
            let (e, p) = try easel("Board \(i % 50)", text: "n\(i)", picture: i % 10 == 0 ? png : nil)
            try w.add(e, pictures: p)
        }
        try w.finish(dateText: "today")
        let files = try read(url)
        XCTAssertEqual(files.count, 2 + 1_000 * 2 + 100)
        let folders = Set(files.keys.compactMap { k -> String? in
            let parts = k.split(separator: "/")
            return parts.count >= 3 ? String(parts[1]) : nil
        })
        XCTAssertEqual(folders.count, 1_000, "every Easel its own folder")
        XCTAssertTrue(folders.contains("Board 7") && folders.contains("Board 7 2") && folders.contains("Board 7 20"))
        let list = String(decoding: try XCTUnwrap(files["Many/index.html"]), as: UTF8.self)
        XCTAssertEqual(list.components(separatedBy: "<li>").count - 1, 1_000)
        XCTAssertTrue(list.contains("1000 Easels, saved from Airc"))
    }

    // MARK: The ZIP

    func testTheFileWriterWritesTheSameBytesAsTheMemoryOne() throws {
        let date = Date(timeIntervalSince1970: 1_794_700_500)
        var mem = ZipWriter(date: date)
        let url = dir.appendingPathComponent("same.zip")
        let file = try ZipFileWriter(url: url, date: date)
        for (n, d) in [("a/index.html", Data("<p>hi</p>".utf8)), ("a/assets/x.png", png), ("a/empty", Data())] {
            mem.add(n, d)
            try file.add(n, d)
        }
        try file.finish()
        XCTAssertEqual(try Data(contentsOf: url), mem.finish())
    }

    func testPast65535EntriesTheArchiveIsZip64AndReadsBack() throws {
        let url = dir.appendingPathComponent("big.zip")
        let w = try ZipFileWriter(url: url)
        let n = 70_000
        for i in 0..<n { try w.add("r/\(i)", Data([UInt8(i & 0xFF)])) }
        try w.finish()
        let data = try Data(contentsOf: url)
        let b = [UInt8](data)
        func u32(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
        XCTAssertEqual(u32(b.count - 22), 0x06054B50)
        XCTAssertEqual(u32(b.count - 42), 0x07064B50, "the ZIP64 locator")
        XCTAssertEqual(b[b.count - 12], 0xFF, "the plain record's count says 'see ZIP64'")
        let entries = try XCTUnwrap(ZipReader.entries(data))
        XCTAssertEqual(entries.count, n)
        XCTAssertEqual(entries.last?.name, "r/\(n - 1)")
        XCTAssertEqual(entries[300].data, Data([UInt8(300 & 0xFF)]))
        // The system's own unzip reads it too, where there is one.
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        if FileManager.default.isExecutableFile(atPath: unzip.path) {
            let p = Process()
            p.executableURL = unzip
            p.arguments = ["-tqq", url.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "unzip -t accepts the ZIP64 archive")
        }
    }
}

private extension Data {
    init(hex: String) {
        var d = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            d.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self = d
    }
}

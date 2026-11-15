// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
@testable import AircKit
import XCTest

/// P19c: what an Easel's export or link holds (EaselPublic), the HTML ZIP (round trip, safe names, nothing private in
/// it), Easel link records, and an undone row copy taking its Easel with it.
final class EaselExportTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("easel-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        EaselFiles.shared = nil
        EaselFiles.didDelete = nil
        try? FileManager.default.removeItem(at: root)
    }

    // A real 1×1 PNG.
    let png = Data(hex: "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360f8cf00000301010018dd8db40000000049454e44ae426082")
    let localAsset = String(repeating: "b", count: 64) + ".png"
    let secrets = ["s3cr3t-session", "tok-123456", "hunter2", "profile-secret-p1", "oauth-abc", "page-of-origin"]

    func board() -> EaselDocument {
        var d = EaselDocument(id: "e1", title: "Trip / plans: \u{202E}v2")
        var text = NoteDocument(blocks: [NoteBlock(kind: .heading1, runs: [NoteRun("Lisbon")]),
                                         NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("Book")]),
                                         NoteBlock(kind: .paragraph, runs: [NoteRun("signed in"), NoteRun(" here")])])
        text.blocks[2].runs[0].link = "https://mail.example.com/inbox?session=s3cr3t-session&view=all"
        text.blocks[2].runs[1].link = "javascript:alert(1)"
        d.add(EaselBlock(id: "t", frame: EaselRect(x: 0, y: 0, width: 280, height: 90), content: .text(EaselText(text, color: .red))))
        d.add(EaselBlock(id: "i", frame: EaselRect(x: 300, y: 0, width: 100, height: 100), rotation: 0.2,
                         content: .image(EaselImage(asset: localAsset, pixelWidth: 1, pixelHeight: 1, source: "https://page-of-origin.example/", altText: "A tram"))))
        let live = EaselLiveSource(url: "https://dash.example.com/stats?token=tok-123456#access_token=oauth-abc", profileID: "profile-secret-p1",
                                   rect: EaselRect(x: 0, y: 0, width: 300, height: 200), scrollX: 0, scrollY: 0, viewportWidth: 1200,
                                   viewportHeight: 800, zoom: 1, mode: .live, refreshedAt: Date())
        d.add(EaselBlock(id: "c", frame: EaselRect(x: 0, y: 120, width: 300, height: 200),
                         content: .capture(EaselCapture(asset: localAsset, pixelWidth: 1, pixelHeight: 1, url: live.url, title: "Stats", live: live))))
        d.add(EaselBlock(id: "l", frame: EaselRect(x: 320, y: 120, width: 320, height: 96),
                         content: .link(EaselLink(url: "https://user:hunter2@example.com/doc?id=7&api_key=k", title: "Doc", detail: "Line\none"))))
        d.add(EaselBlock(id: "j", frame: EaselRect(x: 320, y: 230, width: 320, height: 96), content: .link(EaselLink(url: "file:///etc/hosts"))))
        d.add(EaselBlock(id: "s", frame: EaselRect(x: 0, y: 340, width: 50, height: 50), content: .shape(EaselShape(.ellipse, fill: .lightGreen, stroke: .white))))
        d.add(EaselBlock(id: "a", frame: .init(x: 0, y: 0, width: 1, height: 1),
                         content: .line(EaselLine(from: EaselPoint(60, 340), to: EaselPoint(160, 400), color: .lightBlue))))
        d.add(EaselBlock(id: "u", frame: EaselRect(x: 0, y: 420, width: 10, height: 10), content: .unknown(type: "pencil", fields: ["path": .string("M0 0")])))
        return d
    }

    func published(_ only: Set<String>? = nil) throws -> (EaselPublic, EaselPublic.Report) {
        var (p, report) = EaselPublic.make(board(), only: only)
        let name = try XCTUnwrap(EaselPublic.pictureName(png))
        p = p.settingPictures([localAsset: .init(name: name, size: png.count)], report: &report)
        return (p, report)
    }

    // MARK: What goes out

    func testThePublicFormHasTheBlocksAndNothingPrivate() throws {
        let (p, report) = try published()
        XCTAssertEqual(p.blocks.map(\.content.type), ["text", "image", "capture", "link", "shape", "line"])
        XCTAssertEqual(report.leftOut, 1, "the newer build's block")
        XCTAssertEqual(report.liveCaptures, 1)
        XCTAssertEqual(report.linksDropped, 2, "javascript: in the text, file: as a card")
        XCTAssertEqual(report.addressesCleaned, 3, "the mail link's session, the capture's token, the card's password and key")
        XCTAssertEqual(p.title, "Trip / plans: v2", "no direction override")
        XCTAssertEqual(p.background, "#FEFDFE")
        let text = p.blocks[0].content
        XCTAssertEqual(text.color, EaselColor.red.hex(.chill, dark: false))
        XCTAssertEqual(text.paragraphs?.map(\.kind), [.heading1, .checkbox, .paragraph])
        XCTAssertEqual(text.paragraphs?[1].checked, true)
        XCTAssertEqual(text.paragraphs?[2].runs.map(\.link), ["https://mail.example.com/inbox?view=all", nil])
        XCTAssertEqual(p.blocks[1].rotation, 0.2)
        XCTAssertEqual(p.blocks[1].content.alt, "A tram")
        XCTAssertEqual(p.blocks[2].content.url, "https://dash.example.com/stats")
        XCTAssertEqual(p.blocks[3].content.url, "https://example.com/doc?id=7")
        XCTAssertEqual(p.blocks[3].content.detail, "Line\none")
        XCTAssertEqual(p.blocks[4].content.stroke, "#0000001A")
        let name = try XCTUnwrap(EaselPublic.pictureName(png))
        XCTAssertEqual(p.assets, [.init(name: name, size: png.count)], "one picture, shown twice")
        XCTAssertEqual(p.blocks[1].content.asset, name)
        let json = String(decoding: try p.encoded(), as: UTF8.self)
        for s in secrets { XCTAssertFalse(json.contains(s), s) }
        for key in ["profileID", "live", "group", "\"id\"", "source", "revision", "viewport", "scroll"] { XCTAssertFalse(json.contains(key), key) }
        XCTAssertNoThrow(try p.check())
    }

    func testTheJSONHasExactlyEachKindsKeys() throws {
        let (p, _) = try published()
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: try p.encoded()) as? [String: Any])
        XCTAssertEqual(Set(top.keys), ["kind", "version", "title", "background", "blocks", "assets"])
        let blocks = try XCTUnwrap(top["blocks"] as? [[String: Any]])
        let keys = blocks.map { Set(($0["content"] as? [String: Any] ?? [:]).keys) }
        XCTAssertEqual(keys[0], ["type", "paragraphs", "font", "size", "color", "alignment"])
        XCTAssertEqual(keys[1], ["type", "asset", "alt"])
        XCTAssertEqual(keys[2], ["type", "asset", "url", "title"])
        XCTAssertEqual(keys[3], ["type", "url", "title", "detail"])
        XCTAssertEqual(keys[4], ["type", "kind", "fill", "stroke", "strokeWidth", "cornerRadius"])
        XCTAssertEqual(keys[5], ["type", "from", "to", "startHead", "endHead", "color", "width"])
        XCTAssertEqual(Set(blocks[1].keys), ["frame", "rotation", "content"])
        XCTAssertEqual(Set(blocks[0].keys), ["frame", "content"])
    }

    func testASelectionHasOnlyItsBlocks() throws {
        let (p, _) = try published(["s", "t"])
        XCTAssertEqual(p.blocks.map(\.content.type), ["text", "shape"])
        XCTAssertEqual(p.assets, [])
    }

    func testAMissingPictureTakesItsBlock() throws {
        var (p, report) = EaselPublic.make(board())
        p = p.settingPictures([:], report: &report)
        XCTAssertEqual(report.picturesMissing, 2)
        XCTAssertFalse(p.blocks.contains { $0.content.type == "image" || $0.content.type == "capture" })
        XCTAssertEqual(p.assets, [])
    }

    func testWebAddresses() {
        let cases: [(String, String?)] = [
            ("https://example.com/a?b=1#top", "https://example.com/a?b=1#top"),
            ("HTTPS://Example.com/", "https://Example.com/"),
            ("https://u:p@example.com/", "https://example.com/"),
            ("https://example.com/?access_token=x&q=cats", "https://example.com/?q=cats"),
            ("https://example.com/?SessionID=x", "https://example.com/"),
            ("https://example.com/?X-Amz-Signature=x&X-Amz-Credential=y&page=2", "https://example.com/?page=2"),
            ("https://example.com/cb#access_token=x&expires=1", "https://example.com/cb"),
            ("https://example.com/?author=me", "https://example.com/?author=me"),
            ("javascript:alert(1)", nil), ("data:text/html,x", nil), ("file:///etc/hosts", nil), ("airc-easel:e1", nil),
            ("https://", nil), ("not a url", nil),
        ]
        for (input, want) in cases { XCTAssertEqual(EaselPublic.webAddress(input), want, input) }
    }

    func testPictureTypesAreReadFromTheBytes() {
        XCTAssertEqual(EaselPublic.pictureType(png), "png")
        XCTAssertEqual(EaselPublic.pictureType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
        XCTAssertEqual(EaselPublic.pictureType(Data("GIF89a".utf8)), "gif")
        XCTAssertEqual(EaselPublic.pictureType(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), "webp")
        XCTAssertNil(EaselPublic.pictureType(Data("<svg>".utf8)))
        XCTAssertNil(EaselPublic.pictureType(Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])), "HEIC is converted first")
    }

    func testLimitsAreCheckedBeforeAnythingIsSent() throws {
        var (p, _) = try published()
        p.assets = [.init(name: p.assets[0].name, size: EaselPublic.maxAssetBytes + 1)]
        XCTAssertThrowsError(try p.check()) { XCTAssertEqual($0 as? EaselPublic.Problem, .tooLarge) }
        XCTAssertThrowsError(try EaselPublic.make(EaselDocument(id: "x")).0.check()) { XCTAssertEqual($0 as? EaselPublic.Problem, .empty) }
    }

    // MARK: The HTML export

    func testTheHTMLArchiveRoundTrips() throws {
        let (p, _) = try published()
        let zip = try EaselExport.htmlArchive(p, pictures: [p.assets[0].name: png], date: Date(timeIntervalSince1970: 1_800_000_000))
        let entries = try XCTUnwrap(ZipReader.entries(zip))
        let folder = "Trip - plans- v2"
        XCTAssertEqual(entries.map(\.name), ["\(folder)/index.html", "\(folder)/easel.json", "\(folder)/assets/\(p.assets[0].name)"])
        XCTAssertTrue(entries.allSatisfy { ZipWriter.isSafeName($0.name) })
        let back = try JSONDecoder().decode(EaselPublic.self, from: entries[1].data)
        XCTAssertEqual(back, p)
        XCTAssertEqual(entries[2].data, png)
        let html = String(decoding: entries[0].data, as: UTF8.self)
        XCTAssertTrue(html.contains("src=\"assets/\(p.assets[0].name)\""))
        XCTAssertTrue(html.contains("<h1>Lisbon</h1>"))
        XCTAssertTrue(html.contains("href=\"https://example.com/doc?id=7\" target=\"_blank\" rel=\"noopener noreferrer nofollow\""))
        XCTAssertTrue(html.contains("transform:rotate(0.2rad)"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("http://") || html.contains("//fonts"), "nothing loads from the web")
        // The same bytes for the same Easel and date.
        XCTAssertEqual(zip, try EaselExport.htmlArchive(p, pictures: [p.assets[0].name: png], date: Date(timeIntervalSince1970: 1_800_000_000)))
        // A picture whose bytes aren't what its name says is refused.
        XCTAssertThrowsError(try EaselExport.htmlArchive(p, pictures: [p.assets[0].name: Data("x".utf8)]))
    }

    func testNoTokensCookiesOrProfilesInTheZip() throws {
        let (p, _) = try published()
        let zip = try EaselExport.htmlArchive(p, pictures: [p.assets[0].name: png], date: Date(timeIntervalSince1970: 1_800_000_000))
        let text = String(decoding: zip, as: UTF8.self)
        for s in secrets + ["Cookie", "cookie", "localStorage", "p1"] { XCTAssertFalse(text.contains(s), s) }
    }

    func testTheHTMLEscapesEverything() throws {
        var d = EaselDocument(id: "x", title: "<script>alert(1)</script>")
        d.add(EaselBlock(frame: EaselRect(x: 0, y: 0, width: 100, height: 40), content: .text(EaselText(plain: "<img src=x onerror=alert(1)>\"'"))))
        d.add(EaselBlock(frame: EaselRect(x: 0, y: 50, width: 320, height: 96),
                         content: .link(EaselLink(url: "https://example.com/", title: "<b>", detail: "&"))))
        let html = EaselHTML.page(EaselPublic.make(d).0, asset: { $0 })
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<img src=x"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;&quot;&#39;"))
        XCTAssertTrue(html.contains("&lt;b&gt;"))
    }

    func testSafeFileNames() {
        let cases: [(String, String)] = [
            ("Trip: Lisbon?", "Trip- Lisbon"), ("a/b\\c", "a-b-c"), ("../../etc/passwd", "etc-passwd"), (".hidden", "hidden"),
            ("", "Untitled Easel"), ("   ", "Untitled Easel"), ("CON", "Easel CON"), ("nul.txt", "Easel nul.txt"),
            ("abc\u{202E}gpj.exe", "abcgpj.exe"), ("line\nbreak", "line break"), ("x\u{0}y", "xy"), ("Plans 🏝️", "Plans 🏝️"),
        ]
        for (input, want) in cases { XCTAssertEqual(EaselExport.fileName(input), want, input) }
        XCTAssertEqual(EaselExport.fileName(String(repeating: "a", count: 300)).count, 80)
        for (input, _) in cases { XCTAssertTrue(ZipWriter.isSafeName(EaselExport.fileName(input) + "/index.html"), input) }
        XCTAssertFalse(ZipWriter.isSafeName("../x"))
        XCTAssertFalse(ZipWriter.isSafeName("/x"))
        XCTAssertFalse(ZipWriter.isSafeName("a//b"))
    }

    // MARK: Links this Mac made

    func testEaselLinkRecordsAndALaterKindKeepTheOthers() throws {
        let r = SharedLinkRecord(id: "AbCdEfGhIjKl", url: URL(string: "https://aircbrowser.com/e/AbCdEfGhIjKl")!, kind: .easel,
                                 name: "Board", sourceID: "e1", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(SharedLinkRecord.load(SharedLinkRecord.save([r])), [r])
        var json = String(decoding: SharedLinkRecord.save([r]), as: UTF8.self)
        json = json.replacingOccurrences(of: "[", with: "[{\"id\":\"ZZZZZZZZZZZZ\",\"kind\":\"hologram\",\"name\":\"x\",\"sourceID\":\"y\",\"url\":\"https://x.example\",\"createdAt\":\"2027-01-01T00:00:00Z\"},")
        XCTAssertEqual(SharedLinkRecord.load(Data(json.utf8)), [r])
        XCTAssertTrue(HostedEaselLink.isLink(URL(string: "https://aircbrowser.com/e/AbCdEfGhIjKl"), id: "AbCdEfGhIjKl"))
        XCTAssertFalse(HostedEaselLink.isLink(URL(string: "https://aircbrowser.com/s/AbCdEfGhIjKl"), id: "AbCdEfGhIjKl"))
        XCTAssertFalse(HostedEaselLink.isLink(URL(string: "https://aircbrowser.com/e/AbCdEfGhIjKl?x=1"), id: "AbCdEfGhIjKl"))
    }

    // MARK: Publishing (against a stubbed network; the service's side is apps/marketing/test/easel.test.mjs)

    func testPublishSendsTheEaselThenEachPictureThenPublishes() async throws {
        typealias Stub = SharingServiceTests.Stub
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        let service = SharingService(base: URL(string: "https://aircbrowser.com")!, session: URLSession(configuration: c))
        let (p, _) = try published()
        let name = p.assets[0].name, id = "Ab3dEf6hIj9K", token = "secret-token-0123456789"
        Stub.seen = []
        Stub.answer = { r, _ in
            switch (r.httpMethod, r.url?.query) {
            case ("POST", nil):
                return (201, try! JSONSerialization.data(withJSONObject: ["id": id, "url": "https://aircbrowser.com/e/\(id)", "token": token, "missing": [name]]))
            case ("PUT", _): return (204, Data())
            case ("POST", _): return (200, try! JSONSerialization.data(withJSONObject: ["id": id, "url": "https://aircbrowser.com/e/\(id)"]))
            default: return (404, Data())
            }
        }
        let made = try await service.publishEasel(p, pictures: [name: png])
        XCTAssertEqual(made.url.absoluteString, "https://aircbrowser.com/e/\(id)")
        XCTAssertEqual(made.token, token)
        let steps = Stub.seen.map { "\($0.0.httpMethod ?? "") \($0.0.url?.path ?? "")?\($0.0.url?.query ?? "")" }
        XCTAssertEqual(steps, ["POST /api/easel?", "PUT /api/easel?asset=\(name)&id=\(id)", "POST /api/easel?id=\(id)&publish=1"])
        XCTAssertEqual(try JSONDecoder().decode(EaselPublic.self, from: try XCTUnwrap(Stub.seen[0].1)), p)
        XCTAssertEqual(Stub.seen[1].1, png)
        XCTAssertEqual(Stub.seen[1].0.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(Stub.seen[1].0.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertNil(Stub.seen[0].0.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(Stub.seen[0].0.value(forHTTPHeaderField: "Cookie"))

        // A picture that's refused: the unfinished link is taken back, and the error is the service's sentence.
        Stub.seen = []
        Stub.answer = { r, _ in
            switch r.httpMethod {
            case "POST": return (201, try! JSONSerialization.data(withJSONObject: ["id": id, "url": "https://aircbrowser.com/e/\(id)", "token": token, "missing": [name]]))
            case "PUT": return (422, try! JSONSerialization.data(withJSONObject: ["error": "damaged", "message": "This picture didn't arrive whole. Try sharing again."]))
            default: return (204, Data())
            }
        }
        do { _ = try await service.publishEasel(p, pictures: [name: png]); XCTFail() }
        catch SharingService.Failure.refused(let why) { XCTAssertEqual(why, "This picture didn't arrive whole. Try sharing again.") }
        XCTAssertEqual(Stub.seen.last?.0.httpMethod, "DELETE")
        // An answer that isn't an Easel link of the id is refused.
        Stub.answer = { _, _ in (201, try! JSONSerialization.data(withJSONObject: ["id": id, "url": "https://evil.example/e/\(id)x", "token": token, "missing": []])) }
        do { _ = try await service.publishEasel(p, pictures: [name: png]); XCTFail() } catch let f as SharingService.Failure { XCTAssertEqual(f, .damaged) }
        // Pictures that don't match what the Easel says are never sent.
        Stub.seen = []
        do { _ = try await service.publishEasel(p, pictures: [name: Data("x".utf8)]); XCTFail() } catch {}
        XCTAssertTrue(Stub.seen.isEmpty)
    }

    // MARK: P19b's leftover: undoing a row copy

    func testUndoingARowCopyDeletesItsEasel() throws {
        let f = EaselFiles(root: root)
        EaselFiles.shared = f
        var deleted: [String] = []
        EaselFiles.didDelete = { deleted += $0 }
        let s = try makeStore()
        let space = s.selectedSpace.id
        try f.save(board())
        let t = try s.createEasel("e1", inSpace: space, pinned: false, title: "Board")
        // ⌥-drag copies the row (one undo step, "Duplicate"): the copy has an Easel of its own.
        let made = try s.copy(.tab(t.id), to: .today(spaceID: space, index: 0))
        let copyID = try XCTUnwrap(EaselURL.easelID(s.tab(made)?.url))
        XCTAssertTrue(f.exists(copyID))
        XCTAssertEqual(s.undoLabel, "Duplicate")
        try s.undo()
        XCTAssertNil(s.tab(made))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.folder(copyID).path), "the copied Easel is gone")
        XCTAssertEqual(deleted, [copyID])
        XCTAssertTrue(f.exists("e1"), "the original stays")
        XCTAssertFalse(f.list().contains { $0.id == copyID })
        // The sidebar's Duplicate on a selection, undone: the same.
        let dups = try s.duplicate([.tab(t.id)])
        let dupID = try XCTUnwrap(dups.compactMap { EaselURL.easelID(s.tab($0)?.url ?? s.item($0)?.savedURL) }.first)
        XCTAssertTrue(f.exists(dupID))
        try s.undo()
        XCTAssertFalse(f.exists(dupID))
        XCTAssertEqual(deleted, [copyID, dupID])
        // A copy that's kept stays, and undoing something else leaves it and the original alone.
        let kept = try s.copy(.tab(t.id), to: .today(spaceID: space, index: 0))
        let keptID = try XCTUnwrap(EaselURL.easelID(s.tab(kept)?.url))
        try s.togglePin([.tab(t.id)], inSpace: space)
        XCTAssertEqual(s.undoLabel, "Pin")
        try s.undo()
        XCTAssertTrue(f.exists(keptID))
        XCTAssertTrue(f.exists("e1"))
        XCTAssertEqual(deleted, [copyID, dupID])
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

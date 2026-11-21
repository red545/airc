// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
@testable import AircKit
import CoreGraphics
import ImageIO
import XCTest

/// P19d: a shared Easel link added to Airc. The link forms, the strict reading of what the service sends (all or
/// nothing, as the service checks it), each picture's checks, the local copy (the same items, new ids, not linked), and
/// the client's requests (https only, never answered from another host).
final class EaselImportTests: XCTestCase {
    override class func setUp() { super.setUp(); TestSuffixes.installForClass() }
    override class func tearDown() { TestSuffixes.restoreAfterClass(); super.tearDown() }

    let id = "Ab3dEf6hIj9K"

    /// A real PNG of `w`×`h` pixels.
    func png(_ w: Int = 4, _ h: Int = 3) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// The shared form of a board with every kind of item, its pictures named by their bytes.
    func shared() throws -> (EaselPublic, [String: Data]) {
        let pic = png(), local = String(repeating: "c", count: 64) + ".png"
        var d = EaselDocument(id: "src", title: "Lisbon trip", palette: .vibrant)
        var text = NoteDocument(blocks: [NoteBlock(kind: .heading1, runs: [NoteRun("Plan", marks: [.bold])]),
                                         NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("Book "), NoteRun("tram", marks: [.italic, .code], link: "https://example.com/tram")]),
                                         NoteBlock(kind: .bullet, indent: 2, runs: [NoteRun("Line\tone\ntwo")])])
        text.blocks[0].runs[0].marks.insert(.underline)
        d.add(EaselBlock(id: "t", frame: EaselRect(x: 10, y: 20, width: 280, height: 90), content: .text(EaselText(text, font: .mono, size: 21, color: .purple, alignment: .center))))
        d.add(EaselBlock(id: "p", frame: EaselRect(x: 0, y: 100, width: 200, height: 40), content: .text(EaselText(plain: "Default colour"))))
        d.add(EaselBlock(id: "i", frame: EaselRect(x: 300, y: 0, width: 120, height: 90), rotation: 0.3,
                         content: .image(EaselImage(asset: local, pixelWidth: 4, pixelHeight: 3, source: "https://origin.example/", altText: "Red"))))
        d.add(EaselBlock(id: "s", frame: EaselRect(x: 0, y: 340, width: 50, height: 60),
                         content: .shape(EaselShape(.rectangle, fill: .yellow, stroke: .white, strokeWidth: 4, cornerRadius: 8))))
        d.add(EaselBlock(id: "e", frame: EaselRect(x: 60, y: 340, width: 50, height: 60), content: .shape(EaselShape(.ellipse, stroke: .darkGreen))))
        d.add(EaselBlock(id: "a", frame: .init(x: 0, y: 0, width: 1, height: 1),
                         content: .line(EaselLine(from: EaselPoint(60, 340), to: EaselPoint(160, 400), startHead: true, endHead: true, color: .red, width: 5))))
        d.add(EaselBlock(id: "l", frame: EaselRect(x: 320, y: 120, width: 320, height: 96),
                         content: .link(EaselLink(url: "https://example.com/doc", title: "Doc", detail: "Two\nlines", image: local))))
        d.add(EaselBlock(id: "c", frame: EaselRect(x: 0, y: 420, width: 300, height: 200),
                         content: .capture(EaselCapture(asset: local, pixelWidth: 4, pixelHeight: 3, url: "https://dash.example.com/", title: "Stats"))))
        var (p, report) = EaselPublic.make(d)
        let name = try XCTUnwrap(EaselPublic.pictureName(pic))
        p = p.settingPictures([local: .init(name: name, size: pic.count)], report: &report)
        return (p, [name: pic])
    }

    func json(_ p: EaselPublic) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: try p.encoded()) as? [String: Any]) }
    func data(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    func refused(_ o: Any, _ want: EaselImport.Failure, _ why: String, line: UInt = #line) {
        XCTAssertThrowsError(try EaselImport.decode(data(o)), why, line: line) { XCTAssertEqual($0 as? EaselImport.Failure, want, why, line: line) }
    }

    /// `p`'s JSON with `change` applied to block `i`'s content.
    func editing(_ p: EaselPublic, block i: Int, _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var top = try json(p)
        var blocks = try XCTUnwrap(top["blocks"] as? [[String: Any]])
        var c = try XCTUnwrap(blocks[i]["content"] as? [String: Any])
        change(&c)
        blocks[i]["content"] = c
        top["blocks"] = blocks
        return top
    }

    // MARK: Links

    func testEaselLinks() {
        XCTAssertEqual(HostedEaselLink.id(from: URL(string: "https://aircbrowser.com/e/\(id)")), id)
        XCTAssertEqual(HostedEaselLink.id(from: URL(string: "https://www.aircbrowser.com/e/\(id)/")), id)
        XCTAssertEqual(HostedEaselLink.id(from: URL(string: "airc://easel/\(id)")), id)
        XCTAssertEqual(HostedEaselLink.appURL(id: id)?.absoluteString, "airc://easel/\(id)")
        XCTAssertNil(HostedEaselLink.appURL(id: "nope"))
        let local = URL(string: "http://127.0.0.1:4390")!
        XCTAssertEqual(HostedEaselLink.id(from: URL(string: "http://127.0.0.1:4390/e/\(id)"), service: local), id)
        for bad in ["http://aircbrowser.com/e/\(id)", "https://aircbrowser.com:8443/e/\(id)", "https://aircbrowser.com/e/\(id)x",
                    "https://aircbrowser.com/e/short", "https://evil.example/e/\(id)", "https://aircbrowser.com.evil.example/e/\(id)",
                    "https://aircbrowser.com/e/\(id)?x=1", "https://aircbrowser.com/e/\(id)#x", "https://aircbrowser.com/e/\(id)/a/x.png",
                    "https://aircbrowser.com/s/\(id)", "airc://share/\(id)", "airc://easel/\(id)/x", "airc://easel:1/\(id)",
                    "https://user@aircbrowser.com/e/\(id)", "http://127.0.0.1:4391/e/\(id)", "https://aircbrowser.com/e/../\(id)", "javascript:/e/\(id)"] {
            XCTAssertNil(HostedEaselLink.id(from: URL(string: bad), service: local), bad)
        }
        XCTAssertNil(HostedShareLink.id(from: URL(string: "https://aircbrowser.com/e/\(id)")), "Space and Easel links don't overlap")
        XCTAssertNil(HostedShareLink.id(from: URL(string: "airc://easel/\(id)")))
        XCTAssertFalse(ShareLink.isLink(URL(string: "airc://easel/\(id)")))
    }

    // MARK: Reading what the service sends

    func testTheSharedFormReadsBackExactly() throws {
        let (p, _) = try shared()
        XCTAssertEqual(try EaselImport.decode(try p.encoded()), p)
        let answer = data(["id": id, "createdAt": "2026-11-12T00:00:00.000Z", "easel": try json(p)])
        XCTAssertEqual(try EaselImport.decodeAnswer(answer), p)
        XCTAssertThrowsError(try EaselImport.decodeAnswer(data(["id": id]))) { XCTAssertEqual($0 as? EaselImport.Failure, .damaged) }
    }

    func testAnythingOffTheSchemaIsRefusedWhole() throws {
        let (p, _) = try shared()
        var top = try json(p)
        top["script"] = "alert(1)"
        refused(top, .damaged, "an extra top-level key")
        top = try json(p); top["title"] = NSNull()
        refused(top, .damaged, "null")
        top = try json(p); top.removeValue(forKey: "assets")
        refused(top, .damaged, "a missing key")
        top = try json(p); top["kind"] = "space"
        refused(top, .damaged, "another kind")
        top = try json(p); top["version"] = 2
        refused(top, .newerVersion, "a newer version")
        top = try json(p); top["version"] = 0
        refused(top, .damaged, "version 0")
        top = try json(p); top["version"] = true
        refused(top, .damaged, "a Boolean version")
        top = try json(p); top["title"] = "Trip \u{202E}gpj.exe"
        refused(top, .damaged, "a direction override in the title")
        top = try json(p); top["title"] = "Two\nlines"
        refused(top, .damaged, "a newline in the title")
        top = try json(p); top["title"] = String(repeating: "x", count: 121)
        refused(top, .damaged, "a title over 120")
        top = try json(p); top["background"] = "red"
        refused(top, .damaged, "a colour that isn't hex")
        top = try json(p); top["blocks"] = []
        refused(top, .damaged, "no blocks")
        top = try json(p); top["blocks"] = Array(repeating: (top["blocks"] as! [Any])[0], count: 2_001)
        refused(top, .tooLarge, "over 2,000 blocks")

        refused(try editing(p, block: 0) { $0["onclick"] = "x" }, .damaged, "an extra content key")
        refused(try editing(p, block: 0) { $0["type"] = "html" }, .damaged, "an unknown kind")
        refused(try editing(p, block: 0) { $0["size"] = 4000 }, .damaged, "a size out of range")
        refused(try editing(p, block: 0) { $0["size"] = "17" }, .damaged, "a number as text")
        refused(try editing(p, block: 0) { $0["font"] = "comic" }, .damaged, "an unknown font")
        refused(try editing(p, block: 5) { $0["startHead"] = 1 }, .damaged, "a number as a Boolean")
        refused(try editing(p, block: 3) { $0["strokeWidth"] = 500 }, .damaged, "a stroke out of range")
        for bad in ["javascript:alert(1)", "data:text/html,<script>x</script>", "file:///etc/passwd", "https://user:pw@example.com/",
                    "airc://easel/\(id)", "https://exa mple.com/", "//example.com/", "https:///nohost", "vbscript:x"] {
            refused(try editing(p, block: 6) { $0["url"] = bad }, .unsafeAddress, "card address \(bad)")
        }
        refused(try editing(p, block: 7) { $0["url"] = "javascript:alert(1)" }, .unsafeAddress, "a capture's address")
        refused(try editing(p, block: 0) { c in
            var ps = c["paragraphs"] as! [[String: Any]]
            var runs = ps[1]["runs"] as! [[String: Any]]
            runs[1]["link"] = "javascript:alert(1)"
            ps[1]["runs"] = runs
            c["paragraphs"] = ps
        }, .unsafeAddress, "a link in the text")
        refused(try editing(p, block: 0) { c in
            var ps = c["paragraphs"] as! [[String: Any]]
            ps[0]["checked"] = true
            c["paragraphs"] = ps
        }, .damaged, "a tick on a heading")
        refused(try editing(p, block: 0) { c in
            var ps = c["paragraphs"] as! [[String: Any]]
            ps[0]["runs"] = [["text": String(repeating: "x", count: 20_001)]]
            c["paragraphs"] = ps
        }, .damaged, "a run over the text limit")
    }

    func testPicturesAreListedExactlyAndWithinLimits() throws {
        let (p, _) = try shared()
        let name = p.assets[0].name
        var top = try json(p)
        top["assets"] = []
        refused(top, .damaged, "a picture that isn't listed")
        top = try json(p); top["assets"] = [["name": name, "size": p.assets[0].size], ["name": String(repeating: "d", count: 64) + ".png", "size": 10]]
        refused(top, .damaged, "a listed picture nothing shows")
        top = try json(p); top["assets"] = [["name": name, "size": p.assets[0].size], ["name": name, "size": p.assets[0].size]]
        refused(top, .damaged, "listed twice")
        top = try json(p); top["assets"] = [["name": name, "size": EaselPublic.maxAssetBytes + 1]]
        refused(top, .damaged, "a picture over 4 MB")
        top = try json(p); top["assets"] = [["name": name, "size": 1.5]]
        refused(top, .damaged, "a fractional size")
        for bad in ["../../etc/passwd", String(repeating: "c", count: 64) + ".svg", String(repeating: "C", count: 64) + ".png",
                    String(repeating: "c", count: 64) + ".png.html", String(repeating: "c", count: 63) + ".png"] {
            refused(try editing(p, block: 2) { $0["asset"] = bad }, .damaged, "picture name \(bad)")
        }
        // 6 pictures of 4 MB: over 20 MB in all.
        var blocks: [[String: Any]] = [], assets: [[String: Any]] = []
        for i in 0..<6 {
            let n = String(repeating: "\(i)", count: 64) + ".png"
            blocks.append(["frame": ["x": 0, "y": 0, "width": 10, "height": 10], "content": ["type": "image", "asset": n]])
            assets.append(["name": n, "size": EaselPublic.maxAssetBytes])
        }
        top = try json(p); top["blocks"] = blocks; top["assets"] = assets
        refused(top, .tooLarge, "over 20 MB of pictures")
        XCTAssertThrowsError(try EaselImport.decode(Data(count: EaselPublic.maxJSON + 1))) { XCTAssertEqual($0 as? EaselImport.Failure, .tooLarge) }
        let deep = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
        XCTAssertThrowsError(try EaselImport.decode(Data(deep.utf8))) { XCTAssertEqual($0 as? EaselImport.Failure, .damaged) }
    }

    func testEachPictureMustBeTheBytesItsNamePromises() throws {
        let pic = png(4, 3), name = try XCTUnwrap(EaselPublic.pictureName(pic))
        let asset = EaselPublic.Asset(name: name, size: pic.count)
        let ok = try XCTUnwrap(EaselImport.checkPicture(pic, as: asset))
        XCTAssertEqual(ok.width, 4)
        XCTAssertEqual(ok.height, 3)
        XCTAssertNil(EaselImport.checkPicture(pic, as: .init(name: name, size: pic.count + 1)), "another size")
        var changed = pic
        changed[changed.count - 1] ^= 0xFF
        XCTAssertNil(EaselImport.checkPicture(changed, as: .init(name: name, size: changed.count)), "other bytes")
        let hash = String(name.prefix(64))
        XCTAssertNil(EaselImport.checkPicture(pic, as: .init(name: hash + ".jpg", size: pic.count)), "a PNG named as a JPEG")
        let html = Data("<script>alert(1)</script>".utf8)
        XCTAssertNil(EaselPublic.pictureName(html))
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' onload='alert(1)'/>".utf8)
        XCTAssertNil(EaselPublic.pictureName(svg), "SVG is never a picture here")
        // PNG's signature on bytes that aren't a picture.
        var fake = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        fake.append(Data("not really a png at all".utf8))
        let fakeName = try XCTUnwrap(EaselPublic.pictureName(fake))
        XCTAssertNil(EaselImport.checkPicture(fake, as: .init(name: fakeName, size: fake.count)), "a signature alone")
        // A picture that says it's 100,000 × 100,000 pixels is refused before it's decoded.
        let huge = Self.pngHeader(width: 100_000, height: 100_000)
        let hugeName = try XCTUnwrap(EaselPublic.pictureName(huge))
        XCTAssertNil(EaselImport.checkPicture(huge, as: .init(name: hugeName, size: huge.count)), "a decompression bomb")
    }

    /// A PNG whose header (with a correct CRC) gives these sides, and one empty image chunk.
    static func pngHeader(width: UInt32, height: UInt32) -> Data {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func crc(_ b: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for x in b {
                c ^= UInt32(x)
                for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            }
            return c ^ 0xFFFF_FFFF
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] { be(UInt32(body.count)) + Array(type.utf8) + body + be(crc(Array(type.utf8) + body)) }
        let ihdr = be(width) + be(height) + [8, 6, 0, 0, 0]
        let idat: [UInt8] = [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IDAT", idat) + chunk("IEND", []))
    }

    // MARK: The local copy

    func testTheLocalCopyHasTheSameItems() throws {
        let (p, pictures) = try shared()
        let name = p.assets[0].name
        let size = try XCTUnwrap(EaselImport.checkPicture(try XCTUnwrap(pictures[name]), as: p.assets[0]))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let doc = EaselImport.document(p, id: "copy1", now: now, pixels: [name: size])
        XCTAssertEqual(doc.id, "copy1")
        XCTAssertEqual(doc.title, "Lisbon trip")
        XCTAssertEqual(doc.palette, .vibrant, "the colours name the vibrant palette")
        XCTAssertEqual(doc.createdAt, now)
        XCTAssertNil(doc.viewport)
        XCTAssertTrue(doc.extra.isEmpty)
        let s = doc.stacked
        XCTAssertEqual(s.map(\.content.type), ["text", "text", "image", "shape", "shape", "line", "link", "capture"])
        XCTAssertEqual(Set(s.map(\.id)).count, 8, "new ids")
        XCTAssertTrue(Set(s.map(\.id)).isDisjoint(with: ["t", "p", "i", "s", "e", "a", "l", "c"]))
        XCTAssertTrue(s.allSatisfy { $0.group == nil })
        XCTAssertEqual(s[0].frame, EaselRect(x: 10, y: 20, width: 280, height: 90))
        guard case .text(let t) = s[0].content, case .text(let plain) = s[1].content else { return XCTFail("text") }
        XCTAssertEqual(t.font, .mono)
        XCTAssertEqual(t.size, 21)
        XCTAssertEqual(t.alignment, .center)
        XCTAssertEqual(t.color, .purple)
        XCTAssertNil(plain.color, "the Easel's own text colour stays its own")
        XCTAssertEqual(plain.plainText, "Default colour")
        XCTAssertEqual(t.text.blocks.map(\.kind), [.heading1, .checkbox, .bullet])
        XCTAssertEqual(t.text.blocks[0].runs[0].marks, [.bold, .underline])
        XCTAssertTrue(t.text.blocks[1].checked)
        XCTAssertEqual(t.text.blocks[1].runs[1].marks, [.italic, .code])
        XCTAssertEqual(t.text.blocks[1].runs[1].link, "https://example.com/tram")
        XCTAssertEqual(t.text.blocks[2].indent, 2)
        XCTAssertEqual(t.text.blocks[2].runs[0].text, "Line\tone\ntwo")
        XCTAssertEqual(s[2].rotation, 0.3)
        guard case .image(let i) = s[2].content else { return XCTFail("image") }
        XCTAssertEqual(i.asset, name)
        XCTAssertEqual(i.pixelWidth, 4)
        XCTAssertEqual(i.pixelHeight, 3)
        XCTAssertEqual(i.altText, "Red")
        XCTAssertNil(i.source, "a picture's source page never travels")
        guard case .shape(let r) = s[3].content, case .shape(let e) = s[4].content else { return XCTFail("shapes") }
        XCTAssertEqual(r, EaselShape(.rectangle, fill: .yellow, stroke: .white, strokeWidth: 4, cornerRadius: 8))
        XCTAssertEqual(e.kind, .ellipse)
        XCTAssertNil(e.fill)
        XCTAssertEqual(e.stroke, .darkGreen)
        guard case .line(let l) = s[5].content else { return XCTFail("line") }
        XCTAssertEqual(l, EaselLine(from: EaselPoint(60, 340), to: EaselPoint(160, 400), startHead: true, endHead: true, color: .red, width: 5))
        guard case .link(let k) = s[6].content else { return XCTFail("link") }
        XCTAssertEqual(k, EaselLink(url: "https://example.com/doc", title: "Doc", detail: "Two\nlines", image: name))
        guard case .capture(let c) = s[7].content else { return XCTFail("capture") }
        XCTAssertEqual(c.asset, name)
        XCTAssertEqual(c.url, "https://dash.example.com/")
        XCTAssertEqual(c.title, "Stats")
        XCTAssertNil(c.live, "never live")
        // Sharing the copy again gives the same board (a new link of its own).
        var (again, report) = EaselPublic.make(doc)
        again = again.settingPictures([name: p.assets[0]], report: &report)
        XCTAssertEqual(again, p)
        XCTAssertEqual(EaselImport.summary(p), "8 items · 1 picture")
    }

    func testColoursOffThePaletteGoToTheNearestNamedOne() {
        XCTAssertEqual(EaselImport.color("#D74807", .chill), .red)
        XCTAssertEqual(EaselImport.color("#D74900", .chill), .red)
        XCTAssertEqual(EaselImport.color("#0000001A", .chill, stroke: true), .white)
        XCTAssertEqual(EaselImport.color("#010101", .vibrant), .black)
    }

    func testTheCopyIsSavedAndReadsBackAsAnyEasel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("easel-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (p, pictures) = try shared()
        let files = EaselFiles(root: root)
        let doc = EaselImport.document(p, id: "copy2", pixels: [:])
        for (n, d) in pictures {
            XCTAssertTrue(EaselFiles.isValidAsset(n))
            XCTAssertEqual(try files.addAsset(d, ext: String(n.split(separator: ".")[1]), to: doc.id), n, "the same name both ways")
        }
        try files.save(doc)
        let back = files.load("copy2")
        XCTAssertEqual(back.document.blocks, doc.blocks)
        XCTAssertTrue(back.issues.isEmpty)
    }

    func testAddingIsOneUndoStepButNewEaselIsNot() throws {
        let s = try makeStore()
        let space = s.selectedSpace.id
        let before = s.children(of: .pinned(spaceID: space), parent: nil).count
        _ = try s.createEasel("plain", inSpace: space, title: "New")
        XCTAssertNil(s.undoLabel, "New Easel isn't a ⌘Z step")
        _ = try s.createEasel("added", inSpace: space, title: "Shared", undoLabel: "Add Easel")
        XCTAssertEqual(s.undoLabel, "Add Easel")
        XCTAssertEqual(s.children(of: .pinned(spaceID: space), parent: nil).count, before + 2)
        _ = try s.undo()
        let rows = s.children(of: .pinned(spaceID: space), parent: nil)
        XCTAssertEqual(rows.count, before + 1)
        XCTAssertFalse(rows.contains { EaselURL.easelID($0.savedURL) == "added" })
        XCTAssertTrue(rows.contains { EaselURL.easelID($0.savedURL) == "plain" })
    }

    // MARK: The client

    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var answer: (URLRequest) -> (Int, Data, URL?) = { _ in (404, Data(), nil) }
        nonisolated(unsafe) static var seen: [URLRequest] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.seen.append(request)
            let (status, data, url) = Self.answer(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func service(_ base: String = "https://aircbrowser.com") -> SharingService {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        return SharingService(base: URL(string: base)!, session: URLSession(configuration: c))
    }

    func testOpeningReadsTheEaselAndEachPicture() async throws {
        let (p, pictures) = try shared()
        let name = p.assets[0].name, pic = try XCTUnwrap(pictures[name])
        let answer = data(["id": id, "createdAt": "2026-11-12T00:00:00.000Z", "easel": try json(p)])
        Stub.seen = []
        Stub.answer = { r in
            if r.url?.path == "/api/easel" { return (200, answer, nil) }
            if r.url?.path == "/e/\(self.id)/a/\(name)" { return (200, pic, nil) }
            return (404, Data(), nil)
        }
        let s = service()
        let read = try await s.easel(id: id)
        XCTAssertEqual(read, p)
        let got = try await s.easelPicture(id: id, p.assets[0])
        XCTAssertEqual(got.data, pic)
        XCTAssertEqual(got.width, 4)
        XCTAssertEqual(Stub.seen.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")?\($0.url?.query ?? "")" },
                       ["GET /api/easel?id=\(id)", "GET /e/\(id)/a/\(name)?"])
        XCTAssertTrue(Stub.seen.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil })

        // Other bytes than the name promises, or a redirect to another host: refused.
        Stub.answer = { _ in (200, self.png(5, 5), nil) }
        await XCTAssertThrowsAsync(try await s.easelPicture(id: id, p.assets[0])) { XCTAssertEqual($0 as? EaselImport.Failure, .picture) }
        Stub.answer = { _ in (200, answer, URL(string: "https://evil.example/api/easel")) }
        await XCTAssertThrowsAsync(try await s.easel(id: id)) { XCTAssertEqual($0 as? SharingService.Failure, .damaged) }
        Stub.answer = { _ in (200, pic, URL(string: "http://aircbrowser.com/e/x")) }
        await XCTAssertThrowsAsync(try await s.easelPicture(id: id, p.assets[0])) { XCTAssertEqual($0 as? SharingService.Failure, .damaged) }
        Stub.answer = { _ in (404, Data(), nil) }
        await XCTAssertThrowsAsync(try await s.easel(id: id)) { XCTAssertEqual($0 as? SharingService.Failure, .notFound) }
        Stub.answer = { _ in (200, Data("{\"easel\":{\"kind\":\"easel\"}}".utf8), nil) }
        await XCTAssertThrowsAsync(try await s.easel(id: id)) { XCTAssertEqual($0 as? EaselImport.Failure, .damaged) }

        // Plain HTTP only to a loopback test server.
        Stub.seen = []
        await XCTAssertThrowsAsync(try await self.service("http://aircbrowser.com").easel(id: id)) { XCTAssertNotNil($0 as? SharingService.Failure) }
        XCTAssertTrue(Stub.seen.isEmpty, "nothing was requested")
        XCTAssertTrue(service("http://127.0.0.1:4390").isSecure)
        XCTAssertTrue(service("http://localhost:4390").isSecure)
        XCTAssertFalse(service("http://10.0.0.2:4390").isSecure)
        await XCTAssertThrowsAsync(try await s.easel(id: "bad")) { XCTAssertEqual($0 as? SharingService.Failure, .notFound) }
    }
}

func XCTAssertThrowsAsync<T>(_ e: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line,
                             _ check: (Error) -> Void = { _ in }) async {
    do {
        _ = try await e()
        XCTFail("didn't throw", file: file, line: line)
    } catch {
        check(error)
    }
}

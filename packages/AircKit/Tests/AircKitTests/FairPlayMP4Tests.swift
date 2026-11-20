// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// The fMP4 facts the FairPlay video bridge reads from the page's appends (FairPlayMP4).
final class FairPlayMP4Tests: XCTestCase {
    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + body.count)
        return [UInt8(size >> 24), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)] + Array(type.utf8) + body
    }
    private let kid: [UInt8] = Array(0x10...0x1f)

    func testPsshKeyIDs() {
        // pssh v1: version 1, flags, FairPlay system ID, KID count 1, the KID, data size 0.
        let pssh = box("pssh", [1, 0, 0, 0] + FairPlayMP4.fairPlaySystem + [0, 0, 0, 1] + kid + [0, 0, 0, 0])
        XCTAssertEqual(FairPlayMP4.fairPlayKeyIDs(Data(pssh)), [Data(kid)])
        let widevine = box("pssh", [0, 0, 0, 0] + Array(repeating: 0xed, count: 16) + [0, 0, 0, 0])
        XCTAssertEqual(FairPlayMP4.fairPlayPssh(Data(widevine + pssh)), Data(pssh))
        XCTAssertNil(FairPlayMP4.fairPlayPssh(Data(widevine)))
        XCTAssertEqual(FairPlayMP4.fairPlayKeyIDs(Data(widevine)), [])
    }

    func testInitKeyIDFromTencAndSinf() {
        // moov > trak > mdia > minf > stbl > stsd > encv > sinf > schi > tenc
        let tenc = box("tenc", [0, 0, 0, 0, 0, 0, 1, 16] + kid)
        let sinf = box("sinf", box("schi", tenc))
        let encv = box("encv", Array(repeating: 0, count: 78) + sinf)
        let stsd = box("stsd", [0, 0, 0, 0, 0, 0, 0, 1] + encv)
        let mdhd = box("mdhd", [0, 0, 0, 0] + [0, 0, 0, 0, 0, 0, 0, 0] + [0, 0, 0x5d, 0xc0] + [0, 0, 0, 0, 0, 0, 0, 0])
        let moov = box("moov", box("trak", box("mdia", mdhd + box("minf", box("stbl", stsd)))))
        XCTAssertEqual(FairPlayMP4.initKeyID(Data(moov)), Data(kid))
        XCTAssertEqual(FairPlayMP4.initTimescale(Data(moov)), 24000)
        let json = try! JSONSerialization.data(withJSONObject: ["sinf": [Data(sinf).base64EncodedString()]])
        XCTAssertEqual(FairPlayMP4.sinfKeyIDs(json), [Data(kid)])
        XCTAssertEqual(FairPlayMP4.sinfKeyIDs(Data("{}".utf8)), [])
    }

    func testFragmentDecodeTime() {
        let tfdt = box("tfdt", [1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2])
        XCTAssertEqual(FairPlayMP4.fragmentDecodeTime(Data(box("moof", box("traf", tfdt)) + box("mdat", [1, 2, 3]))), (1 << 32) + 2)
        XCTAssertEqual(FairPlayMP4.fragmentDecodeTime(Data(box("mdat", []))), -1)
    }

    func testSkdKeyIDs() {
        XCTAssertEqual(FairPlayMP4.keyID(fromSkd: "skd://302f80dd-411e-4886-bca5-bb1f8018a024:77FD1889AAF4143B085548B3C0F95B9A"),
                       FairPlayMP4.unhex("302f80dd411e4886bca5bb1f8018a024"))
        XCTAssertEqual(FairPlayMP4.keyID(fromSkd: "skd://101112131415161718191A1B1C1D1E1F"), Data(kid))
        XCTAssertNil(FairPlayMP4.keyID(fromSkd: "skd://fps.example.com/;09cc0377"))
        XCTAssertNil(FairPlayMP4.keyID(fromSkd: "https://example.com"))
    }

    func testTruncatedInputIsSafe() {
        let bad = Data([0, 0, 0, 200] + Array("moov".utf8) + [1, 2, 3])
        XCTAssertNil(FairPlayMP4.initKeyID(bad))
        XCTAssertEqual(FairPlayMP4.fairPlayKeyIDs(Data([0, 0, 0, 40] + Array("pssh".utf8))), [])
        XCTAssertEqual(FairPlayMP4.initTimescale(Data()), 0)
    }

    func testRoutedOrigins() {
        XCTAssertEqual(FairPlayBridgeSites.routedOrigins, ["https://open.spotify.com", "https://www.disneyplus.com", "https://www.netflix.com"])
        XCTAssertEqual(FairPlayBridgeSites.safariUserAgentOrigins, ["https://www.netflix.com"])
        XCTAssertEqual(FairPlayBridgeSites.withAliases(["https://www.disneyplus.com"]), ["https://www.disneyplus.com", "https://disneyplus.com"])
        var sites = ProtectedMediaSites()
        sites.chromiumOrigins = Set(FairPlayBridgeSites.withAliases(FairPlayBridgeSites.routedOrigins))
        XCTAssertEqual(sites.engine(for: "https://netflix.com/"), .chromium)
        XCTAssertEqual(sites.engine(for: "https://www.netflix.com/watch/1"), .chromium)
        XCTAssertEqual(sites.engine(for: "https://help.netflix.com/"), .webKit, "other hosts keep today's rules")
    }
}

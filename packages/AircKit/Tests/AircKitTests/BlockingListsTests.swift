// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import AircKit

final class BlockingListsTests: XCTestCase {
    private func parse(_ header: String) throws -> BlockingListMetadata {
        try .parse(Data(("[Adblock Plus 2.0]\n" + header + "\n||ads.example^\n").utf8))
    }
    func testHeadersAndExpiry() throws {
        let m = try parse("! Title: EasyList\n! Version: 202611081049\n! Expires: 8 hours (update frequency)")
        XCTAssertEqual(m.title, "EasyList"); XCTAssertEqual(m.version, "202611081049")
        XCTAssertEqual(m.expires, 8 * 3600)
        XCTAssertEqual(try parse("! Expires: 7 days").expires, 7 * 86400)
        XCTAssertEqual(try parse("! Expires: 99 days").expires, 99 * 86400)
        for malformed in ["0 days", "NaN days", "inf hours", "-1 days", "8 seconds"] {
            XCTAssertEqual(try parse("! Expires: " + malformed).expires, BlockingListMetadata.refreshInterval)
        }
    }
    func testRejectsServerErrorsAndInvalidData() {
        for text in ["<html>502 Bad Gateway</html>", "[Adblock Plus 2.0]\n! Empty", "not a filter list"] {
            XCTAssertThrowsError(try BlockingListMetadata.parse(Data(text.utf8)))
        }
        XCTAssertThrowsError(try BlockingListMetadata.parse(Data([0xff, 0xfe])))
    }
    func testBodyCannotChangeMetadata() throws {
        let text = "\u{feff}[Adblock Plus 2.0]\r\n! Version: 1\r\n||ads.example^\r\n! Version: 2"
        XCTAssertEqual(try BlockingListMetadata.parse(Data(text.utf8)).version, "1")
    }
    func testIdentityAndConditionalRefresh() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var v = BlockingListVersion(digest: "abc", converterVersion: 1, metadata: try parse("! Expires: 8 hours"),
                                    etag: "W/\"abc\"", lastModified: "Sun, 08 Nov 2026 10:00:00 GMT", checkedAt: start)
        XCTAssertEqual(v.conditionalHeaders, ["If-None-Match": "W/\"abc\""])
        XCTAssertEqual(v.nextRefresh, start.addingTimeInterval(4 * 86400))
        let key = v.cacheKey
        v.notModified(at: start.addingTimeInterval(4 * 86400), etag: "\"new\"")
        XCTAssertEqual(v.cacheKey, key); XCTAssertEqual(v.etag, "\"new\"")
        v.converterVersion = 2; XCTAssertNotEqual(v.cacheKey, key)
        let changedConverter = v.cacheKey
        v.digest = "def"; XCTAssertNotEqual(v.cacheKey, changedConverter)
        v.etag = "value\r\nInjected: yes"
        XCTAssertEqual(v.conditionalHeaders.keys.sorted(), ["If-Modified-Since"])
    }
    func testHTTPExpiryAndLongAuthorExpiry() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var version = BlockingListVersion(digest: "abc", converterVersion: 1,
            metadata: try parse("! Expires: 8 hours"), checkedAt: now,
            httpExpires: now.addingTimeInterval(8 * 86400))
        XCTAssertEqual(version.nextRefresh, now.addingTimeInterval(8 * 86400))
        version.notModified(at: now.addingTimeInterval(9 * 86400))
        XCTAssertEqual(version.nextRefresh, now.addingTimeInterval(13 * 86400))
    }
    func testNewExistingAndPrivateScope() throws {
        let url = try XCTUnwrap(URL(string: "https://news.example/"))
        let existing = BlockingProfileConfiguration()
        XCTAssertTrue(existing.blocks(url))
        var new = BlockingProfileConfiguration()
        XCTAssertTrue(new.enabled); XCTAssertFalse(new.blockThirdPartyCookies)
        XCTAssertEqual(new.selectedLists, ["easylist", "easyprivacy"])
        new.exceptions.insert("news.example")
        XCTAssertFalse(new.blocks(url)); XCTAssertTrue(new.blocks(url, privateExceptions: []))
        XCTAssertFalse(new.blocks(url, privateExceptions: ["news.example"]))
        XCTAssertTrue(existing.blocks(url)) // profile separation
        XCTAssertEqual(BlockingProfileConfiguration.host(for: URL(string: "https://NEWS.example./")!), "news.example")
        XCTAssertEqual(BlockingProfileConfiguration.host(for: URL(string: "https://name:pass@news.example/path")!), "news.example")
        XCTAssertFalse(new.blocks(URL(string: "file:///fixture.html")!))
    }
    func testExistingProfileMigrationAndExplicitOff() throws {
        func legacy(_ json: String) throws -> BlockingProfileConfiguration {
            try JSONDecoder().decode(BlockingProfileConfiguration.self, from: Data(json.utf8))
        }
        var unchosen = try legacy(#"{"enabled":false,"offered":false,"exceptions":["news.example"],"selectedLists":["easyprivacy"]}"#)
        XCTAssertEqual(unchosen.defaultMigrationVersion, 0)
        unchosen.migrateDefault()
        XCTAssertTrue(unchosen.enabled)
        XCTAssertEqual(unchosen.defaultMigrationVersion, 1)
        XCTAssertEqual(unchosen.exceptions, ["news.example"])
        XCTAssertEqual(unchosen.selectedLists, ["easyprivacy"])
        XCTAssertFalse(unchosen.blockThirdPartyCookies)
        // A recorded migration is idempotent, independently of the choice bit.
        unchosen.enabled = false
        unchosen.migrateDefault()
        XCTAssertFalse(unchosen.enabled)
        var explicitOff = try legacy(#"{"enabled":false,"offered":true}"#)
        explicitOff.migrateDefault()
        XCTAssertFalse(explicitOff.enabled)
        XCTAssertTrue(explicitOff.hasExplicitChoice)
        var current = BlockingProfileConfiguration()
        current.setEnabled(false)
        var restored = try JSONDecoder().decode(BlockingProfileConfiguration.self, from: JSONEncoder().encode(current))
        restored.migrateDefault()
        XCTAssertEqual(restored, current)
        XCTAssertFalse(restored.enabled)
    }

}

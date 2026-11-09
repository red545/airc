// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class MediaArtworkPolicyTests: XCTestCase {
    func testPrivateAndUnknownNeverSelectNetworkOrDiskArtwork() {
        for url in ["https://example.test/art.png", "http://127.0.0.1/art.png", "file:///tmp/art.png", "blob:https://example.test/id"] {
            XCTAssertNil(MediaArtworkPolicy.source([url]))
            XCTAssertNil(MediaArtworkPolicy.source([url], ordinaryTab: false))
        }
    }
    func testPrivateFindsInlineImageAfterNetworkImage() {
        let inline = "data:image/png;base64,aGVsbG8="
        XCTAssertEqual(MediaArtworkPolicy.source(["https://example.test/art.png", inline]), inline)
        XCTAssertNil(MediaArtworkPolicy.source([])) // no remembered last-played source
    }
    func testOrdinaryNetworkArtworkIsPreserved() {
        XCTAssertEqual(MediaArtworkPolicy.source(["https://example.test/art.png"], ordinaryTab: true), "https://example.test/art.png")
        XCTAssertNil(MediaArtworkPolicy.source(["file:///tmp/art.png"], ordinaryTab: true))
    }
}

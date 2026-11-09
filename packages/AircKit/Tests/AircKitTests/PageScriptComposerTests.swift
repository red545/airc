// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
import JavaScriptCore
@testable import AircKit

final class PageScriptComposerTests: XCTestCase {
    func testLiveInstallConsumesSlotRestoresPreviousAndPreservesOtherParts() throws {
        let js = try XCTUnwrap(JSContext())
        let source = try XCTUnwrap(PageScriptComposer.compose(parts: [("other", "function(post) { return function(k) { post(k, ''); }; }")], base: nil))
        js.evaluateScript("var window = globalThis, posts = [], restored = 0; var receive = (\(source))((k,j) => posts.push(k));")
        js.evaluateScript("window.pending = {name:'live', install: post => { post('ready',''); return (k,j) => { if(k === 'enabled' && j === 'false') restored++; }; }}; receive('__aircInstall','pending');")
        XCTAssertEqual(js.evaluateScript("posts.join(',')")?.toString(), "live.ready")
        XCTAssertTrue(js.evaluateScript("!Object.hasOwn(window, 'pending')")?.toBool() == true)
        js.evaluateScript("window.pending = {name:'live', install: post => { post('ready',''); }}; receive('__aircInstall','pending'); receive('other.ping','');")
        XCTAssertEqual(js.evaluateScript("restored")?.toInt32(), 1)
        XCTAssertEqual(js.evaluateScript("posts.join(',')")?.toString(), "live.ready,live.ready,other.ping")
        js.evaluateScript("receive('__aircInstall','missing'); receive('other.pong','');")
        XCTAssertEqual(js.evaluateScript("posts.at(-1)")?.toString(), "other.pong")
        XCTAssertNil(js.exception)
    }
}

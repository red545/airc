// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
import JavaScriptCore
@testable import AircKit

/// boosts3: Boosts stay out of private windows (the engine's third install argument), and a zap made inside a frame
/// is the frames' only, in the store, in shared files and in the content digest.
final class BoostsThreeTests: XCTestCase {
    /// The script as the engine wraps it for a private profile's processes (engine/core/airc_page_script.cc).
    static func privately(_ script: String) -> String {
        "(function (install) {\n  return typeof install !== 'function' ? install\n"
            + "      : function (post, data) { return install(post, data, true); };\n})(\n" + script + "\n)"
    }

    func testAPrivateDocumentGetsNoBoostAndSaysNothing() throws {
        let b = Boost(domain: "example.com", css: "h1 { color: rgb(1, 2, 3) }")
        let script = try BoostTests.composed([b])
        // A normal window: the style from the first script, and ready.
        let page = try BoostTests.page(script, protocol: "https:", hostname: "www.example.com", origin: "https://www.example.com")
        XCTAssertTrue(page.evaluateScript("styles()")?.toString().contains("rgb(1, 2, 3)") == true)
        XCTAssertEqual(page.evaluateScript("ready().d")?.toString(), "example.com")

        // A private window's page and its same-site frame: nothing adopted, no token, no receiver. The page alone says
        // it's there, with nothing but that (the app puts back a Boost's size Chromium's private profile copied).
        let wrapped = Self.privately(script)
        for frameIn in [nil, "https://www.example.com"] as [String?] {
            let priv = try BoostTests.page(wrapped, protocol: "https:", hostname: "www.example.com", origin: "https://www.example.com",
                                           frameIn: frameIn)
            XCTAssertEqual(priv.evaluateScript("styles()")?.toString(), "", "frame: \(frameIn ?? "none")")
            XCTAssertEqual(priv.evaluateScript("JSON.stringify(posted)")?.toString(),
                           frameIn == nil ? #"[["boost.ready","{\"private\":true}"]]"# : "[]")
            // A message that names no token of its can't style it either.
            priv.objectForKeyedSubscript("receive").call(withArguments: [
                "boost.apply", BoostPageScript.applyMessage(for: b, domain: "example.com", token: "guess", version: 2),
            ])
            XCTAssertEqual(priv.evaluateScript("styles()")?.toString(), "")
            XCTAssertNil(priv.exception)
        }
    }

    func testTheComposerHandsThePrivateFlagToEveryPart() throws {
        let js = try XCTUnwrap(JSContext())
        let part = "function (post, data, isPrivate) { post('seen', String(isPrivate) + ':' + String(data)); return function () {}; }"
        let source = try XCTUnwrap(PageScriptComposer.compose(parts: [("a", part), ("b", part)], base: nil))
        js.evaluateScript("var window = globalThis, posts = []; function post(k, j) { posts.push(k + '=' + j); }")
        js.evaluateScript("var open = (\(source))(post, 'pa');")
        js.evaluateScript("var priv = (\(Self.privately(source)))(post, 'pb');")
        XCTAssertEqual(js.evaluateScript("posts.join(',')")?.toString(), "a.seen=false:pa,b.seen=false:pa,a.seen=true:pb,b.seen=true:pb")
        // A part installed into an open private document later gets the flag too.
        js.evaluateScript("window.pending = { name: 'live', install: function (post, data, isPrivate) { post('seen', String(isPrivate)); } }; priv('__aircInstall', 'pending');")
        XCTAssertEqual(js.evaluateScript("posts[posts.length - 1]")?.toString(), "live.seen=true")
        XCTAssertNil(js.exception)
    }

    func testAZapMadeInAFrameIsTheFramesOnly() throws {
        var b = Boost(domain: "example.com")
        b.zaps = [BoostZap(selector: "#top-ad", label: "Ad"), BoostZap(selector: "#banner", label: "Banner", frame: true)]
        let page = BoostStyle.generated(for: b), frame = BoostStyle.generated(for: b, frame: true)
        XCTAssertTrue(page.contains("#top-ad") && !page.contains("#banner"), page)
        XCTAssertTrue(frame.contains("#top-ad") && frame.contains("#banner"), frame)
        XCTAssertTrue(BoostPageScript.carries(b), "a Boost of frame zaps only is still carried")

        // Saved with "frame" only when true; data from before (no key) is a page's zap.
        let data = try JSONEncoder().encode(b.zaps)
        XCTAssertEqual(String(decoding: data, as: UTF8.self).components(separatedBy: "\"frame\"").count, 2)
        XCTAssertEqual(try JSONDecoder().decode([BoostZap].self, from: data), b.zaps)
        let old = #"[{"id":"x","selector":".a","label":"A","created":0}]"#
        XCTAssertEqual(try JSONDecoder().decode([BoostZap].self, from: Data(old.utf8)).first?.frame, false)
    }

    func testFrameZapsTravelInVersionTwoFilesAndKeepOldDigests() throws {
        var b = Boost(domain: "example.com", css: "a {}")
        b.zaps = [BoostZap(selector: ".x", label: "X")]
        let before = b.contentDigest
        // A page's zap: the digest is what it was before frames had zaps (no third field).
        var same = b; same.zaps[0].frame = false
        XCTAssertEqual(same.contentDigest, before)
        b.zaps.append(BoostZap(selector: "#banner", label: "Banner", frame: true))
        var asPage = b; asPage.zaps[1].frame = false
        XCTAssertNotEqual(b.contentDigest, asPage.contentDigest, "where a zap applies is part of what the Boost does")

        let file = BoostFile(boost: b)
        let back = try BoostFile.decode(file.encoded())
        XCTAssertEqual(back.boost.zaps.map(\.frame), [false, true])
        XCTAssertEqual(back.boost.zaps.map(\.selector), [".x", "#banner"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any])
        let zaps = try XCTUnwrap(object["zaps"] as? [[String: Any]])
        XCTAssertNil(zaps[0]["frame"], "a page's zap writes no frame key, as before")
        XCTAssertEqual(zaps[1]["frame"] as? Bool, true)

        // Only `true`, and only in version 2 files.
        var wrong = object
        wrong["zaps"] = [["selector": ".x", "label": "X", "frame": false]]
        XCTAssertThrowsError(try BoostFile.decode(JSONSerialization.data(withJSONObject: wrong)))
        wrong["zaps"] = [["selector": ".x", "label": "X", "frame": "yes"]]
        XCTAssertThrowsError(try BoostFile.decode(JSONSerialization.data(withJSONObject: wrong)))
        let v1 = #"{"version":1,"name":"Old","site":"example.com","createdAt":"2026-11-06T10:00:00Z","colors":{"hue":0.5,"tint":0.1,"brightness":1,"contrast":1,"invert":false},"font":{"size":0},"zaps":[{"selector":".x","label":"X","frame":true}],"css":"","js":""}"#
        XCTAssertThrowsError(try BoostFile.decode(Data(v1.utf8)))
    }
}

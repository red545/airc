// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// "Start Granola notes when a call starts": once per call, never in private windows, never with the setting off.
final class CallNotesTriggerTests: XCTestCase {
    private let meet = URL(string: "https://meet.google.com/abc-defg-hij?authuser=0")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testCallSites() {
        let keys: [(String, String?)] = [
            ("https://meet.google.com/abc-defg-hij", "meet.google.com/abc-defg-hij"),
            ("https://MEET.google.com./ABC-defg-hij?pli=1", "meet.google.com/abc-defg-hij"),
            ("https://app.zoom.us/wc/123456789/join?fromPWA=1", "zoom/123456789"),
            ("https://us02web.zoom.us/j/1234567890?pwd=x", "zoom/1234567890"),
            ("https://teams.microsoft.com/v2/", "teams.microsoft.com"),
            ("https://teams.live.com/meet/9876", "teams.live.com"),
            ("https://acme.webex.com/meet/someone", "acme.webex.com"),
            ("https://whereby.com/demo-room", "whereby.com/demo-room"),
            ("https://meet.jit.si/SomeRoom", "meet.jit.si/someroom"),
            ("https://meet.google.com/landing", "meet.google.com"),
            ("https://example.com/meet.google.com/abc", nil),
            ("https://meet.google.com.example.com/abc", nil),
            ("https://notzoom.us/j/123456789", nil),
            ("https://www.youtube.com/", nil),
            ("file:///tmp/airc-test-home/meet.google.com.html", nil),
            ("about:blank", nil),
        ]
        for (url, key) in keys { XCTAssertEqual(CallNotesTrigger.callKey(URL(string: url)), key, url) }
    }

    func testOnceWhenTheMicrophoneStarts() {
        var t = CallNotesTrigger()
        XCTAssertFalse(t.microphone(false, tab: 1, url: meet, isPrivate: false, enabled: true, now: t0))
        XCTAssertTrue(t.microphone(true, tab: 1, url: meet, isPrivate: false, enabled: true, now: t0))
        // Repeat notices while it stays on (zoom, security, pop-ups) ask nothing.
        XCTAssertFalse(t.microphone(true, tab: 1, url: meet, isPrivate: false, enabled: true, now: t0 + 10))
        XCTAssertFalse(t.microphone(true, tab: 1, url: meet, isPrivate: false, enabled: true, now: t0 + 3600))
    }

    func testRejoinWithinTheWindowAsksNothing() {
        var t = CallNotesTrigger()
        XCTAssertTrue(t.microphone(true, tab: 1, url: meet, isPrivate: false, enabled: true, now: t0))
        XCTAssertFalse(t.microphone(false, tab: 1, url: meet, isPrivate: false, enabled: true, now: t0 + 600))
        // Left at +600 s, back at +840 s (4 min later): the same call.
        XCTAssertFalse(t.microphone(true, tab: 1, url: meet, isPrivate: false, enabled: true, now: t0 + 840))
        XCTAssertFalse(t.microphone(false, tab: 1, url: meet, isPrivate: false, enabled: true, now: t0 + 900))
        // Rejoined from another tab, also within the window.
        XCTAssertFalse(t.microphone(true, tab: 2, url: meet, isPrivate: false, enabled: true, now: t0 + 1000))
        t.forget(tab: 2, now: t0 + 1100)
        // Back after more than five minutes: a new call.
        XCTAssertTrue(t.microphone(true, tab: 3, url: meet, isPrivate: false, enabled: true,
                                   now: t0 + 1100 + CallNotesTrigger.rejoinWindow + 1))
    }

    func testSecondTabOfTheSameCallAndOtherCalls() {
        var t = CallNotesTrigger()
        XCTAssertTrue(t.microphone(true, tab: 1, url: meet, isPrivate: false, enabled: true, now: t0))
        XCTAssertFalse(t.microphone(true, tab: 2, url: meet, isPrivate: false, enabled: true, now: t0 + 1))
        // Another meeting code is another call, even at once.
        XCTAssertTrue(t.microphone(true, tab: 3, url: URL(string: "https://meet.google.com/xyz-abcd-efg"),
                                   isPrivate: false, enabled: true, now: t0 + 2))
        // Zoom's join page and its web client are the same meeting.
        XCTAssertTrue(t.microphone(true, tab: 4, url: URL(string: "https://us02web.zoom.us/j/123456789"),
                                   isPrivate: false, enabled: true, now: t0 + 3))
        XCTAssertFalse(t.microphone(false, tab: 4, url: URL(string: "https://us02web.zoom.us/j/123456789"),
                                    isPrivate: false, enabled: true, now: t0 + 4))
        XCTAssertFalse(t.microphone(true, tab: 4, url: URL(string: "https://app.zoom.us/wc/123456789/join"),
                                    isPrivate: false, enabled: true, now: t0 + 5))
    }

    func testOffPrivateAndOtherSites() {
        var t = CallNotesTrigger()
        XCTAssertFalse(t.microphone(true, tab: 1, url: meet, isPrivate: false, enabled: false, now: t0))
        var p = CallNotesTrigger()
        XCTAssertFalse(p.microphone(true, tab: 1, url: meet, isPrivate: true, enabled: true, now: t0))
        // A private call leaves nothing behind: the same call in a normal window right after still asks.
        XCTAssertTrue(p.microphone(true, tab: 2, url: meet, isPrivate: false, enabled: true, now: t0 + 1))
        var o = CallNotesTrigger()
        XCTAssertFalse(o.microphone(true, tab: 1, url: URL(string: "https://www.example.com/voice-memo"),
                                    isPrivate: false, enabled: true, now: t0))
    }

    func testGranolaURL() {
        let c = URLComponents(url: CallNotesTrigger.granolaURL, resolvingAgainstBaseURL: false)
        XCTAssertEqual(c?.scheme, "granola")
        XCTAssertEqual(c?.host, "new-document")
        XCTAssertEqual(c?.queryItems, [URLQueryItem(name: "creation_source", value: "airc")])
    }
}

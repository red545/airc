// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// P06d: Arc's "Open Little Arc when clicking on links with ⌥⌘ held" (optionCommandClickLittleArcEntryPointEnabled).
final class ParityP06dTests: XCTestCase {
    private func opens(_ url: String = "https://b.example/page", gesture: Bool = true, disposition: String = "background_tab",
                       held: Bool = true, enabled: Bool = true) -> Bool {
        LinkRouting.opensInLittleArc(url: URL(string: url)!, userGesture: gesture, disposition: disposition, heldOptionCommand: held,
                                     enabled: enabled)
    }

    func testAnOptionCommandClickedLinkOpensInLittleArc() {
        XCTAssertTrue(opens())
        XCTAssertTrue(opens(disposition: "foreground_tab"), "⇧ held too: still ⌥⌘")
        XCTAssertTrue(opens("http://127.0.0.1:8080/la"), "a loopback page")
    }

    func testOnlyThatClickAndOnlyANewTabLink() {
        XCTAssertFalse(opens(held: false), "⌘ alone keeps the engine's background tab")
        XCTAssertFalse(opens(enabled: false), "the setting off")
        XCTAssertFalse(opens(gesture: false), "a page opening a link on its own")
        XCTAssertFalse(opens(disposition: "current_tab"), "the page's own navigation")
        XCTAssertFalse(opens(disposition: "popup"), "a popup the click opened")
        XCTAssertFalse(opens(disposition: "window"), "⇧-click is Peek's")
        XCTAssertFalse(opens("mailto:a@b.example"), "not a web link")
        XCTAssertFalse(opens("file:///tmp/a.html"), "not a web link")
    }
}

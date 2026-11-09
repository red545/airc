// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit
final class ShortcutMigrationTests: XCTestCase {
    func testLayoutsAndUnrelatedBindings() {
        let old = ["capture": "shift+cmd+@", "other": "shift+cmd+\"", "third": "shift+cmd+#", "plain": "cmd+@", "priority:first": "airc"]
        let us = ShortcutMigration.shiftedDigits(old, symbols: ["@": "2", "#": "3"])
        XCTAssertEqual(us["capture"], "shift+cmd+2")
        XCTAssertEqual(us["third"], "shift+cmd+3")
        XCTAssertEqual(us["other"], old["other"])
        XCTAssertEqual(us["plain"], old["plain"])
        XCTAssertEqual(us["priority:first"], old["priority:first"])
        let german = ShortcutMigration.shiftedDigits(old, symbols: ["\"": "2", "§": "3"])
        XCTAssertEqual(german["other"], "shift+cmd+2")
        XCTAssertEqual(german["third"], old["third"])
        XCTAssertEqual(ShortcutMigration.shiftedDigits(us, symbols: ["@": "2"]), us)
    }
}

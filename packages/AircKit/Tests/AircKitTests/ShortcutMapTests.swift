// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class ShortcutMapTests: XCTestCase {
    private let cmd: KeyCombo.Modifiers = .command

    private var table: [ShortcutMap.Command] {
        [
            .init(id: "file.openLocation", defaultKey: KeyCombo("l", cmd)),
            .init(id: "tabs.library", defaultKey: KeyCombo("l", [.shift, .command])),
            .init(id: "tabs.pin", defaultKey: KeyCombo("d", cmd)),
            .init(id: "tabs.favorite", defaultKey: nil),
            .init(id: "spaces.next", defaultKey: KeyCombo("right", [.option, .command])),
        ]
    }

    // MARK: Keys

    func testKeyStringsRoundTrip() {
        for s in ["cmd+l", "alt+cmd+l", "ctrl+alt+shift+cmd+right", "ctrl+tab", "cmd+=", "cmd++", "shift+cmd+}", "cmd+f5"] {
            XCTAssertEqual(KeyCombo(string: s)?.string, s, s)
        }
        XCTAssertEqual(KeyCombo(string: "cmd++"), KeyCombo("+", .command))
        // Modifiers in any order come back in macOS's.
        XCTAssertEqual(KeyCombo(string: "cmd+alt+L")?.string, "alt+cmd+l")
        for bad in ["", "cmd+", "hyper+l", "cmd+lol", "cmd+leftt"] { XCTAssertNil(KeyCombo(string: bad), bad) }
    }

    func testDisplay() {
        XCTAssertEqual(KeyCombo("l", [.option, .command]).display, "⌥⌘L")
        XCTAssertEqual(KeyCombo("right", [.option, .command]).symbols, ["⌥", "⌘", "→"])
        XCTAssertEqual(KeyCombo("tab", .control).display, "⌃⇥")
        XCTAssertEqual(KeyCombo("=", [.control, .shift]).display, "⌃⇧=")
    }

    func testCodableIsAString() throws {
        let data = try JSONEncoder().encode([KeyCombo("l", [.option, .command])])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["alt+cmd+l"]"#)
        XCTAssertEqual(try JSONDecoder().decode([KeyCombo].self, from: data), [KeyCombo("l", [.option, .command])])
    }

    // MARK: Defaults and remapping

    func testDefaults() {
        let m = ShortcutMap(commands: table)
        XCTAssertEqual(m.key("file.openLocation"), KeyCombo("l", cmd))
        XCTAssertNil(m.key("tabs.favorite"))
        XCTAssertEqual(m.command(for: KeyCombo("d", cmd)), "tabs.pin")
        XCTAssertTrue(m.stored.isEmpty)
        XCTAssertFalse(m.isFreedDefault(KeyCombo("l", cmd)))
    }

    func testRemapFreesTheOldKey() {
        var m = ShortcutMap(commands: table)
        XCTAssertEqual(m.assign(KeyCombo("l", [.option, .command]), to: "file.openLocation"), .done)
        XCTAssertEqual(m.key("file.openLocation"), KeyCombo("l", [.option, .command]))
        XCTAssertNil(m.command(for: KeyCombo("l", cmd)))
        XCTAssertTrue(m.isFreedDefault(KeyCombo("l", cmd)))
        XCTAssertEqual(m.stored, ["file.openLocation": "alt+cmd+l"])
        XCTAssertEqual(m.assign(KeyCombo("l", [.option, .command]), to: "file.openLocation"), .unchanged)
    }

    func testAKeylessCommandGetsOne() {
        var m = ShortcutMap(commands: table)
        XCTAssertEqual(m.assign(KeyCombo("j", [.control, .command]), to: "tabs.favorite"), .done)
        XCTAssertEqual(m.command(for: KeyCombo("j", [.control, .command])), "tabs.favorite")
        XCTAssertEqual(m.reset("tabs.favorite"), .done)
        XCTAssertNil(m.key("tabs.favorite"))
        XCTAssertTrue(m.stored.isEmpty)
    }

    func testClear() {
        var m = ShortcutMap(commands: table)
        XCTAssertEqual(m.assign(nil, to: "tabs.pin"), .done)
        XCTAssertNil(m.key("tabs.pin"))
        XCTAssertEqual(m.stored, ["tabs.pin": ""])
        XCTAssertEqual(m.assign(nil, to: "tabs.pin"), .unchanged)
        XCTAssertEqual(m.assign(nil, to: "nope"), .unknownCommand)
    }

    // MARK: Conflicts

    func testConflictIsRefusedByDefault() {
        var m = ShortcutMap(commands: table)
        XCTAssertEqual(m.check(KeyCombo("d", cmd), for: "file.openLocation"), .conflict("tabs.pin"))
        XCTAssertEqual(m.assign(KeyCombo("d", cmd), to: "file.openLocation"), .conflict("tabs.pin"))
        XCTAssertEqual(m.key("file.openLocation"), KeyCombo("l", cmd))
        XCTAssertEqual(m.key("tabs.pin"), KeyCombo("d", cmd))
    }

    func testSwap() {
        var m = ShortcutMap(commands: table)
        XCTAssertEqual(m.assign(KeyCombo("d", cmd), to: "file.openLocation", resolving: .swap), .done)
        XCTAssertEqual(m.key("file.openLocation"), KeyCombo("d", cmd))
        XCTAssertEqual(m.key("tabs.pin"), KeyCombo("l", cmd))
        XCTAssertEqual(m.stored, ["file.openLocation": "cmd+d", "tabs.pin": "cmd+l"])
        // Swapping back is the defaults again: nothing to store.
        XCTAssertEqual(m.assign(KeyCombo("l", cmd), to: "file.openLocation", resolving: .swap), .done)
        XCTAssertTrue(m.stored.isEmpty)
    }

    func testSwapWithAKeylessCommandLeavesTheOtherWithout() {
        var m = ShortcutMap(commands: table)
        XCTAssertEqual(m.assign(KeyCombo("d", cmd), to: "tabs.favorite", resolving: .swap), .done)
        XCTAssertEqual(m.key("tabs.favorite"), KeyCombo("d", cmd))
        XCTAssertNil(m.key("tabs.pin"))
    }

    func testClearOther() {
        var m = ShortcutMap(commands: table)
        XCTAssertEqual(m.assign(KeyCombo("d", cmd), to: "file.openLocation", resolving: .clearOther), .done)
        XCTAssertEqual(m.key("file.openLocation"), KeyCombo("d", cmd))
        XCTAssertNil(m.key("tabs.pin"))
        XCTAssertTrue(m.isFreedDefault(KeyCombo("l", cmd)))
    }

    func testResetIntoATakenKeyAsks() {
        var m = ShortcutMap(commands: table)
        m.assign(KeyCombo("l", [.option, .command]), to: "file.openLocation")
        m.assign(KeyCombo("l", cmd), to: "tabs.library")
        XCTAssertEqual(m.reset("file.openLocation"), .conflict("tabs.library"))
        XCTAssertEqual(m.reset("file.openLocation", resolving: .swap), .done)
        XCTAssertEqual(m.key("file.openLocation"), KeyCombo("l", cmd))
        XCTAssertEqual(m.key("tabs.library"), KeyCombo("l", [.option, .command]))
        m.resetAll()
        XCTAssertEqual(m, ShortcutMap(commands: table))
        XCTAssertEqual(m.key("tabs.library"), KeyCombo("l", [.shift, .command]))
    }

    // MARK: Reserved keys

    func testSystemKeysAreRefused() {
        var m = ShortcutMap(commands: table)
        for k in [KeyCombo("q", cmd), KeyCombo("h", cmd), KeyCombo("tab", cmd), KeyCombo("space", cmd), KeyCombo("c", cmd),
                  KeyCombo("4", [.shift, .command]), KeyCombo("f", [.control, .command]), KeyCombo("left", .control)] {
            guard case .refused = m.assign(k, to: "tabs.pin") else { return XCTFail("\(k) was allowed") }
            XCTAssertEqual(KeyReservation.of(k)?.kind, .system, "\(k)")
        }
        XCTAssertEqual(m.key("tabs.pin"), KeyCombo("d", cmd))
    }

    func testAKeyNeedsCommandOptionOrControl() {
        var m = ShortcutMap(commands: table)
        for k in [KeyCombo("l", []), KeyCombo("l", .shift), KeyCombo("f5", [])] {
            XCTAssertEqual(m.assign(k, to: "tabs.pin"), .refused("A shortcut needs ⌘, ⌥ or ⌃."), "\(k)")
        }
        XCTAssertEqual(m.assign(KeyCombo("f5", .control), to: "tabs.pin"), .done)
    }

    func testPageKeysAreAllowedWithAWarning() {
        var m = ShortcutMap(commands: table)
        for k in [KeyCombo("b", cmd), KeyCombo("i", cmd), KeyCombo("u", cmd), KeyCombo("k", cmd), KeyCombo("v", [.shift, .command]),
                  KeyCombo("z", cmd)] {
            XCTAssertEqual(KeyReservation.of(k)?.kind, .pageCommon, "\(k)")
            XCTAssertEqual(m.assign(k, to: "tabs.favorite"), .done, "\(k)")
        }
        XCTAssertNil(KeyReservation.of(KeyCombo("j", [.control, .command])))
    }

    // MARK: Persistence and migration

    func testStoredRoundTrip() {
        var m = ShortcutMap(commands: table)
        m.assign(KeyCombo("l", [.option, .command]), to: "file.openLocation")
        m.assign(nil, to: "tabs.pin")
        let again = ShortcutMap(commands: table, stored: m.stored)
        XCTAssertEqual(again, m)
        XCTAssertEqual(again.key("file.openLocation"), KeyCombo("l", [.option, .command]))
        XCTAssertNil(again.key("tabs.pin"))
    }

    func testUnknownAndBrokenEntriesAreIgnored() {
        let m = ShortcutMap(commands: table, stored: ["gone.command": "cmd+j", "tabs.pin": "cmd+banana", "tabs.library": "cmd+q",
                                                      "file.openLocation": "l"])
        XCTAssertTrue(m.stored.isEmpty)
        XCTAssertEqual(m, ShortcutMap(commands: table))
    }

    func testAnOverrideEqualToItsDefaultIsDropped() {
        let m = ShortcutMap(commands: table, stored: ["tabs.pin": "cmd+d"])
        XCTAssertTrue(m.stored.isEmpty)
    }

    func testUntouchedCommandsFollowNewDefaults() {
        // Version 1 stored one change; version 2 moves Library's default and adds a command.
        var v1 = ShortcutMap(commands: table)
        v1.assign(KeyCombo("p", [.control, .command]), to: "tabs.pin")
        var v2 = table.filter { $0.id != "tabs.library" }
        v2.append(.init(id: "tabs.library", defaultKey: KeyCombo("b", [.option, .command])))
        v2.append(.init(id: "tabs.new", defaultKey: KeyCombo("n", [.control, .shift])))
        let m = ShortcutMap(commands: v2, stored: v1.stored)
        XCTAssertEqual(m.key("tabs.pin"), KeyCombo("p", [.control, .command]))
        XCTAssertEqual(m.key("tabs.library"), KeyCombo("b", [.option, .command]))
        XCTAssertEqual(m.key("tabs.new"), KeyCombo("n", [.control, .shift]))
    }

    func testANewDefaultTheUserAlreadyUsesStaysTheUsers() {
        var v1 = ShortcutMap(commands: table)
        v1.assign(KeyCombo("j", [.control, .command]), to: "tabs.favorite")
        let v2 = table + [.init(id: "tabs.join", defaultKey: KeyCombo("j", [.control, .command]))]
        let m = ShortcutMap(commands: v2, stored: v1.stored)
        XCTAssertEqual(m.command(for: KeyCombo("j", [.control, .command])), "tabs.favorite")
        XCTAssertNil(m.key("tabs.join"))
    }

    func testTwoOverridesOnOneKeyKeepTheFirst() {
        let m = ShortcutMap(commands: table, stored: ["file.openLocation": "ctrl+cmd+k", "tabs.pin": "ctrl+cmd+k"])
        XCTAssertEqual(m.command(for: KeyCombo("k", [.control, .command])), "file.openLocation")
        XCTAssertNil(m.key("tabs.pin"))
        XCTAssertEqual(m.stored["tabs.pin"], "")
    }
}

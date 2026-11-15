// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// prefs (E12, Q03): the sounds and haptics defaults (as Arc's), and what a launch restores.
final class PrefsTests: XCTestCase {
    func testIconsAreAircsOwnWithAResourceEachButTheDefault() throws {
        XCTAssertEqual(PersonalizationPreferences.AppIcon.allCases.map(\.rawValue),
                       ["holographic", "outline", "sunset", "ocean", "midnight", "graphite"])
        XCTAssertNil(PersonalizationPreferences.AppIcon.holographic.resourceName, "the default is the bundle's own icon")
        XCTAssertEqual(PersonalizationPreferences.AppIcon.midnight.resourceName, "AppIcon-midnight")
        for icon in PersonalizationPreferences.AppIcon.allCases {
            var p = PersonalizationPreferences()
            p.appIcon = icon
            XCTAssertEqual(try JSONDecoder().decode(PersonalizationPreferences.self, from: JSONEncoder().encode(p)).appIcon, icon)
        }
    }

    func testSoundsAndHapticsDefaultOnAsArcs() {
        // Arc 1.171 keeps playUserInterfaceSoundsDisabled and tabReorderingHapticsDisabled, both false unless set.
        let p = PersonalizationPreferences()
        XCTAssertTrue(p.playsSounds)
        XCTAssertTrue(p.haptics)
    }

    func testStartupChoiceDefaultsToTheLastSessionAndReadsUnknownValuesAsIt() throws {
        XCTAssertEqual(StartupWindows.allCases.map(\.title), ["Open my windows and tabs from last time", "Open a new window"])
        struct Box: Codable { var s: StartupWindows }
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: Data(#"{"s":"newWindow"}"#.utf8)).s, .newWindow)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: Data(#"{"s":"somethingNewer"}"#.utf8)).s, .lastSession)
    }

    func testANewWindowOnlyAfterAQuitThePersonChose() {
        XCTAssertTrue(LaunchRestore.restoresLastSession(.lastSession, previous: .clean))
        XCTAssertTrue(LaunchRestore.restoresLastSession(.lastSession, previous: .running))
        XCTAssertFalse(LaunchRestore.restoresLastSession(.newWindow, previous: .clean), "a quit, then a fresh window")
        XCTAssertTrue(LaunchRestore.restoresLastSession(.newWindow, previous: .running), "after a crash the windows come back")
        XCTAssertTrue(LaunchRestore.restoresLastSession(.newWindow, previous: .restart), "an update's restart keeps them")
    }

    func testTheExitMark() {
        XCTAssertEqual(PreviousExit(mark: nil), .running, "no mark (first launch, older build) counts as a crash")
        XCTAssertEqual(PreviousExit(mark: "clean"), .clean)
        XCTAssertEqual(PreviousExit(mark: "garbage"), .running)
        XCTAssertTrue(PreviousExit.running.crashed)
        XCTAssertFalse(PreviousExit.restart.crashed)
        XCTAssertEqual(LaunchRestore.markOnQuit(current: .running), .clean)
        XCTAssertEqual(LaunchRestore.markOnQuit(current: .restart), .restart, "the update's quit stays a restart")
    }
}

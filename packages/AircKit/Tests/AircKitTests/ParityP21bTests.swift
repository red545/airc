// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// P21b: the personalization choices (E15) and when a downloaded update may restart by itself (E13).
final class ParityP21bTests: XCTestCase {
    func testPersonalizationDefaultsRoundTripAndUnknownIcons() throws {
        let p = PersonalizationPreferences()
        XCTAssertEqual(p.appIcon, .holographic)
        XCTAssertTrue(p.playsSounds && p.haptics)
        var q = p
        q.appIcon = .outline
        q.playsSounds = false
        q.haptics = false
        XCTAssertEqual(try JSONDecoder().decode(PersonalizationPreferences.self, from: JSONEncoder().encode(q)), q)
        XCTAssertEqual(try JSONDecoder().decode(PersonalizationPreferences.self, from: Data("{}".utf8)), p, "an older settings file")
        let newer = try JSONDecoder().decode(PersonalizationPreferences.self, from: Data(#"{"appIcon":"neon","playsSounds":false}"#.utf8))
        XCTAssertEqual(newer.appIcon, .holographic, "a newer build's icon reads as the default")
        XCTAssertFalse(newer.playsSounds)
        XCTAssertEqual(PersonalizationPreferences.AppIcon.allCases.map(\.title), ["Holographic", "Outline"])
    }

    func testAnUpdateRestartsByItselfOnlyWhenNothingWouldBeInterrupted() {
        XCTAssertFalse(IdleUpdatePolicy().enabled, "off unless the person turns it on, as Arc's")
        var p = IdleUpdatePolicy()
        p.enabled = true
        p.updateReady = true
        p.idleSeconds = IdleUpdatePolicy.requiredIdle
        XCTAssertTrue(p.restartsNow)
        func blocked(_ change: (inout IdleUpdatePolicy) -> Void) -> [IdleUpdatePolicy.Blocker] {
            var x = p
            change(&x)
            return x.blockers
        }
        XCTAssertEqual(blocked { $0.enabled = false }, [.turnedOff])
        XCTAssertEqual(blocked { $0.automated = true }, [.automated], "never in an automated run")
        XCTAssertEqual(blocked { $0.updateReady = false }, [.notReady])
        XCTAssertEqual(blocked { $0.appActive = true }, [.active], "never while Airc is in front")
        XCTAssertEqual(blocked { $0.idleSeconds = IdleUpdatePolicy.requiredIdle - 1 }, [.recentInput], "30 minutes of HID idle")
        XCTAssertEqual(blocked { $0.playing = true }, [.media])
        XCTAssertEqual(blocked { $0.pausedMedia = true }, [.media], "paused part-way would start over")
        XCTAssertEqual(blocked { $0.pictureInPicture = true }, [.pictureInPicture])
        XCTAssertEqual(blocked { $0.call = true }, [.call])
        XCTAssertEqual(blocked { $0.screenSharing = true }, [.screenSharing])
        XCTAssertEqual(blocked { $0.downloads = 1 }, [.downloads])
        XCTAssertEqual(blocked { $0.loading = 1 }, [.loading], "a form or file being sent")
        XCTAssertEqual(blocked { $0.leaveSite = 2 }, [.leaveSite])
        XCTAssertEqual(blocked { $0.editedForms = 1 }, [.editedForms])
        XCTAssertEqual(blocked { $0.developerMode = 1 }, [.developerMode])
        XCTAssertEqual(blocked { $0.privateWindowsWithPages = true }, [.privateWindows])
        XCTAssertEqual(blocked { $0.dialogOpen = true }, [.dialog])
        XCTAssertEqual(blocked { $0.playing = true; $0.appActive = true }, [.active, .media], "every reason, in order")
        XCTAssertEqual(blocked { $0.editedForms = 1; $0.idleSeconds = 0 }.count, 2)
        XCTAssertEqual(IdleUpdatePolicy().cheapBlockers, [.turnedOff, .notReady, .recentInput], "nothing asks the pages first")
        XCTAssertEqual(IdleUpdatePolicy.Blocker.allCases.count, 16)
    }
}

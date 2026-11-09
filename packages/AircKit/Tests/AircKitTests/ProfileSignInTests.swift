// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class ProfileSignInTests: XCTestCase {
    let account = GoogleAccount(name: "Alex Example", email: "alex@example.com")

    func testTransitionsAndIsolation() throws {
        let s = try makeStore()
        let p = try s.createProfile(name: "Studio")
        let other = try s.createProfile(name: "Other")
        XCTAssertEqual(p.signInState, .created)
        try s.receiveGoogleSignIn(p.id, accounts: [account])
        XCTAssertNil(s.profile(p.id)?.googleAccount)
        try s.beginGoogleSignIn(p.id)
        for response: [GoogleAccount]? in [nil, []] {
            try s.receiveGoogleSignIn(p.id, accounts: response)
            XCTAssertEqual(s.profile(p.id)?.signInState, .signingIn)
        }
        try s.receiveGoogleSignIn(p.id, accounts: [account])
        XCTAssertEqual(s.profile(p.id)?.googleAccount, account.email)
        XCTAssertEqual(s.profile(p.id)?.signInState, .offered)
        try s.finishGoogleSignIn(p.id, choice: .added)
        try s.finishGoogleSignIn(p.id, choice: .added)
        let favorites = s.favorites(ofProfile: p.id)
        XCTAssertEqual(favorites.count, 2)
        XCTAssertTrue(favorites.allSatisfy { URLComponents(string: $0.savedURL!)?.queryItems?.first?.value == account.email })
        XCTAssertFalse(s.profile(p.id)!.signInState.showsCard)
        XCTAssertEqual(s.profile(other.id)?.signInState, .created)
        XCTAssertTrue(s.favorites(ofProfile: other.id).isEmpty)
        try s.beginGoogleSignIn(other.id)
        try s.finishGoogleSignIn(other.id, choice: .dismissed)
        try s.receiveGoogleSignIn(other.id, accounts: [account])
        XCTAssertEqual(s.profile(other.id)?.signInState, .dismissed)
        XCTAssertNil(s.profile(other.id)?.googleAccount)
    }

    func testEveryStateSurvivesReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        for state: ProfileSignInState in [.created, .signingIn, .offered, .added, .declined, .dismissed] {
            var id = ""
            do {
                let s = try SpacesStore(path: path)
                id = try s.createProfile(name: state.rawValue).id
                if state != .created { try s.beginGoogleSignIn(id) }
                if state != .created && state != .signingIn { try s.receiveGoogleSignIn(id, accounts: [account]) }
                if !state.showsCard { try s.finishGoogleSignIn(id, choice: state) }
                try s.flush()
            }
            let reopened = try SpacesStore(path: path)
            XCTAssertEqual(reopened.profile(id)?.signInState, state)
            XCTAssertEqual(reopened.favorites(ofProfile: id).count, state == .added ? 2 : 0)
        }
    }

    func testFullGridLeavesOfferAndNoPartialWrite() throws {
        let s = try makeStore(), p = try s.createProfile(name: "Studio")
        try s.beginGoogleSignIn(p.id)
        try s.receiveGoogleSignIn(p.id, accounts: [account])
        try s.perform(nil) {
            for i in 0..<11 { s.put(Item(kind: .tab, container: .favorites(profileID: p.id), order: Double(i), savedURL: "https://example.com/\(i)")) }
        }
        XCTAssertThrowsError(try s.finishGoogleSignIn(p.id, choice: .added))
        XCTAssertEqual(s.favorites(ofProfile: p.id).count, 11)
        XCTAssertEqual(s.profile(p.id)?.signInState, .offered)
        try s.finishGoogleSignIn(p.id, choice: .declined)
        XCTAssertEqual(s.profile(p.id)?.signInState, .declined)
    }

    func testLegacyProfileDecodesWithoutState() throws {
        let p = Profile(name: "Legacy")
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.signInState, .created)
        XCTAssertNil(decoded.googleSignIn)
    }
}

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
        XCTAssertEqual(favorites.map(\.title), ["Gmail", "Calendar", "Drive"])
        XCTAssertEqual(favorites.map(\.savedURL), ["https://mail.google.com/mail/u/0/?authuser=alex@example.com",
                                                   "https://calendar.google.com/calendar/u/0/r?authuser=alex@example.com",
                                                   "https://drive.google.com/drive/u/0/my-drive?authuser=alex@example.com"])
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
            XCTAssertEqual(reopened.favorites(ofProfile: id).count, state == .added ? 3 : 0)
        }
    }

    func testFullGridLeavesOfferAndNoPartialWrite() throws {
        let s = try makeStore(), p = try s.createProfile(name: "Studio")
        try s.beginGoogleSignIn(p.id)
        try s.receiveGoogleSignIn(p.id, accounts: [account])
        try s.perform(nil) {
            for i in 0..<10 { s.put(Item(kind: .tab, container: .favorites(profileID: p.id), order: Double(i), savedURL: "https://example.com/\(i)")) }
        }
        XCTAssertThrowsError(try s.finishGoogleSignIn(p.id, choice: .added))
        XCTAssertEqual(s.favorites(ofProfile: p.id).count, 10)
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

    func testSecondAccountIsTheNewOneAtItsIndex() throws {
        let blair = GoogleAccount(name: "Blair Example", email: "blair@example.com", photoURL: "https://lh3.example.com/b")
        let both = [blair, GoogleAccount(name: "Alex Example", email: "alex@example.com", photoURL: "https://lh3.example.com/a")]
        XCTAssertNil(GoogleSignInChoice.account([blair], before: ["Blair@example.com"]))
        XCTAssertEqual(GoogleSignInChoice.account(both, before: [blair.email])?.account.email, "alex@example.com")
        XCTAssertEqual(GoogleSignInChoice.account(both, before: [blair.email])?.index, 1)
        XCTAssertEqual(GoogleSignInChoice.account(both, before: nil)?.index, 1)
        XCTAssertNil(GoogleSignInChoice.account([], before: []))

        let s = try makeStore(), p = try s.createProfile(name: "Work")
        try s.beginGoogleSignIn(p.id)
        let pick = try XCTUnwrap(GoogleSignInChoice.account(both, before: [blair.email]))
        try s.receiveGoogleSignIn(p.id, account: pick.account, index: pick.index)
        let kept = try XCTUnwrap(s.profile(p.id))
        XCTAssertEqual(kept.googleAccount, "alex@example.com")
        XCTAssertEqual(kept.googleAccountName, "Alex Example")
        XCTAssertEqual(kept.googleAccountLabel, "Alex Example")
        XCTAssertEqual(kept.googleAccountPhoto, "https://lh3.example.com/a")
        XCTAssertEqual(kept.googleAccountIndex, 1)
        // A u/0 Gmail tile is another account's: it doesn't count, the u/1 one is added.
        try s.perform(nil) { s.put(Item(kind: .tab, container: .favorites(profileID: p.id), order: 0, savedURL: "https://mail.google.com/mail/u/0/#inbox")) }
        try s.finishGoogleSignIn(p.id, choice: .added)
        XCTAssertEqual(s.favorites(ofProfile: p.id).compactMap(\.savedURL), [
            "https://mail.google.com/mail/u/0/#inbox",
            "https://mail.google.com/mail/u/1/?authuser=alex@example.com",
            "https://calendar.google.com/calendar/u/1/r?authuser=alex@example.com",
            "https://drive.google.com/drive/u/1/my-drive?authuser=alex@example.com"])
        XCTAssertTrue(s.missingGoogleFavorites(p.id).isEmpty)
    }

    func testSameAccountTilesAreNotDuplicated() {
        XCTAssertTrue(GoogleSuggestedFavorites.opens("https://mail.google.com/mail/u/0/", host: "mail.google.com", email: "a@example.com", index: 0))
        XCTAssertTrue(GoogleSuggestedFavorites.opens("https://mail.google.com/", host: "mail.google.com", email: "a@example.com", index: 0))
        XCTAssertTrue(GoogleSuggestedFavorites.opens("https://mail.google.com/mail/u/3/?authuser=A@example.com", host: "mail.google.com", email: "a@example.com", index: 1))
        XCTAssertTrue(GoogleSuggestedFavorites.opens("https://drive.google.com/?authuser=1", host: "drive.google.com", email: "a@example.com", index: 1))
        XCTAssertFalse(GoogleSuggestedFavorites.opens("https://mail.google.com/mail/u/1/", host: "mail.google.com", email: "a@example.com", index: 0))
        XCTAssertFalse(GoogleSuggestedFavorites.opens("https://calendar.google.com/", host: "mail.google.com", email: "a@example.com", index: 0))
        XCTAssertEqual(GoogleSuggestedFavorites.names, "Gmail, Calendar and Drive")
    }

    func testKeepGoogleAccountSetsAndClearsEverything() throws {
        let s = try makeStore(), p = try s.createProfile(name: "Studio")
        try s.keepGoogleAccount(p.id, account: GoogleAccount(name: "Alex Example", email: "alex@example.com", photoURL: "https://lh3.example.com/a"), index: 0)
        XCTAssertEqual(s.profile(p.id)?.googleAccountPhoto, "https://lh3.example.com/a")
        try s.keepGoogleAccount(p.id, account: nil, index: 0)
        let cleared = try XCTUnwrap(s.profile(p.id))
        XCTAssertNil(cleared.googleAccount); XCTAssertNil(cleared.googleAccountName)
        XCTAssertNil(cleared.googleAccountPhoto); XCTAssertNil(cleared.googleAccountIndex)
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// SP-12. Terminal choices stay with the profile, including across relaunch and shared Spaces.
public enum ProfileSignInState: String, Codable, Hashable, Sendable {
    case created, signingIn, offered, added, declined, dismissed
    public var showsCard: Bool { self == .created || self == .signingIn || self == .offered }
}

extension Profile {
    public var signInState: ProfileSignInState {
        googleSignIn ?? (isDefault || googleAccount != nil ? .dismissed : .created)
    }
}

extension SpacesStore {
    /// An explicit retry can restart a previously dismissed flow (e.g. Settings → Sign In).
    public func beginGoogleSignIn(_ id: String) throws {
        try updateProfile(id) { $0.googleSignIn = .signingIn }
    }

    /// Only a pending sign-in accepts a probe answer. Late responses cannot undo a dismissal.
    public func receiveGoogleSignIn(_ id: String, accounts: [GoogleAccount]?) throws {
        guard profile(id)?.signInState == .signingIn, let account = accounts?.first else { return }
        try updateProfile(id) {
            $0.googleAccount = account.email
            $0.googleSignIn = .offered
        }
    }

    /// Both tiles and the final state commit atomically. Repeated Add or a second window cannot duplicate them.
    public func finishGoogleSignIn(_ id: String, choice: ProfileSignInState) throws {
        guard var p = profile(id) else { throw StoreError.notFound }
        guard p.signInState.showsCard else { return }
        guard choice == .dismissed || (p.signInState == .offered && (choice == .added || choice == .declined)) else { return }
        try perform(nil) {
            if choice == .added, let email = p.googleAccount {
                let existing = favorites(ofProfile: id)
                let sites = [("Gmail", "https://mail.google.com/mail/"), ("Calendar", "https://calendar.google.com/calendar/")]
                let missing = sites.compactMap { title, address -> (String, String)? in
                    var url = URLComponents(string: address)!
                    // An email selects the detected account even when Google's cookie jar contains several accounts.
                    url.queryItems = [URLQueryItem(name: "authuser", value: email)]
                    let host = url.host
                    guard !existing.contains(where: { URL(string: $0.savedURL ?? "")?.host == host }) else { return nil }
                    return (title, url.string!)
                }
                guard existing.count + missing.count <= Self.maxFavorites else { throw StoreError.favoritesFull }
                var order = (existing.map(\.order).max() ?? -1) + 1
                for (title, url) in missing {
                    put(Item(kind: .tab, container: .favorites(profileID: id), order: order, savedURL: url, title: title))
                    order += 1
                }
            }
            p.googleSignIn = choice
            put(p)
        }
    }
}

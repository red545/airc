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

    /// The account's name when Google gave one, else its email.
    public var googleAccountLabel: String? { googleAccountName.flatMap { $0.isEmpty ? nil : $0 } ?? googleAccount }
}

/// SP-12: the Favorites offered once a profile signs in to Google, each opened as that account
/// (`/u/<index>/` as Arc's Google links, plus `authuser=<email>` so it stays right if the order of sign-ins changes).
public enum GoogleSuggestedFavorites {
    public static let sites: [(title: String, host: String, path: String)] = [
        ("Gmail", "mail.google.com", "/mail/u/%d/"),
        ("Calendar", "calendar.google.com", "/calendar/u/%d/r"),
        ("Drive", "drive.google.com", "/drive/u/%d/my-drive"),
    ]

    /// "Gmail, Calendar and Drive".
    public static var names: String {
        let t = sites.map(\.title)
        return t.dropLast().joined(separator: ", ") + " and " + t.last!
    }

    public static func url(_ site: (title: String, host: String, path: String), email: String, index: Int) -> String {
        var c = URLComponents()
        c.scheme = "https"
        c.host = site.host
        c.path = String(format: site.path, max(0, index))
        c.queryItems = [URLQueryItem(name: "authuser", value: email)]
        return c.string!
    }

    /// Whether `saved` already opens `host` as this account: same host and the same `authuser` email, or, without one,
    /// the same `/u/<n>/` index (a plain address is u/0).
    public static func opens(_ saved: String?, host: String, email: String, index: Int) -> Bool {
        guard let c = saved.flatMap(URLComponents.init(string:)), c.host?.lowercased() == host else { return false }
        if let user = c.queryItems?.first(where: { $0.name == "authuser" })?.value {
            return Int(user).map { $0 == index } ?? (user.lowercased() == email.lowercased())
        }
        let n = c.path.range(of: #"/u/(\d+)(?=/|$)"#, options: .regularExpression)
            .flatMap { Int(c.path[$0].dropFirst(3)) } ?? 0
        return n == index
    }
}

/// Which account a sign-in just added, from Google's list (sign-in order, so the position is its u/N).
public enum GoogleSignInChoice {
    /// The last account that wasn't signed in before (`before`: the emails from the answer read when sign-in began).
    /// Without that earlier answer, the last account listed. nil: nobody new yet.
    public static func account(_ accounts: [GoogleAccount], before: Set<String>?) -> (account: GoogleAccount, index: Int)? {
        let known = Set((before ?? []).map { $0.lowercased() })
        guard let i = accounts.lastIndex(where: { !known.contains($0.email.lowercased()) }) else { return nil }
        return (accounts[i], i)
    }
}

extension SpacesStore {
    /// An explicit retry can restart a previously dismissed flow (e.g. Settings → Sign In).
    public func beginGoogleSignIn(_ id: String) throws {
        try updateProfile(id) { $0.googleSignIn = .signingIn }
    }

    /// Keeps `account` (or forgets it) on the profile: email, name, picture and u/N. Onboarding and the sidebar's
    /// sign-in both come through here. Local only.
    public func keepGoogleAccount(_ id: String, account: GoogleAccount?, index: Int?) throws {
        guard let p = profile(id), p.googleAccount != account?.email || p.googleAccountName != account?.name
            || p.googleAccountPhoto != account?.photoURL || p.googleAccountIndex != index else { return }
        try updateProfile(id) { Self.keep(account, index: index, in: &$0) }
    }

    private static func keep(_ account: GoogleAccount?, index: Int?, in p: inout Profile) {
        p.googleAccount = account?.email
        p.googleAccountName = account?.name
        p.googleAccountPhoto = account?.photoURL
        p.googleAccountIndex = account == nil ? nil : index
    }

    /// Only a pending sign-in accepts a probe answer. Late responses cannot undo a dismissal.
    public func receiveGoogleSignIn(_ id: String, account: GoogleAccount, index: Int) throws {
        guard profile(id)?.signInState == .signingIn else { return }
        try updateProfile(id) {
            Self.keep(account, index: index, in: &$0)
            $0.googleSignIn = .offered
        }
    }

    /// The whole list, with no earlier answer to compare: the last account listed.
    public func receiveGoogleSignIn(_ id: String, accounts: [GoogleAccount]?) throws {
        guard let accounts, let pick = GoogleSignInChoice.account(accounts, before: nil) else { return }
        try receiveGoogleSignIn(id, account: pick.account, index: pick.index)
    }

    /// The suggested Favorites this profile doesn't have yet for its account.
    public func missingGoogleFavorites(_ id: String) -> [(title: String, url: String)] {
        guard let p = profile(id), let email = p.googleAccount else { return [] }
        let index = p.googleAccountIndex ?? 0
        let existing = favorites(ofProfile: id)
        return GoogleSuggestedFavorites.sites.compactMap { site in
            existing.contains { GoogleSuggestedFavorites.opens($0.savedURL, host: site.host, email: email, index: index) } ? nil
                : (site.title, GoogleSuggestedFavorites.url(site, email: email, index: index))
        }
    }

    /// The tiles and the final state commit atomically. Repeated Add or a second window cannot duplicate them.
    public func finishGoogleSignIn(_ id: String, choice: ProfileSignInState) throws {
        guard var p = profile(id) else { throw StoreError.notFound }
        guard p.signInState.showsCard else { return }
        guard choice == .dismissed || (p.signInState == .offered && (choice == .added || choice == .declined)) else { return }
        try perform(nil) {
            if choice == .added {
                let existing = favorites(ofProfile: id)
                let missing = missingGoogleFavorites(id)
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

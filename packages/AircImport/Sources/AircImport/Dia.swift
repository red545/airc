// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Dia (The Browser Company's Chromium browser, company.thebrowser.dia). Its data is a Chromium "User Data" folder, as
// Arc's is: ~/Library/Application Support/Dia/User Data/<Default | Profile N>. Like Arc, it locks saved passwords and
// cookies with a key in the login keychain: generic password "Dia Safe Storage", account "Dia" (Chromium's v10:
// PBKDF2-SHA1, "saltysalt", 1003 rounds, AES-128-CBC). Since Dia 1.54 its bookmarks are locked with the same key too:
// `EncryptedBookmarks2` is "v10" + AES-128-CBC of Chromium's usual `Bookmarks` JSON, and the plain `Bookmarks` file
// stops being written (a fresh profile may have none). Dia's sidebar (Spaces, pinned tabs, custom names) is a
// SQLCipher database whose key only Dia's own team can read from Keychain, so it isn't imported.
// See docs/user/import-from-dia.md and artifacts/diaimport/REPORT.md for what is verified and what is assumed.

/// A browser whose logins and cookies Airc can unlock with the user's consent (IM-2): its name in the UI and the
/// Keychain item holding its key.
public struct CredentialSource: Sendable, Equatable {
    public var name: String
    public var item: ArcSafeStorage.Item
    public init(name: String, item: ArcSafeStorage.Item) { self.name = name; self.item = item }
    public static let arc = CredentialSource(name: "Arc", item: .arc)
    public static let dia = CredentialSource(name: "Dia", item: .dia)
}

extension ArcSafeStorage.Item {
    /// Dia's key: generic password "Dia Safe Storage", account "Dia". The app reads only `.arc` and `.dia`.
    public static let dia = ArcSafeStorage.Item(service: "Dia Safe Storage", account: "Dia")
}

extension BrowserKind {
    /// The browsers whose logins and cookies come over with their Keychain key (IM-2): Dia. Every other browser's
    /// passwords come from a CSV file only (IM-4).
    public var credentialSource: CredentialSource? { self == .dia ? .dia : nil }
}

/// Dia's encrypted bookmarks (`EncryptedBookmarks2`, Dia 1.54 and later).
public enum DiaBookmarks {
    public static let fileName = "EncryptedBookmarks2"

    /// The profile keeps its bookmarks locked: `EncryptedBookmarks2` is there and the plain `Bookmarks` file is
    /// missing or older (Dia stopped writing it), so the plain one would bring back an old state.
    public static func isLocked(profile: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enc = try? profile.appendingPathComponent(fileName).resourceValues(forKeys: keys), enc.isRegularFile == true else { return false }
        guard let plain = try? profile.appendingPathComponent("Bookmarks").resourceValues(forKeys: keys), plain.isRegularFile == true else { return true }
        return (plain.contentModificationDate ?? .distantPast) < (enc.contentModificationDate ?? .distantPast)
    }

    /// The `Bookmarks` JSON inside `EncryptedBookmarks2`, decrypted with Dia's key (`ArcSafeStorage.deriveKey`).
    public static func decrypt(profile: URL, key: Data) throws -> Data {
        let data = try BrowserImporter.readLimited(profile.appendingPathComponent(fileName))
        return try ArcSafeStorage.decrypt(data, key: key)
    }
}

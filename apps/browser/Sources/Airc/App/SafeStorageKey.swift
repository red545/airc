// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

/// The key to saved passwords and cookies: Chromium keeps it in the "Airc Safe Storage" item of the login keychain
/// (engine patch 021) and reads it once per launch. The keychain lets an item's creator read it without asking, and
/// asks about every other app (owner report 2026-11-06: "I still need to put in 2x the password" at every launch):
///   - an item made by an ad-hoc build trusts that build's cdhash only, so every later build asks, the Developer ID
///     builds included;
///   - an item made by a Developer ID build trusts its designated requirement, so every later build signed the same
///     way reads it without asking;
///   - an app can't add itself to an item's access list without the keychain password, but it may delete an item it
///     doesn't own and add its own.
/// (Proven on scratch keychains, with interaction off: artifacts/littlearc.) So once per signing identity, before the
/// engine starts: if the key exists and this build would be asked, ask once (the question Chromium would ask anyway),
/// put the same secret in an item of this build's own, and delete the old one. Chromium's read is then silent, and so
/// is every later launch and update. Nothing is lost: the copy is read back and compared before the old item goes, and
/// a copy left by an interrupted repair is put back first.
enum SafeStorageKey {
    static let service = "Airc Safe Storage"
    static let account = "Airc"
    private static let copySuffix = ".new"

    enum Outcome: Equatable {
        case notFound, alreadySilent, recreated, recovered, declined(OSStatus), failed(String)
    }

    /// The repair. `keychains`: where to look (nil: the user's search list, as Chromium does). `readAsking`: the read
    /// that may ask the person (nil: the keychain's own question; the scratch-keychain proof answers it itself).
    static func repair(service: String = service, account: String = account, keychains: [SecKeychain]? = nil,
                       readAsking: (() -> (OSStatus, Data?))? = nil) -> Outcome {
        let copyAccount = account + copySuffix
        // A copy left by an interrupted repair, its original gone: it's this build's own, so put it back silently.
        var recovered = false
        if silently({ read(service, account, keychains).0 }) == errSecItemNotFound {
            let (copyStatus, copy) = silently { read(service, copyAccount, keychains) }
            guard copyStatus == errSecSuccess, let copy else { return .notFound }
            guard rename(service, from: copyAccount, to: account, keychains) == errSecSuccess
                    || add(service, account, copy, keychain(of: service, copyAccount, keychains)) == errSecSuccess else {
                return .failed("a copy waits under \(copyAccount) and couldn't be put back")
            }
            _ = delete(service, copyAccount, keychains)
            recovered = true
        }
        let (silent, _) = silently { read(service, account, keychains) }
        if silent == errSecSuccess { return recovered ? .recovered : .alreadySilent }
        if silent == errSecItemNotFound { return .notFound }
        // This build would be asked: ask now, once.
        let (status, secret) = readAsking?() ?? read(service, account, keychains)
        guard status == errSecSuccess, let secret, !secret.isEmpty else { return .declined(status) }
        guard let target = keychain(of: service, account, keychains) else { return .failed("the item's keychain") }
        _ = delete(service, copyAccount, keychains)
        var s = add(service, copyAccount, secret, target)
        guard s == errSecSuccess else { return .failed("adding the copy: \(s)") }
        let (back, copy) = silently { read(service, copyAccount, keychains) }
        guard back == errSecSuccess, copy == secret else {
            _ = delete(service, copyAccount, keychains)
            return .failed("reading the copy back: \(back)")
        }
        s = delete(service, account, keychains)
        guard s == errSecSuccess else {
            _ = delete(service, copyAccount, keychains)
            return .failed("deleting the old item: \(s)")
        }
        s = rename(service, from: copyAccount, to: account, keychains)
        if s != errSecSuccess {
            // The secret is still in memory: add it under the real name, then drop the copy. If even that fails, the
            // copy stays and the next launch puts it back before Chromium looks.
            guard add(service, account, secret, target) == errSecSuccess else { return .failed("renaming the copy: \(s)") }
            _ = delete(service, copyAccount, keychains)
        }
        let (check, again) = silently { read(service, account, keychains) }
        return check == errSecSuccess && again == secret ? .recreated : .failed("reading the new item: \(check)")
    }

    // MARK: Keychain calls (the legacy file keychain, as Chromium's KeychainV2 uses)

    private static func query(_ service: String, _ account: String, _ keychains: [SecKeychain]?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecMatchLimit as String: kSecMatchLimitOne]
        if let keychains { q[kSecMatchSearchList as String] = keychains }
        return q
    }

    static func read(_ service: String, _ account: String, _ keychains: [SecKeychain]?) -> (OSStatus, Data?) {
        var q = query(service, account, keychains)
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &result)
        return (s, result as? Data)
    }

    /// `body` with the keychain's questions off: what would ask fails instead (errSecAuthFailed or
    /// errSecInteractionNotAllowed). Process-wide, so only before the engine starts.
    private static func silently<T>(_ body: () -> T) -> T {
        var allowed = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return body()
    }

    private static func keychain(of service: String, _ account: String, _ keychains: [SecKeychain]?) -> SecKeychain? {
        var q = query(service, account, keychains)
        q[kSecReturnRef as String] = true
        var ref: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess, let ref else { return nil }
        var keychain: SecKeychain?
        // Deleting or adding never reads the secret, so these never ask (the scratch proof checks it).
        return SecKeychainItemCopyKeychain(ref as! SecKeychainItem, &keychain) == errSecSuccess ? keychain : nil
    }

    /// As Chromium's KeychainV2::AddGenericPassword makes it, in the old item's keychain.
    private static func add(_ service: String, _ account: String, _ secret: Data, _ keychain: SecKeychain?) -> OSStatus {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecValueData as String: secret,
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecAttrLabel as String: service]
        if let keychain { q[kSecUseKeychain as String] = keychain }
        return SecItemAdd(q as CFDictionary, nil)
    }

    private static func delete(_ service: String, _ account: String, _ keychains: [SecKeychain]?) -> OSStatus {
        var q = query(service, account, keychains)
        q[kSecReturnRef as String] = true
        var ref: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &ref)
        guard s == errSecSuccess, let ref else { return s }
        return SecKeychainItemDelete(ref as! SecKeychainItem)
    }

    private static func rename(_ service: String, from: String, to: String, _ keychains: [SecKeychain]?) -> OSStatus {
        var q = query(service, from, keychains)
        q.removeValue(forKey: kSecMatchLimit as String)
        return SecItemUpdate(q as CFDictionary, [kSecAttrAccount as String: to] as CFDictionary)
    }
}

#if !SAFE_STORAGE_PROOF
extension SafeStorageKey {
    /// main.swift, before the Chromium engine starts: the repair, once per signing identity. Only builds signed by a
    /// team (Developer ID): an ad-hoc build would only move the trust to its own cdhash. Never on the mock keychain.
    static func prepareForEngine(_ options: LaunchOptions) {
        guard !options.isAutomated, !options.engineSwitches.contains(where: { $0.hasPrefix("--use-mock-keychain") }),
              let identity = signingIdentity() else { return }
        let marker = "AircSafeStorageKeyOwner"
        // Done for this identity: only Chromium's own read from here on.
        guard UserDefaults.standard.string(forKey: marker) != identity else { return }
        let started = Date()
        let outcome = repair()
        switch outcome {
        case .alreadySilent, .recreated, .recovered, .notFound: UserDefaults.standard.set(identity, forKey: marker)
        case .declined, .failed: break   // asked again next launch
        }
        LinkLog.write("Safe Storage key: \(outcome) in \(Int(Date().timeIntervalSince(started) * 1000)) ms", file: "Keychain.log")
    }

    /// This build's bundle identifier and team, or nil when it isn't signed by a team.
    private static func signingIdentity() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any], let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        else { return nil }
        return "\(info[kSecCodeInfoIdentifier as String] as? String ?? "?") \(team)"
    }
}
#endif

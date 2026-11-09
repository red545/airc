// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Security

public enum SyncKeyError: Error, Equatable, Sendable {
    /// A key for this group exists already: never overwrite it (another Mac may be using it).
    case duplicate
    case unreadable
    case keychain(OSStatus)
}

/// Where the per-group AES key lives. In release builds: iCloud Keychain, so a second Mac signed in to the same Apple
/// ID can decrypt. A key is only ever added, never replaced, and turning sync off leaves it (deleting a synchronizable
/// item deletes it on every Mac).
public protocol SyncKeyStore: Sendable {
    /// nil: not on this Mac (yet). iCloud Keychain may still be bringing it over from the first Mac.
    func key(group: UUID) throws -> SymmetricKey?
    /// Throws `.duplicate` when the group already has a key.
    func add(_ key: SymmetricKey, group: UUID) throws
    /// Only for a key this Mac just made for a group that lost the race to another Mac's (nobody else has it).
    func removeUnused(group: UUID) throws
}

extension SyncGroupRecord {
    private static func checkText(_ group: UUID) -> Data { Data("Airc sidebar sync key check|\(group.uuidString)".utf8) }

    /// A new group's record, with proof of `key`.
    public static func make(group: UUID, key: SymmetricKey, created: Date) throws -> Self {
        let box = try AES.GCM.seal(checkText(group), using: key)
        guard let check = box.combined else { throw SyncError.invalidEnvelope }
        return Self(group: group, check: check, created: created)
    }

    /// The key belongs to this group (a key with the same account but from another group would fail).
    public func verifies(_ key: SymmetricKey) -> Bool {
        guard let box = try? AES.GCM.SealedBox(combined: check), let text = try? AES.GCM.open(box, using: key) else { return false }
        return text == Self.checkText(group)
    }
}

/// The group key as a synchronizable generic password in the data-protection keychain: service "Airc sidebar sync",
/// account = the group UUID, readable when the Mac is unlocked (not "this device only", so iCloud Keychain carries it).
public struct KeychainSyncKeyStore: SyncKeyStore {
    public static let service = "Airc sidebar sync"
    /// `<team>.<bundle id>` from the app's entitlements (SyncCapability.keychainAccessGroup).
    public let accessGroup: String?
    /// `service`; the real-iCloud test keeps its key apart and deletes it afterwards.
    public let service: String
    /// Always true in the product (the second Mac needs the key). The real-iCloud test's two installations share one
    /// Mac, so its key stays local and never reaches the owner's other devices.
    public let synchronizable: Bool
    /// When the key can be read. The product: while the Mac is unlocked (iCloud Keychain carries it). The real-iCloud
    /// test's local key: after the first unlock, on this Mac only, so it runs with the screen locked.
    public enum Accessibility: Sendable { case whenUnlocked, afterFirstUnlockThisDeviceOnly }
    public let accessibility: Accessibility

    public init(accessGroup: String?, service: String = Self.service, synchronizable: Bool = true,
                accessibility: Accessibility = .whenUnlocked) {
        self.accessGroup = accessGroup; self.service = service; self.synchronizable = synchronizable
        self.accessibility = accessibility
    }

    private func query(_ group: UUID) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: group.uuidString,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func key(group: UUID) throws -> SymmetricKey? {
        var q = query(group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SyncKeyError.keychain(status) }
        guard let data = result as? Data, data.count == 32 else { throw SyncKeyError.unreadable }
        return SymmetricKey(data: data)
    }

    public func add(_ key: SymmetricKey, group: UUID) throws {
        var q = query(group)
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        q[kSecAttrAccessible as String] = accessibility == .whenUnlocked ? kSecAttrAccessibleWhenUnlocked
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrLabel as String] = "Airc sidebar sync key"
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem { throw SyncKeyError.duplicate }
        guard status == errSecSuccess else { throw SyncKeyError.keychain(status) }
    }

    public func removeUnused(group: UUID) throws {
        let status = SecItemDelete(query(group) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncKeyError.keychain(status) }
    }
}

/// Fake keychain for unit tests. `copy(from:)` plays iCloud Keychain bringing a key over.
public final class InMemorySyncKeyStore: SyncKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]
    /// Unit tests: the keychain refuses access (locked, or no entitlement).
    public var failure: SyncKeyError?

    public init() {}

    public var groups: Set<UUID> { lock.withLock { Set(keys.keys) } }

    public func copy(from other: InMemorySyncKeyStore) {
        let theirs = other.lock.withLock { other.keys }
        lock.withLock { keys.merge(theirs) { mine, _ in mine } }
    }

    public func key(group: UUID) throws -> SymmetricKey? {
        if let failure { throw failure }
        return lock.withLock { keys[group].map { SymmetricKey(data: $0) } }
    }

    public func add(_ key: SymmetricKey, group: UUID) throws {
        if let failure { throw failure }
        try lock.withLock {
            guard keys[group] == nil else { throw SyncKeyError.duplicate }
            keys[group] = key.withUnsafeBytes { Data($0) }
        }
    }

    public func removeUnused(group: UUID) throws { _ = lock.withLock { keys.removeValue(forKey: group) } }
}

/// A "keychain" in a folder, one file per group: the scripted check gives each app instance its own and copies a file
/// across to play iCloud Keychain. Test builds only (`--sync-keychain`); never for real keys.
public struct FolderSyncKeyStore: SyncKeyStore {
    public let folder: URL

    public init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(_ group: UUID) -> URL { folder.appendingPathComponent(group.uuidString + ".key") }

    public func key(group: UUID) throws -> SymmetricKey? {
        guard let data = try? Data(contentsOf: file(group)) else { return nil }
        guard data.count == 32 else { throw SyncKeyError.unreadable }
        return SymmetricKey(data: data)
    }

    public func add(_ key: SymmetricKey, group: UUID) throws {
        let data = key.withUnsafeBytes { Data($0) }
        do { try data.write(to: file(group), options: .withoutOverwriting) }
        catch CocoaError.fileWriteFileExists { throw SyncKeyError.duplicate }
    }

    public func removeUnused(group: UUID) throws { try? FileManager.default.removeItem(at: file(group)) }
}

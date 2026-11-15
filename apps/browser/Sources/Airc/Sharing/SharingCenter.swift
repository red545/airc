// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import Foundation
import Security

/// H01, H02, B03: the app's side of the sharing service (AircKit SharingService; docs/dev/sharing-service.md).
///   - Where it is: aircbrowser.com. Test builds may point it at a local or Preview deployment (AIRC_SHARING_BASE,
///     and AIRC_SHARING_BYPASS for a protected Preview).
///   - The links this Mac published: "Shared Links.json" next to Airc's data (id, address, what was shared, when).
///   - Each link's token, which takes it back: in the login Keychain ("Airc Shared Link", one item per link). Scripted
///     runs keep tokens in memory and never touch the Keychain.
/// Nothing about the person goes to the service: no account, no name, no device id.
final class SharingCenter {
    static let shared = SharingCenter()
    static let didChange = Notification.Name("AircSharedLinksDidChange")
    static let keychainService = "Airc Shared Link"

    let service: SharingService
    private(set) var records: [SharedLinkRecord]
    private let keychain: Bool
    private var memoryTokens: [String: String] = [:]

    private init() {
        var base = SharingService.site
        var headers: [String: String] = [:]
        #if AIRC_TESTING
        let env = ProcessInfo.processInfo.environment
        if let s = env["AIRC_SHARING_BASE"], let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") { base = u }
        if let b = env["AIRC_SHARING_BYPASS"], !b.isEmpty { headers["x-vercel-protection-bypass"] = b }
        #endif
        service = SharingService(base: base, extraHeaders: headers)
        keychain = !LaunchOptions.current.isAutomated
        records = SharedLinkRecord.load(try? Data(contentsOf: Self.file)) + SharedLinkRecord.load(try? Data(contentsOf: Self.easelFile))
    }

    static var file: URL { AppPaths.dataDirectory.appendingPathComponent("Shared Links.json") }
    /// P19c: Easel links, in a file of their own (a build before them reads "Shared Links.json" whole or not at all).
    static var easelFile: URL { AppPaths.dataDirectory.appendingPathComponent("Shared Easel Links.json") }

    /// The links made of a Space or folder, newest first.
    func links(of sourceID: String) -> [SharedLinkRecord] {
        records.filter { $0.sourceID == sourceID }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Publishes a Space's or folder's snapshot; the link is recorded and its token kept.
    @MainActor
    func publish(_ draft: ShareDraft, sourceID: String) async throws -> SharedLinkRecord {
        let p = try await service.publish(draft.snapshot)
        let kind: SharedLinkRecord.Kind = { if case .space = draft.snapshot.kind { .space } else { .folder } }()
        let r = SharedLinkRecord(id: p.id, url: p.url, kind: kind, name: draft.snapshot.name, sourceID: sourceID, createdAt: Date())
        storeToken(p.token, for: p.id)
        records.append(r)
        save()
        return r
    }

    /// P19c: publishes an Easel's read-only snapshot (its public form and pictures); the link is recorded and its token kept.
    @MainActor
    func publishEasel(_ easel: EaselPublic, pictures: [String: Data], easelID: String,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> SharedLinkRecord {
        let p = try await service.publishEasel(easel, pictures: pictures, progress: progress)
        let r = SharedLinkRecord(id: p.id, url: p.url, kind: .easel, name: easel.displayTitle, sourceID: easelID, createdAt: Date())
        storeToken(p.token, for: p.id)
        records.append(r)
        save()
        return r
    }

    enum RevokeFailure: Error, LocalizedError {
        case noToken
        var errorDescription: String? { "This Mac no longer has the key that takes this link back." }
    }

    /// Takes a link back: the service forgets it (it 404s from then on), then this Mac forgets it and its token.
    @MainActor
    func revoke(_ record: SharedLinkRecord) async throws {
        guard let token = token(for: record.id) else {
            throw RevokeFailure.noToken
        }
        if record.kind == .easel {
            try await service.revokeEasel(id: record.id, token: token)
        } else {
            try await service.revoke(id: record.id, token: token)
        }
        deleteToken(for: record.id)
        records.removeAll { $0.id == record.id }
        save()
    }

    /// Forgets a link whose key is gone (the link stays up: only its maker could take it back).
    func forget(_ record: SharedLinkRecord) {
        deleteToken(for: record.id)
        records.removeAll { $0.id == record.id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: AppPaths.dataDirectory, withIntermediateDirectories: true)
        try? SharedLinkRecord.save(records.filter { $0.kind != .easel }).write(to: Self.file, options: [.atomic])
        let easels = records.filter { $0.kind == .easel }
        if easels.isEmpty { try? FileManager.default.removeItem(at: Self.easelFile) }
        else { try? SharedLinkRecord.save(easels).write(to: Self.easelFile, options: [.atomic]) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Tokens

    #if AIRC_TESTING
    /// The checks: whether this link's token is held (without reading it out).
    func holdsToken(for id: String) -> Bool { token(for: id) != nil }
    #endif

    private func storeToken(_ token: String, for id: String) {
        guard keychain else { memoryTokens[id] = token; return }
        deleteToken(for: id)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                kSecAttrAccount as String: id, kSecAttrLabel as String: Self.keychainService,
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked, kSecValueData as String: Data(token.utf8)]
        _ = SecItemAdd(q as CFDictionary, nil)
    }

    private func token(for id: String) -> String? {
        guard keychain else { return memoryTokens[id] }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                kSecAttrAccount as String: id, kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteToken(for id: String) {
        guard keychain else { memoryTokens[id] = nil; return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                kSecAttrAccount as String: id]
        _ = SecItemDelete(q as CFDictionary)
    }
}

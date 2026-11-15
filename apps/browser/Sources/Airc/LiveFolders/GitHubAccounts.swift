// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import Security

/// The GitHub account of each profile, for live folders that need one ("Your Pull Requests", "Review Requests",
/// private repositories). Its token is in the login Keychain (service "Airc GitHub", account = the profile's ID), never
/// in Airc's files, backups or sync; the login it belongs to is shown, nothing else. Profiles don't share accounts, as
/// they don't share website logins.
///
/// Signing in: GitHub's device flow when the build has an OAuth App's client ID (`clientID`), else a personal access
/// token pasted in the sheet. Scripted runs keep tokens in memory only, so a check never reads or writes the Keychain.
final class GitHubAccounts {
    static let shared = GitHubAccounts()

    /// The OAuth App's client ID: the `AircGitHubClientID` Info.plist key, or the `AircGitHubClientID` default (for a
    /// developer's own app). Empty in builds made before the maintainer registered one: the sheet then offers a token.
    /// A client ID isn't a secret (it's sent in the clear to every user's browser); the app has no client secret.
    var clientID: String {
        if let override = clientIDOverride { return override }
        let plist = Bundle.main.object(forInfoDictionaryKey: "AircGitHubClientID") as? String
        let value = (plist?.isEmpty == false ? plist : nil) ?? UserDefaults.standard.string(forKey: "AircGitHubClientID") ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var clientIDOverride: String?
    var canUseDeviceFlow: Bool { !clientID.isEmpty }

    static let service = "Airc GitHub"
    private var memory: [String: (token: String, login: String)] = [:]
    private var logins: [String: String] = [:]
    /// Scripted runs: tokens in memory only.
    var inMemory = (NSApp.delegate as? AppDelegate)?.options.isAutomated ?? false

    private init() {}

    // MARK: Tokens

    func token(forProfile id: String) -> String? {
        if inMemory { return memory[id]?.token }
        return read(id)?.token
    }

    /// The login the profile's token belongs to ("Signed in as …").
    func login(forProfile id: String) -> String? {
        if inMemory { return memory[id]?.login }
        if let l = logins[id] { return l }
        let l = read(id)?.login
        logins[id] = l
        return l
    }

    func save(token: String, login: String, forProfile id: String) {
        logins[id] = login
        if inMemory { memory[id] = (token, login); return }
        delete(id)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
            kSecAttrLabel as String: "Airc GitHub (\(login))",
            kSecAttrGeneric as String: Data(login.utf8),
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func signOut(profileID id: String) {
        logins[id] = nil
        if inMemory { memory[id] = nil; return }
        delete(id)
    }

    private func read(_ id: String) -> (token: String, login: String)? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? [String: Any],
              let data = d[kSecValueData as String] as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
        let login = (d[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (token, login)
    }

    private func delete(_ id: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                kSecAttrAccount as String: id]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: Signing in

    /// Checks a token with GitHub (`GET /user`) and keeps it for the profile. The error is the sheet's message.
    func useToken(_ raw: String, forProfile id: String, client: GitHubClient) async -> Result<String, LiveFolderStatus> {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.signedOut) }
        let r = await client.viewer(token: token)
        if case .success(let login) = r {
            await MainActor.run {
                self.save(token: token, login: login, forProfile: id)
                LiveFolderCenter.shared.accountChanged(profileID: id)
            }
        }
        return r
    }

    func deviceFlow(client: GitHubClient) -> GitHubDeviceFlow {
        GitHubDeviceFlow(http: client.http, endpoint: client.endpoint, clientID: clientID)
    }
}

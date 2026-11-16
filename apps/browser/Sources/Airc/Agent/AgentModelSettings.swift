// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import Security

/// Settings › AI › Agent (docs/design/agent.md, "Bring your own model"): which provider and model the Airc Agent uses,
/// its default level and the sites it never uses, in AgentPanel.json; the API keys in the login Keychain, never in a
/// file, a log or anything the model or an agent can read. Scripted runs keep keys in memory only.
final class AgentModelSettings {
    static let shared = AgentModelSettings()
    static let changed = Notification.Name("AircAgentModelSettingsChanged")
    static let keychainService = "Airc Agent Model Key"

    struct Values: Codable, Equatable {
        var provider: AgentProvider = .anthropic
        var anthropicModel = AgentProvider.anthropic.defaultModel.id
        var openaiModel = AgentProvider.openai.defaultModel.id
        var level: AgentLevel = .quick
        /// Sites (hosts) the agent never uses.
        var blockedSites: [String] = []

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider = (try? c.decode(AgentProvider.self, forKey: .provider)) ?? .anthropic
            anthropicModel = (try? c.decode(String.self, forKey: .anthropicModel)) ?? AgentProvider.anthropic.defaultModel.id
            openaiModel = (try? c.decode(String.self, forKey: .openaiModel)) ?? AgentProvider.openai.defaultModel.id
            level = (try? c.decode(AgentLevel.self, forKey: .level)) ?? .quick
            blockedSites = (try? c.decode([String].self, forKey: .blockedSites)) ?? []
        }
    }

    private(set) var values = Values()
    private var memoryKeys: [AgentProvider: String] = [:]
    /// Scripted runs: keys in memory only, and the base address of a local fake model server.
    private(set) var inMemory = false
    var baseOverride: String?

    private var file: URL { AppPaths.dataDirectory.appendingPathComponent("AgentPanel.json") }

    private init() {
        if let data = try? Data(contentsOf: file), let v = try? JSONDecoder().decode(Values.self, from: data) { values = v }
    }

    /// From the app's launch: scripted runs never touch the Keychain. Test builds take `--agent-model-base=<url>` and
    /// `--agent-model-key=<fixture key>` (memory only).
    func launch(automated: Bool) {
        inMemory = automated
        #if AIRC_TESTING
        let args = CommandLine.arguments
        if let b = args.first(where: { $0.hasPrefix("--agent-model-base=") }) { baseOverride = String(b.dropFirst("--agent-model-base=".count)) }
        if let k = args.first(where: { $0.hasPrefix("--agent-model-key=") }) {
            inMemory = true
            memoryKeys[values.provider] = String(k.dropFirst("--agent-model-key=".count))
        }
        #endif
    }

    func update(_ change: (inout Values) -> Void) {
        var v = values
        change(&v)
        guard v != values else { return }
        values = v
        if let data = try? JSONEncoder.agents.encode(v) { _ = AgentPaths.writePrivate(data, to: file.path) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    var model: AgentModel {
        let id = values.provider == .anthropic ? values.anthropicModel : values.openaiModel
        return AgentModel.find(id).flatMap { $0.provider == values.provider ? $0 : nil } ?? values.provider.defaultModel
    }

    var baseURL: URL { URL(string: baseOverride ?? values.provider.defaultBase)! }

    func isBlocked(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return values.blockedSites.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    // MARK: Keys

    func key(_ p: AgentProvider) -> String? {
        if inMemory { return memoryKeys[p] }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                kSecAttrAccount as String: p.rawValue, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func hasKey(_ p: AgentProvider) -> Bool { !(key(p) ?? "").isEmpty }

    /// "…a1b2": what Settings shows of a saved key.
    func keyHint(_ p: AgentProvider) -> String? { key(p).map { "…" + $0.suffix(4) } }

    /// Saves (or, empty, removes) a key. False if the Keychain refused.
    @discardableResult
    func setKey(_ raw: String, for p: AgentProvider) -> Bool {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { NotificationCenter.default.post(name: Self.changed, object: self) }
        if inMemory { memoryKeys[p] = k.isEmpty ? nil : k; return true }
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: p.rawValue]
        if k.isEmpty { SecItemDelete(match as CFDictionary); return true }
        let data = Data(k.utf8)
        if SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Airc Agent (\(p.name))"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    #if AIRC_TESTING
    /// Checks: a fixture key for this run (memory only).
    func setTestKey(_ key: String?, provider: AgentProvider, base: String?) {
        inMemory = true
        memoryKeys[provider] = key
        baseOverride = base
        update { $0.provider = provider }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    #endif
}

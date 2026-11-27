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
        /// Who runs the agent: your API key (Airc's loop), or your own Claude Code / Codex (docs/design/agent-cli.md).
        var backend: AgentBackend = .apiKey
        var provider: AgentProvider = .anthropic
        var anthropicModel = AgentProvider.anthropic.defaultModel.id
        var openaiModel = AgentProvider.openai.defaultModel.id
        var level: AgentLevel = .quick
        /// "Stop after N steps": nil (Off) by default; a task then runs until it's done, the person stops it or it needs
        /// them. Files from before 2026-11-23 have no value here, so everyone on the old default (Quick, 25 steps) is
        /// now on Off.
        var stepCap: Int?
        /// Sites (hosts) the agent never uses.
        var blockedSites: [String] = []
        /// "Remember things between tasks" (docs/design/agent.md, "Memory"): off by default.
        var memory = false
        /// agentparallel: how many Airc Agent tasks run at once; more start as Queued. 0 = no limit.
        var maxParallel = Values.defaultMaxParallel
        static let defaultMaxParallel = 3

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            backend = (try? c.decode(AgentBackend.self, forKey: .backend)) ?? .apiKey
            provider = (try? c.decode(AgentProvider.self, forKey: .provider)) ?? .anthropic
            anthropicModel = (try? c.decode(String.self, forKey: .anthropicModel)) ?? AgentProvider.anthropic.defaultModel.id
            openaiModel = (try? c.decode(String.self, forKey: .openaiModel)) ?? AgentProvider.openai.defaultModel.id
            level = (try? c.decode(AgentLevel.self, forKey: .level)) ?? .quick
            stepCap = (try? c.decodeIfPresent(Int.self, forKey: .stepCap)).flatMap { $0 > 0 ? $0 : nil }
            blockedSites = (try? c.decode([String].self, forKey: .blockedSites)) ?? []
            memory = (try? c.decode(Bool.self, forKey: .memory)) ?? false
            maxParallel = max(0, (try? c.decode(Int.self, forKey: .maxParallel)) ?? Values.defaultMaxParallel)
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
        hasKeyCache = nil
        #if AIRC_TESTING
        let args = CommandLine.arguments
        if let b = args.first(where: { $0.hasPrefix("--agent-model-base=") }) { baseOverride = String(b.dropFirst("--agent-model-base=".count)) }
        // agentparallel checks: the limit of tasks at once for this run only (not saved).
        if let n = ProcessInfo.processInfo.environment["AIRC_AGENT_MAX_PARALLEL"].flatMap(Int.init) { values.maxParallel = max(0, n) }
        if let k = args.first(where: { $0.hasPrefix("--agent-model-key=") }) {
            inMemory = true
            hasKeyCache = nil
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

    /// The Memory folder (in the data folder: ~/Library/Application Support/Airc/Memory).
    var memoryStore: AgentMemoryStore { AgentMemoryStore(folder: AppPaths.dataDirectory.appendingPathComponent("Memory", isDirectory: true)) }

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

    /// Whether the chosen provider has a key, cached (the Command Bar asks on every keystroke); refreshed on changes.
    var hasCurrentKey: Bool {
        // The person's own CLI: usable unless Airc already knows it's missing or logged out.
        if let k = values.backend.cli { return AgentCLIDetector.shared.status(k).map { $0.isReady || $0 == .checking } ?? true }
        if let c = hasKeyCache, c.provider == values.provider { return c.has }
        let has = hasKey(values.provider)
        hasKeyCache = (values.provider, has)
        return has
    }
    private var hasKeyCache: (provider: AgentProvider, has: Bool)?

    /// "…a1b2": what Settings shows of a saved key.
    func keyHint(_ p: AgentProvider) -> String? { key(p).map { "…" + $0.suffix(4) } }

    /// Saves (or, empty, removes) a key. False if the Keychain refused.
    @discardableResult
    func setKey(_ raw: String, for p: AgentProvider) -> Bool {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        hasKeyCache = nil
        defer { hasKeyCache = nil; NotificationCenter.default.post(name: Self.changed, object: self) }
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
    func setBackendForTesting(_ b: AgentBackend) { update { $0.backend = b } }

    func setTestKey(_ key: String?, provider: AgentProvider, base: String?) {
        inMemory = true
        memoryKeys[provider] = key
        hasKeyCache = nil
        baseOverride = base
        update { $0.provider = provider }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    #endif
}

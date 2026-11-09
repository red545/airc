// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import Combine
import AircKit

/// Ordinary profiles persist their own policy. Private-context overrides have
/// a separate owner and disappear with that context; they never enter this file.
final class BlockingSettings: ObservableObject {
    static private(set) var shared: BlockingSettings?
    @Published private(set) var profiles: [String: BlockingProfileConfiguration]
    @Published private(set) var error: String?
    private let file: URL
    private var coexistenceDismissed: Set<String>
    private struct Saved: Codable {
        var schema = 2
        var profiles: [String: BlockingProfileConfiguration]
        var coexistenceDismissed: Set<String> = []
    }
    var didChange: ((String) -> Void)?

    init(directory: URL, existingProfiles: [String]) {
        file = directory.appendingPathComponent("Blocking/settings.json")
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        let supported = saved.map { [1, 2].contains($0.schema) } ?? false
        profiles = supported ? saved!.profiles : [:]
        coexistenceDismissed = supported ? saved!.coexistenceDismissed : []
        // Migrate each saved profile once, preserving explicit choices. The
        // version is persisted before the engine reads its first policy.
        for id in Array(profiles.keys) { profiles[id]?.migrateDefault() }
        for id in existingProfiles where profiles[id] == nil {
            profiles[id] = BlockingProfileConfiguration()
        }
        Self.shared = self
        save()
    }

    func configuration(_ id: String) -> BlockingProfileConfiguration {
        if let value = profiles[id] { return value }
        let value = BlockingProfileConfiguration()
        profiles[id] = value; save()
        return value
    }
    func update(_ id: String, _ body: (inout BlockingProfileConfiguration) -> Void) {
        var value = configuration(id); body(&value)
        guard value != profiles[id] else { return }
        profiles[id] = value; save(); didChange?(id)
    }
    func setEnabled(_ value: Bool, profile id: String) {
        update(id) { $0.setEnabled(value) }
    }
    func setException(_ excepted: Bool, url: URL, profile id: String) {
        guard let host = BlockingProfileConfiguration.host(for: url) else { return }
        update(id) { if excepted { $0.exceptions.insert(host) } else { $0.exceptions.remove(host) } }
    }
    func removeException(_ host: String, profile id: String) {
        update(id) { $0.exceptions.remove(host) }
    }
    func shouldOfferCoexistence(profile id: String, extensionIDs: [String]) -> Bool {
        configuration(id).enabled && !extensionIDs.isEmpty &&
            !coexistenceDismissed.contains(coexistenceKey(id, extensionIDs))
    }
    func dismissCoexistence(profile id: String, extensionIDs: [String]) {
        coexistenceDismissed.insert(coexistenceKey(id, extensionIDs)); save()
        objectWillChange.send()
    }
    private func coexistenceKey(_ id: String, _ extensions: [String]) -> String {
        id + ":" + extensions.sorted().joined(separator: ",")
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Saved(profiles: profiles, coexistenceDismissed: coexistenceDismissed)).write(to: file, options: .atomic)
            error = nil
        } catch { self.error = "Your blocking settings couldn’t be saved." }
    }
}

/// One instance per private browsing context. An explicit true override can
/// turn blocking back on even if the ordinary profile bypasses that site.
final class PrivateBlockingPolicy {
    private var siteOverrides: [String: Bool] = [:]
    func enabled(for url: URL, regular: BlockingProfileConfiguration) -> Bool {
        guard regular.enabled, let host = BlockingProfileConfiguration.host(for: url) else { return false }
        return siteOverrides[host] ?? !regular.exceptions.contains(host)
    }
    func setEnabled(_ enabled: Bool, for url: URL) {
        guard let host = BlockingProfileConfiguration.host(for: url) else { return }
        siteOverrides[host] = enabled
    }
    func exceptions(regular: BlockingProfileConfiguration) -> Set<String> {
        var result = regular.exceptions
        for (host, enabled) in siteOverrides { if enabled { result.remove(host) } else { result.insert(host) } }
        return result
    }
}

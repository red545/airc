// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import Combine

/// Settings in iCloud sync (docs/sync.md, "Settings"): the app's side of AircKit's SyncSettingsSource. It turns the app's
/// settings into flat keys with canonical JSON values, the allowlisted ones only (`SyncSettings.synced`):
///
/// - settings.json (AppSettings.Values): "app.<key>"; Site Search and Ask AI per profile: "app.siteSearch@<profile>";
/// - Blocking (Blocking/settings.json): "blocking@<profile>" (on or off, third-party cookies, the lists, the exceptions);
/// - the store's per-profile choices: "profile.archiveAfter@…", "profile.searchEngine@…", "profile.searchSuggestions@…";
/// - the sidebar's side (window state): "window.sidebarOnRight".
///
/// It keeps a SyncSettingsLedger (Sync/settings-ledger.json, this Mac only) of what the person changed and when: only
/// those travel. Values from other Macs are applied as Settings would (shortcuts, the sidebar, blocking, the app icon
/// follow at once). Per-Mac settings (paths, Developer Mode, approvals, …) are never read here.
final class SettingsSync {
    private weak var app: AppDelegate?
    private let url: URL
    private var ledger: SyncSettingsLedger
    private var subscriptions: [AnyCancellable] = []
    private var observer: Int?
    /// The synced store fields as last seen (the sidebar's side, each profile's archive timing and search choices).
    private var storeSignature: [String] = []
    /// While applying another Mac's values: their changes aren't this Mac's.
    private var applying = false
    var changed: (() -> Void)?

    init(app: AppDelegate) {
        self.app = app
        url = AppPaths.dataDirectory.appendingPathComponent("Sync", isDirectory: true).appendingPathComponent("settings-ledger.json")
        ledger = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SyncSettingsLedger.self, from: $0) } ?? SyncSettingsLedger()
        observe()
        // Whether sync is on or not: a change made while it's off still counts from when it was made.
        subscriptions.append(app.settings.$values.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsDidChange() }
        })
        if let blocking = BlockingSettings.shared {
            subscriptions.append(blocking.$profiles.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.settingsDidChange() }
            })
        }
        storeSignature = Self.storeSignature(app.store)
        observer = app.store.observe { [weak self, weak app] change in
            // Cheap first: most store changes (tabs, window state) touch none of the synced store fields.
            guard let self, let store = app?.store, !change.contentOnly, change.windowStateChanged || change.touches(.profile) else { return }
            let signature = Self.storeSignature(store)
            guard signature != self.storeSignature else { return }
            self.storeSignature = signature
            self.settingsDidChange()
        }
    }

    deinit { if let observer { app?.store.removeObserver(observer) } }

    var source: SyncSettingsSource {
        SyncSettingsSource(explicit: { [weak self] in self?.explicit() ?? [:] },
                           apply: { [weak self] in self?.apply($0) ?? [] })
    }

    private func settingsDidChange() {
        guard !applying else { return }
        if observe() { changed?() }
    }

    /// Records what changed since the last look. Returns whether anything did.
    @discardableResult
    private func observe() -> Bool {
        guard let current = current() else { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard ledger.observe(current, defaults: Self.defaults(current), now: now) else { return false }
        save()
        return true
    }

    private func explicit() -> [String: SyncSettingEntry] {
        observe()
        return current().map { ledger.explicit($0) } ?? [:]
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ledger).write(to: url, options: .atomic)
    }

    // MARK: Reading

    private static func storeSignature(_ store: SpacesStore) -> [String] {
        [String(store.windowState.sidebarOnRight)] + store.orderedProfiles.map {
            "\($0.id)|\($0.archiveAfter.rawValue)|\($0.searchEngine.rawValue)|\(String(describing: $0.searchSuggestions))"
        }
    }

    /// Every synced setting's current value, by local key.
    func current() -> [String: String]? {
        guard let app, let store = app.store, let settings = app.settings else { return nil }
        let profiles = store.orderedProfiles
        var result = Self.flatten(settings.values, profiles: profiles.map(\.id))
        for p in profiles {
            result["profile.archiveAfter@" + p.id] = Self.json(p.archiveAfter)
            result["profile.searchEngine@" + p.id] = Self.json(p.searchEngine)
            result["profile.searchSuggestions@" + p.id] = Self.json(p.searchSuggestions)
            if let blocking = BlockingSettings.shared, let config = blocking.profiles[p.id] {
                result["blocking@" + p.id] = Self.json(BlockingValue(config))
            }
        }
        result["window.sidebarOnRight"] = Self.json(store.windowState.sidebarOnRight)
        return result.filter { SyncSettings.isSynced($0.key) }
    }

    /// The defaults of the keys in `current`.
    static func defaults(_ current: [String: String]) -> [String: String] {
        let profiles = Set(current.keys.compactMap { SyncSettings.parts($0).profile })
        var result = flatten(AppSettings.Values(), profiles: Array(profiles))
        let fresh = Profile(name: "")
        for p in profiles {
            result["profile.archiveAfter@" + p] = json(fresh.archiveAfter)
            result["profile.searchEngine@" + p] = json(fresh.searchEngine)
            result["profile.searchSuggestions@" + p] = json(fresh.searchSuggestions)
            var config = BlockingProfileConfiguration()
            config.migrateDefault()
            result["blocking@" + p] = json(BlockingValue(config))
        }
        result["window.sidebarOnRight"] = json(false)
        return result
    }

    /// settings.json's synced keys, and its per-profile ones for `profiles`.
    static func flatten(_ values: AppSettings.Values, profiles: [String]) -> [String: String] {
        guard let object = dictionary(values) else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            let k = "app." + key
            if SyncSettings.synced.contains(k) { result[k] = canonical(value) }
        }
        let searches = (object["siteSearch"] as? [String: Any])?["profiles"] as? [String: Any] ?? [:]
        let ask = (object["askAI"] as? [String: Any])?["profiles"] as? [String: Any] ?? [:]
        for p in profiles {
            result["app.siteSearch@" + p] = searches[p].map(canonical) ?? "null"
            result["app.askAI@" + p] = ask[p].map(canonical) ?? "null"
        }
        return result
    }

    // MARK: Applying

    /// Values from other Macs, by local key. Returns the keys applied; one that doesn't read keeps this Mac's value.
    private func apply(_ changes: [String: SyncSettingEntry]) -> Set<String> {
        guard let app, let store = app.store, let settings = app.settings else { return [] }
        applying = true
        defer { applying = false }
        var done = Set<String>()
        let profiles = Set(store.orderedProfiles.map(\.id))

        // settings.json: all at once, then each key checked (a value that doesn't decode would read as its default).
        let appKeys = changes.filter { $0.key.hasPrefix("app.") }
        if !appKeys.isEmpty, var object = Self.dictionary(settings.values) {
            var accepted: [String: String] = [:]
            for (key, entry) in appKeys {
                guard let value = Self.parse(entry.json) else { continue }
                let (base, profile) = SyncSettings.parts(key)
                let name = String(base.dropFirst("app.".count))
                if let profile {
                    guard profiles.contains(profile), name == "siteSearch" || name == "askAI" else { continue }
                    var outer = object[name] as? [String: Any] ?? [:]
                    var inner = outer["profiles"] as? [String: Any] ?? [:]
                    inner[profile] = value is NSNull ? nil : value
                    outer["profiles"] = inner
                    object[name] = outer
                } else {
                    object[name] = value
                }
                accepted[key] = entry.json
            }
            if let decoded = Self.decode(object) {
                let flat = Self.flatten(decoded, profiles: Array(profiles))
                // Only keys that read back as sent; the others keep this Mac's value.
                let good = accepted.filter { flat[$0.key] == $0.value }
                var values = settings.values
                let before = values
                if good.count == accepted.count { values = decoded } else if !good.isEmpty, var partial = Self.dictionary(values) {
                    let full = Self.dictionary(decoded) ?? [:]
                    for key in good.keys {
                        let name = String(SyncSettings.parts(key).base.dropFirst("app.".count))
                        partial[name] = full[name]
                    }
                    values = Self.decode(partial) ?? values
                }
                done.formUnion(good.keys)
                if values != before { applyApp(values, before: before, settings: settings) }
            }
        }

        for (key, entry) in changes {
            let (base, profile) = SyncSettings.parts(key)
            switch base {
            case "profile.archiveAfter", "profile.searchEngine", "profile.searchSuggestions":
                guard let profile, profiles.contains(profile) else { continue }
                do {
                    switch base {
                    case "profile.archiveAfter":
                        let v = try Self.decode(ArchiveInterval.self, entry.json)
                        try store.updateProfile(profile) { $0.archiveAfter = v }
                    case "profile.searchEngine":
                        let v = try Self.decode(SearchEngine.self, entry.json)
                        try store.updateProfile(profile) { $0.searchEngine = v }
                    default:
                        let v = try Self.decode(Bool?.self, entry.json)
                        try store.updateProfile(profile) { $0.searchSuggestions = v }
                    }
                    done.insert(key)
                } catch { continue }
            case "blocking":
                guard let profile, profiles.contains(profile), let blocking = BlockingSettings.shared,
                      let v = try? Self.decode(BlockingValue.self, entry.json) else { continue }
                blocking.update(profile) { v.apply(to: &$0) }
                done.insert(key)
            case "window.sidebarOnRight":
                guard let v = try? Self.decode(Bool.self, entry.json) else { continue }
                app.setSidebarOnRight(v)
                done.insert(key)
            default:
                continue
            }
        }
        // Taken from another Mac, with its time: not this Mac's change. Anything else that moved is.
        let now = current() ?? [:]
        for key in done { if let entry = changes[key] { ledger.adopt(key, SyncSettingEntry(json: now[key] ?? entry.json, changed: entry.changed)) } }
        ledger.observe(now, defaults: Self.defaults(now), now: Int64(Date().timeIntervalSince1970 * 1000))
        save()
        return done
    }

    /// New settings.json values from another Mac, with what Settings would do besides saving them.
    private func applyApp(_ values: AppSettings.Values, before: AppSettings.Values, settings: AppSettings) {
        guard let app else { return }
        settings.values = values
        if values.translucency != before.translucency { for c in app.controllers { c.applyTranslucency(values.translucency) } }
        if values.shortcuts != before.shortcuts {
            ShortcutCenter.shared.update { map in
                map = ShortcutMap(commands: map.commands, stored: values.shortcuts)
                return .done
            }
        }
        if values.sidebarNavigation != before.sidebarNavigation {
            ShortcutCenter.shared.setNavigation { $0 = values.sidebarNavigation }
        }
        if values.personalization.appIcon != before.personalization.appIcon { AppPersonalization.applyIcon(bundle: true) }
        // Little Airc follows settings.json by itself (LittleArcGlobalActions.install); the rest is read when used.
    }

    // MARK: JSON

    /// Blocking's synced part (never its migration bookkeeping or the coexistence notes).
    struct BlockingValue: Codable, Equatable {
        var enabled: Bool
        var thirdPartyCookies: Bool
        var lists: [String]
        var exceptions: [String]

        init(_ c: BlockingProfileConfiguration) {
            enabled = c.enabled; thirdPartyCookies = c.blockThirdPartyCookies
            lists = c.selectedLists.sorted(); exceptions = c.exceptions.sorted()
        }

        func apply(to c: inout BlockingProfileConfiguration) {
            if c.enabled != enabled { c.setEnabled(enabled) }
            c.blockThirdPartyCookies = thirdPartyCookies
            c.selectedLists = Set(lists)
            c.exceptions = Set(exceptions)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func json<T: Encodable>(_ value: T) -> String {
        (try? encoder.encode(value)).flatMap { parse(String(decoding: $0, as: UTF8.self)) }.map(canonical) ?? "null"
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    static func dictionary(_ values: AppSettings.Values) -> [String: Any]? {
        (try? encoder.encode(values)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func decode(_ object: [String: Any]) -> AppSettings.Values? {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? decoder.decode(AppSettings.Values.self, from: $0) }
    }

    static func parse(_ json: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) }

    /// One form for one value: sorted keys, no escaped slashes.
    static func canonical(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}

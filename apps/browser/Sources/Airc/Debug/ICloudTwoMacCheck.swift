// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
import CryptoKit

/// Manual real-iCloud qualification only. Commands and evidence contain synthetic data, never key bytes.
/// No SnapshotRunner timeout override: --script disables updates, without --snapshot starting that runner.
@MainActor final class ICloudTwoMacCheck {
    static let flag = "--sync-two-macs"
    static let service = "Airc sidebar sync test (two Macs)"
    static var requested: Bool { CommandLine.arguments.contains(flag) }
    static func argument(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static var enabled: Bool {
        requested && LaunchOptions.current.isScripted && LaunchOptions.current.isAutomated
        && AppPaths.dataDirectory.path.contains("/arcfork/work/synctest/data-")
        && argument("--sync-cloudkit-test-zone")?.hasPrefix("AircSidebarTest") == true
        && argument("--sync-test-deadline").flatMap(Double.init).map { $0 > Date().timeIntervalSince1970 && $0 < Date().timeIntervalSince1970 + 1800 } == true
    }
    static var root: URL { AppPaths.dataDirectory.appendingPathComponent("synctest") }
    static var instance: ICloudTwoMacCheck?
    static func event(_ name: String, _ values: [String: Any] = [:]) {
        guard requested else { return }
        var data = values; data["event"] = name; data["time"] = Date().timeIntervalSince1970
        guard var bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return }
        bytes.append(10)
        let url = root.appendingPathComponent("events.jsonl")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) { try? h.seekToEnd(); try? h.write(contentsOf: bytes); try? h.close() }
    }
    static func start(app: AppDelegate) {
        guard enabled else { return }
        let check = ICloudTwoMacCheck(app: app); instance = check
        Task { await check.loop() }
    }
    let app: AppDelegate
    var sync: SyncCenter { .shared }
    var store: SpacesStore { app.store }
    var quitting = false
    var lastCommand = ""
    var previousState = Data()
    init(app: AppDelegate) { self.app = app }
    func write(_ name: String, _ object: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try bytes.write(to: Self.root.appendingPathComponent(name), options: .atomic)
    }
    func state() -> [String: Any] {
        var status = "other"
        switch sync.status {
        case .off: status = "off"
        case .upToDate: status = "upToDate"
        case .waitingForKeychain: status = "waitingForKeychain"
        case .choosing: status = "choosing"
        default: status = String(describing: sync.status)
        }
        return ["launch": Self.argument("--sync-test-launch") ?? "", "status": status, "enabled": sync.isEnabled, "pushEntitlement": SyncCapability.receivesPushes,
                "group": sync.engine?.groupID?.uuidString ?? "",
                "lastSynced": sync.lastSynced?.timeIntervalSince1970 ?? 0,
                "backup": sync.lastBackup.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                "firstSyncSpaces": sync.firstSync?.iCloud.spaces ?? [],
                "firstSyncSheet": app.settingsWindow?.window.attachedSheet != nil,
                "spaces": store.orderedSpaces.map { ["id": $0.id, "name": $0.name] },
                "items": store.state.items.values.sorted { $0.id < $1.id }.map {
                    ["id": $0.id, "title": $0.title ?? "", "url": $0.savedURL ?? "", "parent": $0.parentID ?? "", "space": $0.spaceID ?? ""]
                }]
    }
    func loop() async {
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            try write("pid.json", ["pid": ProcessInfo.processInfo.processIdentifier])
            Self.event("started", ["pushEntitlement": SyncCapability.receivesPushes])
            let deadline = Double(Self.argument("--sync-test-deadline")!)!
            while !quitting && Date().timeIntervalSince1970 < deadline {
                let s = state(), bytes = try JSONSerialization.data(withJSONObject: s, options: [.sortedKeys])
                if bytes != previousState { Self.event("state", s); previousState = bytes }
                try write("state.json", s.merging(["time": Date().timeIntervalSince1970]) { _, new in new })
                let requestURL = Self.root.appendingPathComponent("command.json")
                if let bytes = try? Data(contentsOf: requestURL),
                   let request = try JSONSerialization.jsonObject(with: bytes) as? [String: String],
                   let id = request["id"], id != lastCommand {
                    lastCommand = id
                    do {
                        let result = try await command(request)
                        try write("response.json", result.merging(["id": id, "ok": true]) { _, new in new })
                    } catch {
                        Self.event("command-failed", ["command": request["command"] ?? "", "error": String(describing: error)])
                        try write("response.json", ["id": id, "ok": false, "error": String(describing: error)])
                    }
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        } catch { Self.event("harness-failed", ["error": String(describing: error)]) }
        // A lost SSH session must not leave the test running. This stops scheduling but retains the test key for cleanup.
        sync.setEnabled(false)
        Self.event("quit")
        for w in NSApp.windows { if let sheet = w.attachedSheet { w.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
    func space(_ name: String) throws -> Space {
        guard let s = store.orderedSpaces.first(where: { $0.name == name }) else { throw StoreError.notFound }; return s
    }
    func item(_ title: String) throws -> Item {
        guard let i = store.state.items.values.first(where: { $0.title == title }) else { throw StoreError.notFound }; return i
    }
    func pin(_ title: String, space: Space) throws {
        let url = "https://example.com/synctest/" + title.lowercased().replacingOccurrences(of: " ", with: "-")
        let t = try store.openTab(url: url, inSpace: space.id, activate: false, title: title)
        try store.move(.tab(t.id), to: .pinned(spaceID: space.id, parentID: nil, index: 0))
        guard let id = store.tab(t.id)?.itemID else { throw StoreError.notFound }
        try store.replaceSavedURL(ofItem: id, with: url, title: title)
        // Page titles and custom names are separate fields; the harness addresses these synthetic custom names.
        try store.renameItem(id, to: title)
        try store.closeTab(t.id)
    }
    func command(_ r: [String: String]) async throws -> [String: Any] {
        let name = r["command"] ?? ""
        Self.event("command", ["command": name])
        switch name {
        case "seed":
            // Equal names with independent IDs intentionally exercise Merge's documented duplicate behavior.
            let s = try store.createSpace(name: "Sync Test Shared", icon: .emoji("🧪"))
            try pin(r["role"] == "A" ? "Seed A" : "Seed B", space: s)
            if r["role"] == "A" { try pin("Delete Target", space: s); _ = try store.createSpace(name: "Conflict Target") }
        case "enable": sync.setEnabled(true)
        case "disable": sync.setEnabled(false)
        case "merge", "replace":
            guard sync.firstSync != nil else { throw StoreError.notFound }
            if let view = app.settingsWindow?.window.attachedSheet?.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: Self.root.appendingPathComponent("first-sync-" + name + ".png"))
                }
            }
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                sync.choose(name == "merge" ? .merge : .replace, profiles: [:]) { error in
                    if let error { done.resume(throwing: error) } else { done.resume() }
                }
            }
        case "edit":
            let role = r["role"] ?? "A"
            let s: Space
            if r["space"] == "Sync Test Shared", let id = try item("Seed A").spaceID, let found = store.space(id) { s = found }
            else { s = try space(r["space"] ?? "Sync Test Shared") }
            try store.updateSpace(s.id) { $0.name = "Sync Test " + role }
            try pin("Pin " + role, space: s)
            let folder = try store.createFolder(named: "Folder " + role, inSpace: s.id)
            try store.move(.item(try item("Pin " + role).id), to: .pinned(spaceID: s.id, parentID: folder.id, index: 0))
            try store.deleteItem(try item(r["delete"] ?? "Delete Target").id)
        case "offline":
            try Data().write(to: Self.root.appendingPathComponent("offline"))
        case "online":
            try FileManager.default.removeItem(at: Self.root.appendingPathComponent("offline"))
            sync.syncNow()
        case "rename-conflict":
            let s = try space("Conflict Target"); try store.updateSpace(s.id) { $0.name = r["value"] ?? "Conflict B" }
        case "delete-conflict": try store.deleteSpace(try space("Conflict Target").id)
        case "sync":
            if let engine = sync.engine { await engine.syncNow() }
        case "cleanup", "verify-cleanup":
            sync.setEnabled(false)
            guard let zone = sync.cloudTestZone, zone.hasPrefix("AircSidebarTest"),
                  let container = SyncCapability.container,
                  let keys = sync.keyStore else { throw StoreError.notFound }
            let groupText = r["group"] ?? ""
            let group = UUID(uuidString: groupText)
            guard groupText.isEmpty || group != nil else { throw StoreError.notFound }
            let known = (try? Data(contentsOf: Self.root.appendingPathComponent("groups.json")))
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            guard group != nil || known.isEmpty else { throw StoreError.notFound }
            let db = CloudKitSyncDatabase(container: container)
            if name == "cleanup" {
                if let group { try keys.removeUnused(group: group) }
                try await db.deleteTestZone(zone, subscription: SyncCenter.testSubscription)
            }
            // A Keychain access error must never be mistaken for absence.
            let keyGone = try group.map { try keys.key(group: $0) == nil } ?? true
            var zoneGone = false
            do { _ = try await db.fetchChanges(zone: zone, since: nil) }
            catch SyncCloudFailure.zoneNotFound { zoneGone = true }
            let subscriptionGone = !(try await db.hasSubscription(SyncCenter.testSubscription))
            let result = ["keyGone": keyGone, "zoneGone": zoneGone, "subscriptionGone": subscriptionGone]
            let receipt = AppPaths.dataDirectory.deletingLastPathComponent().appendingPathComponent("cleanup.json")
            var receipts = (try? Data(contentsOf: receipt)).flatMap { try? JSONDecoder().decode([String: [String: Bool]].self, from: $0) } ?? [:]
            receipts[zone + ":" + groupText] = result
            try JSONEncoder().encode(receipts).write(to: receipt, options: .atomic)
            return result
        case "quit": quitting = true
        default: throw StoreError.notFound
        }
        return ["at": Date().timeIntervalSince1970]
    }
}

/// Offline injection is limited to this test app's CloudKit transport, never the Mac's networking or SSH.
final class ICloudTwoMacDatabase: SyncCloudDatabase, @unchecked Sendable {
    let base: CloudKitSyncDatabase
    let offline: URL
    init(_ base: CloudKitSyncDatabase, root: URL) { self.base = base; offline = root.appendingPathComponent("offline") }
    func check() throws { if FileManager.default.fileExists(atPath: offline.path) { throw SyncCloudFailure.network(retryAfter: nil) } }
    func accountStatus() async throws -> SyncCloudAccount { try check(); return try await base.accountStatus() }
    func accountIdentity() async throws -> String { try check(); return try await base.accountIdentity() }
    func createZone(_ zone: String) async throws { try check(); try await base.createZone(zone) }
    func fetchChanges(zone: String, since token: Data?) async throws -> SyncCloudChanges { try check(); return try await base.fetchChanges(zone: zone, since: token) }
    func save(_ records: [SyncCloudRecord], zone: String, mode: SyncSaveMode) async throws -> [String: Result<SyncCloudRecord, SyncCloudFailure>] { try check(); return try await base.save(records, zone: zone, mode: mode) }
    func fetch(_ names: [String], zone: String) async throws -> [SyncCloudRecord] { try check(); return try await base.fetch(names, zone: zone) }
    func subscribe(zone: String, id: String) async throws { try check(); try await base.subscribe(zone: zone, id: id) }
}
/// Logs lookup time and result only; no key material or account identity leaves the Keychain.
final class ICloudTwoMacKeys: SyncKeyStore, @unchecked Sendable {
    let base: KeychainSyncKeyStore
    let root: URL
    let lock = NSLock()
    init(accessGroup: String?, service: String, root: URL) {
        self.root = root
        base = KeychainSyncKeyStore(accessGroup: accessGroup, service: service, synchronizable: true, accessibility: .whenUnlocked)
    }
    func record(_ event: String, group: UUID) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // A durable list permits cleanup even if creating the CloudKit group fails after creating its key.
            var groups = (try? Data(contentsOf: root.appendingPathComponent("groups.json")))
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            if !groups.contains(group.uuidString) { groups.append(group.uuidString) }
            try JSONEncoder().encode(groups).write(to: root.appendingPathComponent("groups.json"), options: .atomic)
            let url = root.appendingPathComponent("key-events.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
            try h.seekToEnd()
            var bytes = try JSONSerialization.data(withJSONObject: ["event": event, "group": group.uuidString, "time": Date().timeIntervalSince1970])
            bytes.append(10); try h.write(contentsOf: bytes)
        }
    }
    func key(group: UUID) throws -> SymmetricKey? {
        let key = try base.key(group: group)
        try record(key == nil ? "key.missing" : "key.found", group: group)
        return key
    }
    func add(_ key: SymmetricKey, group: UUID) throws {
        try record("key.will-add", group: group)
        try base.add(key, group: group)
        try record("key.added", group: group)
    }
    func removeUnused(group: UUID) throws { try base.removeUnused(group: group); try record("key.removed", group: group) }
}
#endif

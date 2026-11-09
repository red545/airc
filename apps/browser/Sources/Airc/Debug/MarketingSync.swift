// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `AIRC_MARKETING_PART=sync` (scripts/marketing-shots.sh): iCloud sync on the demo sidebar, through a mock CloudKit
/// database in the run's own folder (`--sync-mock`, `--sync-keychain`): never the real iCloud or Keychain. "Another
/// Mac" is a synthetic sidebar, sealed with a key put in this run's fake keychain, as iCloud Keychain would.
/// Shots: the first-sync screen (both sidebars, the Work profile matched to this Mac's), then Settings → Sync up to date
/// with both Macs.
extension SnapshotRunner {
    func mkSyncShots(_ d: MarketingDemo) {
        let sync = SyncCenter.shared
        let args = ProcessInfo.processInfo.arguments
        func folder(_ name: String) -> URL? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil }
        }
        run { [self] in
            guard let mock = folder("--sync-mock"), let keychain = folder("--sync-keychain") else {
                return note("marketing: MISSING settings-sync: no --sync-mock and --sync-keychain")
            }
            do { try mkSeedOtherMac(database: SyncFolderCloudDatabase(folder: mock), keys: FolderSyncKeyStore(folder: keychain)) }
            catch { note("marketing: MISSING settings-sync: seeding the other Mac failed: \(error)") }
            mkShow(d, "personal", "apple")
            c.app?.showSettings(page: .sync)
            if let w = c.app?.settingsWindow?.window { w.setFrameOrigin(NSPoint(x: -6000, y: 200)) }
            sync.setEnabled(true)
        }
        step { [self] done in
            waitUntil({ sync.firstSync != nil && self.c.app?.settingsWindow?.window.attachedSheet != nil }, timeout: 20) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                    defer { done() }
                    guard let w = c.app?.settingsWindow?.window, let sheet = w.attachedSheet, let view = w.contentView,
                          let img = mkContentImage(w), let card = mkContentImage(sheet) else {
                        return note("marketing: MISSING settings-sync-first: no first-sync screen (\(sync.status))")
                    }
                    let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
                    let frame = NSRect(origin: origin, size: view.bounds.size)
                    let sf = sheet.frame, wf = w.frame
                    mkWrite("settings-sync-first", canvas: canvas, dark: false, [
                        MarketingStudio.Layer(image: img, frame: frame, lights: mkLights(w)),
                        MarketingStudio.Layer(image: card, frame: NSRect(x: frame.minX + sf.minX - wf.minX, y: frame.minY + sf.minY - wf.minY,
                                                                         width: sf.width, height: sf.height), radius: 16, shadow: .panel),
                    ])
                }
            }
        }
        run {
            let work = sync.firstSync?.profiles.first { $0.suggestion != nil }
            sync.choose(.merge, profiles: work.flatMap { p in p.suggestion.map { [p.id: .use($0)] } } ?? [:])
        }
        step { [self] done in
            waitUntil({ sync.status == .upToDate && sync.devices.count == 2 }, timeout: 20) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                    defer { done() }
                    guard let w = c.app?.settingsWindow?.window, let view = w.contentView, let img = mkContentImage(w),
                          sync.devices.count == 2 else {
                        return note("marketing: MISSING settings-sync: not up to date with two Macs (\(sync.status))")
                    }
                    let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
                    mkWrite("settings-sync", canvas: canvas, dark: false, [
                        MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: view.bounds.size), lights: mkLights(w)),
                    ])
                }
            }
        }
        run { [self] in c.app?.settingsWindow?.window.orderOut(nil) }
        wait(0.3)
    }

    /// Another Mac's sidebar in the mock database: its group, its device record and one sealed batch.
    private func mkSeedOtherMac(database: SyncFolderCloudDatabase, keys: FolderSyncKeyStore) throws {
        var other = SyncReplica()
        let device = other.clock.device, group = UUID(), key = SyncEnvelope.newGroupKey()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let personal = UUID().uuidString.lowercased(), work = UUID().uuidString.lowercased()
        try other.edit(.init(.profile, personal), [.name: .text("Personal"), .kind: .text("default")], now: now)
        try other.edit(.init(.profile, work), [.name: .text("Work"), .icon: .text("💼"), .kind: .text("profile")], now: now)
        var order: SyncOrder?
        for (name, icon, theme, profile, pins) in [
            ("Home", "🏡", "mint", personal, ["https://www.apple.com/", "https://en.wikipedia.org/wiki/Lisbon"]),
            ("Work", "💼", "grape", work, ["https://linear.app/", "https://github.com/"]),
            ("Reading", "📚", "lemon", personal, ["https://news.ycombinator.com/"]),
        ] {
            let space = UUID().uuidString.lowercased()
            order = try SyncOrder.between(order, nil)
            try other.edit(.init(.space, space), [.name: .text(name), .icon: .icon(.emoji(icon)),
                                                 .theme: .theme(DesignTheme.preset(theme)?.model ?? .neutral),
                                                 .profile: .text(profile), .order: .order(order!), .deleted: .flag(false)], now: now)
            var row: SyncOrder?
            for url in pins {
                row = try SyncOrder.between(row, nil)
                try other.edit(.init(.row, "item:" + UUID().uuidString.lowercased()), [
                    .kind: .text("tab"), .location: .location(.pinned(space: space)), .url: .text(url), .order: .order(row!),
                    .deleted: .flag(false)], now: now)
            }
        }
        let envelope = try SyncEnvelope.seal(other.log, group: group, device: device, key: key)
        let name = try SyncEngine.sealDeviceName("MacBook Air", group: group, device: device, key: key)
        try keys.add(key, group: group)
        try database.withState { state in
            try state.seed([SyncCloudSchema.record(try SyncGroupRecord.make(group: group, key: key, created: Date())),
                            SyncCloudSchema.record(envelope),
                            SyncCloudSchema.record(SyncDeviceRecord(group: group, device: device, sealed: name, seen: Date(timeIntervalSinceNow: -3600)))],
                           zone: SyncCloudSchema.zone)
        }
    }
}
#endif

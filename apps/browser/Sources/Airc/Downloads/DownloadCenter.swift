// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import Combine
import UniformTypeIdentifiers

/// Every profile's downloads, from the engine's download service (engine/PASS13.md): the sidebar's progress row
/// (SB-54), the Library's Downloads list (SB-62), the risky-file question and the question before a close or quit
/// would cancel downloads. One per app (MediaLibrary). Rows arrive as the engine sends them and go out to the views at
/// most ten times a second; nothing runs while no download moves.
final class DownloadCenter: ObservableObject {
    struct Item: Identifiable, Equatable {
        let profileID: String
        var download: EngineDownload
        /// Bytes per second, smoothed; nil until the bytes have moved twice.
        var speed: Double?
        var id: String { profileID + "/" + download.id }
    }

    /// Newest first.
    @Published private(set) var items: [Item] = []
    /// What the sidebar shows: running, paused and risky downloads, and ones that finished a moment ago.
    @Published private(set) var sidebarItems: [Item] = []
    /// The risky download being asked about (one at a time, oldest first).
    @Published private(set) var dangerous: Item? {
        didSet { if dangerous?.id != oldValue?.id { library?.downloadPromptChanged() } }
    }

    let engine: EngineDownloads
    weak var library: MediaLibrary?
    private var byKey: [String: Item] = [:]
    private var lastSample: [String: (at: CFTimeInterval, bytes: Int64)] = [:]
    private var finishedAt: [String: Date] = [:]
    /// Retries that started a new download: its row replaces the old one.
    private var retries: [(profileID: String, url: String, oldID: String, at: Date)] = []
    private var observed: Set<String> = []
    private var publishQueued = false
    private var dangerQueue: [String] = []
    /// A finished download stays in the sidebar this long (it can be dragged out or opened from there).
    static var finishedLinger: TimeInterval = 6
    /// Scripted runs record these instead of opening apps or Finder on the build Mac.
    static var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    static var interceptOpen: ((Item) -> Bool)?

    init(engine: EngineDownloads) {
        self.engine = engine
    }

    // MARK: Engine

    /// Starts listening to a loaded profile (once).
    func attach(_ profile: EngineProfile, profileID: String) {
        guard !observed.contains(profileID) else { return }
        observed.insert(profileID)
        for d in engine.downloadItems(in: profile) { update(d, profileID: profileID) }
        engine.observeDownloadItems(in: profile) { [weak self] d in self?.update(d, profileID: profileID) }
    }

    func detachAll(_ profiles: [(EngineProfile, String)]) {
        for (p, id) in profiles where observed.contains(id) { engine.observeDownloadItems(in: p, nil) }
        observed.removeAll()
    }

    private func update(_ d: EngineDownload, profileID: String) {
        let key = profileID + "/" + d.id
        if d.removed {
            byKey[key] = nil
            lastSample[key] = nil
            finishedAt[key] = nil
            dangerQueue.removeAll { $0 == key }
            if dangerous?.id == key { dangerous = nil; nextDanger() }
            return publishSoon()
        }
        let old = byKey[key]
        // A new one (not a row of the history the observer replays).
        if old == nil, d.state == .inProgress { Telemetry.shared.record(.featureUsed(.downloadStarted)) }
        var item = old ?? Item(profileID: profileID, download: d)
        item.download = d
        let now = CACurrentMediaTime()
        if d.state == .inProgress, !d.paused, let s = lastSample[key], d.received > s.bytes, now - s.at > 0.05 {
            let instant = Double(d.received - s.bytes) / (now - s.at)
            item.speed = item.speed.map { 0.75 * $0 + 0.25 * instant } ?? instant
            lastSample[key] = (now, d.received)
        } else if lastSample[key] == nil || d.paused || d.state != .inProgress {
            lastSample[key] = (now, d.received)
            if d.paused || d.state != .inProgress { item.speed = nil }
        }
        if d.state == .complete, old.map({ $0.download.state != .complete }) ?? false {
            Telemetry.shared.record(.featureUsed(.downloadCompleted))
            finishedAt[key] = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishedLinger + 0.05) { [weak self] in self?.publishSoon() }
        }
        byKey[key] = item
        if old == nil, let i = retries.firstIndex(where: { $0.profileID == profileID && $0.url == d.url && $0.oldID != d.id }) {
            let r = retries.remove(at: i)
            if let p = profile(profileID) { engine.performDownloadAction(.remove, id: r.oldID, in: p) }
        }
        retries.removeAll { Date().timeIntervalSince($0.at) > 15 }
        if d.dangerous, d.state == .inProgress {
            if !dangerQueue.contains(key), dangerous?.id != key { dangerQueue.append(key) }
            if dangerous == nil { nextDanger() } else if dangerous?.id == key { dangerous = item }
        } else if dangerous?.id == key {
            dangerous = nil
            nextDanger()
        }
        publishSoon()
    }

    private func nextDanger() {
        while let k = dangerQueue.first {
            dangerQueue.removeFirst()
            if let i = byKey[k], i.download.dangerous, i.download.state == .inProgress {
                dangerous = i
                return
            }
        }
    }

    private func publishSoon() {
        guard !publishQueued else { return }
        publishQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.publishQueued = false
            self.publish()
        }
    }

    /// Now (the scripted checks and the first rows).
    func publish() {
        let all = byKey.values.sorted { a, b in
            let x = a.download.startTime ?? .distantPast, y = b.download.startTime ?? .distantPast
            return x != y ? x > y : a.id > b.id
        }
        if all != items { items = all }
        let cutoff = Date().addingTimeInterval(-Self.finishedLinger)
        let side = all.filter { $0.download.state == .inProgress || (finishedAt[$0.id].map { $0 > cutoff } ?? false) }
        if side != sidebarItems {
            sidebarItems = side
            library?.trayContentChanged()
        }
    }

    func item(_ key: String) -> Item? { byKey[key] }

    private func profile(_ id: String) -> EngineProfile? { library?.controller?.profiles.engineProfile(for: id) }

    // MARK: Actions

    @discardableResult
    func perform(_ action: EngineDownloadAction, _ item: Item) -> Bool {
        guard let p = profile(item.profileID) else { return false }
        if action == .retry { retries.append((item.profileID, item.download.url, item.download.id, Date())) }
        let ok = engine.performDownloadAction(action, id: item.download.id, in: p)
        if !ok, action == .retry { retries.removeAll { $0.oldID == item.download.id } }
        return ok
    }

    /// A finished file opens in its app; a running one opens when it's done (toggled).
    func open(_ item: Item) {
        if item.download.state == .complete, let intercept = Self.interceptOpen, intercept(item) { return }
        perform(.open, item)
    }

    func file(_ item: Item) -> URL? {
        guard item.download.state == .complete, !item.download.dangerous, let p = profile(item.profileID) else { return nil }
        return engine.downloadedFile(item.download.id, in: p)
    }

    func showInFinder(_ item: Item) {
        if let url = file(item) {
            Self.reveal([url])
        } else if let path = item.download.path {
            // A file that's gone (moved or deleted): its folder.
            Self.reveal([URL(fileURLWithPath: path).deletingLastPathComponent()])
        }
    }

    func copyLink(_ item: Item) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.download.url, forType: .string)
    }

    /// Keep (after the person confirmed it) or discard the risky download being asked about.
    func answerDanger(keep: Bool) {
        guard let d = dangerous else { return }
        if keep, d.download.canKeep { perform(.keep, d) } else if !keep { perform(.discard, d) }
        dangerous = nil
        nextDanger()
    }

    /// Later: the question goes, the download keeps waiting (the sidebar row and the Library still offer it).
    func dismissDanger() {
        dangerous = nil
    }

    func askAgain(_ item: Item) {
        guard item.download.dangerous, item.download.state == .inProgress else { return }
        dangerous = byKey[item.id]
    }

    var runningCount: Int { byKey.values.filter { $0.download.state == .inProgress && !$0.download.dangerous }.count }

    // MARK: Text

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "12 of 45 MB · 2 min left", "Paused · 12 of 45 MB", "45 MB · example.com", "Failed · Network error".
    static func status(_ i: Item, host: Bool = true) -> String {
        let d = i.download
        let site = URLRules.displayHost(d.url)
        switch d.state {
        case .inProgress where d.dangerous:
            return "May be harmful" + (host && !site.isEmpty ? " · " + site : "")
        case .inProgress:
            var progress = d.total.map { progressText(d.received, of: $0) } ?? size(d.received)
            if d.paused { return "Paused · " + progress }
            if let total = d.total, let speed = i.speed, speed > 1 {
                progress += " · " + timeLeft(Double(total - d.received) / speed)
            }
            return progress
        case .complete:
            let s = size(d.total ?? d.received)
            return host && !site.isEmpty ? s + " · " + site : s
        case .cancelled:
            return "Cancelled" + (host && !site.isEmpty ? " · " + site : "")
        case .interrupted:
            return "Failed · " + interruption(d.interruptReason)
        }
    }

    /// "12 of 45 MB" (one unit when they share it), "800 KB of 1.2 GB".
    static func progressText(_ received: Int64, of total: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        let t = f.string(fromByteCount: total)
        f.includesUnit = false
        let r = f.string(fromByteCount: received)
        f.includesUnit = true
        let unit = { (s: String) in s.split(separator: " ").last.map(String.init) ?? "" }
        if unit(f.string(fromByteCount: received)) == unit(t) { return "\(r) of \(t)" }
        return "\(f.string(fromByteCount: received)) of \(t)"
    }

    static func timeLeft(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 5 { return "almost done" }
        if seconds < 60 { return "\(Int((seconds / 5).rounded(.up)) * 5) s left" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded(.up))) min left" }
        let h = Int(seconds / 3600), m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        return m > 0 ? "\(h) h \(m) min left" : "\(h) h left"
    }

    /// Chromium's interrupt reasons, in words.
    static func interruption(_ reason: Int) -> String {
        switch reason {
        case 3: "Disk full"
        case 2: "No permission to save"
        case 5: "Name too long"
        case 7, 11, 12: "Blocked"
        case 20...24: "Network error"
        case 34, 36: "Not allowed by the site"
        case 30...39: "Server problem"
        case 41: "Airc quit before it finished"
        default: "Couldn't finish"
        }
    }

    /// Chromium's danger types, in words (Chrome's own copy).
    static func dangerText(_ d: EngineDownload) -> String {
        switch d.dangerType {
        case 2, 3, 7: "This file is dangerous, so Airc has blocked it."
        case 5: "This file isn't commonly downloaded and may be dangerous."
        case 8: "This file may make unexpected changes to your Mac."
        default: "Files like this can harm your Mac. Keep it only if you trust where it came from."
        }
    }

    /// The file's icon: the file itself once it's there, else its type's.
    static func icon(_ d: EngineDownload) -> NSImage {
        if d.state == .complete, let p = d.path, FileManager.default.fileExists(atPath: p) {
            return NSWorkspace.shared.icon(forFile: p)
        }
        let ext = (d.fileName as NSString).pathExtension
        if let hit = typeIcons[ext] { return hit }
        let img = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        typeIcons[ext] = img
        return img
    }
    private static var typeIcons: [String: NSImage] = [:]
}

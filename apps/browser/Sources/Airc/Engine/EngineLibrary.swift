// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

// Downloads, media sessions and the call window's page hosting (engine/PASS13.md). An engine that has them adopts
// these protocols in its own file (ChromiumEngine+Library.swift, WebKitEngine+Library.swift); the app asks
// `engine as? EngineDownloads` and shows nothing for an engine without them. All of it is main-thread only.

/// One download, running or from the profile's history (PASS13 "Downloads").
struct EngineDownload: Identifiable, Equatable {
    enum State: Int { case inProgress = 0, complete = 1, cancelled = 2, interrupted = 3 }

    /// The engine's GUID; a retry that can't resume starts a new download with a new one.
    let id: String
    var url: String
    /// Where the file is (or will be); nil while the engine doesn't know yet.
    var path: String?
    var fileName: String
    var mimeType: String?
    var received: Int64
    /// nil when the server didn't say.
    var total: Int64?
    var state: State
    var paused: Bool
    /// Waiting for Keep or Discard (never kept without the person saying so).
    var dangerous: Bool
    var canKeep: Bool
    var canResume: Bool
    var openWhenComplete: Bool
    var startTime: Date?
    var endTime: Date?
    var referrer: String?
    /// Chromium's interrupt reason (0 none); the dev engine uses 1 for "failed".
    var interruptReason: Int
    var dangerType: Int
    /// The last row of a download taken off the list.
    var removed: Bool

    init(id: String, url: String, path: String?, fileName: String, mimeType: String? = nil, received: Int64, total: Int64?,
         state: State, paused: Bool = false, dangerous: Bool = false, canKeep: Bool = false, canResume: Bool = false,
         openWhenComplete: Bool = false, startTime: Date? = nil, endTime: Date? = nil, referrer: String? = nil,
         interruptReason: Int = 0, dangerType: Int = 0, removed: Bool = false) {
        self.id = id
        self.url = url
        self.path = path
        self.fileName = fileName
        self.mimeType = mimeType
        self.received = received
        self.total = total
        self.state = state
        self.paused = paused
        self.dangerous = dangerous
        self.canKeep = canKeep
        self.canResume = canResume
        self.openWhenComplete = openWhenComplete
        self.startTime = startTime
        self.endTime = endTime
        self.referrer = referrer
        self.interruptReason = interruptReason
        self.dangerType = dangerType
        self.removed = removed
    }

    /// The engine's dictionary (PASS13 keys). Unknown totals and paths are allowed; a row without an id is not.
    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        func int(_ k: String) -> Int64 { (d[k] as? NSNumber)?.int64Value ?? 0 }
        func flag(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }
        func date(_ k: String) -> Date? {
            let s = (d[k] as? NSNumber)?.doubleValue ?? 0
            return s > 0 ? Date(timeIntervalSince1970: s) : nil
        }
        let path = (d["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let url = d["url"] as? String ?? ""
        var name = d["fileName"] as? String ?? ""
        if name.isEmpty { name = path.map { ($0 as NSString).lastPathComponent } ?? "" }
        if name.isEmpty { name = URL(string: url)?.lastPathComponent ?? "" }
        if name.isEmpty || name == "/" { name = URLRules.displayHost(url) }
        let total = int("total")
        self.init(id: id, url: url, path: path, fileName: name, mimeType: (d["mimeType"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  received: max(0, int("received")), total: total > 0 ? total : nil,
                  state: State(rawValue: Int(int("state"))) ?? .inProgress, paused: flag("paused"), dangerous: flag("dangerous"),
                  canKeep: flag("canKeep"), canResume: flag("canResume"), openWhenComplete: flag("openWhenComplete"),
                  startTime: date("startTime"), endTime: date("endTime"),
                  referrer: (d["referrer"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  interruptReason: Int(int("interruptReason")), dangerType: Int(int("dangerType")), removed: flag("removed"))
    }

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }
    /// Still going (or paused), or stopped for a Keep / Discard answer.
    var isActive: Bool { state == .inProgress }
}

enum EngineDownloadAction: String, CaseIterable {
    case pause, resume, cancel, retry, remove, keep, discard, open
}

protocol EngineDownloads: AnyObject {
    /// False on a framework without the downloads service (the app then shows no downloads at all).
    var downloadsAvailable: Bool { get }
    /// The profile's downloads, history included (it may still be loading: the observer brings the rest).
    func downloadItems(in profile: EngineProfile) -> [EngineDownload]
    /// The rows there are now, then each change; a download taken off the list comes once more with `removed`. One
    /// observer per profile (a new one replaces the old and gets the rows again); nil stops.
    func observeDownloadItems(in profile: EngineProfile, _ handler: ((EngineDownload) -> Void)?)
    /// Whether the engine took the action (not that its disk or network work has finished). `keep` only after the
    /// person confirmed it; `open` is refused while a download is dangerous and toggles "open when done" while it runs.
    @discardableResult func performDownloadAction(_ action: EngineDownloadAction, id: String, in profile: EngineProfile) -> Bool
    /// A finished, safe download's file (Show in Finder, drag out).
    func downloadedFile(_ id: String, in profile: EngineProfile) -> URL?
    /// The engine asks (through `downloadsCloseConfirmation`) before a close or quit cancels downloads; otherwise the
    /// app asks before its window closes.
    var asksBeforeClosingWithDownloads: Bool { get }
    /// Asked before a window closes or the app quits with downloads that would be cancelled (Chromium's
    /// confirmCloseWithDownloads): the count, and the answer (true: close anyway). Without one the close goes ahead.
    var downloadsCloseConfirmation: ((Int, @escaping (Bool) -> Void) -> Void)? { get set }
}

/// A tab's Media Session (PASS13 "Media"): what plays, what the page lets us do, and what it captures.
struct EngineMediaSession: Equatable {
    enum Playback: String { case playing, paused, none }
    struct Capture: Equatable {
        var microphone = false
        var camera = false
        var screen = false
        var tab = false
    }

    var playback: Playback = .none
    var active = false
    var title = ""
    var artist = ""
    var album = ""
    /// Artwork URLs, best first.
    var artwork: [String] = []
    var duration: Double?
    var position: Double?
    var rate: Double = 1
    /// The Media Session actions the page handles (play, pause, nexttrack, togglemicrophone, hangup…).
    var actions: Set<String> = []
    /// What the page says (setMicrophoneActive / setCameraActive); nil when it doesn't say.
    var microphoneActive: Bool?
    var cameraActive: Bool?
    /// What the devices are actually doing.
    var capture = Capture()

    init() {}

    init(_ d: [String: Any]) {
        playback = Playback(rawValue: d["playbackState"] as? String ?? "") ?? .none
        active = (d["active"] as? NSNumber)?.boolValue ?? false
        title = d["title"] as? String ?? ""
        artist = d["artist"] as? String ?? ""
        album = d["album"] as? String ?? ""
        artwork = (d["artwork"] as? [Any] ?? []).compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["src"] as? String) }
        let dur = (d["duration"] as? NSNumber)?.doubleValue ?? -1
        duration = dur > 0 && dur.isFinite ? dur : nil
        let pos = (d["position"] as? NSNumber)?.doubleValue ?? -1
        position = pos >= 0 ? pos : nil
        rate = (d["playbackRate"] as? NSNumber)?.doubleValue ?? 1
        actions = Set(d["actions"] as? [String] ?? [])
        microphoneActive = (d["microphoneActive"] as? NSNumber)?.boolValue
        cameraActive = (d["cameraActive"] as? NSNumber)?.boolValue
        let c = d["capture"] as? [String: Any] ?? [:]
        func on(_ k: String) -> Bool { (c[k] as? NSNumber)?.boolValue ?? false }
        capture = Capture(microphone: on("microphone"), camera: on("camera"), screen: on("screen"), tab: on("tab"))
    }

    /// A call: the page captures the microphone or camera, or can hang up (a page that once said what its microphone
    /// does keeps saying it after the call, so that alone isn't one).
    var isCall: Bool { capture.microphone || capture.camera || actions.contains("hangup") }
    /// Something the tray can show: playing or paused media, or a call.
    var isPresent: Bool { isCall || playback != .none }
    /// The microphone as the call shows it: the page's own state when it reports one, else the device's.
    var microphoneOn: Bool { microphoneActive ?? capture.microphone }
    var cameraOn: Bool { cameraActive ?? capture.camera }
}

protocol EngineMedia: AnyObject {
    /// False on a framework without Media Session tabs (no media tray, no call window controls).
    var mediaAvailable: Bool { get }
    /// The profile's tabs with a media session or capturing a device: the list now, then each change. One observer per
    /// profile; nil stops.
    func observeMediaTabs(in profile: EngineProfile, _ handler: (([EngineTab]) -> Void)?)
    func mediaSession(of tab: EngineTab) -> EngineMediaSession
    /// The session now (maybe more than once while it starts), then each change. One observer per tab; nil stops.
    func observeMediaSession(of tab: EngineTab, _ handler: ((EngineMediaSession) -> Void)?)
    /// play, pause, nexttrack, previoustrack, seekto (`value` seconds), togglemicrophone, togglecamera, hangup…
    /// True: sent to the page (not that the page did it). Offer only the session's `actions`.
    @discardableResult func performMediaAction(_ action: String, value: Double, in tab: EngineTab) -> Bool
}

protocol EngineCallHosting: AnyObject {
    /// An engine window around a window the app made (the call window's floating panel); pages move in and out of its
    /// `hostView` with `moveTab`, live (no reload).
    func makeWindow(hosting window: NSWindow) -> EngineWindow
}

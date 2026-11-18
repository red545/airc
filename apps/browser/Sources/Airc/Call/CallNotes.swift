// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import WebKit

/// Settings › Calendar › "Start Granola notes when a call starts" (docs/user/call-notes.md). Granola detects calls only
/// in browsers on its own list, and Airc isn't on it yet (artifacts/callrecorders). So when a tab on a call site starts
/// using the microphone, Airc opens Granola's undocumented `granola://new-document` link, once per call
/// (AircKit's CallNotesTrigger). Stopping is Granola's: it stops when the audio ends, or the person stops it.
///
/// The microphone comes from the engines' own capture state through SiteControlsCenter's notice: Chromium's capture
/// indicator for every tab, WebKit's `microphoneCaptureState` (muted counts as on, so muting isn't leaving).
final class CallNotes {
    static let shared = CallNotes()

    private var trigger = CallNotesTrigger()
    private final class Weak { weak var tab: EngineTab?; init(_ t: EngineTab) { tab = t } }
    private var tabs: [ObjectIdentifier: Weak] = [:]
    private var observer: NSObjectProtocol?
    /// What Airc opened and the app it went to, newest last (for checks and the log).
    private(set) var opened: [(date: Date, url: URL, app: URL?)] = []

    #if AIRC_TESTING
    /// Checks: a tab's microphone as the engine would report it (no getUserMedia in tests, common.md 2026-11-06).
    static var testMicrophone: [ObjectIdentifier: Bool] = [:]
    /// Checks: AIRC_CALLNOTES_TEST_HANDLER=<path of a fake app>. With it set, that app (only if it exists) stands in for
    /// Granola, and links go to it by path, never to the system's `granola:` handler: a real Granola on the test Mac
    /// must never get one. A path that doesn't exist means "Granola isn't installed".
    static let testHandler: URL? = ProcessInfo.processInfo.environment["AIRC_CALLNOTES_TEST_HANDLER"]
        .map { URL(fileURLWithPath: $0) }
    #endif

    private var settings: AppSettings? { (NSApp.delegate as? AppDelegate)?.settings }

    /// Starts listening (cheap: one notice observer; nothing polls). Called at launch.
    func start() {
        guard observer == nil else { return }
        _ = SiteControlsCenter.shared   // installs the engines' activity callback
        observer = NotificationCenter.default.addObserver(forName: SiteControlsCenter.didChange, object: nil, queue: .main) { [weak self] n in
            guard let tab = n.userInfo?["tab"] as? EngineTab else { return }
            self?.changed(tab)
        }
    }

    /// Granola's app, if this Mac has one that opens `granola:` links.
    static var granolaApp: URL? {
        #if AIRC_TESTING
        if let fake = testHandler { return FileManager.default.fileExists(atPath: fake.path) ? fake : nil }
        #endif
        return NSWorkspace.shared.urlForApplication(toOpen: URL(string: "granola://")!)
    }

    func changed(_ tab: EngineTab) {
        sweep()
        let id = ObjectIdentifier(tab)
        guard !tab.isClosed else { trigger.forget(tab: id); tabs[id] = nil; return }
        let on = microphone(tab)
        if on { tabs[id] = Weak(tab) }
        let enabled = settings?.values.granolaCallNotes == true
        guard trigger.microphone(on, tab: id, url: tab.url, isPrivate: Self.isPrivate(tab), enabled: enabled),
              Self.granolaApp != nil else { return }
        open(CallNotesTrigger.granolaURL)
    }

    private func microphone(_ tab: EngineTab) -> Bool {
        #if AIRC_TESTING
        if let on = Self.testMicrophone[ObjectIdentifier(tab)] { return on }
        #endif
        if let web = (tab as? WebKitTab)?.webView { return web.microphoneCaptureState != .none }
        return SiteControlsCenter.shared?.activity(of: tab).microphone ?? false
    }

    static func isPrivate(_ tab: EngineTab) -> Bool {
        BoostCenter.isPrivate(tab) || PrivateBrowsing.shared.windows.contains { $0.profile === tab.profile }
    }

    /// Tabs that closed without a last notice end their call (so a rejoin window starts, and nothing lingers).
    private func sweep() {
        for (id, w) in tabs where w.tab == nil || w.tab?.isClosed == true {
            trigger.forget(tab: id)
            tabs[id] = nil
        }
    }

    private func open(_ url: URL) {
        // Granola shows its window on every link (its open-url handler focuses it), so this can't keep it behind.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        let done: (NSRunningApplication?, Error?) -> Void = { _, error in
            if let error { NSLog("CallNotes: opening the note taker failed: \(error.localizedDescription)") }
        }
        #if AIRC_TESTING
        if Self.testHandler != nil {
            guard let fake = Self.granolaApp else { return }
            record(url, app: fake)
            NSWorkspace.shared.open([url], withApplicationAt: fake, configuration: config, completionHandler: done)
            return
        }
        #endif
        record(url, app: Self.granolaApp)
        NSWorkspace.shared.open(url, configuration: config, completionHandler: done)
    }

    private func record(_ url: URL, app: URL?) {
        opened.append((Date(), url, app))
        if opened.count > 20 { opened.removeFirst() }
    }
}

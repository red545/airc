// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import CoreServices

/// AT-1 / LA-1: a link from another app (Mail, Slack, Notes) arrives as a GURL Apple event. AppKit hands it to the
/// delegate's `application(_:open:)` only when the delegate was there as NSApp finished launching, and on Chromium it
/// isn't: Chromium runs NSApp, then the engine starts the app (engineDidStart sets the delegate). So on Chromium no link
/// from another app opened anything, not Little Arc and not a tab (owner report, 2026-11-06). The app answers GURL
/// itself, from before the engine runs on: a link that launches the app waits here until the delegate exists.
final class URLEventHandler: NSObject {
    static let shared = URLEventHandler()
    private weak var delegate: AppDelegate?
    private var waiting: [(url: URL, source: String?)] = []
    /// kInternetEventClass / kAEGetURL ('GURL').
    private static let gurl: FourCharCode = 0x4755_524C

    /// Before the engine runs (a link that launches the app is its launch event), and again once it has started, in
    /// case anything put another handler in between. Returns who had GURL before (Links.log).
    @discardableResult
    func install() -> String {
        let before = Self.registeredHandler()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handle(_:withReplyEvent:)),
                                                     forEventClass: Self.gurl, andEventID: Self.gurl)
        return before
    }

    /// The delegate exists: links that came before it open now.
    func attach(_ d: AppDelegate) {
        delegate = d
        let early = waiting
        waiting = []
        for item in early { d.openFromOtherApp([item.url], source: item.source) }
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        // keyDirectObject ('----'): the URL.
        guard let s = event.paramDescriptor(forKeyword: 0x2D2D_2D2D)?.stringValue, let url = URL(string: s) else { return }
        Self.noteLaunchLink()
        if let delegate { delegate.application(NSApp, open: [url]) } else {
            // LA-1: whether its sender is in full screen, now, while its Space is still on screen (a link that launches the
            // app: Little Arc opens over that app once the app is up, LittleArcFullScreen).
            LittleArcFullScreen.shared.linkArrived(from: LinkLog.eventSenderPID(), url: url)
            waiting.append((url, LinkLog.eventSource()))
        }
    }

    /// LA-1 (linklaunch): a link arrived before the launch finished (the link launched the app).
    static func noteLaunchLink() { if !LaunchEvent.shared.finished { LaunchEvent.shared.linkDuringLaunch = true } }

    /// The GURL handler registered now: none, NSAppleEventManager's (Foundation; ours or another object's), or the
    /// image whose C handler it is.
    static func registeredHandler() -> String {
        var handler: AEEventHandlerUPP?
        var refcon: UnsafeMutableRawPointer?
        let err = AEGetEventHandler(gurl, gurl, &handler, &refcon, false)
        guard err == noErr, let handler else { return "none (\(err))" }
        var info = Dl_info()
        guard dladdr(unsafeBitCast(handler, to: UnsafeRawPointer.self), &info) != 0 else { return "unknown" }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
        return "\(symbol) in \(image)"
    }
}

/// linklaunch: why macOS launched the app. Launch Services starts an app with one Apple event, which AppKit dispatches
/// while it finishes launching: 'oapp' (the Dock, Finder, Spotlight, a login item, `open -a`, Sparkle's relaunch),
/// 'odoc' (files) or 'GURL' (a link from another app: Mail, Slack, WhatsApp). It's the current Apple event at
/// will/did-finish-launching (the same read a login-item check makes), so main.swift starts observing before NSApp runs
/// (on both engines: Chromium runs NSApp itself, and the app's own did-finish-launching comes later, from the engine).
/// A link can also come before did-finish-launching, or right after it: `linkDuringLaunch` records one that came first.
/// AppDelegate decides on the launch's browser window from all of it, one run-loop turn after its profiles loaded.
final class LaunchEvent {
    static let shared = LaunchEvent()
    /// The launch event's ID ('oapp', 'odoc', 'GURL'), or nil: none was current.
    private(set) var eventID: FourCharCode?
    /// AppKit's did-finish-launching came (from NSApp, whatever the engine).
    private(set) var finished = false
    /// A link from another app came before did-finish-launching.
    var linkDuringLaunch = false
    /// For Links.log: what each phase saw.
    private(set) var summary = "not seen"
    private var observers: [NSObjectProtocol] = []

    private static let openApplication: FourCharCode = 0x6F61_7070   // 'oapp'
    static let getURL: FourCharCode = 0x4755_524C                     // 'GURL'

    /// main.swift, before NSApp runs.
    func observe() {
        guard observers.isEmpty else { return }
        summary = ""
        for (name, phase) in [(NSApplication.willFinishLaunchingNotification, "will"), (NSApplication.didFinishLaunchingNotification, "did")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                self?.record(phase: phase, note: note)
            })
        }
    }

    private func record(phase: String, note: Notification) {
        let e = NSAppleEventManager.shared().currentAppleEvent
        if eventID == nil, let id = e?.eventID { eventID = id }
        let isDefault = (note.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber).map { $0.boolValue ? "yes" : "no" } ?? "-"
        summary += (summary.isEmpty ? "" : ", ") + "\(phase) \(e.map { Self.code($0.eventClass) + "/" + Self.code($0.eventID) } ?? "none") (default \(isDefault), "
            + "link \(linkDuringLaunch ? "yes" : "no"))"
        if linkDuringLaunch, !finished { holdActivation() }
        if phase == "did" { finished = true }
    }

    /// The launch is for a link, so far: macOS must not activate the app yet. Launch Services activates an app it launches
    /// in the foreground as it finishes launching, and macOS then leaves a full-screen app's Space for the desktop, a
    /// window or not (measured: 0.15 to 0.3 s into the launch, before any window). A prohibited app isn't activated
    /// (no Dock icon either, for that moment); Little Airc opens as a non-activating panel over the sending app, then
    /// `releaseActivation` makes the app regular again, without activating it.
    private(set) var holdingActivation = false
    private func holdActivation() {
        guard !holdingActivation, NSApp != nil else { return }
        #if AIRC_TESTING
        if ProcessInfo.processInfo.environment["AIRC_LL_NO_HOLD"] == "1" { return }
        #endif
        holdingActivation = true
        NSApp.setActivationPolicy(.prohibited)
        summary += " [activation held]"
        // Never left held: whatever the launch does, a regular app 10 s on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.releaseActivation(activate: false) }
    }

    /// Back to a regular app (the Dock icon, menus); `activate`: as Launch Services would have (the window opens instead).
    func releaseActivation(activate: Bool) {
        guard holdingActivation else { return }
        holdingActivation = false
        NSApp.setActivationPolicy(.regular)
        if activate { NSApp.activate(ignoringOtherApps: true) }
    }

    /// A plain launch ('oapp', with no link before did-finish-launching): the browser window opens as always, even if a
    /// link comes while it launches.
    var isPlainLaunch: Bool { eventID == Self.openApplication && !linkDuringLaunch }
    /// The launch event is a link: worth waiting a moment for it before deciding on the window.
    var announcesLink: Bool { eventID == Self.getURL }

    static func code(_ c: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((c >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(c)
    }
}

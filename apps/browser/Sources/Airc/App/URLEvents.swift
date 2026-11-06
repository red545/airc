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
        if let delegate { delegate.application(NSApp, open: [url]) } else { waiting.append((url, LinkLog.eventSource())) }
    }

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

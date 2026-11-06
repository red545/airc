// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// AT-1 / LA-1 diagnostics (owner report 2026-11-06: links from other apps and Little Arc): `<data folder>/Links.log`,
/// next to Updates.log. One line per link from another app (when, the sending app, the route, whether a window opened,
/// and half a second later the window's key/main state and the app's), and one per press in a Little Arc window until
/// one reaches its page (what it hit, whether the page took it). Dev and test builds only; never a URL, only its host;
/// the file is cut to its newest half past 128 KB.
enum LinkLog {
    static let enabled: Bool = {
        #if AIRC_TESTING
        return true
        #else
        return Bundle.main.object(forInfoDictionaryKey: "AircDevChannel") as? Bool == true
        #endif
    }()

    static var url: URL { AppPaths.dataDirectory.appendingPathComponent("Links.log") }
    private static let queue = DispatchQueue(label: "airc.links-log", qos: .utility)
    private static let limit = 128 * 1024

    /// One line in `file` (default Links.log) in the data folder; Keychain.log (SafeStorageKey) uses it too.
    static func write(_ event: String, file name: String = "Links.log") {
        guard enabled else { return }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: TimeZone(identifier: "UTC")!,
                                                formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        let line = "\(stamp) \(event)\n"
        let file = AppPaths.dataDirectory.appendingPathComponent(name)
        queue.async {
            if let handle = try? FileHandle(forWritingTo: file) {
                let size = handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
                if size > limit, let data = try? Data(contentsOf: file) {
                    try? data.suffix(limit / 2).write(to: file, options: .atomic)
                }
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }

    /// The bundle ID of the app that sent the Apple event being handled, from the Apple Event Manager (never the
    /// front app): the same answer as the engine's `currentEventSourceBundleID`.
    static func eventSource() -> String? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return nil }
        // keySenderPIDAttr ('spid'): set by the Apple Event Manager, not by the sender.
        guard let pid = event.attributeDescriptor(forKeyword: 0x7370_6964)?.int32Value, pid > 0 else { return "unknown sender" }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
    }

    /// The URL's host (or its scheme for one without), never its path or query.
    static func host(_ url: URL) -> String { url.host ?? (url.scheme.map { "\($0):" } ?? "?") }

    static func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

    /// The window's state as the person sees it: key, main, on the active Space, visible, the app's front window.
    static func windowState(_ w: NSWindow) -> String {
        "key \(yesNo(w.isKeyWindow)), main \(yesNo(w.isMainWindow)), visible \(yesNo(w.isVisible)), "
            + "on the active Space \(yesNo(w.isOnActiveSpace)), occluded \(yesNo(!w.occlusionState.contains(.visible))), "
            + "front \(yesNo(NSApp.orderedWindows.first === w))"
    }
}

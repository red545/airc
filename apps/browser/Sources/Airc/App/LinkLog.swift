// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// AT-1 / LA-1 diagnostics (owner report 2026-11-06: links from other apps and Little Arc): `<data folder>/Links.log`,
/// next to Updates.log. One line per link from another app (when, the sending app, the route, whether a window opened,
/// and half a second later the window's key/main state and the app's), and one per press in a Little Arc window until
/// one reaches its page (what it hit, whether the page took it). Dev and test builds; a public build only when asked
/// (`defaults write <bundle ID> AircLinksLog -bool YES`, for a report from Stable); never a URL, only its host; the
/// file is cut to its newest half past 128 KB.
enum LinkLog {
    static let enabled: Bool = {
        #if AIRC_TESTING
        return true
        #else
        return Bundle.main.object(forInfoDictionaryKey: "AircDevChannel") as? Bool == true
            || UserDefaults.standard.bool(forKey: "AircLinksLog")
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

    /// The pid of the app that sent the Apple event being handled (keySenderPIDAttr), if it's another app.
    static func eventSenderPID() -> pid_t? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: 0x7370_6964)?.int32Value, pid > 0, pid != getpid() else { return nil }
        return pid
    }

    /// The sending app as the link came: in native full screen (it owns a full-screen Space) and whether that Space was
    /// on screen, for Links.log. Airc's own front state at that moment says nothing about the sender (Launch Services
    /// may have activated Airc already).
    static func senderState(_ pid: pid_t?) -> String {
        guard let pid else { return "sender unknown" }
        guard let space = FullScreenSpaces.space(of: pid) else {
            return "sender full screen \(yesNo(isFullScreen(pid)))\(FullScreenSpaces.available ? "" : " (no Space list)")"
        }
        return "sender full screen yes, its Space on screen \(yesNo(space.current))"
    }

    /// The URL's host (or its scheme for one without), never its path or query.
    static func host(_ url: URL) -> String { url.host ?? (url.scheme.map { "\($0):" } ?? "?") }

    static func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

    /// The front app (at a link: the one it came from, before Airc activates) and whether it's in full screen on the
    /// active Space, as the window server lists windows on screen (no screen-recording access needed).
    static func frontApp() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication else { return "front app none" }
        return "front app \(front.bundleIdentifier ?? "pid \(front.processIdentifier)"), full screen \(yesNo(isFullScreen(front.processIdentifier)))"
    }

    /// One of the app's windows fills a whole screen on the active Space (a full-screen app: a zoomed window stops
    /// at the menu bar). On a screen with a camera housing the full-screen window stops below it, where a zoomed one
    /// stops too (the menu bar is as tall): there AppKit's transparent full-screen title bar window, as wide as the
    /// screen at the same top, tells them apart (the build Mac, 2026-11-07: 1512×949 at y 33 and 1512×32 at alpha 0).
    /// The window server's Space list first (exact, whatever the app's windows look like: a Catalyst app's full screen
    /// has no AppKit title bar window); the window geometry below if that list can't be read.
    static func isFullScreen(_ pid: pid_t) -> Bool {
        if FullScreenSpaces.space(of: pid)?.current == true { return true }
        return fillsScreen(pid)
    }

    static func fillsScreen(_ pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        let windows = list.compactMap { w -> (bounds: CGRect, alpha: Double)? in
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid, (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d) else { return nil }
            return (b, (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
        return windows.contains { w in
            screens.contains { s in
                if w.bounds == s { return true }
                // Below a camera housing: the screen's width down to its bottom, from at most 50 pt down, with the title
                // bar window at the same top.
                guard w.alpha > 0, w.bounds.minX == s.minX, w.bounds.width == s.width, w.bounds.maxY == s.maxY,
                      w.bounds.minY > s.minY, w.bounds.minY - s.minY <= 50 else { return false }
                return windows.contains { $0.alpha == 0 && $0.bounds.minY == w.bounds.minY && $0.bounds.width == w.bounds.width && $0.bounds.height < 60 }
            }
        }
    }

    /// The window's state as the person sees it: key, main, on the active Space, visible, the app's front window.
    static func windowState(_ w: NSWindow) -> String {
        "key \(yesNo(w.isKeyWindow)), main \(yesNo(w.isMainWindow)), visible \(yesNo(w.isVisible)), "
            + "on the active Space \(yesNo(w.isOnActiveSpace)), occluded \(yesNo(!w.occlusionState.contains(.visible))), "
            + "front \(yesNo(NSApp.orderedWindows.first === w))"
    }
}

/// LA-1: native full-screen Spaces as the window server (SkyLight) manages them, read through CoreGraphics' Space calls
/// (`CGSCopyManagedDisplaySpaces`: no Screen Recording or Accessibility access). Each display lists its Spaces; a
/// full-screen one has type 4 and the pid of the app it belongs to (also in its tiles, for Split View), and each display
/// names its current Space. Looked up by name at run time: if macOS drops or changes them, `available` is false and
/// callers fall back to the window geometry.
enum FullScreenSpaces {
    struct Space: Equatable {
        let id: UInt64
        let pids: Set<pid_t>
        /// On screen now: the current Space of its display.
        let current: Bool
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let handle = UnsafeMutableRawPointer(bitPattern: -2)
    private static let connection: Int32? = dlsym(handle, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self)() }
    private static let copyDisplaySpaces = dlsym(handle, "CGSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopyDisplaySpaces.self) }
    private static let copySpacesForWindows = dlsym(handle, "CGSCopySpacesForWindows").map { unsafeBitCast($0, to: CopySpacesForWindows.self) }

    static var available: Bool { connection != nil && copyDisplaySpaces != nil }

    /// Every full-screen Space on every display (nil: the list can't be read).
    static func all() -> [Space]? {
        guard let cid = connection, let copy = copyDisplaySpaces,
              let displays = copy(cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        var out: [Space] = []
        for display in displays {
            let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard (space["type"] as? NSNumber)?.intValue == 4, let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                var pids = Set<pid_t>()
                collectPIDs(space, into: &pids)
                out.append(Space(id: id, pids: pids, current: id == current))
            }
        }
        return out
    }

    /// The full-screen Space `pid` is in (its own, or a Split View it shares), the one on screen first.
    static func space(of pid: pid_t) -> Space? {
        let mine = all()?.filter { $0.pids.contains(pid) } ?? []
        return mine.first { $0.current } ?? mine.first
    }

    /// The Spaces a window of ours is in (the checks: the panel on the full-screen app's Space).
    static func spaces(ofWindow number: Int) -> [UInt64] {
        guard let cid = connection, let copy = copySpacesForWindows,
              let ids = copy(cid, 7, [NSNumber(value: number)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return ids.map(\.uint64Value)
    }

    private static func collectPIDs(_ value: Any, into pids: inout Set<pid_t>) {
        if let d = value as? [String: Any] {
            for (k, v) in d {
                if k == "pid", let n = v as? NSNumber, n.int32Value > 0 { pids.insert(n.int32Value) } else { collectPIDs(v, into: &pids) }
            }
        } else if let a = value as? [Any] {
            for v in a { collectPIDs(v, into: &pids) }
        }
    }
}

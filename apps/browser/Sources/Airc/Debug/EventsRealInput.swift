// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit

/// The events script's real-pointer helpers.
///
/// Posted clicks name their window, but AppKit still looks at the real pointer: while the app is active (dedicated
/// sessions bring it to the front) and the pointer rests on the menu bar, every posted mouse-down first starts
/// main-menu tracking, which can swallow the release (eventsmode, 2026-11-13: 10 reds, identical on both engines,
/// with the window key and the app active). A person's click is always where their pointer is, so the checks put the
/// pointer in the window first, and in dedicated sessions with the UI driver they make the modifier clicks and drags
/// with real input.
///
/// `AIRC_EVENTS_TRACE=1` (for diagnosis): the window, app and input state at each real-event case, and every mouse,
/// modifier and menu-tracking event the app sees while it runs.
extension SnapshotRunner {
    /// Real driver clicks and drags: the driver is there and this is a dedicated session (the app is in front).
    var realPointerInput: Bool {
        UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
    }

    /// While the app is active, the real pointer must rest on our window (see above). It is moved there with the driver, or warped there without one; it is only ever moved in a dedicated session.
    /// FAIL-ENV, with what is under it, when it stays outside.
    func pointerInWindow(_ label: String) {
        step { [self] done in
            let w = c.window
            func under() -> Int { NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) }
            guard NSApp.isActive, under() != w.windowNumber else { return done() }
            let was = Self.hidState
            guard ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
                note("FAIL-ENV events (\(label)): the app is active and the real pointer rests outside our window (\(was))"); return done()
            }
            // Low in the sidebar's list, where nothing the checks open appears (the page's middle is under the Command
            // Bar, whose rows follow a pointer resting there). It's where eventsfront parked it: green with and without the driver.
            let target = NSPoint(x: min(114, c.sidebar.frame.width / 2), y: 179)
            func verify(_ how: String) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if under() == w.windowNumber {
                        self.note("events (\(label)): the real pointer was outside our window (\(was)); \(how) into the sidebar")
                    } else {
                        self.note("FAIL-ENV events (\(label)): the real pointer stays outside our window after \(how) (\(Self.hidState))")
                    }
                    done()
                }
            }
            if realPointerInput {
                UIDriverClient.move(target, in: w) { ok, out in verify(ok ? "moved with the driver" : "a driver move that failed (\(out.prefix(120)))") }
            } else {
                let s = w.convertPoint(toScreen: target)
                CGWarpMouseCursorPosition(CGPoint(x: s.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - s.y))
                verify("warped")
            }
        }
    }

    /// A real driver drag between two window points; `done(ok, why)` once the app has settled.
    func eventsRealDrag(from: NSPoint, to: NSPoint, mods: String? = nil, _ done: @escaping (Bool, String) -> Void) {
        let w = c.window
        guard NSApp.isActive, w.isKeyWindow, w.isOnActiveSpace, let top = NSScreen.screens.first?.frame.maxY else {
            return done(false, "not the active key window on the active Space (active \(NSApp.isActive), key \(w.isKeyWindow))")
        }
        let s = w.convertPoint(toScreen: from), e = w.convertPoint(toScreen: to)
        let args = ["--drag", String(Double(s.x)), String(Double(top - s.y)), String(Double(e.x)), String(Double(top - e.y))]
        UIDriverClient.run(args + (mods.map { ["--mods", $0] } ?? [])) { ok, out in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done(ok, ok ? "" : "the driver refused the drag: \(out.prefix(160))") }
        }
    }

    /// A plain real driver click at a window point (the driver refuses an empty `--mods`).
    func eventsRealClick(_ p: NSPoint, _ done: @escaping (Bool, String) -> Void) {
        let w = c.window
        guard NSApp.isActive, w.isKeyWindow, w.isOnActiveSpace, let top = NSScreen.screens.first?.frame.maxY else {
            return done(false, "not the active key window on the active Space (active \(NSApp.isActive), key \(w.isKeyWindow))")
        }
        let g = w.convertPoint(toScreen: p)
        UIDriverClient.run(["--click", String(Double(g.x)), String(Double(top - g.y))], done)
    }

    /// What a press at a window point hits, and whether that is (inside) a view of type `T`.
    func pressHits<T: NSView>(_ p: NSPoint, _ type: T.Type) -> (Bool, String) {
        let frame = c.window.contentView?.superview
        let hit = frame.flatMap { $0.hitTest($0.convert(p, from: nil)) }
        let ok = hit.map { sequence(first: $0, next: { $0.superview }).contains { $0 is T } } ?? false
        return (ok, hit.map { String(describing: Swift.type(of: $0)) } ?? "nothing")
    }

    static var eventsTraceOn: Bool { ProcessInfo.processInfo.environment["AIRC_EVENTS_TRACE"] == "1" }
    private static var traceTokens: [Any] = []

    func eventsTraceStart() {
        guard Self.eventsTraceOn, Self.traceTokens.isEmpty else { return }
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .flagsChanged, .mouseMoved]
        if let m = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] e in
            if e.type != .mouseMoved && e.type != .leftMouseDragged || Self.traceMoves {
                self?.note(String(format: "trace: %@ mods %@ at (%.0f, %.0f) win %d src %@ | ", "\(e.type.rawValue)",
                                  Self.mods(e.modifierFlags), e.locationInWindow.x, e.locationInWindow.y, e.windowNumber,
                                  e.cgEvent.map { "\($0.getIntegerValueField(.eventSourceUnixProcessID))" } ?? "-") + Self.hidState)
            }
            return e
        }) { Self.traceTokens.append(m) }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            Self.traceTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] n in
                let menu = n.object as? NSMenu
                let main = menu === NSApp.mainMenu
                self?.note("trace: \(name.rawValue) \(main ? "MAIN MENU" : menu?.title ?? "-") (\(menu?.items.prefix(3).map(\.title) ?? [])) | " + Self.hidState)
            })
        }
    }

    static var traceMoves = false

    static func mods(_ f: NSEvent.ModifierFlags) -> String {
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s.isEmpty ? "-" : s
    }

    /// The real (HID) input state, which posted events don't change.
    static var hidState: String {
        let p = NSEvent.mouseLocation
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let under = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        return String(format: "pointer (%.0f, %.0f top-left), buttons %d, HID mods %@, under window %d %@, front %@",
                      p.x, top - p.y, NSEvent.pressedMouseButtons, mods(NSEvent.modifierFlags), under,
                      windowInfo(under).text, NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")
    }

    /// One line at the start of a case: what decides how a real or posted click lands.
    func eventsState(_ label: String) {
        guard Self.eventsTraceOn else { return }
        run { [self] in
            let w = c.window
            note("state \(label): window key \(w.isKeyWindow), main \(w.isMainWindow), app active \(NSApp.isActive), "
                 + "first responder \(w.firstResponder.map { String(describing: type(of: $0)) } ?? "-"), "
                 + "frame \(NSStringFromRect(w.frame)), number \(w.windowNumber), menu bar tracking "
                 + "\(NSApp.mainMenu.map { $0.highlightedItem?.title ?? "none" } ?? "-"), " + Self.hidState)
        }
    }
}
#endif

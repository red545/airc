// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit

/// `AIRC_DIAG_LOG=<file>`: for a launch the way the owner launches (Finder, `open`, or the binary from Terminal), not a
/// scripted run. Appends to the file what decides whether clicks and the traffic lights work: app activation, the key
/// and main window, occlusion, the traffic lights (hidden, alpha, frame, the top window at their centre), and for every
/// real mouse-down in the browser window the top window at that point, the view it hit-tests to, and the first
/// responder before and after. Off (nothing installed) without the variable.
enum LaunchDiagnostics {
    private static var file: FileHandle?
    private static var monitor: Any?

    static func start(_ c: WindowController) {
        guard monitor == nil, let path = ProcessInfo.processInfo.environment["AIRC_DIAG_LOG"], !path.isEmpty else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        file = FileHandle(forWritingAtPath: path)
        file?.seekToEndOfFile()
        log("launch: engine \(c.app?.engine.name ?? "?"), pid \(getpid()), args \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        for delay in [0.0, 1, 3, 6, 12] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak c] in if let c { state(c, "after \(delay) s") } }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak c] n in
                if let c { state(c, n.name.rawValue) }
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak c] e in
            guard let c else { return e }
            if e.type == .keyDown {
                log("key \(e.keyCode) to window \(e.window?.windowNumber ?? 0), key window \(NSApp.keyWindow?.windowNumber ?? 0), "
                    + "first responder \(SnapshotRunner.describe(c.window.firstResponder))")
                return e
            }
            let w = c.window
            guard e.window === w else {
                log("\(e.type == .leftMouseDown ? "down" : "up") in another window \(e.window.map { String(describing: type(of: $0)) } ?? "none")")
                return e
            }
            let p = e.locationInWindow
            let top = NSWindow.windowNumber(at: w.convertPoint(toScreen: p), belowWindowWithWindowNumber: 0)
            let frame = w.contentView?.superview
            let hit = frame.flatMap { $0.hitTest($0.convert(p, from: nil)) }
            let page = c.shownTabID.flatMap { c.engineTab(for: $0) }?.view
            log("\(e.type == .leftMouseDown ? "down" : "up") at \(Int(p.x)),\(Int(p.y)) clicks \(e.clickCount): active \(NSApp.isActive), "
                + "key \(w.isKeyWindow), top window \(top == w.windowNumber ? "ours" : SnapshotRunner.windowInfo(top).text), "
                + "hit \(page.map { SnapshotRunner.chain(hit, to: $0) } ?? SnapshotRunner.describe(hit)), "
                + "first responder \(SnapshotRunner.describe(w.firstResponder))"
                + (SnapshotRunner.windowServerDrags(at: p, hit: hit, in: w).map { "; window-server drag area: \($0)" } ?? ""))
            if e.type == .leftMouseDown {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    log("  0.3 s later: first responder \(SnapshotRunner.describe(w.firstResponder)), key \(w.isKeyWindow), active \(NSApp.isActive)")
                }
            }
            return e
        }
    }

    private static func state(_ c: WindowController, _ when: String) {
        let w = c.window
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }.map { b in
            let r = b.convert(b.bounds, to: nil)
            let top = NSWindow.windowNumber(at: w.convertPoint(toScreen: NSPoint(x: r.midX, y: r.midY)), belowWindowWithWindowNumber: 0)
            return "\(b.isHiddenOrHasHiddenAncestor ? "hidden" : "shown") α\(b.alphaValue) (\(Int(r.midX)),\(Int(w.frame.height - r.midY)))"
                + (top == w.windowNumber ? "" : " under \(SnapshotRunner.windowInfo(top).text)")
        }
        log("\(when): active \(NSApp.isActive), activation policy \(NSApp.activationPolicy().rawValue), key \(w.isKeyWindow), "
            + "main \(w.isMainWindow), visible \(w.isVisible), alpha \(w.alphaValue), occlusion visible \(w.occlusionState.contains(.visible)), "
            + "full screen \(w.styleMask.contains(.fullScreen)), sidebar \(c.sidebarFraction), window \(w.windowNumber) \(NSStringFromRect(w.frame)), "
            + "first responder \(SnapshotRunner.describe(w.firstResponder)), traffic lights \(lights.joined(separator: "; ")), "
            + "app windows \(NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))#\($0.windowNumber)" }.joined(separator: " "))")
    }

    private static func log(_ s: String) {
        let line = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + s + "\n"
        file?.write(Data(line.utf8))
    }
}
#endif

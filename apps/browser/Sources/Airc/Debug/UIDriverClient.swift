// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import Carbon
import Foundation

/// The build Mac's stable UI driver (infra/ui-driver, infra/w10/README.md): real key presses and clicks through the
/// HID event stream, posted by a separately signed helper that holds the event-posting and Input Monitoring grants
/// (a test app never does). Opt in with `AIRC_REAL_KEYS=1`, in a dedicated session under the UI lock only: without
/// a `--pid` the keys go to whatever app is in front. Checks still assert what the app did with them.
enum UIDriverClient {
    /// The helper in the account's real home (a check's CFFIXED_USER_HOME is not where the service lives).
    static var path: String {
        // scripts/step-watchdog-check.py points the watchdog's environment probe at a stand-in (never used to send input).
        if let stand = ProcessInfo.processInfo.environment["AIRC_UI_DRIVER_PATH_FOR_PROBE"], !stand.isEmpty,
           ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("watchdog-step-") }) { return stand }
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return home + "/arcfork/tools/airc-ui-driver/airc-ui-driver"
    }
    static var requested: Bool { ProcessInfo.processInfo.environment["AIRC_REAL_KEYS"] == "1" }
    static var available: Bool { requested && FileManager.default.isExecutableFile(atPath: path) }

    /// Runs one driver command off the main thread (AppKit must keep handling the input it posts); `done` on main:
    /// true when the driver reports `"ok": true`, with its output. Bounded at 15 s.
    static func run(_ args: [String], _ done: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["--json"] + args
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CFFIXED_USER_HOME")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch {
                return DispatchQueue.main.async { done(false, "driver did not start: \(error)") }
            }
            let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: stop)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            stop.cancel()
            let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = p.terminationStatus == 0 && out.replacingOccurrences(of: " ", with: "").contains("\"ok\":true")
            DispatchQueue.main.async { done(ok, out) }
        }
    }

    /// Presses `combos` one after another (each a driver `--key` combo), stopping at the first failure.
    static func press(_ combos: [String], pid: pid_t? = nil, _ done: @escaping (Bool, String) -> Void) {
        guard let first = combos.first else { return done(true, "") }
        run(["--key", first] + (pid.map { ["--pid", String($0)] } ?? [])) { ok, out in
            guard ok else { return done(false, "\(first): \(out)") }
            press(Array(combos.dropFirst()), pid: pid, done)
        }
    }

    /// Convert AppKit window points to Quartz global display points (primary display's top-left origin).
    static func click(_ point: NSPoint, in window: NSWindow, mods: String, _ done: @escaping (Bool, String) -> Void) {
        guard available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1",
              let primary = NSScreen.screens.first else { return done(false, "real clicks require the driver and a dedicated UI session") }
        guard NSApp.isActive, window.isKeyWindow, window.isOnActiveSpace else {
            return done(false, "real click target is not the active key window on the active Space")
        }
        let screen = window.convertPoint(toScreen: point)
        run(["--click", String(Double(screen.x)), String(Double(primary.frame.maxY - screen.y)), "--mods", mods], done)
    }

    /// Real HID pointer movement; leaves the pointer at the destination. Coordinates are in the window.
    static func move(_ point: NSPoint, in window: NSWindow, steps: Int = 20, duration: Int = 200,
                     _ done: @escaping (Bool, String) -> Void) {
        pointer(point, in: window, options: ["--move"], steps: steps, duration: duration, done)
    }

    static func hover(_ point: NSPoint, in window: NSWindow, dwell: Int,
                      steps: Int = 20, duration: Int = 200, _ done: @escaping (Bool, String) -> Void) {
        pointer(point, in: window, options: ["--hover", "--dwell", String(dwell)], steps: steps, duration: duration, done)
    }

    private static func pointer(_ point: NSPoint, in window: NSWindow, options: [String], steps: Int,
                                duration: Int, _ done: @escaping (Bool, String) -> Void) {
        guard available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1",
              let primary = NSScreen.screens.first else { return done(false, "real movement requires the driver and a dedicated UI session") }
        guard NSApp.isActive, window.isKeyWindow, window.isOnActiveSpace else {
            return done(false, "real movement target is not the active key window on the active Space")
        }
        let screen = window.convertPoint(toScreen: point)
        run([options[0], String(Double(screen.x)), String(Double(primary.frame.maxY - screen.y))]
            + Array(options.dropFirst()) + ["--steps", String(steps), "--duration", String(duration),
                                          "--pid", String(ProcessInfo.processInfo.processIdentifier)], done)
    }

    /// The character a key code types in the current keyboard layout, with or without Shift.
    private static func character(_ code: UInt16, shift: Bool) -> Character? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> Character? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                        0, &dead, chars.count, &length, &chars)
            guard status == noErr, dead == 0, length == 1, let scalar = Unicode.Scalar(chars[0]) else { return nil }
            return Character(scalar)
        }
    }

    /// Character combos for the layout-aware driver. Check availability here for the
    /// caller's diagnostics, but let the service resolve keycodes at delivery time.
    /// Returning old ANSI names would translate QWERTZ letters twice.
    static func keys(typing text: String) -> [String]? {
        var supported: Set<Character> = [" "]
        for shift in [false, true] {
            for code in UInt16(0)..<128 {
                if let ch = character(code, shift: shift) { supported.insert(ch) }
            }
        }
        var out: [String] = []
        for ch in text {
            guard supported.contains(ch) else { return nil }
            out.append(ch == " " ? "space" : ch == "+" ? "plus" : String(ch))
        }
        return out
    }

    /// The current keyboard layout's name, for logs.
    static var layoutName: String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "unknown" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
#endif

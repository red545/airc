// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// smoke.sh's helper, no test hooks needed in the app:
//   window PID SECONDS   wait for a normal window (layer 0, at least 400×300) owned by PID
//   quit PID SECONDS     ask PID to quit as the Quit menu does (an Apple quit event), wait until it has exited
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let pid = pid_t(args[2]), let seconds = Double(args[3]) else {
    FileHandle.standardError.write(Data("usage: smoke-window window|quit PID SECONDS\n".utf8))
    exit(2)
}
let deadline = Date().addingTimeInterval(seconds)
func running() -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

switch args[1] {
case "window":
    while Date() < deadline {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in windows where (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid
            && (w[kCGWindowLayer as String] as? Int) == 0 {
            let bounds = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
            if let width = bounds["Width"], let height = bounds["Height"], width >= 400, height >= 300 {
                let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
                print("window \(Int(width))×\(Int(height)), on screen \(onscreen)")
                exit(0)
            }
        }
        guard running() else { print("exited before showing a window"); exit(1) }
        Thread.sleep(forTimeInterval: 0.25)
    }
    print("no window after \(Int(seconds)) s")
    exit(1)
case "quit":
    guard let app = NSRunningApplication(processIdentifier: pid) else { print("not running"); exit(1) }
    app.terminate()
    while Date() < deadline {
        if !running() { print("quit"); exit(0) }
        Thread.sleep(forTimeInterval: 0.25)
    }
    print("still running after \(Int(seconds)) s")
    exit(1)
default:
    exit(2)
}

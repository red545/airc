// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Window and activation probe for arcbench.py. Public CoreGraphics/AppKit only: no screen capture, no Accessibility,
// no AppleEvents. Window names aren't read (they need Screen Recording); only owner PID, layer and bounds.
//   arcbench-probe window PID [TIMEOUT_S]   wait for PID's first on-screen normal window (layer 0, over 100 pt each way, not parked off screen);
//                                           prints "<epoch seconds> x y w h"; exit 3 on timeout
//   arcbench-probe bounds PID               the largest on-screen normal window of PID: "x y w h" (exit 3: none)
//   arcbench-probe count PID | list PID     on-screen normal windows of PID: how many, or their bounds
//   arcbench-probe front                    the frontmost app's PID
//   arcbench-probe activate PID             activate PID (NSRunningApplication; no AppleEvent), then print the front PID
//   arcbench-probe hide PID | unhide PID    hide/unhide PID; prints "hidden" or "visible" a second later
//   arcbench-probe hidden PID               "hidden" or "visible" (NSRunningApplication.isHidden), no change
import AppKit
import CoreGraphics

let args = CommandLine.arguments
func windows(_ pid: pid_t) -> [CGRect] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w -> CGRect? in
        guard (w[kCGWindowOwnerPID as String] as? Int) == Int(pid), (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: Double], (b["Width"] ?? 0) > 100, (b["Height"] ?? 0) > 100,
              (b["X"] ?? 0) > -10_000 else { return nil }   // not an off-screen helper window
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }
}
func show(_ r: CGRect) -> String { "\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))" }
guard args.count >= 2 else { exit(2) }
let pid = args.count >= 3 ? pid_t(args[2]) ?? 0 : 0
switch args[1] {
case "window":
    let deadline = Date().addingTimeInterval(args.count >= 4 ? Double(args[3]) ?? 30 : 30)
    while Date() < deadline {
        if let r = windows(pid).first {
            print(String(format: "%.4f ", Date().timeIntervalSince1970) + show(r)); exit(0)
        }
        usleep(2000)
    }
    exit(3)
case "bounds":
    guard let r = windows(pid).max(by: { $0.width * $0.height < $1.width * $1.height }) else { exit(3) }
    print(show(r))
case "count":
    print(windows(pid).count)
case "list":
    print(windows(pid).map(show).joined(separator: "; "))
case "front":
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
case "activate":
    _ = NSRunningApplication(processIdentifier: pid)?.activate()
    Thread.sleep(forTimeInterval: 0.5)
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
case "hide", "unhide":
    guard let app = NSRunningApplication(processIdentifier: pid) else { exit(3) }
    _ = args[1] == "hide" ? app.hide() : app.unhide()
    Thread.sleep(forTimeInterval: 1)
    print(windows(pid).isEmpty ? "hidden" : "visible")
case "hidden":
    guard let app = NSRunningApplication(processIdentifier: pid) else { exit(3) }
    print(app.isHidden ? "hidden" : "visible")
default:
    exit(2)
}

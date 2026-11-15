// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreGraphics
// window PID           wait for the first normal window, then hide the app (background runs)
// window PID keep      wait for it and leave it up (run.py --foreground)
// window PID hide      hide the app now and report "hidden" or "visible" (no normal window on screen a second later)
let pid = pid_t(CommandLine.arguments[1])!
let mode = CommandLine.arguments.dropFirst(2).first ?? ""
func windows(onscreen: Bool) -> Bool {
    let options: CGWindowListOption = onscreen ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
    let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains(where: {
        ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) &&
        ($0[kCGWindowLayer as String] as? Int) == 0 &&
        (($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0) > 100
    })
}
if mode == "hide" {
    NSRunningApplication(processIdentifier: pid)?.hide()
    Thread.sleep(forTimeInterval: 1)
    print(windows(onscreen: true) ? "visible" : "hidden")
    exit(0)
}
let deadline = Date().addingTimeInterval(20)
while Date() < deadline {
    if windows(onscreen: false) {
        print("window")
        if mode != "keep" { NSRunningApplication(processIdentifier: pid)?.hide() }
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.01)
}
exit(3)

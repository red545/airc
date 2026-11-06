// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreGraphics
let pid = pid_t(CommandLine.arguments[1])!
let deadline = Date().addingTimeInterval(20)
while Date() < deadline {
    let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    if windows.contains(where: {
        ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) &&
        ($0[kCGWindowLayer as String] as? Int) == 0 &&
        (($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0) > 100
    }) {
        print("window")
        NSRunningApplication(processIdentifier: pid)?.hide()
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.01)
}
exit(3)

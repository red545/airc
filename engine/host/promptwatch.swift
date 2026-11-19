// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// safestorage checks: prints the system prompts that could be up (one JSON line): on-screen windows owned by
// SecurityAgent or UserNotificationCenter, and those processes' PIDs. Window owners and bounds need no Screen
// Recording grant (titles do, and aren't read). Build: swiftc -O promptwatch.swift -o promptwatch
import AppKit
import CoreGraphics

let owners: Set<String> = ["SecurityAgent", "UserNotificationCenter"]
let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
let windows = info.compactMap { w -> [String: Any]? in
    guard let owner = w[kCGWindowOwnerName as String] as? String, owners.contains(owner) else { return nil }
    return ["owner": owner, "pid": w[kCGWindowOwnerPID as String] as? Int ?? 0, "layer": w[kCGWindowLayer as String] as? Int ?? 0]
}
let processes = NSWorkspace.shared.runningApplications.compactMap { app -> [String: Any]? in
    guard let path = app.executableURL?.lastPathComponent, owners.contains(path) else { return nil }
    return ["name": path, "pid": Int(app.processIdentifier)]
}
// runningApplications misses some agents; pgrep fills them in.
func pgrep(_ name: String) -> [Int] {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-x", name]
    let out = Pipe(); p.standardOutput = out
    try? p.run(); p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int($0) }
}
let result: [String: Any] = ["windows": windows, "apps": processes,
                             "securityAgent": pgrep("SecurityAgent"), "userNotificationCenter": pgrep("UserNotificationCenter")]
let data = try! JSONSerialization.data(withJSONObject: result)
print(String(decoding: data, as: UTF8.self))

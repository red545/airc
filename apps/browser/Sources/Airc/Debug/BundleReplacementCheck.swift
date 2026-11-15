// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit

extension SnapshotRunner {
    func bundleReplacementChecks() {
        run { [self] in
            let fm = FileManager.default
            let root = AppPaths.dataDirectory.appendingPathComponent("replacement-fixture.app")
            let contents = root.appendingPathComponent("Contents")
            let executable = contents.appendingPathComponent("MacOS/Fixture")
            try? fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("fixture".utf8).write(to: executable)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let old: [String: Any] = ["CFBundleIdentifier": "org.airc.fixture", "CFBundleShortVersionString": "0.1.4",
                                       "CFBundleVersion": "1", "CFBundleExecutable": "Fixture"]
            var next = old; next["CFBundleShortVersionString"] = "0.1.5"; next["CFBundleVersion"] = "2"
            let plist = contents.appendingPathComponent("Info.plist")
            func write(_ info: [String: Any]) {
                if let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) {
                    try? data.write(to: plist, options: .atomic)
                }
            }
            let center = UpdateCenter()
            var terminationRequests = 0
            let monitor = BundleReplacementMonitor(bundleURL: root, launchInfo: old, center: center,
                                                     terminate: { terminationRequests += 1 })
            write(old); monitor.check(); monitor.check()
            check(center.ready == nil, "bundle replacement: unchanged install has no prompt")
            write(next); monitor.check()
            check(center.ready == nil, "bundle replacement: first observation waits for stable copy")
            monitor.check()
            check(center.ready?.restartNotice == "Airc was updated. Restart to use 0.1.5.", "bundle replacement: changed on-disk version offers restart")
            center.ready?.installAndRelaunch()
            check(terminationRequests == 1 && monitor.hasPendingRestart, "bundle replacement: restart requests normal termination")
            monitor.quitCancelled()
            check(!monitor.hasPendingRestart, "bundle replacement: cancelled quit cancels relaunch")
            let ready = center.ready; monitor.check()
            check(center.ready === ready, "bundle replacement: stable copy does not repeatedly announce")
            try? Data("partial plist".utf8).write(to: plist); monitor.check()
            check(center.ready == nil, "bundle replacement: incomplete replacement removes stale action")
            ready?.installAndRelaunch()
            check(terminationRequests == 1 && !monitor.hasPendingRestart, "bundle replacement: old action cannot restart a changed bundle")
            var foreign = next; foreign["CFBundleIdentifier"] = "org.airc.other"
            write(foreign); monitor.check(); monitor.check()
            check(center.ready == nil, "bundle replacement: different application never becomes an update")
            write(next); try? fm.removeItem(at: executable); monitor.check(); monitor.check()
            check(center.ready == nil, "bundle replacement: missing executable never offers restart")
            // A replacement disappearing must not clear Sparkle's independent verified update.
            let sparkle = FakeReadyUpdate(version: "0.1.6")
            center.setReady(sparkle); monitor.check()
            check(center.ready === sparkle, "bundle replacement: preserves unrelated updater readiness")
            try? fm.removeItem(at: root)
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import Foundation

/// Child processes that end abnormally (docs/user/telemetry.md): a tab's renderer ("Aw, Snap") is counted as
/// `process.gone` with the kind of process and the signal that ended it, nothing else. macOS's own report of the same
/// crash (an `.ips` of "Airc Helper (Renderer)"), when it writes one, is a crash report (AppCrashReports).
///
/// Every tab a renderer served reports its end: one event per process type and signal a second, at most
/// `maxPerLaunch` a launch.
final class ProcessCrashes {
    static let shared = ProcessCrashes()
    static let maxPerLaunch = 20

    private var last: (process: TelemetryEvent.ChildProcess, exit: TelemetryEvent.ExitSignal, at: Date)?   // main thread
    private var sent = 0

    /// Main thread.
    func rendererGone(status: String, waitStatus: Int32) {
        gone(process: .renderer, waitStatus: waitStatus)
    }

    func gone(process: TelemetryEvent.ChildProcess, waitStatus: Int32) {
        let exit = TelemetryEvent.ExitSignal(waitStatus: waitStatus)
        let now = Date()
        if let last, last.process == process, last.exit == exit, now.timeIntervalSince(last.at) < 1 { return }
        last = (process, exit, now)
        guard sent < Self.maxPerLaunch else { return }
        sent += 1
        Telemetry.shared.record(.processGone(process: process, exit: exit))
    }
}

#if canImport(AircCore)
import AircCore

extension ChromiumRuntime {
    @objc func engine(_ engine: AircEngine, childProcessGone type: String, status: Int32, exitCode: Int32) {
        ProcessCrashes.shared.gone(process: .init(engineType: type), waitStatus: exitCode)
    }
}

extension ChromiumTab {
    /// The engine's report that this tab's renderer process died (status: crashed, killed, oom, abnormal …; code: the
    /// wait status). Only counted; the tab itself is left as the engine leaves it.
    @objc func tab(_ tab: AircTab, rendererGone status: String, code: Int32) {
        ProcessCrashes.shared.rendererGone(status: status, waitStatus: code)
    }
}
#endif

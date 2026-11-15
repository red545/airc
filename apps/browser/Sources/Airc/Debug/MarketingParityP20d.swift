// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of the Task Manager (P20d), the marketing scenario's part "parityp20d"
/// (`scripts/marketing-shots.sh --parts parityp20d`):
///   - task-manager: Work on linear.app, Help › Troubleshooting › Open Task Manager over it: the demo's tabs, the
///     browser and its helpers with their memory, CPU and process IDs, sampled live. No "Sign in to Google" card.
extension SnapshotRunner {
    func mkParityP20dShots(_ d: MarketingDemo) {
        mkShow(d, "work", "linear")
        mkPutAwaySignInCards()   // MarketingParityP12.swift
        mkSettleShown()
        run { [self] in
            TaskManagerWindow.show(from: c.window, app: app)
            guard let w = TaskManagerWindow.shared?.window else { return note("marketing: MISSING task-manager: no window") }
            // Its own width, so all six columns show (Task, Profile, Memory Footprint, CPU, Network, Process ID).
            w.setContentSize(NSSize(width: 820, height: 360))
            // Drawn off screen, as the Settings shots are: it's composited over the browser window.
            w.setFrameOrigin(NSPoint(x: -6000, y: 200))
        }
        // CPU needs a second sample per process, and Chromium samples it on BEST_EFFORT tasks. Those don't run until
        // Chromium's startup is complete: when a visible tab has loaded and gone idle (chrome/browser/
        // after_startup_task_utils.cc), else after a 3-minute failsafe. linear.app keeps its page busy, so it counts as
        // loaded only a minute after it stops loading (kWaitingForIdleTimeout): the first CPU came 68 s after launch in
        // three runs, never in polish4's 36 s (artifacts/settingsshots/REPORT.md). So wait until past the failsafe, then
        // for the demo pages to settle (every process sampled, each under 60 %, three refreshes after the first CPU).
        step { [self] done in
            let launched = NSRunningApplication.current.launchDate ?? Date()
            note(String(format: "marketing: task-manager: opened %.1f s after launch", Date().timeIntervalSince(launched)))
            let deadline = max(Date().addingTimeInterval(12), launched.addingTimeInterval(200))
            var firstCPU: Date?, noted = false
            func poll() {
                let rows = TaskManagerWindow.shared?.shown ?? []
                let processes = rows.filter(\.firstOfProcess)
                if firstCPU == nil, rows.contains(where: { $0.cpu != nil }) {
                    firstCPU = Date()
                    note(String(format: "marketing: task-manager: first CPU %.1f s after launch", Date().timeIntervalSince(launched)))
                }
                let settled = firstCPU.map { Date().timeIntervalSince($0) > 3.2 } ?? false
                    && !processes.isEmpty && processes.allSatisfy { ($0.cpu ?? 100) < 60 }
                if settled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                } else if Date() > deadline {
                    note(firstCPU == nil ? "marketing: MISSING task-manager: no CPU from the engine"
                                         : "marketing: task-manager: CPU not settled (\(processes.map { $0.cpu.map { String(format: "%.1f", $0) } ?? "-" }))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                } else {
                    if firstCPU == nil, !noted, Date().timeIntervalSince(launched) > 12 {
                        noted = true
                        note(String(format: "marketing: task-manager: no CPU yet; waiting for Chromium's startup failsafe (until %.0f s after launch)",
                                    deadline.timeIntervalSince(launched)))
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                }
            }
            poll()
        }
        mkWindowShot("task-manager") { [self] frame in
            guard let w = TaskManagerWindow.shared?.window, let view = w.contentView, let img = mkContentImage(w) else { return [] }
            let size = view.bounds.size
            note("marketing: task manager rows: \(TaskManagerWindow.shared?.shown.prefix(8).map { "\($0.title) cpu \($0.cpu.map { String(format: "%.1f", $0) } ?? "-")" } ?? [])")
            return [MarketingStudio.Layer(image: img, frame: NSRect(x: frame.maxX - size.width - 44, y: frame.minY + 44,
                                                                     width: size.width, height: size.height),
                                          dark: false, lights: mkLights(w), shadow: .window)]
        }
        run { TaskManagerWindow.shared?.window.close() }
    }
}
#endif

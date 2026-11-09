// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of the Task Manager (P20d), the marketing scenario's part "parityp20d"
/// (`scripts/marketing-shots.sh --parts parityp20d`):
///   - task-manager: Work on linear.app, Help › Troubleshooting › Open Task Manager over it: the demo's tabs, the
///     browser and its helpers with their memory, CPU and process IDs, sampled live.
extension SnapshotRunner {
    func mkParityP20dShots(_ d: MarketingDemo) {
        mkShow(d, "work", "linear")
        mkSettleShown()
        run { [self] in
            TaskManagerWindow.show(from: c.window, app: app)
            guard let w = TaskManagerWindow.shared?.window else { return note("marketing: MISSING task-manager: no window") }
            // Its own width, so all six columns show (Task, Profile, Memory Footprint, CPU, Network, Process ID).
            w.setContentSize(NSSize(width: 820, height: 360))
            // Drawn off screen, as the Settings shots are: it's composited over the browser window.
            w.setFrameOrigin(NSPoint(x: -6000, y: 200))
        }
        // CPU needs a second sample per process: wait until each process has one and the demo pages have settled (CPU
        // under 60 % each), at most 12 s.
        step { done in
            let start = Date()
            func poll() {
                let rows = TaskManagerWindow.shared?.shown ?? []
                let ready = !rows.isEmpty && rows.filter(\.firstOfProcess).allSatisfy { ($0.cpu ?? 100) < 60 }
                let waited = Date().timeIntervalSince(start)
                if (ready && waited > 2.2) || waited > 12 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                } else {
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

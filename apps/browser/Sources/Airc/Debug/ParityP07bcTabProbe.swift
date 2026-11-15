// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script parityp07bc-tabprobe`: where Tab → site search spends its main-thread time (parityp07's timing), section
/// by section (CommandBarView.enterScope's Perf sections), as parityp07 measures it: "yt", then Tab through the field's
/// command. Diagnostic only, never in the suite. Run it in a dedicated UI session too (AIRC_UI_DEDICATED_SESSION=1):
/// the app active with its window key is where suitegreen2 measured 26 ms.
extension SnapshotRunner {
    func parityP07bcTabProbe() {
        var bar: CommandBarView? { self.c.commandBar }
        var works: [Double] = []
        run { [self] in
            note("parityp07bc-tabprobe: app active \(NSApp.isActive), window key \(c.window.isKeyWindow), load \(Self.loadAverage())")
        }
        for i in 0..<10 {
            run { [self] in c.closeCommandBar(); c.openCommandBar(mode: .newTab); bar?.type("yt") }
            wait(0.2)
            step { [self] done in
                guard let b = bar, let ed = c.window.firstResponder as? NSTextView else {
                    note("parityp07bc-tabprobe: no field editor"); return done()
                }
                Perf.reset()
                Perf.enabled = true
                FrameTiming.measure({ _ = b.control(NSTextField(), textView: ed, doCommandBy: #selector(NSResponder.insertTab(_:))) }) { t in
                    Perf.enabled = false
                    works.append(t.work)
                    self.note(String(format: "parityp07bc-tabprobe %d: main %.2f ms, commit %.2f ms, after %.2f ms; ", i, t.work, t.frame, t.followUp) + Perf.report())
                    done()
                }
            }
            run { [self] in c.closeCommandBar() }
            wait(0.15)
        }
        run { [self] in
            let s = works.sorted()
            note(String(format: "parityp07bc-tabprobe: median %.2f ms, max %.2f ms (n=%d)", s.isEmpty ? -1 : s[s.count / 2], s.last ?? -1, s.count))
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// aidemo4's finding (2026-11-26), part of `--script agentmain` (`AIRC_AGENTMAIN_ONLY=blank`): a new task's tab, before
/// its first page (the model's first turn holds 2.5 s, as a real model's does), shows the card's own fill with
/// "Starting…", never the blank page's white, and its Today row is titled with the task, never "about:blank"; once the
/// first page has loaded, the page's own pixels and title.
extension AgentMainCheck {
    func caseBlank(_ done: @escaping () -> Void) {
        let task = "Count the tally once"
        k.start("blank", [.toolThenHold("wait", ["duration": 1], hold: 2.5), .tool("navigate", ["url": "\(base)/am-shop.html"]),
                          .toolThenHold("wait", ["duration": 4], hold: 0.5), .text("Done.")], task: task)
        var white = 0, samples = 0, covered = 0, rows: Set<String> = []
        var sampling = true
        func tick() {
            guard sampling else { return }
            if let e = entry, c.shownTabID == e.tabID, let page = e.page, page.url?.host == nil {
                samples += 1
                if let p = pagePicture(), look(p, want: nil).white > 0.5 { white += 1 }
                if chrome?.starting == true { covered += 1 }
                rows.insert(c.store.tab(e.tabID)?.title ?? "")
            }
            after(0.05, tick)
        }
        wait({ self.entry != nil }, 15) { [self] in
            tick()
            wait({ self.k.events.contains("tool navigate") }, 15) { [self] in
                sampling = false
                check(samples >= 10, "blank: the task's new tab was sampled before its first page (\(samples) samples)")
                check(white == 0, "blank: … never white in the main view (\(white) of \(samples) samples ≥ 50 % white)")
                check(covered == samples, "blank: … the card's fill with “Starting…” over it (\(covered) of \(samples))")
                let title = AgentTaskTitle.make(task)
                check(rows == [title], "blank: … its Today row says the task (“\(rows.sorted().joined(separator: "”, “"))”), never about:blank")
                wait({ self.chrome?.starting == false && self.entry?.page?.isLoading == false }, 10) { [self] in
                    after(0.4) { [self] in
                        if let p = pagePicture() {
                            let l = look(p, want: (0x1e, 0x8c, 0x7a))
                            check(l.match > 0.5 && l.white < 0.2, "blank: once the first page has loaded, the page's own pixels (teal \(Int(l.match * 100)) %, white \(Int(l.white * 100)) %)")
                        } else { note("FAIL-ENV agentmain \(engine): blank: no window-server picture") }
                        let t = entry.flatMap { c.store.tab($0.tabID)?.title } ?? ""
                        check(t.hasPrefix("Tally") || t.hasPrefix("Counted"), "blank: … and the row takes the page's title (“\(t)”)")
                        k.untilIdle(15) { done() }
                    }
                }
            }
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script cbperf` (code review H5): the Command Bar with a full history (20,000 synthetic entries, the per-profile
/// cap). Opens the bar, then types a query one key at a time and logs, per keystroke, the main thread's work, the time
/// to the frame that shows it, and when the off-main history matches reach the rows. Synthetic data, ephemeral store.
extension SnapshotRunner {
    func commandBarHistoryPerf() {
        newSpacePerf()
        let entries = HistoryStore.maxEntriesPerProfile
        run { [self] in
            guard let h = c.app?.history else { return }
            let profile = c.store.profile(ofSpace: c.currentSpaceID).id
            let t0 = CACurrentMediaTime()
            let words = ["page", "title", "docs", "issue", "pull", "search", "news", "video", "inbox", "settings", "project", "notes"]
            for i in 0..<entries {
                let host = "site\(i % 2_000).example\(i % 7 == 0 ? ".org" : ".com")"
                h.recordVisit(profileID: profile, url: "https://\(host)/path/\(i)",
                              title: "\(words[i % words.count].capitalized) \(words[(i / 12) % words.count]) \(i)", typed: i % 50 == 0)
            }
            h.recordVisit(profileID: profile, url: "https://github.com/", title: "GitHub", typed: true)
            note(String(format: "cbperf: seeded %d history entries in %.0f ms", entries, (CACurrentMediaTime() - t0) * 1000))
        }
        // A few Today tabs, so ⌘T lists recent tabs as it does in real use.
        run { [self] in
            for i in 0..<8 {
                _ = try? c.store.openTab(url: "https://site\(i).example.com/", inSpace: c.currentSpaceID, activate: false,
                                         title: "Recent page \(i)")
            }
            c.reloadAll(animated: false)
            Perf.enabled = true; Perf.reset()
        }
        wait(1)
        var opens: [Double] = []
        for _ in 0..<3 {
            step { [self] done in
                FrameTiming.measure({ self.c.openCommandBar(mode: .newTab) }) { t in opens.append(t.frame); done() }
            }
            wait(0.5)
            run { [self] in c.closeCommandBar() }
            wait(0.3)
        }
        run { [self] in
            note(String(format: "cbperf: open %@ ms to the commit (first, then reused)", opens.map { String(format: "%.2f", $0) }.joined(separator: ", ")))
            note("cbperf: open sections (avg ms) " + Perf.report())
            Perf.reset()
            c.openCommandBar(mode: .newTab)
        }
        wait(1)   // the index builds off the main thread while the bar is open
        var mainMs: [Double] = [], frameMs: [Double] = [], historyMs: [Double] = []
        for text in ["g", "gi", "git", "gith", "githu", "github", "site1", "site12", "page t", "page ti"] {
            step { [self] done in
                guard let bar = c.commandBar else { return done() }
                let t0 = CACurrentMediaTime()
                var arrived: Double?
                var hits = 0
                bar.onHistoryApplied = { n in arrived = CACurrentMediaTime(); hits = n }
                var mainWork = 0.0, frame = 0.0
                FrameTiming.measure({ bar.type(text) }) { t in mainWork = t.work; frame = t.frame }
                waitUntil({ arrived != nil }, timeout: 1) { [self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                        let h = arrived.map { ($0 - t0) * 1000 } ?? -1
                        mainMs.append(mainWork); frameMs.append(frame); historyMs.append(h)
                        note(String(format: "cbperf: “%@” main %.2f ms, frame %.2f ms, history %.2f ms (%d matches), inline %@", text,
                                    mainWork, frame, h, hits, bar.inlineText ?? "-"))
                        done()
                    }
                }
            }
        }
        run { [self] in
            func med(_ a: [Double]) -> Double { a.isEmpty ? -1 : a.sorted()[a.count / 2] }
            note(String(format: "cbperf: median per keystroke at %d entries: main %.2f ms (max %.2f), frame %.2f ms, history matches on screen after %.2f ms (max %.2f)",
                        entries, med(mainMs), mainMs.max() ?? -1, med(frameMs), med(historyMs), historyMs.max() ?? -1))
            note("cbperf: sections (avg ms) " + Perf.report())
            c.closeCommandBar()
        }
    }
}

extension SnapshotRunner {
    /// New Space, five times: Create → the commit that shows it, with the time per section (speed pass, budget 1 frame).
    func newSpacePerf() {
        run { Perf.enabled = true; Perf.reset() }
        var frames: [Double] = [], works: [Double] = []
        for i in 0..<5 {
            run { [self] in
                c.openNewSpacePanel()
                c.newSpacePanel?.model.name = "Perf \(i)"
            }
            wait(0.5)
            step { [self] done in
                FrameTiming.measure({ self.c.newSpacePanel?.model.onCreate?() }) { t in
                    frames.append(t.frame); works.append(t.work); done()
                }
            }
            wait(0.5)
        }
        run { [self] in
            func med(_ a: [Double]) -> Double { a.isEmpty ? -1 : a.sorted()[a.count / 2] }
            note(String(format: "newspace: median work %.2f ms, commit %.2f ms (samples %@)", med(works), med(frames),
                        frames.map { String(format: "%.1f", $0) }.joined(separator: " ")))
            note("newspace: sections (avg ms) " + Perf.report())
            Perf.reset()
            for s in c.store.orderedSpaces where s.name.hasPrefix("Perf ") { try? c.store.deleteSpace(s.id) }
            c.reloadAll(animated: false)
            c.switchToSpace(c.store.orderedSpaces[0].id, animated: false)
        }
        wait(0.5)
    }
}
#endif

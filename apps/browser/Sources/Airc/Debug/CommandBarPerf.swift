// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script cbperf` (code review H5): the Command Bar with a full history (20,000 synthetic entries, the per-profile
/// cap). Opens the bar, then types a query one key at a time and logs, per keystroke, the main thread's work, the time
/// to the frame that shows it, and when the off-main history matches reach the rows. Synthetic data, ephemeral store.
extension SnapshotRunner {
    func commandBarHistoryPerf() {
        // Launch to first paint: process start (kernel) → the first time the run loop waits after the window opened
        // (its first frame committed), as `--script perf` reports it. cbfirstkey compares it before/after its idle
        // prewarm, which must never delay it.
        step { [self] done in waitUntil({ PerfLaunch.interactiveAt != nil }, timeout: 10) { done() } }
        run { [self] in
            if let start = PerfLaunch.processStart, let ready = PerfLaunch.interactiveAt, let w = PerfLaunch.windowAt {
                note(String(format: "cbperf: launch to first paint %.1f ms (window %.1f ms, then %.1f ms to its first idle commit)",
                            ready.timeIntervalSince(start) * 1000, w.timeIntervalSince(start) * 1000, ready.timeIntervalSince(w) * 1000))
            }
        }
        // xctrace (cbfirstkey's profiles): time to attach Instruments before anything is measured.
        if let s = ProcessInfo.processInfo.environment["AIRC_CBPERF_ATTACH_WAIT"].flatMap(Double.init), s > 0 {
            run { [self] in note(String(format: "cbperf: waiting %.0f s for a profiler to attach (pid %d)", s, getpid())) }
            wait(s)
        }
        newSpacePerf()
        let entries = HistoryStore.maxEntriesPerProfile
        run { [self] in
            guard let h = c.app?.history else { return check(false, "cbperf: history store available") }
            let profile = c.store.profile(ofSpace: c.currentSpaceID).id
            app?.settings.values.suggestionsEnabled = false
            h.clear(profileID: profile)
            let t0 = CACurrentMediaTime()
            let words = ["page", "title", "docs", "issue", "pull", "search", "news", "video", "inbox", "settings", "project", "notes"]
            // Reserve one slot for GitHub: crossing the cap benchmarks pruning instead of a full history.
            for i in 0..<(entries - 1) {
                let host = "site\(i % 2_000).example\(i % 7 == 0 ? ".org" : ".com")"
                h.recordVisit(profileID: profile, url: "https://\(host)/path/\(i)",
                              title: "\(words[i % words.count].capitalized) \(words[(i / 12) % words.count]) \(i)", typed: i % 50 == 0)
            }
            h.recordVisit(profileID: profile, url: "https://github.com/", title: "GitHub", typed: true)
            check(h.entries(ofProfile: profile).count == entries, "cbperf: fixture contains exactly \(entries) entries (actual \(h.entries(ofProfile: profile).count))")
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
        step { [self] done in
            guard let source = c.commandBarHistory else {
                check(false, "cbperf: history source available"); return done()
            }
            waitUntil({ source.store.indexSnapshot(profileID: source.profileID)?.count == entries }, timeout: 15) { [self] in
                check(source.store.indexSnapshot(profileID: source.profileID)?.count == entries, "cbperf: full history index ready before timing")
                done()
            }
        }
        run { Perf.reset() }   // the opening's sections are reported above; from here, the keystrokes'
        var mainMs: [Double] = [], frameMs: [Double] = [], historyMs: [Double] = []
        let queries = ["g", "gi", "git", "gith", "githu", "github", "site1", "site12", "page t", "page ti"]
        for text in queries {
            step { [self] done in
                guard let bar = c.commandBar else {
                    check(false, "cbperf: command bar available for “\(text)”"); return done()
                }
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
                        if mainMs.count == 1 {
                            // The first keystroke on its own: what a cold path costs (cbfirstkey).
                            note("cbperf: first key sections (avg ms) " + Perf.report())
                            Perf.reset()
                        }
                        check(hits > 0 && bar.results.contains { $0.historyURL != nil }, "cbperf: “\(text)” applies nonzero history matches and renders history rows (\(hits))")
                        bar.onHistoryApplied = nil
                        done()
                    }
                }
            }
        }
        run { [self] in
            func med(_ a: [Double]) -> Double { a.isEmpty ? -1 : a.sorted()[a.count / 2] }
            note(String(format: "cbperf: median per keystroke at %d entries: main %.2f ms (max %.2f), frame %.2f ms, history matches on screen after %.2f ms (max %.2f)",
                        entries, med(mainMs), mainMs.max() ?? -1, med(frameMs), med(historyMs), historyMs.max() ?? -1))
            note("cbperf: sections after the first key (avg ms) " + Perf.report())
            let ix = c.commandIndex.stats
            note(String(format: "cbperf: command index at idle: %d builds in %d slices, longest slice %.2f ms; spelling panel made at idle in %.1f ms (-1: not by the index)",
                        ix.builds, ix.slices, ix.maxSliceMs, ix.spellingPanelMs))
            note("cbperf: command candidate blocks made \(c.commandIndex.blocksMade) (cbrows: one per change of the commands, not per key)")
            // cbfirstkey: one 120 Hz frame for the first keystroke, 4 ms for the median, on the main thread. Asserted in
            // a dedicated session (the window key and active, nothing else of ours on the Mac: AIRC_UI_DEDICATED_SESSION=1);
            // other runs (background windows, shared CPU) only report them.
            let first = mainMs.first ?? -1, median = med(mainMs)
            if ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" {
                check(first >= 0 && first <= 8.3, String(format: "cbperf: first keystroke main thread %.2f ms ≤ 8.3 ms (one 120 Hz frame)", first))
                check(median >= 0 && median <= 4, String(format: "cbperf: median keystroke main thread %.2f ms ≤ 4 ms", median))
            } else {
                note(String(format: "cbperf: budgets not asserted (not a dedicated session): first %.2f ms (≤ 8.3), median %.2f ms (≤ 4)", first, median))
            }
        }
        // After the timings: each query again, its rows (history refined) against the unindexed path's.
        for text in queries + ["/", "/rel", "full", "speak", "copy url", "tidy", "block"] {
            run { [self] in c.commandBar?.type(text) }
            wait(0.4)
            run { [self] in if let bar = c.commandBar { checkCommandIndexParity(bar, text) } }
        }
        // Services (owner bug, 2026-11-15): other apps' services in Airc › Services ("Ask Claude", "Send to Claude",
        // "Encode Selected Audio Files") were listed as dead commands. None may become one, including one planted now.
        var serviceTitles: [String] = []
        run { [self] in
            let planted = NSMenuItem(title: "Airc Check Planted Service", action: NSSelectorFromString("_doUserService:"), keyEquivalent: "")
            NSApp.servicesMenu?.addItem(planted)
            defer { NSApp.servicesMenu?.removeItem(planted) }
            serviceTitles = (NSApp.servicesMenu?.items ?? []).filter { !$0.isSeparatorItem && !$0.title.isEmpty }.map(\.title)
            let walked = ParityCommandCatalog.entries(of: NSApp.mainMenu)
            let leaked = walked.filter { $0.item.menu === NSApp.servicesMenu || ParityCommandCatalog.isService($0.item) }.map(\.item.title)
            let made = Set(c.makeMenuCommandActions().map(\.title))
            check(NSApp.servicesMenu != nil && leaked.isEmpty && !made.contains(planted.title),
                  "cbperf: no Services menu item becomes a Command Bar command (\(serviceTitles.count) services incl. a planted one; leaked: \(leaked))")
        }
        run { [self] in c.commandBar?.type("/claude") }
        wait(0.4)
        run { [self] in
            let titles = c.commandBar?.results.map(\.title) ?? []
            let services = titles.filter { serviceTitles.contains($0) }
            check(titles.contains(AgentsConnect.commandTitle) && services.isEmpty,
                  "cbperf: “/claude” lists Connect Claude and no Services rows (rows: \(titles))")
        }
        run { [self] in c.closeCommandBar() }
    }

    /// The rows the bar shows for `text` are the ones the synchronous path (every menu walked and validated now, no
    /// prepared index) makes for it: same titles, order, kinds and keys (cbfirstkey: the index must change nothing).
    func checkCommandIndexParity(_ bar: CommandBarView, _ text: String) {
        func rows(_ r: [CommandResult]) -> [String] {
            r.map { "\($0.title)|\($0.subtitle)|\($0.badge)|\($0.shortcut.joined())|\($0.historyURL ?? "")|\($0.selectionID)" }
        }
        let shown = rows(bar.results)
        let direct = rows(bar.resultsWithoutCommandIndexForTesting())
        check(shown == direct, "cbperf: “\(text)” rows match the unindexed path (\(shown.count) rows)"
              + (shown == direct ? "" : "\n  shown: \(shown)\n  direct: \(direct)"))
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

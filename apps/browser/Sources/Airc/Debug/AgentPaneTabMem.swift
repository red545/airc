// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import Darwin

/// cardflicker, opt-in only (`AIRC_AGENTPANE2_ONLY=tabmem`): engine patch 042 holds a hidden view's compositor for
/// 250 ms, but only for the page the agent pane's live card shows. With the card closed, tab switches must cost what
/// they did: six loopback tabs in the window, 60 switches 150 ms apart, then the physical footprint of every process
/// Airc owns (the app, Chromium's GPU and renderer helpers; WebKit's services) right after and 2 s later, against the
/// same before. A report for an A/B between engines, not a budget: it checks only that no agent page is held.
extension AgentPane2Check {
    func caseTabMem(_ done: @escaping () -> Void) {
        let urls = (1...6).map { "\(k.base)/tabmem-\($0).html" }
        for i in urls.indices {
            k.extraPages["/tabmem-\(i + 1).html"] = "<title>Tab \(i + 1)</title><style>body{margin:0;font:24px sans-serif;background:hsl(\(i * 50),60%,85%)}</style><h1>Tab \(i + 1)</h1><p>"
                + String(repeating: "Some text for the page to lay out. ", count: 200) + "</p>"
        }
        let first = c.shownTabID
        for u in urls { c.navigate(to: URL(string: u)!, newTab: true) }
        func id(of u: String) -> String? { c.store.state.tabs.values.first { $0.url == u }?.id }
        wait({ urls.allSatisfy { id(of: $0) != nil } }, 20) { [self] in
            let ids = urls.compactMap(id(of:))
            check(ids.count == 6, "tabmem: six loopback tabs open (\(ids.count))")
            // AIRC_TABMEM_HOLD=1: the other arm, every tab held (what the hold costs where it is on).
            let held = ProcessInfo.processInfo.environment["AIRC_TABMEM_HOLD"] == "1"
            #if canImport(AircCore)
            for id in ids { (c.engineTab(for: id) as? ChromiumTab)?.core.holdsFramesOnHide = held }
            #endif
            note("agentpane2 \(engine): tabmem: arm \(held ? "hold on (every tab)" : "hold off (card closed)")")
            check(held || AgentRunCenter.shared.runWindowID == nil || AgentPaneLiveView.current?.window == nil,
                  "tabmem: no live card shows an agent page (the hold is off for every page)")
            // Each shown once, then settle.
            var i = 0
            func warm() {
                guard i < ids.count else { return after(3) { measure() } }
                c.show(ids[i], focus: false); i += 1
                after(0.4, warm)
            }
            func measure() {
                let before = Self.ownedFootprints()
                let t0 = CACurrentMediaTime()
                var n = 0
                func flip() {
                    guard n < 60 else {
                        let right = Self.ownedFootprints()
                        let switching = CACurrentMediaTime() - t0
                        return after(2) {
                            let later = Self.ownedFootprints()
                            func line(_ f: [String: Double]) -> String { f.keys.sorted().map { "\($0) \(String(format: "%.1f", f[$0]!))" }.joined(separator: ", ") }
                            func total(_ f: [String: Double]) -> Double { f.values.reduce(0, +) }
                            self.note("agentpane2 \(self.engine): tabmem: 60 switches in \(String(format: "%.1f", switching)) s; footprint MB total before \(String(format: "%.1f", total(before))), right after \(String(format: "%.1f", total(right))), 2 s later \(String(format: "%.1f", total(later)))")
                            self.note("agentpane2 \(self.engine): tabmem: before [\(line(before))]")
                            self.note("agentpane2 \(self.engine): tabmem: right after [\(line(right))]")
                            self.note("agentpane2 \(self.engine): tabmem: 2 s later [\(line(later))]")
                            self.check(total(before) > 0, "tabmem: footprints read (\(before.count) kinds)")
                            for id in ids { self.c.closeTab(id) }
                            if let first { self.c.show(first, focus: false) }
                            done()
                        }
                    }
                    c.show(ids[n % ids.count], focus: false); n += 1
                    after(0.15, flip)
                }
                flip()
            }
            warm()
        }
    }

    /// Physical footprint (MB) of every process Airc owns, summed per kind (main, gpu-process, renderer, …).
    static func ownedFootprints() -> [String: Double] {
        var out: [String: Double] = [:]
        for (pid, p) in SnapshotRunner.ownedProcessCPU() {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            out[p.kind, default: 0] += Double(info.ri_phys_footprint) / 1e6
        }
        return out
    }
}
#endif

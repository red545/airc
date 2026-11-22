// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// agentfix, `--script agentfixquote` (both engines), review21's Share Quote chip leak: 20 times, a window opens, its page
/// has a selection worth a Share Quote chip, the chip shows, and the window closes with the chip on screen. Afterwards no
/// chip may outlive its window controller and no closed window's chip may still run its 0.5 s poll (the chips sat in a
/// weak-to-strong NSMapTable that AppKit never purges, and the poll returned without stopping when its window was
/// gone). Memory, and closed windows' controllers that stay alive for other reasons, are logged.
extension SnapshotRunner {
    private static func agentFixFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : 0
    }

    func agentFixQuoteScenario() {
        let engine = app?.engine is WebKitEngine ? "webkit" : "chromium"
        let tag = "agentfixquote \(engine)"
        let sentence = "Quiet harbours keep their lanterns lit long after the ferries stop"
        var server: LocalPageServer?
        var url = ""
        let closed = NSHashTable<WindowController>.weakObjects()
        var opened: [String] = []
        var shown = 0
        var memory: [Double] = []
        let cycles = 20
        let sharedBefore = app?.settings.values.sharedQuotes

        step { [self] done in
            server = LocalPageServer(responses: ["/quote": .init(body: "<!doctype html><title>quote</title><style>body{font:22px sans-serif}</style><p id=q>\(sentence).</p>")])
            server?.start { port in
                url = "http://127.0.0.1:\(port ?? 0)/quote"
                self.app?.settings.values.sharedQuotes = true
                if self.c.sidebarHidden { self.c.toggleSidebar() }
                done()
            }
        }
        /// One window: its page, the selection, the chip on screen, then the window closes.
        func cycle(_ i: Int) {
            step { [self] done in
                guard let b = app?.openNewWindow(from: c, commandBar: false) else { check(false, "\(tag): window \(i) opens"); return done() }
                b.navigate(to: URL(string: url)!, newTab: true)
                let id = b.shownTabID ?? ""
                opened.append(id)
                waitUntil({ b.engineTab(for: id)?.isLoading == false && b.engineTab(for: id)?.title == "quote" }, timeout: 10) { [self] in
                    b.engineTab(for: id)?.evaluate("getSelection().selectAllChildren(document.getElementById('q'));1") { _ in
                        b.quotePill?.refresh()
                        self.waitUntil({ b.quotePill?.isHidden == false }, timeout: 4) { [self] in
                            if b.quotePill?.isHidden == false { shown += 1 }
                            closed.add(b)
                            b.window.close()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                if i == 1 || i % 5 == 0 { memory.append(Self.agentFixFootprintMB()) }
                                done()
                            }
                        }
                    }
                }
            }
        }
        for i in 1...cycles { cycle(i) }
        // Closed windows' controllers may take a moment to go (an engine tears its pages down asynchronously).
        step { [self] done in waitUntil({ closed.allObjects.isEmpty }, timeout: 10, then: done) }
        run { [self] in
            let open = Set((app?.controllers ?? []).map(ObjectIdentifier.init))
            let chips = QuotePillView.allForTesting.allObjects
            let ownerless = chips.filter { $0.controller == nil }
            let ofClosed = chips.filter { $0.controller.map { !open.contains(ObjectIdentifier($0)) } ?? true }
            let polling = ofClosed.filter(\.pollingForTesting)
            check(shown == cycles, "\(tag): the chip showed in each of the \(cycles) windows before it closed (\(shown))")
            note("\(tag): after \(cycles) open/close cycles: \(chips.count) chips alive, \(ownerless.count) without a window controller, \(ofClosed.count) of closed windows, \(polling.count) of those polling; closed windows' controllers still alive \(closed.allObjects.count); open windows \(open.count)")
            check(ownerless.isEmpty, "\(tag): no Share Quote chip outlives its window controller (\(ownerless.count) of \(chips.count) do)")
            check(polling.isEmpty, "\(tag): no closed window's chip keeps its 0.5 s timer running (\(polling.count) do)")
            if !closed.allObjects.isEmpty {
                note("NOTE \(tag): \(closed.allObjects.count) closed windows' controllers are still alive 10 s after closing (held elsewhere, not by their chips); their chips go with them")
            }
            note("\(tag): memory (phys_footprint MB) after cycles 1, 5, 10, 15, 20: \(memory.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        }
        // The chip keeps its stopped timer stopped (a running poll would show here a few seconds later too).
        wait(1.5)
        run { [self] in
            let open = Set((app?.controllers ?? []).map(ObjectIdentifier.init))
            let polling = QuotePillView.allForTesting.allObjects.filter { $0.pollingForTesting && ($0.controller.map { !open.contains(ObjectIdentifier($0)) } ?? true) }
            check(polling.isEmpty, "\(tag): … still none 1.5 s later (\(polling.count))")
            for id in opened { _ = try? c.store.closeTab(id) }
            if let s = sharedBefore { app?.settings.values.sharedQuotes = s }
            server?.stop()
        }
    }
}
#endif

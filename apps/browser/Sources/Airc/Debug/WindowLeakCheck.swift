// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// windowleak, `--script windowleak` (both engines): 20 times, a window opens with a page and closes. After each close
/// the allocator's large-block cache is flushed (AllocatorCacheFlush) and the main process's phys_footprint sampled.
/// Every closed window's objects are watched through weak references: its controller, NSWindow, content view, root and
/// card views, engine window and host view, and its page (engine tab and page view; on Chromium also the engine's
/// AircWindow and AircTab). All must be gone a few seconds after the last close, and the footprint must stay flat.
/// AIRC_WINDOWLEAK_HOLD=<s> (leak hunting): before the assertions, the survivors' addresses are logged and the app waits
/// that long, so `leaks <pid> --traceTree=<address>` can show what holds them.
extension SnapshotRunner {
    private static func windowLeakFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : 0
    }

    func windowLeakScenario() {
        let engine = app?.engine is WebKitEngine ? "webkit" : "chromium"
        let tag = "windowleak \(engine)"
        let cycles = 20
        var server: LocalPageServer?
        var url = ""
        var opened: [String] = []
        var memory: [Double] = []
        var loaded = 0
        let env = ProcessInfo.processInfo.environment
        let hold = Double(env["AIRC_WINDOWLEAK_HOLD"] ?? "") ?? 0
        // AIRC_WINDOWLEAK_CLOSE=direct|perform; with AIRC_REAL_KEYS=1 (FG runs) the default is a real ⌘⇧W.
        let closeMode = env["AIRC_WINDOWLEAK_CLOSE"] ?? (env["AIRC_REAL_KEYS"] == "1" ? "key" : "perform")
        var closes: [String: Int] = [:]
        var closeFailures = 0
        // kind → the closed windows' objects of that kind, weakly.
        let kinds = ["controller", "NSWindow", "contentView", "root", "card", "engineWindow", "hostView", "page", "pageView",
                     "AircWindow", "AircTab"]
        var probes: [String: NSHashTable<AnyObject>] = [:]
        for k in kinds { probes[k] = NSHashTable<AnyObject>.weakObjects() }
        var registered: [String: Int] = [:]
        func watch(_ kind: String, _ object: AnyObject?) {
            guard let object else { return }
            probes[kind]?.add(object)
            registered[kind, default: 0] += 1
        }
        func alive(_ kind: String) -> [AnyObject] { probes[kind]?.allObjects ?? [] }
        func sample() -> Double {
            AllocatorCacheFlush.flush()
            return Self.windowLeakFootprintMB()
        }

        step { [self] done in
            // A plain synthetic page with some text and an image-like block, so a page has a real layer tree.
            let body = "<!doctype html><title>leak</title><style>body{font:20px sans-serif;margin:40px}div{width:600px;height:300px;"
                + "background:linear-gradient(90deg,#c7d2fe,#fbcfe8)}</style><h1>Window leak probe</h1><p>Quiet harbours keep their "
                + "lanterns lit long after the ferries stop.</p><div></div>"
            server = LocalPageServer(responses: ["/leak": .init(body: body)])
            server?.start { port in
                url = "http://127.0.0.1:\(port ?? 0)/leak"
                done()
            }
        }
        step { [self] done in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.note("\(tag): memory before the first window \(String(format: "%.1f", sample())) MB")
                done()
            }
        }
        func cycle(_ i: Int) {
            step { [self] done in
                guard let b = app?.openNewWindow(from: c, commandBar: false) else { check(false, "\(tag): window \(i) opens"); return done() }
                b.navigate(to: URL(string: url)!, newTab: true)
                let id = b.shownTabID ?? ""
                opened.append(id)
                waitUntil({ b.engineTab(for: id)?.isLoading == false && b.engineTab(for: id)?.title == "leak" }, timeout: 10) { [self] in
                    let page = b.engineTab(for: id)
                    if page?.title == "leak" { loaded += 1 }
                    watch("controller", b)
                    watch("NSWindow", b.window)
                    watch("contentView", b.window.contentView)
                    watch("root", b.root)
                    watch("card", b.card)
                    watch("engineWindow", b.engineWindow as AnyObject)
                    watch("hostView", b.engineWindow.hostView)
                    watch("page", page.map { $0 as AnyObject })
                    watch("pageView", page?.view)
                    #if canImport(AircCore)
                    watch("AircWindow", (b.engineWindow as? ChromiumWindow)?.core)
                    watch("AircTab", (page as? ChromiumTab)?.core)
                    #endif
                    // Weak: the real key's completion is released on the driver's background queue, and a Chromium window's
                    // engine objects must never be freed off the main thread (they were, through this closure: a SIGTRAP).
                    let after = { [self, weak b] in
                        waitUntil({ b.map { w in !w.window.isVisible && !(self.app?.controllers ?? []).contains { $0 === w } } ?? true },
                                  timeout: 6) { [self, weak b] in
                            if b?.window.isVisible == true { closeFailures += 1 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                memory.append(sample())
                                done()
                            }
                        }
                    }
                    switch closeMode {
                    case "direct":
                        // NSWindow.close() straight away: no windowShouldClose, so the engine hears of it only from AppKit.
                        closes["direct", default: 0] += 1
                        b.window.close(); after()
                    case "key" where UIDriverClient.available:
                        // A real ⌘⇧W (Close Window) to our key window.
                        b.window.makeKeyAndOrderFront(nil)
                        waitUntil({ [weak b] in b?.window.isKeyWindow ?? true }, timeout: 3) { [weak b] in
                            UIDriverClient.press(["cmd+shift+w"], pid: getpid()) { [weak b] ok, _ in
                                closes[ok ? "real ⌘⇧W" : "performClose (driver refused)", default: 0] += 1
                                if !ok { b?.window.performClose(nil) }
                                after()
                            }
                        }
                    default:
                        // The person's close (⌘⇧W, the close button): windowShouldClose, the engine's beforeunload pass.
                        closes["performClose", default: 0] += 1
                        b.window.performClose(nil); after()
                    }
                }
            }
        }
        for i in 1...cycles { cycle(i) }
        // An engine tears its pages down asynchronously: give the closed windows' objects a moment to go.
        step { [self] done in
            waitUntil({ kinds.allSatisfy { alive($0).isEmpty } }, timeout: 12, then: done)
        }
        run { [self] in
            memory.append(sample())
            let counts = kinds.filter { registered[$0] != nil }.map { "\($0) \(alive($0).count)/\(registered[$0] ?? 0)" }
            note("\(tag): closed windows' objects still alive after \(cycles) cycles: \(counts.joined(separator: ", "))")
            note("\(tag): memory (phys_footprint MB, after a malloc cache flush) after cycles 1…\(cycles), then settled: "
                 + memory.map { String(format: "%.1f", $0) }.joined(separator: ", "))
            if hold > 0 {
                let addresses = kinds.compactMap { k in alive(k).first.map { "\(k)=\(Unmanaged.passUnretained($0).toOpaque())" } }
                note("WINDOWLEAK-HOLD pid=\(getpid()) \(addresses.joined(separator: " "))")
            }
        }
        if hold > 0 {
            for _ in 0..<Int((hold / 10).rounded(.up)) { wait(10) }
            run { [self] in note("\(tag): hold over") }
        }
        // AIRC_WINDOWLEAK_PROBE=1 (leak hunting; `leaks`/`heap` can't read Chromium's PartitionAlloc heap): experiments on
        // the survivors, one at a time, each followed by a recount.
        if env["AIRC_WINDOWLEAK_PROBE"] == "1" {
            func recount(_ what: String) {
                wait(2)
                run { [self] in
                    let counts = kinds.filter { registered[$0] != nil && !alive($0).isEmpty }.map { "\($0) \(alive($0).count)" }
                    note("PROBE \(tag) after \(what): alive \(counts.isEmpty ? "none" : counts.joined(separator: ", "))")
                }
            }
            run { [self] in
                for case let w as NSWindow in alive("NSWindow") {
                    let inList = NSApp.windows.contains { $0 === w }
                    note("PROBE \(tag): survivor \(w.className) #\(w.windowNumber) visible \(w.isVisible) key \(w === NSApp.keyWindow) "
                         + "main \(w === NSApp.mainWindow) in NSApp.windows \(inList) retain \(CFGetRetainCount(w)) "
                         + "delegate \(w.delegate.map { String(describing: type(of: $0)) } ?? "nil") firstResponder "
                         + "\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
                }
                for p in alive("page") { note("PROBE \(tag): page \(type(of: p)) retain \(CFGetRetainCount(p))") }
                for v in alive("root") { note("PROBE \(tag): root retain \(CFGetRetainCount(v)) window \((v as? NSView)?.window.map { "#\($0.windowNumber)" } ?? "nil")") }
            }
            run {
                // AppKit's tool tip manager keeps views that have a tool tip (the sidebar rows' sharing indicator).
                for case let w as NSWindow in alive("NSWindow") {
                    func clear(_ v: NSView) { v.toolTip = nil; v.removeAllToolTips(); v.subviews.forEach(clear) }
                    w.contentView.map(clear)
                }
            }
            recount("clearing tool tips")
            run {
                for case let w as NSWindow in alive("NSWindow") { _ = w.makeFirstResponder(nil) }
            }
            recount("resigning first responder")
            run {
                for case let w as NSWindow in alive("NSWindow") { w.contentView?.subviews.forEach { $0.removeFromSuperview() } }
            }
            recount("detaching the content view's subviews")
        }
        // On Chromium the last closed window's NSWindow (and what hangs off it) stays until the next window closes: one
        // slot, not a leak (artifacts/windowleak/REPORT.md). So: at most one closed window's objects before one more
        // window opens and closes (not watched), and none after it.
        var survivorsBefore: [String: Int] = [:]
        run { for k in kinds where registered[k] != nil { survivorsBefore[k] = alive(k).count } }
        step { [self] done in
            guard let b = app?.openNewWindow(from: c, commandBar: false) else { check(false, "\(tag): one more window opens"); return done() }
            b.navigate(to: URL(string: url)!, newTab: true)
            let id = b.shownTabID ?? ""
            opened.append(id)
            waitUntil({ b.engineTab(for: id)?.isLoading == false }, timeout: 10) { [self] in
                b.window.performClose(nil)
                waitUntil({ kinds.allSatisfy { alive($0).isEmpty } }, timeout: 8, then: done)
            }
        }
        run { [self] in
            note("\(tag): closed by \(closes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            check(loaded == cycles, "\(tag): the page loaded in each of the \(cycles) windows (\(loaded))")
            check(closeFailures == 0, "\(tag): each window closed (\(closeFailures) still on screen 6 s later)")
            for k in kinds where registered[k] != nil {
                check((survivorsBefore[k] ?? 0) <= 1, "\(tag): at most the last closed window's \(k) is still alive before the next "
                      + "window (\(survivorsBefore[k] ?? 0) of \(registered[k] ?? 0))")
                check(alive(k).isEmpty, "\(tag): no closed window's \(k) outlives the next window's close (\(alive(k).count) of "
                      + "\(registered[k] ?? 0) alive)")
            }
            // Flat within noise: from cycle 5 (caches warm) to the settled sample, under 1 MB per window on average.
            if memory.count > cycles, memory[4] > 0 {
                let growth = memory[cycles] - memory[4]
                check(growth < Double(cycles - 5),
                      "\(tag): the footprint stays flat over \(cycles) windows (cycle 5 \(String(format: "%.1f", memory[4])) MB → settled "
                      + "\(String(format: "%.1f", memory[cycles])) MB, \(String(format: "%+.1f", growth)) MB; limit \(cycles - 5) MB)")
            } else {
                check(false, "\(tag): memory samples taken (\(memory.count))")
            }
            for id in opened { _ = try? c.store.closeTab(id) }
            server?.stop()
        }
    }
}
#endif

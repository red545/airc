// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// One windowleak cycle's window, weakly, for the diagnostics.
final class WindowLeakCycle {
    weak var window: NSWindow?
    weak var root: AnyObject?
    weak var page: AnyObject?
    weak var engineWindow: AnyObject?
    var state = ""
    var frame = ""
    var aliveAt: [Int] = []   // the later cycles whose samples still found this NSWindow alive
}

/// windowleak, `--script windowleak` (both engines): 20 times, a window opens with a page and closes. After each close
/// the allocator's large-block cache is flushed (AllocatorCacheFlush) and the main process's phys_footprint sampled.
/// Every closed window's objects are watched through weak references: its controller, NSWindow, content view, root and
/// card views, engine window and host view, and its page (engine tab and page view; on Chromium also the engine's
/// AircWindow and AircTab). All must be gone a few seconds after the last close, and the footprint must stay flat.
/// AIRC_WINDOWLEAK_HOLD=<s> (leak hunting): before the assertions, the survivors' addresses are logged and the app waits
/// that long, so `leaks <pid> --traceTree=<address>` can show what holds them.
/// AppKit keeps the last window that heard of the pointer until the next mouse event, and buildmac's pointer never moves:
/// so before counting, a mouse-moved event where the pointer rests stands in for the person's (second windowleak task).
/// The tab preview pictures kept for rows under that resting pointer (TabPreviewCache, bounded) are left out of the
/// footprint. A closed window still alive after that gets DIAG lines: which cycle, its state at close, how long it lives.
extension SnapshotRunner {
    private static func windowLeakFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : 0
    }

    /// A mouse-moved event where the real pointer rests, posted to an open window: AppKit's mouse tracking (enter and exit,
    /// cursor updates) hears of the pointer again without it moving.
    static func windowLeakPostMouseMoved() {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.windowNumber > 0 }) else { return }
        let p = w.convertPoint(fromScreen: NSEvent.mouseLocation)
        if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// Our helper processes (Chromium's renderers, GPU, utility; WebKit's run under launchd, so none there).
    private static func windowLeakChildren() -> Int {
        var children = [pid_t](repeating: 0, count: 512)
        let n = proc_listchildpids(getpid(), &children, Int32(children.count * MemoryLayout<pid_t>.size))
        return n > 0 ? children.prefix(Int(n)).filter { $0 > 0 }.count : 0
    }

    func windowLeakScenario() {
        let engine = app?.engine is WebKitEngine ? "webkit" : "chromium"
        let tag = "windowleak \(engine)"
        let env = ProcessInfo.processInfo.environment
        // AIRC_WINDOWLEAK_CYCLES=<n> (leak hunting): more cycles per launch; the footprint limit scales with it.
        let cycles = max(6, Int(env["AIRC_WINDOWLEAK_CYCLES"] ?? "") ?? 20)
        var server: LocalPageServer?
        var url = ""
        var opened: [String] = []
        var memory: [Double] = []
        var helpers: [Int] = []
        var previewMB: [Double] = []
        var loaded = 0
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
        // Per cycle (diagnostics): its NSWindow, root view and page, weakly, and the state at its close, so a survivor can
        // be named by cycle and its lifetime followed (release068 W and release074 C each kept one earlier window).
        var records: [Int: WindowLeakCycle] = [:]
        func recordState(_ w: NSWindow) -> String {
            let mouse = NSEvent.mouseLocation
            let local = w.convertPoint(fromScreen: mouse)
            var hit = w.contentView?.superview?.hitTest(local)
            var hitPath: [String] = []
            var tip = false
            while let v = hit, hitPath.count < 4 { hitPath.append(String(describing: type(of: v))); if v.toolTip != nil { tip = true }; hit = v.superview }
            return "active \(NSApp.isActive) key \(w.isKeyWindow) main \(w.isMainWindow) onSpace \(w.isOnActiveSpace) "
                + "occlVisible \(w.occlusionState.contains(.visible)) mouseIn \(w.frame.contains(mouse)) "
                + "keyWindow \(NSApp.keyWindow.map { "#\($0.windowNumber)" } ?? "nil") windows \(NSApp.windows.count) "
                + "hit \(w.frame.contains(mouse) ? hitPath.joined(separator: "<") : "-") tip \(tip)"
        }
        let started = Date()
        func t() -> String { String(format: "%.2f s", Date().timeIntervalSince(started)) }
        // The tab preview pictures (TabPreviewCache: at most 24, ~1 MB each) are left out of the footprint: with the
        // pointer resting on the sidebar, each new window's row under it is pictured (a hover), by design and bounded.
        var rawMemory: [Double] = []
        func sample() -> Double {
            AllocatorCacheFlush.flush()
            let raw = Self.windowLeakFootprintMB()
            rawMemory.append(raw)
            return raw - Double(TabPreviewCache.shared.storedBytes) / 1e6
        }
        // AppKit keeps the last window under the pointer until the next mouse event (artifacts/windowleak/REPORT.md, the
        // second task). buildmac's pointer never moves, so before counting, a mouse-moved event where it rests stands in
        // for the person's pointer. AIRC_WINDOWLEAK_NOMOVE=1 leaves it out (the A/B).
        let postsMove = env["AIRC_WINDOWLEAK_NOMOVE"] != "1"
        func pointerEvent() { if postsMove { Self.windowLeakPostMouseMoved() } }
        // AIRC_WINDOWLEAK_KEEP=<cycle> (the check's own test): that cycle's NSWindow is kept, as a leaking cache would, so
        // the run must go red with DIAG lines, pointer event or not.
        let keep = Int(env["AIRC_WINDOWLEAK_KEEP"] ?? "") ?? 0
        var kept: [NSWindow] = []

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
                    let rec = WindowLeakCycle()
                    rec.window = b.window; rec.root = b.root; rec.page = page.map { $0 as AnyObject }
                    rec.engineWindow = b.engineWindow as AnyObject
                    records[i] = rec
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
                    rec.frame = "\(b.window.frame)"
                    if keep == i { kept.append(b.window) }
                    rec.state = "#\(b.window.windowNumber) at close (\(t())): " + recordState(b.window)
                    // Weak: the real key's completion is released on the driver's background queue, and a Chromium window's
                    // engine objects must never be freed off the main thread (they were, through this closure: a SIGTRAP).
                    let after = { [self, weak b] in
                        waitUntil({ b.map { w in !w.window.isVisible && !(self.app?.controllers ?? []).contains { $0 === w } } ?? true },
                                  timeout: 6) { [self, weak b] in
                            if b?.window.isVisible == true { closeFailures += 1 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                memory.append(sample())
                                helpers.append(Self.windowLeakChildren())
                                previewMB.append(Double(TabPreviewCache.shared.storedBytes) / 1e6)
                                // Earlier cycles' windows still alive now (the one just closed may be: AppKit's last window under the pointer).
                                let earlier = records.filter { $0.key < i && $0.value.window != nil }.keys.sorted()
                                for k in earlier { records[k]?.aliveAt.append(i) }
                                if !earlier.isEmpty { self.note("\(tag): after close \(i) (\(t())): earlier windows alive: \(earlier)") }
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
            pointerEvent()
            waitUntil({ kinds.allSatisfy { alive($0).isEmpty } }, timeout: 12, then: done)
        }
        run { [self] in
            memory.append(sample())
            let counts = kinds.filter { registered[$0] != nil }.map { "\($0) \(alive($0).count)/\(registered[$0] ?? 0)" }
            note("\(tag): closed windows' objects still alive after \(cycles) cycles: \(counts.joined(separator: ", "))")
            note("\(tag): memory (phys_footprint MB, after a malloc cache flush, without the tab preview pictures) after cycles "
                 + "1…\(cycles), then settled: " + memory.map { String(format: "%.1f", $0) }.joined(separator: ", "))
            note("\(tag): the same with the pictures (raw phys_footprint MB): "
                 + rawMemory.dropFirst().map { String(format: "%.1f", $0) }.joined(separator: ", "))
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
                         + "\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") currentEvent "
                         + "\(NSApp.currentEvent.map { "type \($0.type.rawValue) #\($0.windowNumber) ours \($0.window === w)" } ?? "nil")")
                }
                for p in alive("page") { note("PROBE \(tag): page \(type(of: p)) retain \(CFGetRetainCount(p))") }
                for v in alive("root") { note("PROBE \(tag): root retain \(CFGetRetainCount(v)) window \((v as? NSView)?.window.map { "#\($0.windowNumber)" } ?? "nil")") }
            }
            run {
                if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(e, atStart: false) }
            }
            recount("an application-defined event (no window) through the queue")
            run {
                for case let w as NSWindow in alive("NSWindow") {
                    func strip(_ v: NSView) { v.trackingAreas.forEach(v.removeTrackingArea); v.subviews.forEach(strip) }
                    w.contentView?.superview.map(strip)
                }
            }
            recount("removing its views' tracking areas")
            run { Self.windowLeakPostMouseMoved() }
            recount("a mouse-moved event at the pointer (posted, to an open window)")
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
        // None of the closed windows' objects is left 12 s after the last close (with the pointer event above), and none
        // after one more window opens and closes (not watched). Before the pointer event, AppKit's last window under the
        // pointer was the "last-window slot" of the first task.
        var survivorsBefore: [String: Int] = [:]
        run { for k in kinds where registered[k] != nil { survivorsBefore[k] = alive(k).count } }
        step { [self] done in
            guard let b = app?.openNewWindow(from: c, commandBar: false) else { check(false, "\(tag): one more window opens"); return done() }
            b.navigate(to: URL(string: url)!, newTab: true)
            let id = b.shownTabID ?? ""
            opened.append(id)
            waitUntil({ b.engineTab(for: id)?.isLoading == false }, timeout: 10) { [self] in
                b.window.performClose(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { pointerEvent() }
                waitUntil({ kinds.allSatisfy { alive($0).isEmpty } }, timeout: 8, then: done)
            }
        }
        // The assertions below count these; the diagnostics after them may free survivors.
        var survivorsAfter: [String: Int] = [:]
        run { for k in kinds where registered[k] != nil { survivorsAfter[k] = alive(k).count } }
        // All kinds: which were registered is only known once the cycles have run (an unregistered kind is never alive).
        windowLeakDiagnose(tag: tag, records: { records }, alive: alive, kinds: kinds, t: t)
        run { [self] in
            let states = records.values.map(\.state)
            func count(_ k: String) -> Int { states.filter { $0.contains(k) }.count }
            note("\(tag): at close: mouseIn \(count("mouseIn true")), active \(count("active true")), key \(count(" key true")), "
                 + "occlVisible \(count("occlVisible true")), onSpace \(count("onSpace true")) of \(states.count); first window "
                 + "frame \(records[1]?.frame ?? "?"), pointer now \(NSEvent.mouseLocation)")
            note("\(tag): under the pointer at each close: " + records.keys.sorted().map { i in
                let st = records[i]?.state ?? ""
                let hit = st.range(of: "hit ").map { String(st[$0.upperBound...].prefix { $0 != " " && $0 != "<" }) } ?? "?"
                return "\(i) \(hit)"
            }.joined(separator: ", "))
            note("\(tag): tab preview pictures kept (MB) after cycles 1…\(cycles): "
                 + previewMB.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " (\(TabPreviewCache.shared.count) pictures)")
            note("\(tag): helper processes after cycles 1…\(cycles), then settled: \(helpers.map(String.init).joined(separator: ", ")), "
                 + "\(Self.windowLeakChildren())")
            note("\(tag): closed by \(closes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            check(loaded == cycles, "\(tag): the page loaded in each of the \(cycles) windows (\(loaded))")
            check(closeFailures == 0, "\(tag): each window closed (\(closeFailures) still on screen 6 s later)")
            for k in kinds where registered[k] != nil {
                check((survivorsBefore[k] ?? 0) == 0, "\(tag): no closed window's \(k) is alive 12 s after the last close "
                      + "(\(survivorsBefore[k] ?? 0) of \(registered[k] ?? 0)\(postsMove ? "" : "; no pointer event"))")
                check((survivorsAfter[k] ?? 0) == 0, "\(tag): no closed window's \(k) outlives the next window's close (\(survivorsAfter[k] ?? 0) of "
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
            if !kept.isEmpty { note("\(tag): kept \(kept.count) window on purpose (AIRC_WINDOWLEAK_KEEP)"); kept.removeAll() }
            server?.stop()
        }
    }

    /// windowleak diagnostics, only when a closed window outlived the extra window: which cycle it was, its state at
    /// close and now, how long it lives on (polled up to AIRC_WINDOWLEAK_LINGER s, default 45), then experiments, each
    /// followed by a recount: an event through the queue, clearing its tracking areas, its content view, ordering it out.
    func windowLeakDiagnose(tag: String, records: @escaping () -> [Int: WindowLeakCycle], alive: @escaping (String) -> [AnyObject],
                            kinds: [String], t: @escaping () -> String) {
        let linger = Double(ProcessInfo.processInfo.environment["AIRC_WINDOWLEAK_LINGER"] ?? "") ?? 45
        func survivors() -> [String] { kinds.filter { !alive($0).isEmpty }.map { "\($0) \(alive($0).count)" } }
        var any = false
        run { [self] in
            any = kinds.contains { !alive($0).isEmpty }
            guard any else { return }
            note("DIAG \(tag) (\(t())): survivors after the extra window: \(survivors().joined(separator: ", "))")
            for (i, r) in records().sorted(by: { $0.key < $1.key }) where r.window != nil || r.root != nil || r.page != nil {
                note("DIAG \(tag): cycle \(i) \(r.state); alive at later samples \(r.aliveAt); window \(r.window != nil) root "
                     + "\(r.root != nil) page \(r.page != nil) engineWindow \(r.engineWindow != nil)")
                if let w = r.window {
                    let mouse = NSEvent.mouseLocation
                    func areas(_ v: NSView) -> Int { v.trackingAreas.count + v.subviews.reduce(0) { $0 + areas($1) } }
                    func views(_ v: NSView) -> Int { 1 + v.subviews.reduce(0) { $0 + views($1) } }
                    let frameView = w.contentView?.superview
                    note("DIAG \(tag): cycle \(i) now: #\(w.windowNumber) \(w.className) visible \(w.isVisible) inNSAppWindows "
                         + "\(NSApp.windows.contains { $0 === w }) retain \(CFGetRetainCount(w)) delegate "
                         + "\(w.delegate.map { String(describing: type(of: $0)) } ?? "nil") windowController "
                         + "\(w.windowController.map { String(describing: type(of: $0)) } ?? "nil") firstResponder "
                         + "\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") parent \(w.parent != nil) children "
                         + "\(w.childWindows?.count ?? 0) sheet \(w.attachedSheet != nil) mouseIn \(w.frame.contains(mouse)) "
                         + "views \(frameView.map(views) ?? 0) trackingAreas \(frameView.map(areas) ?? 0) contentRetain "
                         + "\(w.contentView.map { CFGetRetainCount($0) } ?? 0) appActive \(NSApp.isActive) currentEvent "
                         + "\(NSApp.currentEvent.map { "type \($0.type.rawValue) ours \($0.window === w)" } ?? "nil")")
                }
            }
        }
        run { [self] in
            guard any else { return }
            note("DIAG \(tag): app windows: " + NSApp.windows.map { "\($0.className)#\($0.windowNumber) vis \($0.isVisible)" }.joined(separator: ", "))
        }
        // How long does it live on? (A late release, bounded, or a holder that never lets go.)
        step { [self] done in
            guard any else { return done() }
            var last = survivors()
            let start = Date()
            func poll() {
                let now = survivors()
                if now != last { note("DIAG \(tag) (\(t())): +\(String(format: "%.1f", Date().timeIntervalSince(start))) s alive: \(now.isEmpty ? "none" : now.joined(separator: ", "))"); last = now }
                if now.isEmpty || Date().timeIntervalSince(start) > linger {
                    if !now.isEmpty { note("DIAG \(tag): still alive \(Int(linger)) s after the extra window") }
                    return done()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
            poll()
        }
        func experiment(_ what: String, _ body: @escaping () -> Void) {
            run { if any, kinds.contains(where: { !alive($0).isEmpty }) { body() } }
            step { [self] done in
                guard any else { return done() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    let now = survivors()
                    note("DIAG \(tag) after \(what): alive \(now.isEmpty ? "none" : now.joined(separator: ", "))")
                    done()
                }
            }
        }
        experiment("an application-defined event through the queue") {
            if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(e, atStart: false) }
        }
        experiment("removing its views' tracking areas") {
            for r in records().values {
                guard let v = r.window?.contentView?.superview else { continue }
                func strip(_ v: NSView) { v.trackingAreas.forEach(v.removeTrackingArea); v.subviews.forEach(strip) }
                strip(v)
            }
        }
        experiment("a mouse-moved event at the pointer (posted, to an open window)") { Self.windowLeakPostMouseMoved() }
        experiment("ordering it out and clearing its first responder") {
            for r in records().values { guard let w = r.window else { continue }; w.orderOut(nil); _ = w.makeFirstResponder(nil) }
        }
        experiment("detaching its content view") {
            for r in records().values { r.window?.contentView = nil }
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import Darwin
import SwiftUI

/// MEM-6 (idlecpu): "an idle window with no media uses < 1% CPU", in FRONT. A static loopback page is shown in the front,
/// key window, and nothing is typed; each case settles, then the CPU time of every process Airc owns is read over
/// AIRC_IDLECPU_SECONDS (default 30): the app, its Chromium helpers (children) and, on WebKit, the web-content, GPU and
/// networking XPC services (not our children: matched by responsibility, as infra/perf/run.py does). A case over the
/// budget (AIRC_IDLECPU_BUDGET, default 1%) FAILS and names the hottest process.
///
/// Cases (AIRC_IDLECPU_CASES, comma-separated names, picks some):
/// - `key`: the static page, window key, sidebar shown.
/// - `notkey`: the app deactivated; the window stays on screen but isn't key.
/// - `hidden`: the app hidden (⌘H).
/// - `devmodeoff`: Developer Mode off for the loopback page (it's on by itself for localhost, as in `key`).
/// - `pane`: the agent pane open, no task.
/// - `server`: the agent (MCP) server listening, no client.
/// - `littlearc`: a Little Airc window with the static page in front and key.
/// - `row`: a working agent row's dot (AgentPulseDot acting) shown in the window. Its motion must stay, on Core Animation.
/// - `thinking`: the agent pane's "Thinking…" shimmer (AgentPaneThinking) shown in the window. Same rule.
/// - `pulse`: REPORT ONLY: a loopback copy of Wikipedia's pulsing dot (perf's reference page runs it) vs Chrome's cost of
///   the same page (AIRC_IDLECPU_CHROME_PULSE, default 10%). A page that animates isn't idle: no budget.
///
/// Run it in front (AIRC_LA_AS_OWNER=1, dedicated session) with AIRC_KEEP_OCCLUSION=1, like hiddenpaint. While a case
/// measures, phase.txt says "measure <case>" (and "end <case>"), so an outside sampler can `sample` the hot process.
/// On Chromium no case measures across 280–400 s after launch: a fresh profile installs its components then (once).
extension SnapshotRunner {
    private static let idleStaticPage = "<!doctype html><title>static</title><p style='font:15px -apple-system;margin:40px'>A static page.</p>"

    func idleCPUScenario() {
        let env = ProcessInfo.processInfo.environment
        let engine = app?.engine.name ?? "?"
        let tag = "idlecpu \(engine)"
        let seconds = Double(env["AIRC_IDLECPU_SECONDS"] ?? "") ?? 30
        let budget = Double(env["AIRC_IDLECPU_BUDGET"] ?? "") ?? 1
        let chromePulse = Double(env["AIRC_IDLECPU_CHROME_PULSE"] ?? "") ?? 10
        let all = ["key", "notkey", "hidden", "devmodeoff", "pane", "server", "littlearc", "row", "thinking", "pulse"]
        let picked = Set((env["AIRC_IDLECPU_CASES"] ?? "").split(separator: ",").map(String.init))
        let cases = picked.isEmpty ? all : all.filter(picked.contains)
        var server: LocalPageServer?
        var base = ""
        var still = "", pulse = ""
        var little: LittleArcController?
        var overlay: NSView?
        var results: [[String: Any]] = []
        let phase = dir.appendingPathComponent("phase.txt")
        func say(_ line: String) {
            let text = "\(Date().timeIntervalSince1970) \(line)\n"
            if let h = try? FileHandle(forWritingTo: phase) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
            else { try? text.write(to: phase, atomically: true, encoding: .utf8) }
        }
        func front() {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
        }
        func onScreen(_ w: NSWindow) -> Bool { w.isVisible && w.occlusionState.contains(.visible) && w.isOnActiveSpace }
        func show(_ view: some View, size: NSSize) {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.frame = NSRect(x: 24, y: 24, width: size.width, height: size.height)
            c.window.contentView?.addSubview(host)
            overlay = host
        }

        step { [self] done in
            if env["AIRC_LA_AS_OWNER"] == "1" { front() }
            guard let s = LocalPageServer(pages: ["/static": Self.idleStaticPage, "/pulse": Self.pulsePage]) else {
                check(false, "\(tag): the loopback server starts"); return done()
            }
            server = s
            s.start { p in
                guard let p else { self.check(false, "\(tag): the loopback server starts"); return done() }
                base = "http://127.0.0.1:\(p)"
                let space = self.c.currentSpaceID
                do {
                    pulse = try self.c.store.openTab(url: base + "/pulse", inSpace: space, title: "Pulse").id
                    still = try self.c.store.openTab(url: base + "/static", inSpace: space, title: "Static").id
                } catch { self.check(false, "\(tag): open the tabs (\(error))"); return done() }
                self.c.reloadAll(animated: false)
                self.c.show(still, focus: false)
                done()
            }
        }
        waitForPage()
        wait(2)

        /// Sets the case up, settles, measures, tears it down. `ready` returns nil, or why the case can't be measured
        /// (FAIL-ENV, not counted).
        func measure(_ name: String, report: Bool = false, settle: Double = 4, setUp: @escaping () -> Void = {},
                     ready: @escaping () -> String? = { nil }, tearDown: @escaping () -> Void = {}) {
            guard cases.contains(name) else { return }
            run(setUp)
            if name == "pulse" || name == "littlearc" || name == "devmodeoff" { waitForPage() }
            step { [self] done in
                // A fresh Chromium profile installs its components ~300 s after launch (the update check at +300 s
                // downloads Widevine, 17 MB: engineidle's NetLog): a one-time first-run download, not idle work. No
                // case measures across it; the wait is logged.
                var wait = settle
                let age = Self.processAge()
                if !engine.hasPrefix("WebKit"), age + settle + seconds > 280, age + settle < 400 {
                    wait = max(settle, 400 - age)
                    self.note("idlecpu \(name): waits \(Int(wait)) s for the first-run component install (+280–400 s)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    if let why = ready() {
                        self.note("FAIL-ENV \(tag) \(name): \(why)")
                        tearDown()
                        return done()
                    }
                    say("measure \(name)")
                    let cpu0 = Self.ownedProcessCPU(), t0 = CACurrentMediaTime()
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                        let cpu1 = Self.ownedProcessCPU(), dt = CACurrentMediaTime() - t0
                        say("end \(name)")
                        var rows: [[String: Any]] = []
                        for (pid, x) in cpu1 {
                            guard let y = cpu0[pid] else { continue }
                            rows.append(["pid": Int(pid), "kind": x.kind, "cpu": (x.seconds - y.seconds) / dt * 100])
                        }
                        rows.sort { ($0["cpu"] as? Double ?? 0) > ($1["cpu"] as? Double ?? 0) }
                        let total = rows.reduce(0) { $0 + ($1["cpu"] as? Double ?? 0) }
                        let gone = Set(cpu0.keys).subtracting(cpu1.keys).count, new = Set(cpu1.keys).subtracting(cpu0.keys).count
                        let top = rows.prefix(6).map { "\($0["kind"] ?? "?") \(String(format: "%.2f", $0["cpu"] as? Double ?? 0))" }
                            .joined(separator: ", ")
                        let w = NSApp.keyWindow
                        self.note("MEASURE \(tag) \(name): CPU " + String(format: "%.2f", total) + "% over \(Int(dt.rounded())) s "
                                  + "(\(top)); \(rows.count) processes" + (gone + new > 0 ? ", \(gone) gone, \(new) new" : "")
                                  + "; key window \(w.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "none"), "
                                  + "main window key \(self.c.window.isKeyWindow), app active \(NSApp.isActive), hidden \(NSApp.isHidden)")
                        results.append(["case": name, "cpu": total, "seconds": dt, "processes": rows, "report_only": report,
                                        "main_key": self.c.window.isKeyWindow, "app_active": NSApp.isActive])
                        if report {
                            self.note("REPORT \(tag) \(name): " + String(format: "%.2f", total) + "% CPU vs Chrome "
                                      + String(format: "%.1f", chromePulse) + "% on the same page (an animating page isn't idle: no budget)")
                        } else {
                            self.check(total < budget, "\(tag) \(name): idle CPU " + String(format: "%.2f", total) + "% < "
                                       + String(format: "%g", budget) + "% (hottest: \(rows.first?["kind"] ?? "-") "
                                       + String(format: "%.2f", rows.first?["cpu"] as? Double ?? 0) + "%)")
                        }
                        tearDown()
                        done()
                    }
                }
            }
        }

        measure("key", ready: { [self] in onScreen(c.window) && c.window.isKeyWindow ? nil : "our window isn't key on screen" })
        measure("notkey", setUp: { NSApp.deactivate() },
                ready: { [self] in onScreen(c.window) && !c.window.isKeyWindow ? nil : "our window isn't on screen without key" },
                tearDown: { front() })
        measure("hidden", setUp: { NSApp.hide(nil) }, ready: { NSApp.isHidden ? nil : "the app didn't hide" },
                tearDown: { front() })
        measure("devmodeoff", setUp: { [self] in
            if let app { DeveloperMode.shared.setAutomatic(false, app: app) }
            c.engineTab(for: still)?.reload()
        }, ready: { [self] in DeveloperMode.shared.applies(base + "/static") ? "Developer Mode still applies" : (c.window.isKeyWindow ? nil : "not key") },
           tearDown: { [self] in if let app { DeveloperMode.shared.setAutomatic(true, app: app) } })
        measure("pane", setUp: { [self] in AgentUI.toggle(c) },
                ready: { [self] in AgentUI.isShown(c) && c.window.isKeyWindow ? nil : "the agent pane isn't shown in the key window" },
                tearDown: { [self] in AgentUI.close(c) })
        measure("server", setUp: { [self] in
            AgentCenter.shared.app = app
            AgentCenter.shared.enableForCheck(grants: [], http: false)
        }, ready: { AgentCenter.shared.isServing ? nil : "the agent server isn't listening" })
        measure("littlearc", setUp: { [self] in little = app?.openLittleArc(url: URL(string: base + "/static")) },
                ready: { little.map { onScreen($0.window) && $0.window.isKeyWindow } == true ? nil : "Little Airc isn't key on screen" },
                tearDown: { [self] in little?.closeWindow(); little = nil; front() })
        measure("row", setUp: { show(AgentPulseDot(acting: true, color: .controlAccentColor, reduceMotion: false), size: NSSize(width: 8, height: 8)) },
                ready: { AgentPulseDot.pulsing.isEmpty ? "the dot doesn't pulse" : nil },
                tearDown: { overlay?.removeFromSuperview(); overlay = nil })
        measure("thinking", setUp: { show(AgentPaneThinking(), size: NSSize(width: 220, height: 22)) },
                ready: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "Reduce Motion is on (no shimmer)" : nil },
                tearDown: { overlay?.removeFromSuperview(); overlay = nil })
        measure("pulse", report: true, setUp: { [self] in c.show(pulse, focus: false) },
                tearDown: { [self] in c.show(still, focus: false) })

        run { [self] in
            let expected = cases.count
            check(results.count == expected, "\(tag): every case was measured (\(results.count) of \(expected))")
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: dir.appendingPathComponent("idlecpu.json"))
            }
            say("done")
            server?.stop()
            finish()
        }
    }

    /// Seconds since this process started.
    static func processAge() -> Double {
        var info = proc_bsdinfo()
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return 0 }
        let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
        return Date().timeIntervalSince1970 - start
    }

    /// CPU seconds of every process Airc owns: itself, its children (Chromium's helpers) and the processes it's
    /// responsible for (WebKit's XPC services, which launchd parents).
    static func ownedProcessCPU() -> [Int32: (kind: String, seconds: Double)] {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let me = getpid()
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        let responsible = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: Responsible.self) }
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var parent: [pid_t: pid_t] = [:]
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 { parent[pid] = pid_t(info.pbi_ppid) }
        }
        func owned(_ pid: pid_t) -> Bool {
            var p = pid, hops = 0
            while p > 1, hops < 8 { if p == me { return true }; p = parent[p] ?? 0; hops += 1 }
            return responsible?(pid) == me
        }
        var out: [Int32: (kind: String, seconds: Double)] = [:]
        for pid in parent.keys where owned(pid) {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            let ticks = Double(info.ri_user_time + info.ri_system_time)
            out[pid] = (pid == me ? "main" : idleProcessKind(pid), ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9)
        }
        return out
    }

    private static func idleProcessKind(_ pid: Int32) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return "process" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "process" }
        let args = buffer.prefix(size).dropFirst(4).split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }
        if let type = args.first(where: { $0.hasPrefix("--type=") })?.dropFirst(7) {
            if type == "utility", let sub = args.first(where: { $0.hasPrefix("--utility-sub-type=") }) {
                return "utility:" + (sub.split(separator: ".").last.map(String.init) ?? "")
            }
            return String(type)
        }
        return args.first.map { ($0 as NSString).lastPathComponent } ?? "process"
    }
}
#endif

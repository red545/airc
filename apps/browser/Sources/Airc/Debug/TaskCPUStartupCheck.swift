// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircKit
import AppKit

extension SnapshotRunner {
    /// A fresh-process regression: no earlier quiet page may release the startup fence.
    /// Keep the renderer main thread busy (>50%) after load, without blocking navigation or painting.
    /// AIRC_TMCPU_CLOSED=1 measures the same launch with Task Manager closed.
    func taskCPUStartupScenario() {
        var server: LocalPageServer?
        var tab: EngineTab?
        var opened: TimeInterval = 0
        var result: [String: Any] = [:]
        let closed = ProcessInfo.processInfo.environment["AIRC_TMCPU_CLOSED"] == "1"
        func save() { if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("taskcpu.json"), options: .atomic)
        } }
        step { [self] done in
            check(app?.engine.name.hasPrefix("Chromium") == true, "taskcpu: Chromium engine")
            server = LocalPageServer(pages: ["/busy": """
                <!doctype html><title>Task CPU busy startup</title><h1>Busy startup fixture</h1>
                <script>
                window.ticks = 0;
                setInterval(() => { const end = performance.now() + 90;
                  while (performance.now() < end) {} ++window.ticks; }, 120);
                </script>
                """])
            server?.start { port in
                guard let port, let t = try? self.c.store.openTab(url: "http://127.0.0.1:\(port)/busy", inSpace: self.c.currentSpaceID) else {
                    self.check(false, "taskcpu: loopback fixture starts"); return done()
                }
                self.c.reloadAll(animated: false); self.c.show(t.id, focus: false)
                tab = self.c.engineTab(for: t.id)
                self.waitUntil({ tab?.title == "Task CPU busy startup" && tab?.isLoading == false }, timeout: 10) {
                    self.check(tab?.title == "Task CPU busy startup" && tab?.isLoading == false, "taskcpu: busy page loaded")
                    done()
                }
            }
        }
        step { [self] done in
            tab?.evaluate("JSON.stringify({paint:performance.getEntriesByName('first-contentful-paint').map(p=>performance.timeOrigin+p.startTime),ticks:window.ticks,visibility:document.visibilityState})") { value in
                result["page"] = value.map { "\($0)" } ?? "nil"
                result["pid"] = Int(getpid())
                result["closed"] = closed
                self.check(self.c.window.isOnActiveSpace && self.c.window.occlusionState.contains(.visible), "taskcpu: browser visible on active Space")
                save(); done()
            }
        }
        if !closed {
            step { [self] done in
                opened = Date().timeIntervalSince1970
                TaskManagerWindow.show(from: c.window, app: app)
                waitUntil({ TaskManagerWindow.shared?.model.rows.contains { $0.cpu != nil && $0.title.contains("Task CPU busy startup") } == true }, timeout: 75) {
                    let elapsed = Date().timeIntervalSince1970 - opened
                    let sampled = TaskManagerWindow.shared?.model.rows.contains { $0.cpu != nil && $0.title.contains("Task CPU busy startup") } == true
                    result["open_epoch"] = opened
                    result["first_cpu_seconds"] = elapsed
                    result["sampled"] = sampled
                    self.check(sampled && elapsed <= 3.5, String(format: "taskcpu: first busy renderer CPU within about 3 s (%.3f s, sampled %@)", elapsed, sampled.description))
                    save(); done()
                }
            }
        }
        // The outer runner measures the entire process tree's first 60 s from launch.
        step { done in
            let launch = Double(ProcessInfo.processInfo.environment["AIRC_TMCPU_LAUNCH_EPOCH"] ?? "") ?? Date().timeIntervalSince1970 - 60
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, launch + 61 - Date().timeIntervalSince1970), execute: done)
        }
        step { [self] done in
            tab?.evaluate("String(window.ticks)") { value in
                result["final_ticks"] = value.map { "\($0)" } ?? "nil"
                self.check((Int(value.map { "\($0)" } ?? "") ?? 0) > 5, "taskcpu: fixture stayed busy throughout measurement")
                save(); done()
            }
        }
        run { [self] in
            let model = TaskManagerWindow.shared?.model
            TaskManagerWindow.shared?.window.close()
            check(model?.isRunning != true, "taskcpu: closing Task Manager stops sampling")
            server?.stop()
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

extension SnapshotRunner {
    /// JS/API-only MEM-3 timing probe. A single slow freeze handler forces the
    /// native acknowledgement deadline to expire without changing tab selection.
    func unloadRetryScenario() {
        var rows: [[String: Any]] = []
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let repeats = Int(ProcessInfo.processInfo.environment["AIRC_UNLOAD_REPEAT"] ?? "4") ?? 4
        let stall = Int(ProcessInfo.processInfo.environment["AIRC_UNLOAD_STALL_MS"] ?? "0") ?? 0
        let stallCount = max(1, Int(ProcessInfo.processInfo.environment["AIRC_UNLOAD_STALL_COUNT"] ?? "1") ?? 1)
        let hung = stall < 0
        let checkpointDwell = Double(ProcessInfo.processInfo.environment["AIRC_UNLOAD_CHECKPOINT_DWELL"] ?? "0") ?? 0
        let veto = ProcessInfo.processInfo.environment["AIRC_UNLOAD_FALLBACK_VETO"] ?? ""
        let expectUnload = veto.isEmpty
        let freezeBody = hung ? "while(true){}" : "const end=performance.now()+\(stall);while(performance.now()<end){}"
        let script = "<script>window.freezeCount=0;document.addEventListener('freeze',()=>{if(++freezeCount<=\(stallCount)){\(freezeBody)}})</script>"
        let plainHTML = "<title>Plain</title><main style='height:6000px'>plain</main>" + script
        let typedHTML = "<title>Form</title><input id=f value=''>"
        let shownHTML = "<title>Shown</title><p>shown</p>"
        var server: LocalPageServer?, port: UInt16 = 0
        if veto == "shared" || veto == "beforeunload" {
            step { [self] done in
                let child = veto == "beforeunload" ? "<iframe src='/beforeunload'></iframe>" : ""
                server = LocalPageServer(pages: ["/plain": plainHTML + child,
                    "/typed": typedHTML, "/shown": shownHTML,
                    "/beforeunload": "<script>window.onbeforeunload=function(){}</script>child"])
                server?.start { p in port = p ?? 0; self.check(port != 0, "MEM3: veto fixture server starts"); done() }
            }
        }
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: self.dir.appendingPathComponent("unload-retry.json"))
            }
        }
        for iteration in 0..<repeats {
            var plain = "", typed = "", shown = ""
            var start = Date(), elapsed = 0.0
            var didUnload = false
            var row: [String: Any] = ["iteration": iteration, "stall_ms": stall,
                                      "stall_count": stallCount, "fallback_veto": veto, "checkpoint_dwell": checkpointDwell]
            func unloaded(_ id: String) -> Bool { self.c.isPageUnloaded(id) }
            run { [self] in
                WindowController.unloadOverride = 1; c.applyUnloadSetting()
                func page(_ body: String) -> String {
                    "data:text/html," + (body.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
                }
                plain = (try? c.store.openTab(url: server == nil ? page(plainHTML) : "http://127.0.0.1:\(port)/plain", inSpace: c.currentSpaceID, title: "Plain"))?.id ?? ""
                typed = (try? c.store.openTab(url: veto == "shared" ? "http://127.0.0.1:\(port)/typed" : page(typedHTML), inSpace: c.currentSpaceID, title: "Form"))?.id ?? ""
                shown = (try? c.store.openTab(url: veto == "shared" ? "http://127.0.0.1:\(port)/shown" : page(shownHTML), inSpace: c.currentSpaceID, title: "Shown"))?.id ?? ""
                c.reloadAll(animated: false); c.show(plain, focus: false)
            }
            wait(0.8)
            run { [self] in
                row["plain_loaded_before_hide"] = c.engineTab(for: plain)?.isLoading == false
                row["plain_title_before_hide"] = c.engineTab(for: plain)?.title ?? "missing"
            }
            step { [self] done in
                guard let page = c.engineTab(for: plain) else { return done() }
                page.evaluate("scrollTo(0,700);scrollY") { value in
                    row["before_scroll"] = value ?? NSNull()
                    guard veto == "beforeunload" else { return done() }
                    page.evaluate("frames.length === 1 && typeof frames[0].onbeforeunload === 'function'") { ready in
                        row["child_beforeunload_ready"] = ready ?? NSNull()
                        self.check(ready as? Bool == true, "MEM3: child frame beforeunload installed")
                        done()
                    }
                }
            }
            wait(checkpointDwell)
            run { [self] in c.show(typed, focus: false) }
            wait(0.8)
            run { [self] in
                c.engineTab(for: typed)?.evaluate("document.getElementById('f').value = 'typed by hand'; true", completion: nil)
                c.show(shown, focus: false); start = Date()
                if !veto.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        if veto == "select" { self.c.show(plain, focus: false) }
                        #if canImport(AircCore)
                        if veto == "pin" { (self.c.engineTab(for: plain) as? ChromiumTab)?.core.setAutoDiscardable(false) }
                        #endif
                    }
                }
            }
            wait(3.5)
            run { [self] in
                row["at_original_deadline"] = unloaded(plain)
                row["plain_loading_at_deadline"] = c.engineTab(for: plain)?.isLoading ?? false
                #if canImport(AircCore)
                row["plain_frozen_at_deadline"] = (c.engineTab(for: plain) as? ChromiumTab)?.core.frozen ?? false
                #endif
                row["original_elapsed"] = Date().timeIntervalSince(start)
                row["typed_kept"] = !unloaded(typed)
                row["shown_kept"] = !unloaded(shown)
                note("MEM3-SAMPLE iteration \(iteration) stall \(stall) original freed \(unloaded(plain)), typed kept \(!unloaded(typed)), shown kept \(!unloaded(shown))")
            }
            step { [self] done in
                waitUntil({ expectUnload && unloaded(plain) }, timeout: hung ? 70 : 10) {
                    elapsed = Date().timeIntervalSince(start)
                    didUnload = unloaded(plain)
                    row["eventually_unloaded"] = didUnload; row["elapsed"] = elapsed
                    self.check(unloaded(plain) == expectUnload,
                               "MEM3 retry \(iteration): expected unload \(expectUnload), actual \(unloaded(plain)) (\(elapsed)s, stall \(stall)ms, veto \(veto))")
                    let visibleID = veto == "select" ? plain : shown
                    row["final_visible_kept"] = !unloaded(visibleID)
                    row["former_shown_kept"] = !unloaded(shown)
                    self.check(!unloaded(typed) && !unloaded(visibleID), "MEM3 retry \(iteration): dirty and currently shown pages remain")
                    done()
                }
            }
            step { [self] done in
                guard !hung, !unloaded(plain), let page = c.engineTab(for: plain) else { return done() }
                page.evaluate("({freezes:window.freezeCount,visibility:document.visibilityState,ready:document.readyState})") { value in
                    row["live_after_deadline"] = value ?? NSNull(); done()
                }
            }
            step { [self] done in
                // A deliberately hung renderer may share a process. Record window
                // eligibility without asking it to run JavaScript.
                if hung {
                    row["window"] = ["window_visible": c.window.isVisible,
                                     "on_active_space": c.window.isOnActiveSpace,
                                     "occlusion_visible": c.window.occlusionState.contains(.visible),
                                     "screen_locked": Self.screenLocked]
                    return done()
                }
                guard let page = c.engineTab(for: shown) else { return done() }
                scrollRestoreSample(page) { sample in row["window"] = sample; done() }
            }
            step { [self] done in
                guard didUnload else { return done() }
                c.show(plain, focus: false)
                waitUntil({ self.c.engineTab(for: plain)?.title == "Plain" && self.c.engineTab(for: plain)?.isLoading == false }, timeout: 10) { done() }
            }
            wait(0.5)
            step { [self] done in
                guard didUnload, let page = c.engineTab(for: plain) else { return done() }
                let deadline = Date().addingTimeInterval(10)
                var finished = false
                func sample() {
                    self.scrollRestoreSample(page) { value in
                        guard !finished else { return }
                        let ready = value["ready"] as? String == "complete"
                            && (value["height"] as? Double ?? 0) >= 6000
                        if !ready && Date() < deadline {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { sample() }
                            return
                        }
                        finished = true; row["restored"] = value
                        self.check(ready && abs((value["y"] as? Double ?? -100) - 700) <= 2,
                                   "MEM3 retry \(iteration): ready restored page remains at 700")
                        guard hung || stallCount >= 3 else { return done() }
                        page.evaluate("document.wasDiscarded") { discarded in
                            row["restored_document_was_discarded"] = discarded ?? NSNull()
                            self.check(discarded as? Bool == true, "MEM3: fallback reopens a newly loaded document")
                            done()
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
                    guard !finished else { return }
                    finished = true; self.check(false, "MEM3 retry: restored page evaluation timed out"); done()
                }
                sample()
            }
            // Leave a quiet interval for the external process sampler to verify
            // that the old renderer exited and its busy loop stopped consuming CPU.
            wait((hung || stallCount >= 3) && expectUnload ? 5 : 0)
            run { [self] in
                row["foreground_unchanged"] = foregroundPID == NSWorkspace.shared.frontmostApplication?.processIdentifier
                rows.append(row); save()
                WindowController.unloadOverride = 86400; c.applyUnloadSetting()
                for id in [plain, typed, shown] { c.discardScratchTab(id) }
            }
        }
        run { [self] in WindowController.unloadOverride = nil; c.applyUnloadSetting(); server?.stop() }
    }
}
#endif

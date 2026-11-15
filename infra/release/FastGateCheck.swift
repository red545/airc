// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

// Installed only into a clean test export by prepare-fast-gate.py. Public source is untouched.
extension SnapshotRunner {
    func fastGateMark(_ stage: String) {
        note("fast gate step: \(stage)")
        try? stage.write(to: dir.appendingPathComponent("step.txt"), atomically: true, encoding: .utf8)
    }

    /// The outside runner waits for Launch Services, then invokes the unchanged driver.
    /// A rejected key ends this scenario; it can never advance to a later assertion.
    func fastGateKey(_ combo: String, stage: String, _ done: @escaping (String) -> Void) {
        fastGateMark(stage)
        let id = UUID().uuidString
        let response = dir.appendingPathComponent("key-response-\(id).json")
        do {
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "pid": getpid(), "key": combo, "step": stage])
            try data.write(to: dir.appendingPathComponent("key-request.json"), options: .atomic)
        } catch {
            finishForcing("FAIL fast key \(stage): request could not be written: \(error)")
            return
        }
        waitUntil({ FileManager.default.fileExists(atPath: response.path) }, timeout: 20) { [self] in
            guard let bytes = try? Data(contentsOf: response),
                  let answer = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  answer["ok"] as? Bool == true else {
                let reason = (try? String(contentsOf: response, encoding: .utf8)) ?? "outside driver response timed out"
                finishForcing("FAIL fast key \(stage): \(reason)")
                return
            }
            done(answer["output"] as? String ?? "")
        }
    }

    func fastGateScenario(read: Bool) {
        let expected = AppPaths.dataDirectory.appendingPathComponent("fast-note.json")
        let text = "Release persistence check"
        if read {
            run { [self] in
                guard let bytes = try? Data(contentsOf: expected),
                      let saved = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
                      let tab = saved["tab"], let json = saved["document"],
                      let doc = try? JSONDecoder().decode(NoteDocument.self, from: Data(json.utf8)) else {
                    return check(false, "fast notes: missing expected document")
                }
                check(c.store.note(forTab: tab)?.document == doc, "fast notes: persisted document matches after relaunch")
                c.show(tab)
                check(c.shownNote?.textView.document == doc && c.shownNote?.textView.string.contains(text) == true,
                      "fast notes: editor reads persisted content after relaunch")
            }
            return
        }
        var server: LocalPageServer?
        var base = ""
        var enteredFullScreen = false
        step { done in
            server = LocalPageServer(responses: ["/page": .init(body: "<title>Fast gate HTTP</title><p>Release fixture</p>")])
            server?.start { port in base = port.map { "http://127.0.0.1:\($0)/page" } ?? ""; done() }
        }
        for secure in [false, true] {
            step { [self] done in
                fastGateMark(secure ? "https" : "http")
                let address = secure ? "https://example.com/" : base
                guard let row = try? c.store.openTab(url: address, inSpace: c.currentSpaceID) else {
                    check(false, "fast pages: create tab"); return done()
                }
                c.reloadAll(animated: false); c.show(row.id, focus: false)
                let title = secure ? "Example Domain" : "Fast gate HTTP"
                waitUntil({ self.c.engineTab(for: row.id).map { !$0.isLoading && $0.title == title } == true }, timeout: 15) {
                    guard let page = self.c.engineTab(for: row.id) else { self.check(false, "fast pages: missing engine page"); return done() }
                    page.evaluate("JSON.stringify([location.href,document.title,document.readyState])") { value in
                        let result = value as? String ?? ""
                        self.check(result.contains(secure ? "Example Domain" : "Fast gate HTTP") && result.contains("complete")
                                   && result.contains(secure ? "https://example.com/" : base), "fast pages: \(secure ? "https" : "http") loaded: \(result)")
                        done()
                    }
                }
            }
        }
        run { [self] in
            fastGateMark("notes-create")
            server?.stop()
            c.commandActions().first { $0.title == "New Note" }?.run()
            guard let tab = c.shownTabID, let editor = c.shownNote?.textView else { return check(false, "fast notes: create editor") }
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            check(editor.string.contains(text), "fast notes: create and edit through editor")
            note("fast notes: tab \(tab)")
        }
        wait(0.5)
        run { [self] in
            guard let tab = c.shownTabID, let doc = c.store.note(forTab: tab)?.document,
                  let bytes = try? JSONEncoder().encode(doc), let json = String(data: bytes, encoding: .utf8),
                  let record = try? JSONSerialization.data(withJSONObject: ["tab": tab, "document": json]) else {
                return check(false, "fast notes: saved document missing")
            }
            do { try record.write(to: expected, options: .atomic) } catch { check(false, "fast notes: \(error)") }
            check(c.shownNote?.textView.document == doc, "fast notes: editor and store agree")
        }
        step { [self] done in
            c.window.makeKeyAndOrderFront(nil)
            fastGateKey("cmd+opt+n", stage: "little-airc-open") { output in
                self.waitUntil({ self.app?.littleArcs.count == 1 }, timeout: 5) {
                    guard self.app?.littleArcs.count == 1 else {
                        self.finishForcing("FAIL fast Little Airc: real PID-targeted key did not open one window")
                        return
                    }
                    self.check(true, "fast Little Airc: real PID-targeted ⌥⌘N opens one window; \(output)")
                    for little in self.app?.littleArcs ?? [] { little.window.performClose(nil) }
                    done()
                }
            }
        }
        step { [self] done in
            c.window.makeKeyAndOrderFront(nil)
            fastGateKey("ctrl+cmd+f", stage: "fullscreen-enter") { output in
                self.waitUntil({ self.c.window.styleMask.contains(.fullScreen) }, timeout: 8) {
                    guard self.c.window.styleMask.contains(.fullScreen) else {
                        self.finishForcing("FAIL fast fullscreen: real key did not enter full screen; \(output)")
                        return
                    }
                    enteredFullScreen = true
                    self.check(true, "fast fullscreen: real key enters; \(output)")
                    done()
                }
            }
        }
        wait(1)
        step { [self] done in
            fastGateMark("fullscreen-green-exit")
            guard enteredFullScreen && c.window.styleMask.contains(.fullScreen) else {
                finishForcing("FAIL fast fullscreen: entry must be confirmed before the green-button exit")
                return
            }
            // External runner reveals the native titlebar and clicks its green button using the stable driver.
            try? String(getpid()).write(to: dir.appendingPathComponent("green-request"), atomically: true, encoding: .utf8)
            let clicked = dir.appendingPathComponent("green-clicked")
            waitUntil({ FileManager.default.fileExists(atPath: clicked.path) && !self.c.window.styleMask.contains(.fullScreen) }, timeout: 12) {
                guard FileManager.default.fileExists(atPath: clicked.path) && !self.c.window.styleMask.contains(.fullScreen) else {
                    self.finishForcing("FAIL fast fullscreen: confirmed entry and real green click must produce an exit")
                    return
                }
                self.check(true, "fast fullscreen: real green-button click exits")
                done()
            }
        }
        wait(0.5)
        step { [self] done in
            fastGateMark("sharing")
            Task { @MainActor in
                let center = SharingCenter.shared
                guard center.service.base.host == "127.0.0.1",
                      let tab = try? c.store.openTab(url: "https://example.com/", inSpace: c.currentSpaceID) else {
                    check(false, "fast sharing: local backend required"); return done()
                }
                _ = try? c.store.move(.tab(tab.id), to: .pinned(spaceID: c.currentSpaceID, parentID: nil, index: 99))
                guard let draft = c.store.shareDraft(ofSpace: c.currentSpaceID) else { check(false, "fast sharing: draft missing"); return done() }
                do {
                    let record = try await center.publish(draft, sourceID: c.currentSpaceID)
                    let received = try await center.service.snapshot(id: record.id)
                    check(received == draft.snapshot, "fast sharing: local create/read snapshot matches")
                    try await center.revoke(record)
                    check(!center.links(of: c.currentSpaceID).contains { $0.id == record.id }, "fast sharing: revoke removes link")
                } catch { check(false, "fast sharing: \(error)") }
                done()
            }
        }
    }
}
#endif

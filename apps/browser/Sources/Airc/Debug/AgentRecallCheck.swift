// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script agentrecall` then `--script agentrecall-relaunch` with the same data folder (agentrecall): the agent's
/// history and tabs recall and task pictures that survive a relaunch, against the FakeModelServer (it scripts the
/// search_history calls; no real model, a fixture key in memory only). Synthetic history of made-up sites only.
/// - recall: seeded history in this Space's profile is found ("kyoto ryokan", any word order), a second profile's
///   matching page is NOT in the answer, the step row reads "Searched your history: ‘kyoto ryokan’ · N results" with
///   its results as rows, and a click on a row opens that page; the record keeps the rows; pictures go to disk.
/// - tabs: an open tab is found ("the tab with my flight booking") as an open tab.
/// - delete: deleting a task removes its picture folder and its file.
/// - private: a private window's run gets "unavailable", no record and no picture.
/// - relaunch: the first task's card and step pictures come back from disk (none in memory at start), its result rows
///   too, and a row still opens its page.
/// Every phase fails when it made no assertion (zero-guard). Real driver clicks in a dedicated session, else posted.
extension SnapshotRunner {
    func agentRecallScenario(relaunch: Bool) {
        let t = AgentRecallCheck(runner: self)
        step { done in t.setUp(relaunch: relaunch, done) }
        if relaunch {
            step { done in t.caseRelaunch(done) }
        } else {
            step { done in t.caseRecall(done) }
            step { done in t.caseTabs(done) }
            step { done in t.caseDelete(done) }
            step { done in t.casePrivate(done) }
        }
        run { t.finish() }
    }
}

final class AgentRecallCheck {
    let k: AgentPaneCheck
    var runner: SnapshotRunner { k.runner }
    var c: WindowController { k.c }
    var app: AppDelegate { k.app }
    var run: AgentRunCenter { .shared }
    var engine: String { k.engine }
    var real: Bool { k.real }
    var recorder: AgentTaskRecorder { .shared }
    var thumbs: AgentTaskThumbs { .shared }
    let recallPrompt = "Find that ryokan article I read last week"
    let tabsPrompt = "Find the tab with my flight booking"
    var passes = 0, fails = 0
    var recallTask: String?
    var tabsTask: String?
    var otherProfile: String?

    static let ryokan = "<title>Ryokan Hoshizora · Kyoto rooms</title><body style=\"margin:0;background:#2a6f5e;color:#fff;font:20px sans-serif\"><h1 style=\"margin:40px\">Ryokan Hoshizora</h1><p style=\"margin:40px\">Tatami rooms by the river. A made-up fixture page.</p><div style=\"margin:40px;width:300px;height:160px;background:#f2c14e\"></div></body>"
    static let booking = "<title>Flight booking SKY-204 · Skyline Air</title><body style=\"margin:0;background:#1f4fa0;color:#fff;font:20px sans-serif\"><h1 style=\"margin:40px\">Your flight booking</h1><p style=\"margin:40px\">Ashford → Lindenport, a made-up fixture.</p><div style=\"margin:40px;width:260px;height:140px;background:#e0306a\"></div></body>"

    init(runner: SnapshotRunner) {
        k = AgentPaneCheck(runner: runner)
        k.label = "agentrecall"
        k.extraPages = ["/ryokan.html": Self.ryokan, "/booking.html": Self.booking]
    }

    func check(_ ok: Bool, _ what: String) {
        if ok { passes += 1 } else { fails += 1 }
        k.check(ok, what)
    }
    func note(_ s: String) { k.note(s) }
    func after(_ s: Double, _ body: @escaping () -> Void) { k.after(s, body) }
    func wait(_ cond: @escaping () -> Bool, _ timeout: Double, _ then: @escaping () -> Void) { runner.waitUntil(cond, timeout: timeout, then: then) }

    var taskPage: AgentTasksPage? { AgentTasksPage.existing(c.shownTabID) }
    var taskHost: NSView? { taskPage?.host }
    func inTask(_ anchor: String) -> Bool {
        guard let h = taskHost else { return false }
        h.layoutSubtreeIfNeeded()
        return TestAnchors.view(anchor, in: h) != nil
    }
    var profileID: String { c.store.profile(ofSpace: c.currentSpaceID).id }
    var pictureFolders: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: thumbs.store.folder.path)) ?? []).filter { UUID(uuidString: $0) != nil }.sorted()
    }

    // MARK: Set up

    func setUp(relaunch: Bool, _ done: @escaping () -> Void) {
        k.setUp { [self] in
            k.setKeys(anthropic: true)
            var f = c.window.frame
            if f.width < 1320 { f.size.width = min(1320, (c.window.screen?.visibleFrame.width ?? 1320) - 40); c.window.setFrame(f, display: true) }
            guard !relaunch else { return done() }
            seed()
            done()
        }
    }

    /// Made-up sites only. This Space's profile: the ryokan pages (one on loopback, to open), noise; another profile:
    /// a page that matches the same words and must never come back.
    func seed() {
        let h = app.history!
        let mine = profileID
        h.recordVisit(profileID: mine, url: "https://kyoto-stays.example/guides/quiet-ryokan", title: "Ryokan stays in Kyoto: a quiet guide")
        h.recordVisit(profileID: mine, url: "\(k.base)/ryokan.html", title: "Ryokan Hoshizora · Kyoto rooms")
        h.recordVisit(profileID: mine, url: "https://osaka-eats.example/street-food", title: "Osaka street food")
        h.recordVisit(profileID: mine, url: "https://kyoto-temples.example/autumn", title: "Kyoto temples in autumn")
        if let other = try? c.profiles.createProfile(name: "Recall Work", emoji: "", color: nil) {
            otherProfile = other.id
            h.recordVisit(profileID: other.id, url: "https://work-only.example/kyoto-ryokan-offsite", title: "Kyoto ryokan offsite plan")
        }
        check(otherProfile != nil && otherProfile != mine, "a second profile with a matching page")
        let direct = h.recallNow(AgentRecall.words("kyoto ryokan"), profileID: mine)
        check(direct.count >= 2 && !direct.contains { $0.entry.url.contains("work-only") }, "the index finds the seeded pages in this profile only (\(direct.count))")
    }

    /// The search_history answer the fake model got back: its second request (the first call's result, before any
    /// later call names a page).
    func answers(_ name: String) -> String { let b = k.fake.bodies(name); return b.count > 1 ? b[1] : "" }

    // MARK: Recall

    func caseRecall(_ done: @escaping () -> Void) {
        run.newConversation()
        k.fake.begin("recall", [.tool("search_history", ["query": "kyoto ryokan", "days": 30]),
                                .tool("navigate", ["url": "\(k.base)/ryokan.html"]),
                                .text("It was **Ryokan stays in Kyoto: a quiet guide** on kyoto-stays.example. I opened Ryokan Hoshizora too.")])
        CommandBarView.startAgentTask(recallPrompt, attached: [], in: c)
        wait({ !self.run.state.isActive && self.k.fake.requests(for: "recall") >= 3 }, 45) { [self] in
            check(run.state == .done, "the task runs to the end (\(run.state))")
            let id = recorder.currentID
            recallTask = id
            check(id != nil && AgentTasksURL.taskID(c.store.tab(c.shownTabID)?.url) == id, "its task view is shown")
            check(k.fake.toolNames("recall").contains("search_history"), "the model is offered search_history")
            let got = answers("recall")
            check(got.contains("kyoto-stays.example") && got.contains("ryokan.html"), "the seeded history is found (both words, any order)")
            check(!got.contains("work-only.example") && !got.contains("offsite"), "… and the other profile's matching page is not in the answer")
            check(got.contains("untrusted-page-content") && got.contains("airc-history"), "… fenced as untrusted (titles are page text)")
            check(!got.contains("osaka-eats"), "… and pages without the words aren't")
            let step = run.steps.first { $0.kind == .action && $0.text.hasPrefix("Searched your history") }
            let n = step?.found?.count ?? 0
            check(step?.text == "Searched your history: ‘kyoto ryokan’ · \(n) results" && n >= 2, "the step reads “\(step?.text ?? "none")”")
            after(2.6) { [self] in
                check(inTask("agenttask.result.found"), "the task view shows what it found as rows")
                check(pictureDrawn(), "the “Opened …” step's picture is drawn (not blank)")
                let r = recorder.tasks.first { $0.id == id }
                let entry = r?.entries?.first { $0.found != nil }
                check(entry?.found?.count == n && entry?.text.hasPrefix("Searched your history") == true, "the record keeps the step and its \(n) rows")
                let file = AppPaths.dataDirectory.appendingPathComponent("Agent/Tasks/\(id ?? "x").json")
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                check(!text.isEmpty && !text.contains("work-only") && !text.contains(k.key), "the task file: no other profile's page, no key")
                shot("agentrecall-found")
                thumbs.flushForTesting { [self] in
                    let keys = Set(thumbs.store.keys(task: id ?? ""))
                    let opened = r?.entries?.first { $0.kind == .step && $0.text.hasPrefix("Opening") }?.key
                    check(keys.contains(AgentTaskPictureStore.card), "the card picture is on disk (\(keys.count) pictures)")
                    check(opened.map(keys.contains) == true, "… and the “Opened …” step's, by its key")
                    if let f = id.flatMap({ thumbs.store.file(task: $0, key: AgentTaskPictureStore.card) }),
                       let a = try? FileManager.default.attributesOfItem(atPath: f.path) {
                        let size = (a[.size] as? NSNumber)?.intValue ?? 0
                        check(size > 0 && size <= thumbs.store.maxPictureBytes && (a[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                              "… a small JPEG (\(size) B), readable by this user only")
                    }
                    openRow(r, done)
                }
            }
        }
    }

    /// A click on the loopback result opens it in a new tab.
    func openRow(_ r: AgentTaskRecord?, _ done: @escaping () -> Void) {
        let rows = r?.entries?.first { $0.found != nil }?.found ?? []
        guard let n = rows.firstIndex(where: { $0.url.hasSuffix("/ryokan.html") }), let h = taskHost else {
            check(false, "a result row for the loopback page"); return done()
        }
        let url = rows[n].url
        let before = c.shownTabID
        k.press("agenttask.result.found.\(n)", "the history result row", in: h, fallback: { self.taskPage?.task.openPage(url) }) { [self] how in
            wait({ self.c.shownTabID != before && self.c.store.tab(self.c.shownTabID)?.url == url }, 6) { [self] in
                check(c.shownTabID != before && c.store.tab(c.shownTabID)?.url == url, "a click on a result row opens that page in a new tab [\(how) click]")
                done()
            }
        }
    }

    // MARK: Tabs

    func caseTabs(_ done: @escaping () -> Void) {
        c.navigate(to: URL(string: "\(k.base)/booking.html")!, newTab: true)
        wait({ self.c.store.tab(self.c.shownTabID)?.title.contains("Flight booking") == true }, 8) { [self] in
            run.newConversation()
            k.fake.begin("tabs", [.tool("search_history", ["query": "flight booking"]),
                                  .tool("navigate", ["url": "\(k.base)/booking.html"]),
                                  .text("It's your open tab **Flight booking SKY-204**.")])
            CommandBarView.startAgentTask(tabsPrompt, attached: [], in: c)
            wait({ !self.run.state.isActive && self.k.fake.requests(for: "tabs") >= 3 }, 45) { [self] in
                tabsTask = recorder.currentID
                let got = answers("tabs")
                check(got.contains("booking.html") && got.contains("open tab"), "an open tab is found, as an open tab")
                let step = run.steps.first { $0.kind == .action && $0.text.hasPrefix("Searched your history") }
                check(step?.found?.first?.place == .openTab && step?.found?.first?.url.hasSuffix("/booking.html") == true,
                      "… first in the step's rows (\(step?.found?.first.map { "\($0.place.rawValue) \($0.url)" } ?? "none"))")
                after(2.6) { [self] in
                    shot("agentrecall-tabs")
                    done()
                }
            }
        }
    }

    // MARK: Delete

    func caseDelete(_ done: @escaping () -> Void) {
        guard let id = tabsTask else { check(false, "a task to delete"); return done() }
        thumbs.flushForTesting { [self] in
            check(!thumbs.store.keys(task: id).isEmpty, "the task to delete has pictures on disk (\(thumbs.store.keys(task: id).count))")
            run.newConversation()
            recorder.delete(id)
            thumbs.flushForTesting { [self] in
                let folder = thumbs.store.folder.appendingPathComponent(id).path
                let file = AppPaths.dataDirectory.appendingPathComponent("Agent/Tasks/\(id).json").path
                check(!FileManager.default.fileExists(atPath: folder), "deleting the task removes its pictures folder")
                check(!FileManager.default.fileExists(atPath: file) && !recorder.tasks.contains { $0.id == id }, "… and its record")
                check(recallTask.map { !thumbs.store.keys(task: $0).isEmpty } == true, "… and leaves the other task's pictures")
                done()
            }
        }
    }

    // MARK: Private window

    func casePrivate(_ done: @escaping () -> Void) {
        let folders = pictureFolders
        let records = recorder.tasks.count
        run.newConversation()
        k.fake.begin("private", [.tool("search_history", ["query": "kyoto ryokan"]),
                                 .tool("navigate", ["url": "\(k.base)/ryokan.html"]),
                                 .text("History search isn't available here.")])
        let p = c.store.profile(ofSpace: c.currentSpaceID)
        run.ask("Find that ryokan page from a private window", profileID: p.id, profileName: p.name, privateWindow: true)
        wait({ !self.run.state.isActive && self.k.fake.requests(for: "private") >= 3 }, 45) { [self] in
            let got = answers("private")
            check(got.contains("isn't available in private windows"), "a private window's run: search_history says it's unavailable")
            check(!got.contains("kyoto-stays") && !got.contains("ryokan.html"), "… and returns no history")
            let step = run.steps.first { $0.kind == .action && $0.text.contains("history") }
            check(step?.text == "Couldn't search your history" && step?.found == nil, "… its step says so (\(step?.text ?? "none"))")
            after(2.6) { [self] in
                thumbs.flushForTesting { [self] in
                    check(recorder.currentID == nil && recorder.tasks.count == records, "… it keeps no task record")
                    check(pictureFolders == folders, "… and writes no picture (\(pictureFolders.count) folders, \(folders.count) before)")
                    run.newConversation()
                    done()
                }
            }
        }
    }

    // MARK: Relaunch

    func caseRelaunch(_ done: @escaping () -> Void) {
        let title = AgentTaskTitle.make(recallPrompt)
        guard let r = recorder.tasks.first(where: { $0.title == title }) else { check(false, "the first launch's task is back after the relaunch"); return done() }
        check(r.status == .done, "the first launch's task is back (\(r.status))")
        check(!thumbs.inMemory(task: r.id), "no picture in memory at launch")
        let keys = Set(thumbs.store.keys(task: r.id))
        check(keys.contains(AgentTaskPictureStore.card) && keys.count >= 2, "its pictures are on disk (\(keys.count))")
        check(recorder.tasks.contains { $0.title == AgentTaskTitle.make(tabsPrompt) } == false, "the deleted task stays deleted")
        AgentTasksPage.openTask(r.id, in: c)
        _ = thumbs.task(r.id)   // what a Recent tasks card asks for
        wait({ self.inTask("agenttask.result.picture") && self.thumbs.inMemory(task: r.id) }, 8) { [self] in after(1.0) { [self] in
            check(inTask("agenttask.result.picture") && pictureDrawn(), "the “Opened …” step shows its picture again (from disk), drawn (not blank)")
            check(thumbs.task(r.id) != nil, "… and the card's picture is back")
            check(inTask("agenttask.result.found"), "the history step's rows are back")
            shot("agentrecall-relaunch")
            openRow(r, done)
        } }
    }

    /// The step's picture as the view draws it: not one colour (an empty tile). On screen (a dedicated session) the
    /// window server's picture of our own window decides (what the person sees; no Screen Recording needed); the
    /// offscreen render is logged beside it.
    func pictureDrawn() -> Bool {
        let rendered = pictureRendered()
        guard let screen = pictureOnScreen() else { return rendered }
        note("agentrecall \(engine): picture on screen \(screen ? "drawn" : "BLANK"), offscreen render \(rendered ? "drawn" : "blank")")
        return screen
    }

    func pictureOnScreen() -> Bool? {
        guard let h = taskHost, let w = h.window, w.isVisible, w.occlusionState.contains(.visible),
              let v = TestAnchors.view("agenttask.result.picture", in: h), v.bounds.width > 40, v.bounds.height > 40,
              ProcessInfo.processInfo.environment["AIRC_DISABLE_LEGACY_WINDOW_CAPTURE"] != "1",
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let shot = unsafeBitCast(sym, to: Fn.self)(.null, 1 << 3, UInt32(w.windowNumber), (1 << 3) | (1 << 0))?.takeRetainedValue(),
              w.frame.width > 0 else { return nil }
        let scale = CGFloat(shot.width) / w.frame.width
        var r = v.convert(v.bounds, to: nil).insetBy(dx: 12, dy: 12)
        r.origin.y = w.frame.height - r.maxY
        guard let crop = shot.cropping(to: CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral) else { return nil }
        return !AgentTaskThumbs.isBlank(crop)
    }

    func pictureRendered() -> Bool {
        // The anchor is a marker behind the picture: render the whole view and look at the picture's place in it.
        guard let h = taskHost, let v = TestAnchors.view("agenttask.result.picture", in: h), v.bounds.width > 40, v.bounds.height > 40,
              let image = runner.render(h), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), h.bounds.width > 0 else { return false }
        let scale = CGFloat(cg.width) / h.bounds.width
        var r = v.convert(v.bounds, to: h).insetBy(dx: 12, dy: 12)
        if !h.isFlipped { r.origin.y = h.bounds.height - r.maxY }
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
        guard let crop = cg.cropping(to: px) else { return false }
        return !AgentTaskThumbs.isBlank(crop)
    }

    // MARK: Pictures, finish

    func shot(_ name: String) {
        let v: NSView = c.root
        v.layoutSubtreeIfNeeded()
        if let image = runner.render(v), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: runner.dir.appendingPathComponent("\(name)-\(engine).png"))
        }
    }

    func finish() {
        // zero-guard: a phase that asserted nothing is red, never silently green.
        if passes + fails == 0 { k.check(false, "zero-guard: this phase made no assertion") }
        note("agentrecall \(engine): \(passes) passed, \(fails) failed")
        k.finish()
    }
}
#endif

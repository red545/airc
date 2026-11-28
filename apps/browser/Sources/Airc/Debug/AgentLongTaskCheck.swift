// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script agentlong` (nosteplimit, owner 2026-11-23: "these limits need to be default removed!"): Airc's own agent
/// has no step limit by default, against the FakeModelServer (no real model; a fixture key in memory).
/// - Default: "Stop after" is Off, and a settings file from before (no value) reads as Off.
/// - A 60-step task (open a listing, scroll, read it, look at its photos, next listing…) runs to its answer: no stop, no
///   Continue, no banner; older screenshots leave the model's request (at most 16 stay).
/// - The same task in its task view: Done, and no line about a limit.
/// - With "Stop after 25 steps" on: it stops at exactly 25 with a clear message, shown once, in a calm (not red) banner
///   under the last step and right above the composer; Continue gives it 25 more and it finishes.
/// - An error (an unreachable provider): one red banner under the last step, the error not repeated above it.
/// Real driver clicks in a dedicated session; else posted, and said so.
extension SnapshotRunner {
    func agentLongScenario() {
        let t = AgentLongTaskCheck(runner: self)
        step { done in t.setUp(done) }
        step { done in t.caseDefaultOff(done) }
        step { done in t.caseLongTask(done) }
        step { done in t.caseTaskView(done) }
        step { done in t.caseCap(done) }
        step { done in t.caseError(done) }
        run { t.finish() }
    }
}

final class AgentLongTaskCheck {
    let k: AgentPaneCheck
    var runner: SnapshotRunner { k.runner }
    var c: WindowController { k.c }
    var run: AgentRunCenter { .shared }
    var engine: String { k.engine }
    let longTask = "Find a two-room flat under 1,500 a month on Brightport Homes and look at the photos"
    let longSteps = 60
    var longTaskID: String?

    init(runner: SnapshotRunner) {
        k = AgentPaneCheck(runner: runner)
        k.label = "agentlong"
        for n in 1...16 { k.extraPages["/flat\(n).html"] = Self.listing(n) }
    }

    func check(_ ok: Bool, _ what: String) { k.check(ok, what) }
    func note(_ s: String) { k.note(s) }
    func wait(_ cond: @escaping () -> Bool, _ timeout: Double, _ then: @escaping () -> Void) { runner.waitUntil(cond, timeout: timeout, then: then) }

    /// A flat listing with a few "photos" (coloured blocks) and a long description to scroll.
    static func listing(_ n: Int) -> String {
        let hue = (n * 47) % 360
        let photos = (0..<4).map { i in "<div class=ph style=\"background:hsl(\((hue + i * 30) % 360),55%,62%)\">Photo \(i + 1)</div>" }.joined()
        let text = (0..<30).map { "<p>Room \($0 + 1): bright, quiet, wooden floors, close to the tram.</p>" }.joined()
        return """
        <title>Flat \(n) · Brightport Homes</title><style>body{font:16px system-ui;margin:24px}.ph{display:inline-block;width:220px;height:150px;margin:4px;color:#fff;font-weight:600}</style>
        <h1>Flat \(n): \(n % 3 + 1) rooms, \(1100 + n * 37) a month</h1>\(photos)\(text)<a href="/flat\(n + 1).html">Next listing</a>
        """
    }

    /// The fake model's tool turns: per listing navigate, a look at the photos, scroll, another look, read_page (two
    /// screenshots in five steps: 24 in 60, past the 16 the history keeps); then the answer.
    func longScript(_ count: Int, answer: String) -> [FakeModelServer.Turn] {
        var turns: [FakeModelServer.Turn] = []
        var n = 1
        while turns.count < count {
            let page: [FakeModelServer.Turn] = [
                .tool("navigate", ["url": "\(k.base)/flat\(n).html"]),
                .tool("screenshot", [:]),
                .tool("scroll", ["scroll_direction": "down", "scroll_amount": 5, "coordinate": [640, 400]]),
                .tool("screenshot", [:]),
                .tool("read_page", ["mode": "text"]),
            ]
            turns += page.prefix(count - turns.count)
            n = n % 16 + 1
        }
        return turns + [.text(answer)]
    }

    var actions: Int { run.steps.filter { $0.kind == .action }.count }
    var limitLines: [String] { run.steps.map(\.text).filter { $0.localizedCaseInsensitiveContains("limit") || $0.contains("Continue") } }

    func setUp(_ done: @escaping () -> Void) {
        k.setUp { [self] in
            k.setKeys(anthropic: true)
            done()
        }
    }

    // MARK: Default

    func caseDefaultOff(_ done: @escaping () -> Void) {
        let v = AgentModelSettings.shared.values
        check(v.stepCap == nil, "a fresh profile: Settings › AI › Agent › Stop after is Off (stepCap \(v.stepCap.map(String.init) ?? "nil"))")
        // A settings file from before nosteplimit (the old default: Quick, 25 steps) has no stepCap: it reads as Off.
        let old = #"{"backend":"apiKey","provider":"anthropic","level":"quick","blockedSites":[],"memory":false}"#
        let migrated = try? JSONDecoder().decode(AgentModelSettings.Values.self, from: Data(old.utf8))
        check(migrated != nil && migrated?.stepCap == nil && migrated?.level == .quick, "an old settings file on Quick (25 steps) migrates to Off, keeping Quick (\(migrated.map { "\($0.stepCap.map(String.init) ?? "Off"), \($0.level)" } ?? "didn't decode"))")
        let bad = try? JSONDecoder().decode(AgentModelSettings.Values.self, from: Data(#"{"level":"long","stepCap":0}"#.utf8))
        check(bad?.stepCap == nil, "a stepCap of 0 reads as Off")
        check(AgentBudget(level: .quick, stepCap: nil).exceeded(steps: 1_000) == nil && AgentBudget(level: .long, stepCap: nil).exceeded(steps: 1_000) == nil,
              "no level has a step limit (1,000 steps on Quick and Thorough)")
        done()
    }

    // MARK: 60 steps

    func caseLongTask(_ done: @escaping () -> Void) {
        let answer = "Flat 7 fits: 3 rooms for 1,359 a month, bright photos of every room."
        let started = Date()
        k.start("long", longScript(longSteps, answer: answer), task: longTask)
        sawProgress = false
        maxSeen = 0
        sample()
        wait({ !self.run.state.isActive }, 220) { [self] in
            let secs = Date().timeIntervalSince(started)
            note("agentlong \(engine): the 60-step task took \(String(format: "%.1f", secs)) s, \(actions) steps, state \(run.state)")
            check(run.state == .done, "a \(longSteps)-step task runs to the end: Done (state \(run.state))")
            check(actions == longSteps, "… all \(longSteps) steps ran (\(actions); the old default stopped at 25)")
            check(k.finalText == answer, "… with the model's answer (“\(k.finalText.prefix(60))”)")
            check(limitLines.isEmpty, "… no stop, step-limit or Continue line (\(limitLines.joined(separator: " | ")))")
            check(k.fake.requests(for: "long") == longSteps + 1, "… one model turn per step plus the answer (\(k.fake.requests(for: "long")))")
            check(sawProgress && maxSeen >= 30, "… the pane counted the steps as it worked (max \(maxSeen))")
            check(k.model?.problem == nil && k.point("agentpane.error") == nil && k.point("agentpane.continue") == nil, "… no banner and no Continue in the pane")
            // Long tasks keep the model's request small: older screenshots become a line of text.
            let last = k.fake.bodies("long").last ?? ""
            let images = last.components(separatedBy: "\"media_type\"").count - 1
            let pruned = last.contains(AgentConversation.prunedImage.prefix(30))
            check(images >= 1 && images <= 16 && pruned, "… the last request keeps only the newest screenshots (\(images) images, older ones replaced: \(pruned))")
            longTaskID = AgentTaskRecorder.shared.tasks.max(by: { $0.createdAt < $1.createdAt })?.id
            k.shot("agentlong-done")
            done()
        }
    }

    // Watch the run as it goes: the pane's progress line counts the steps up.
    var sawProgress = false
    var maxSeen = 0
    func sample() {
        maxSeen = max(maxSeen, run.stepCount)
        if k.model?.progress?.contains("step") == true { sawProgress = true }
        if run.state.isActive { k.after(0.5) { [weak self] in self?.sample() } }
    }

    func caseTaskView(_ done: @escaping () -> Void) {
        guard let id = longTaskID else { check(false, "the 60-step task is in the task list"); return done() }
        // The recorder saves a state change 0.5 s later (queueSave).
        wait({ AgentTaskRecorder.shared.tasks.first(where: { $0.id == id })?.status == .done }, 5) { [self] in
        let status = AgentTaskRecorder.shared.tasks.first(where: { $0.id == id })?.status
        check(status == .done, "its task row says Done (\(status?.label ?? "no row"))")
        AgentTasksPage.openTask(id, in: c, view: true)
        wait({ AgentTasksPage.existing(self.c.shownTabID)?.task.taskID == id }, 6) { [self] in
            k.after(0.6) { [self] in
                guard let page = AgentTasksPage.existing(c.shownTabID) else { check(false, "the task view opens"); return done() }
                let lines = page.task.lines
                let notes = lines.filter { $0.kind == .note }.map(\.text)
                check(!lines.isEmpty && lines.contains { $0.kind == .answer }, "the task view shows the 60-step task with its answer (\(lines.count) lines)")
                check(!notes.contains { $0.localizedCaseInsensitiveContains("limit") || $0.contains("Continue") }, "… and no line about a limit (\(notes.joined(separator: " | ")))")
                if let img = runner.render(page.host), let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: runner.dir.appendingPathComponent("agentlong-taskview-\(engine).png"))
                }
                AgentPaneController.show(c)
                k.after(0.4) { done() }
            }
        }
        }
    }

    // MARK: The optional cap

    /// Red pixels inside an anchor of the pane (the banner): 0 for a calm one.
    func redPixels(_ anchor: String) -> Int? {
        guard let host = k.host, let v = TestAnchors.view(anchor, in: host) else { return nil }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let r = v.convert(v.bounds, to: host)
        let scale = CGFloat(rep.pixelsWide) / max(1, host.bounds.width)
        let top = host.isFlipped ? r.minY : host.bounds.height - r.maxY
        var red = 0
        for py in stride(from: Int(top * scale), to: Int((top + r.height) * scale), by: 1) {
            for px in stride(from: Int(r.minX * scale), to: Int(r.maxX * scale), by: 1) {
                guard let col = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                if col.redComponent > 0.7 && col.greenComponent < 0.45 && col.blueComponent < 0.45 { red += 1 }
            }
        }
        return red
    }

    /// The banner's place: once, right under the run's last line, and right above the composer (no empty gap).
    func checkBannerPlace(_ what: String, after lastAnchor: String) {
        guard let banner = k.frame("agentpane.error"), let field = k.frame("agentpane.field"), let last = k.frame(lastAnchor) else {
            return check(false, "\(what): the banner, the run's last line (\(lastAnchor)) and the composer are on screen (banner \(k.frame("agentpane.error") != nil), last \(k.frame(lastAnchor) != nil), field \(k.frame("agentpane.field") != nil))")
        }
        // Window coordinates, y up: the last line above the banner, the composer below it.
        let above = last.minY - banner.maxY
        let below = banner.minY - field.maxY
        check(above >= -1 && above <= 24, "\(what): the banner sits right under the run's last line (\(Int(above)) pt between them)")
        check(below >= 0 && below <= 64, "\(what): … and right above the composer, no empty gap (\(Int(below)) pt)")
        if let title = k.frame("agentpane.title") {
            check(banner.maxY < title.minY - 40, "\(what): … not at the top of the pane")
        }
    }

    func caseCap(_ done: @escaping () -> Void) {
        let cap = 25
        AgentModelSettings.shared.update { $0.stepCap = cap }
        let answer = "Done after the extra round."
        k.start("cap", longScript(40, answer: answer), task: "Look through the Brightport Homes listings")
        wait({ !self.run.state.isActive }, 120) { [self] in
            let expected = "Stopped after \(cap) steps, the limit you set in Settings › AI › Agent. Continue gives it \(cap) more."
            if case .stopped(let why) = run.state {
                check(why == expected, "with Stop after \(cap) steps on, the task stops with a clear message (“\(why)”)")
            } else {
                check(false, "with Stop after \(cap) steps on, the task stops (state \(run.state))")
            }
            check(actions == cap, "… at exactly \(cap) steps (\(actions))")
            k.after(0.6) { [self] in
                let items = k.model?.items ?? []
                let repeated = items.filter { if case .note(_, _, let text, _) = $0 { return text == expected }; return false }.count
                check(k.model?.problem?.message == expected && repeated == 0, "… the message shows once: in the banner, not again as a line (\(repeated) repeats)")
                check(k.point("agentpane.continue") != nil, "… with Continue in the banner")
                let summary = items.compactMap { if case .summary(_, let line, _) = $0 { return line }; return nil }.last ?? ""
                check(summary.hasPrefix("Stopped after"), "… and the run's summary says it stopped (“\(summary)”)")
                let red = redPixels("agentpane.error")
                check(red == 0, "… a calm banner, not red: it isn't an error (\(red.map(String.init) ?? "no banner") red px)")
                checkBannerPlace("cap", after: "agentpane.summary")
                k.shot("agentlong-cap")
                k.press("agentpane.continue", "Continue", fallback: { self.run.continueRun() }) { [self] how in
                    wait({ !self.run.state.isActive }, 120) { [self] in
                        check(run.state == .done && k.finalText == answer, "Continue gives it \(cap) more and it finishes [\(how) click] (state \(run.state), \(actions) steps)")
                        check(actions == 40, "… 40 steps in all (\(actions))")
                        check(k.point("agentpane.error") == nil, "… and the banner goes")
                        AgentModelSettings.shared.update { $0.stepCap = nil }
                        check(AgentModelSettings.shared.values.stepCap == nil, "Stop after back to Off")
                        done()
                    }
                }
            }
        }
    }

    // MARK: An error

    func caseError(_ done: @escaping () -> Void) {
        run.newConversation()
        AgentModelSettings.shared.setTestKey(nil, provider: .openai, base: k.base)
        AgentModelSettings.shared.setTestKey(k.key, provider: .anthropic, base: "http://127.0.0.1:9")
        AgentModelSettings.shared.update { $0.provider = .anthropic }
        k.fake.begin("err", [.text("Never reached.")])
        AgentPaneController.show(c)
        k.model?.text = "Try the unreachable provider"
        k.model?.send()
        wait({ !self.run.state.isActive }, 40) { [self] in
            k.after(0.6) { [self] in
                guard case .failed(let m) = run.state else { check(false, "an unreachable provider fails the task (state \(run.state))"); return finish(done) }
                let items = k.model?.items ?? []
                let repeated = items.filter { if case .note(_, _, let text, _) = $0 { return text == m }; return false }.count
                check(k.model?.problem?.message == m && repeated == 0, "an error shows once, in the banner (\(repeated) repeats of “\(m.prefix(60))”)")
                check((redPixels("agentpane.error") ?? 0) > 0, "… red, because it is a real error (\(redPixels("agentpane.error").map(String.init) ?? "no banner") red px)")
                // The run's last line: the dropped request's "Trying again." note (a step of its own), else the prompt.
                checkBannerPlace("error", after: k.frame("agentpane.note") != nil ? "agentpane.note" : "agentpane.prompt")
                k.shot("agentlong-error")
                finish(done)
            }
        }
    }

    private func finish(_ done: @escaping () -> Void) {
        k.setKeys(anthropic: true)
        run.newConversation()
        done()
    }

    func finish() { k.finish() }
}
#endif

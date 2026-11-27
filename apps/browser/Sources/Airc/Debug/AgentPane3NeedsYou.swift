// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// agentux3, part of `--script agentpane2` (owner feedback 2026-11-20: "too many clicks when the agent asks"): every
/// "needs you" entry point lands in one click on the place to answer (AgentAttention). The person is somewhere else
/// first (another app in front, Airc hidden, another Airc Space with the pane closed, a full-screen window of ours);
/// then one click (real driver clicks where the entry point is on screen; the notification's and the Dock's handlers
/// are called as macOS would, labelled posted) must bring the task's window to the front, key, on its Space, with the
/// approval card's keys on Allow once (Return allows once, Esc denies), or the waiting page in front with Take over as
/// the default (Return takes over). Several waiting: the oldest first, the next click the next one, then round again.
extension AgentPane2Check {
    static let login = "<title>Sign in - Example Mail</title><style>body{font:16px sans-serif;margin:40px}</style><h1>Sign in</h1>"
        + "<form action=/signin method=post><label>Email <input type=email name=u></label><br><label>Password <input type=password name=p></label><br><button>Sign in</button></form>"

    enum Away: String {
        case otherApp = "another app in front"
        case hidden = "Airc hidden"
        case otherSpace = "another Space, pane closed"
    }

    /// The person goes elsewhere; true when they are.
    func away(_ a: Away, home: String, other: String, _ done: @escaping (Bool) -> Void) {
        switch a {
        case .otherApp:
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [])
            wait({ !NSApp.isActive }, 4) { done(!NSApp.isActive) }
        case .hidden:
            NSApp.hide(nil)
            wait({ NSApp.isHidden && !NSApp.isActive }, 4) { done(NSApp.isHidden) }
        case .otherSpace:
            AgentUI.close(c)
            c.switchToSpace(other, animated: false)
            wait({ self.c.currentSpaceID == other }, 2) { done(self.c.currentSpaceID == other && self.k.pane?.isShown != true) }
        }
    }

    /// A real driver click on `v` even while Airc is in the background (the point must be our window's), else posted.
    func click(_ v: NSView?, _ what: String, fallback: @escaping () -> Void, _ done: @escaping (String) -> Void) {
        guard k.real, let v, let w = v.window, w.isVisible, let main = NSScreen.screens.first else { fallback(); return done("posted") }
        v.superview?.layoutSubtreeIfNeeded()
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        let top = NSWindow.windowNumber(at: NSPoint(x: r.midX, y: r.midY), belowWindowWithWindowNumber: 0)
        guard r.width > 0, top == w.windowNumber else {
            note("FAIL-ENV agentpane2 \(engine): \(what) isn't on top at its place (window #\(top) there, ours #\(w.windowNumber)); posted")
            fallback()
            return done("posted (covered)")
        }
        UIDriverClient.run(["--click", "\(Int(r.midX.rounded()))", "\(Int((main.frame.maxY - r.midY).rounded()))"]) { ok, out in
            DispatchQueue.main.async {
                if !ok { self.note("FAIL-ENV agentpane2 \(self.engine): the driver refused \(what) (\(out)); posted"); fallback(); return done("posted") }
                done("real")
            }
        }
    }

    /// One click on an entry point.
    func enter(_ entry: String, in w: WindowController? = nil, _ done: @escaping (String) -> Void) {
        let c = w ?? self.c
        switch entry {
        case "notification":
            // What macOS calls when the person clicks the notification (UNUserNotificationCenterDelegate didReceive).
            AgentAttention.Notifications.clicked(AgentAttention.Notifications.recorded.last?.info ?? [:])
            done("posted: the notification's click handler")
        case "toast":
            let b = c.toast.isHidden ? nil : c.toast.actionButton
            click(b, "the toast's Show", fallback: { b?.performClick(nil) }, done)
        case "row":
            let id = AgentAttention.paneRowID ?? ""
            click(TestAnchors.view("agents-row-\(id)", in: c.sidebar.agents), "the task's Agents row", fallback: { _ = AgentAttention.go(row: id, from: "row") }, done)
        case "folderBadge":
            click(TestAnchors.view("agents-needs-you", in: c.sidebar.agents), "the Agents folder's badge", fallback: { AgentAttention.goNext(from: "folderBadge") }, done)
        case "agentButton":
            click(c.sidebar.header.agent.button, "the ✦ button", fallback: { if !AgentAttention.goNext(from: "agentButton", in: c) { AgentUI.toggle(c) } }, done)
        case "pill":
            let pill = c.sidebar.header.agentPill
            click(pill.isHidden ? nil : pill, "the “… needs you” row", fallback: { pill.open() }, done)
        case "dock":
            // What AppKit calls for a click on the Dock icon.
            _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
            done("posted: the Dock icon's reopen")
        case "dockMenu":
            let m = app.applicationDockMenu(NSApp)
            let first = m?.items.first?.title ?? "none"
            check(first.hasPrefix("Airc Agent: "), "… the Dock menu lists it first (“\(first)”)")
            m?.performActionForItem(at: 0)
            done("posted: the Dock menu's item")
        default:
            done("none")
        }
    }

    var app: AppDelegate { k.app }

    /// The key for the landed card: real keys, else posted into the key window.
    func answerKey(_ name: String, _ done: @escaping (String) -> Void) {
        if k.real {
            return UIDriverClient.press([name], pid: getpid()) { ok, out in
                DispatchQueue.main.async {
                    if !ok { self.note("FAIL-ENV agentpane2 \(self.engine): the driver refused \(name) (\(out))") }
                    done(ok ? "real key" : "driver refused")
                }
            }
        }
        let (code, chars): (UInt16, String) = name == "return" ? (36, "\r") : (53, "\u{1b}")
        let wn = NSApp.keyWindow?.windowNumber ?? c.window.windowNumber
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: wn,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        after(0.2) { done("posted key") }
    }

    func spaces() -> (home: String, other: String) {
        let home = c.currentSpaceID
        let pid = c.store.profile(ofSpace: home).id
        if let o = c.windowSpaces.first(where: { $0.id != home && $0.profileID == pid }) { return (home, o.id) }
        let made = (try? c.store.createSpace(name: "Elsewhere", profileID: pid, after: home))?.id ?? home
        return (home, made)
    }

    /// The approval landing, checked.
    func landedOnApproval(_ label: String, in w: WindowController? = nil, home: String?, _ done: @escaping () -> Void) {
        let c = w ?? self.c
        let pane = { AgentPaneController.pane(of: c) }
        // The landing is done when the card is on screen and has the keys (its first focus pass runs just after).
        wait({ NSApp.isActive && c.window.isKeyWindow && c.window.isOnActiveSpace && pane()?.isShown == true && pane()?.model.approvalFocused == true
               && c.window.firstResponder === pane()?.card && (pane()?.card?.hostingView).flatMap { TestAnchors.view("agentpane.approval", in: $0) } != nil }, 4) { [self] in
            let fr = c.window.firstResponder
            let front = NSApp.isActive && c.window.isKeyWindow && c.window.isOnActiveSpace
            let what = "\(label): Airc in front with the task's window key on the active Space (active \(NSApp.isActive), key \(c.window.isKeyWindow), on screen Space \(c.window.isOnActiveSpace), hidden \(NSApp.isHidden))"
            if !front, label.contains("[posted"), !NSApp.isActive {
                note("FAIL-ENV agentpane2 \(engine): \(what): a posted call has no user event, so macOS may refuse the activation; the real click is the proof")
            } else {
                check(front, what)
            }
            if let home { check(c.currentSpaceID == home, "\(label): … on the task's Airc Space") }
            let host = pane()?.card?.hostingView
            check(pane()?.isShown == true && host.flatMap { TestAnchors.view("agentpane.approval", in: $0) } != nil,
                  "\(label): … the agent pane open on the task, its approval card on screen")
            check(pane()?.model.approvalFocused == true && fr === pane()?.card,
                  "\(label): … the keys on it, Allow once the default (responder \(fr.map { String(describing: type(of: $0)) } ?? "none"))")
            check(AgentAttention.lastLanding?.item.kind == .approval, "\(label): … through AgentAttention (\(AgentAttention.lastLanding?.from ?? "none"))")
            done()
        }
    }

    // MARK: Approvals, one entry point each

    /// AgentAttention's and the pane's focus events into the log (diagnosis of a landing that misses).
    func traceAttention() {
        let previous = AgentCenter.shared.onEvent
        AgentCenter.shared.onEvent = { [weak self] e in
            previous?(e)
            if e.hasPrefix("attention") || e.hasPrefix("focus-approval") { self?.note("agentpane2 \(self?.engine ?? ""): event \(e) (responder \(self?.c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"))") }
        }
    }

    func caseNeedsYouApprovals(_ done: @escaping () -> Void) {
        traceAttention()
        // The entry points macOS itself activates Airc for (the notification, the Dock) are called as macOS would, so
        // their person is in "Airc hidden" (an app that isn't in front can't take the front by itself: cooperative
        // activation); the clickable ones get real clicks from another app or another Space.
        let plan: [(entry: String, away: Away)] = [("notification", .hidden), ("toast", .otherApp), ("row", .otherApp), ("folderBadge", .otherSpace),
                                                   ("agentButton", .otherSpace), ("dockMenu", .hidden), ("dock", .hidden)]
        var turns: [FakeModelServer.Turn] = []
        for _ in plan {
            turns += [.tool("navigate", ["url": "\(k.base)/shop.html"]), .tool("wait", ["duration": 2.5]), .tool("left_click", ["coordinate": [100, 180]])]
        }
        turns.append(.text("Paid every time."))
        let (home, other) = spaces()
        check(home != other, "needs you: a second Airc Space of the profile for the “other Space” cases")
        AgentAttention.resetForTesting()
        k.front { [self] _ in
            AgentUI.close(c)
            k.start("needsyou", turns, task: "Pay at the fixture shop a few times")
            var i = 0
            func next() {
                guard i < plan.count else {
                    c.switchToSpace(home, animated: false)
                    return stopRun(done)
                }
                let p = plan[i]
                let last = i == plan.count - 1
                i += 1
                let label = "needs you [\(p.entry), from \(p.away.rawValue)]"
                wait({ self.k.events.filter { $0 == "tool wait" }.count >= i }, 30) { [self] in
                    away(p.away, home: home, other: other) { [self] ok in
                        if !ok { note("FAIL-ENV agentpane2 \(engine): \(label): couldn't go there first (active \(NSApp.isActive), hidden \(NSApp.isHidden), Space \(c.currentSpaceID == other ? "other" : "home"))") }
                        wait({ self.run.approval != nil }, 20) { [self] in
                            guard run.approval != nil else { check(false, "\(label): the agent asks before paying"); return stopRun(done) }
                            after(0.6) { [self] in
                                if p.entry == "toast" { check(c.toast.shownText?.contains("needs your OK") == true, "\(label): Airc's own toast says so (“\(c.toast.shownText ?? "none")”)") }
                                if p.away != .otherSpace {
                                    check(AgentAttention.Notifications.recorded.last?.id.hasPrefix("agent-approval") == true,
                                          "\(label): … a notification is posted (recorded in scripted runs: \(AgentAttention.Notifications.recorded.last?.title ?? "none"))")
                                }
                                if p.entry == "dock" { check(NSApp.dockTile.badgeLabel == "1", "\(label): the Dock badge counts it (\(NSApp.dockTile.badgeLabel ?? "none"))") }
                                if p.entry == "agentButton" { check(c.sidebar.header.agent.dotWaiting, "\(label): the ✦ button's dot says something waits") }
                                enter(p.entry) { [self] how in
                                    landedOnApproval("\(label) [\(how)]", home: home) { [self] in
                                        answerKey(last ? "escape" : "return") { [self] keyHow in
                                            wait({ last ? !self.run.state.isActive : self.run.approval == nil }, 6) { [self] in
                                                if last {
                                                    check(!run.state.isActive, "\(label): Esc denies [\(keyHow)]")
                                                } else {
                                                    check(run.approval == nil && run.state.isActive, "\(label): Return allows once and the agent goes on [\(keyHow)]")
                                                }
                                                after(0.3) { next() }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            next()
        }
    }

    // MARK: From a full-screen window

    /// A second window of ours in native full screen is in front; the approval is the first window's task. One click
    /// on the full-screen window's ✦ (and then the notification) takes the person to the task's window on its Space.
    func caseNeedsYouFullScreen(_ done: @escaping () -> Void) {
        AgentAttention.resetForTesting()
        k.front { [self] _ in
            AgentUI.close(c)
            let b0 = k.base
            k.start("fullscreen", [.tool("navigate", ["url": "\(b0)/shop.html"]), .tool("wait", ["duration": 6]), .tool("left_click", ["coordinate": [100, 180]]),
                                   .tool("navigate", ["url": "\(b0)/shop.html"]), .tool("wait", ["duration": 4]), .tool("left_click", ["coordinate": [100, 180]]),
                                   .text("Paid twice.")], task: "Pay at the fixture shop twice")
            guard let b = app.openNewWindow(from: c, commandBar: false) else { check(false, "needs you (full screen): a second window"); return stopRun(done) }
            func fullScreen(_ on: Bool, _ then: @escaping (Bool) -> Void) {
                b.window.makeKeyAndOrderFront(nil)
                if b.window.styleMask.contains(.fullScreen) != on { b.window.toggleFullScreen(nil) }
                wait({ b.window.styleMask.contains(.fullScreen) == on && (!on || (b.window.isOnActiveSpace && b.window.isKeyWindow)) }, 8) {
                    self.after(0.8) { then(b.window.styleMask.contains(.fullScreen) == on) }
                }
            }
            func cleanUp() {
                fullScreen(false) { _ in
                    b.window.close()
                    self.after(0.5) { self.stopRun(done) }
                }
            }
            after(0.8) { [self] in
                fullScreen(true) { [self] ok in
                    guard ok else { note("FAIL-ENV agentpane2 \(engine): needs you (full screen): the second window didn't go full screen"); return cleanUp() }
                    wait({ self.run.approval != nil }, 20) { [self] in
                        guard run.approval != nil else { check(false, "needs you (full screen): the agent asks"); return cleanUp() }
                        note("agentpane2 \(engine): needs you (full screen): before the click: task window on the active Space \(c.window.isOnActiveSpace), full-screen window key \(b.window.isKeyWindow) on the active Space \(b.window.isOnActiveSpace)")
                        enter("agentButton", in: b) { [self] how in
                            landedOnApproval("needs you [✦ in a full-screen window] [\(how)]", home: nil) { [self] in
                                check(!b.window.isOnActiveSpace, "needs you [✦ in a full-screen window]: … macOS left the full-screen Space for the task's")
                                // Who makes which window key from here on (the diagnosis of the notification landing).
                                let keyWatch = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
                                    guard let self, let w = n.object as? NSWindow else { return }
                                    let stack = Thread.callStackSymbols.prefix(16).dropFirst(2).map { String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first ?? "") }.joined(separator: " < ")
                                    self.note("agentpane2 \(self.engine): needs you (full screen): key #\(w.windowNumber) (task #\(self.c.window.windowNumber)) \(stack)")
                                }
                                after(30) { NotificationCenter.default.removeObserver(keyWatch) }
                                answerKey("return") { [self] _ in
                                    wait({ self.run.approval == nil }, 4) { [self] in
                                        // The second approval while the full-screen window is in front again: the notification.
                                        fullScreen(true) { [self] _ in
                                            wait({ self.run.approval != nil }, 20) { [self] in
                                                note("agentpane2 \(engine): needs you (full screen, again): before: task window on the active Space \(c.window.isOnActiveSpace), full-screen window key \(b.window.isKeyWindow)")
                                                note("agentpane2 \(engine): needs you (full screen) at the click: key #\(NSApp.keyWindow?.windowNumber ?? 0) task #\(c.window.windowNumber) key \(c.window.isKeyWindow) main \(c.window.isMainWindow) tasks \(AgentTaskCenter.shared.runs.count) busy \(AgentTaskCenter.shared.busy.count) waiting \(AgentTaskCenter.shared.waiting.count) items \(AgentAttention.items().map(\.id))")
                                                enter("notification") { [self] how in
                                                    // Where the windows are while the landing settles (Space and key, 4 Hz), for the report.
                                                    for i in 0..<16 {
                                                        after(Double(i) * 0.25) { [self] in
                                                            note("agentpane2 \(engine): needs you (full screen) +\(Double(i) * 0.25) s: key #\(NSApp.keyWindow?.windowNumber ?? 0) task #\(c.window.windowNumber) on Space \(c.window.isOnActiveSpace) full-screen #\(b.window.windowNumber) on Space \(b.window.isOnActiveSpace) fs \(b.window.styleMask.contains(.fullScreen)) landed \(AgentAttention.lastLanding?.window === c ? "task" : AgentAttention.lastLanding?.window === b ? "fs" : "other")")
                                                        }
                                                    }
                                                    landedOnApproval("needs you [notification, from a full-screen window] [\(how)]", home: nil) { [self] in
                                                        answerKey("escape") { [self] _ in
                                                            wait({ !self.run.state.isActive }, 5) { cleanUp() }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Pages that wait (sign-in), several waiting, the outside app's row

    func caseNeedsYouPages(_ done: @escaping () -> Void) {
        k.extraPages["/login.html"] = Self.login
        AgentAttention.resetForTesting()
        AgentCenter.shared.app = app
        AgentCenter.shared.enableForCheck(grants: [], http: false)
        AgentCenter.shared.approvals.automatic = true
        AgentNeedsYou.delay = 1
        let profile = c.store.profile(ofSpace: c.currentSpaceID).name
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/airc-mcp").path
        let m = SpikeMCPClient(helper: helper, args: ["--data-dir", AppPaths.dataDirectory.path, "--client", "agentux3-check", "--profile", profile])
        func end() {
            AgentNeedsYou.delay = 8
            m.stop()
            run.newConversation()
            k.model?.takenOver = nil
            done()
        }
        guard m.start() else { check(false, "needs you (pages): the outside MCP client starts"); return end() }
        m.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "agentux3-check", "version": "1"]], timeout: 15) { [self] r in
            guard r["result"] != nil else { check(false, "needs you (pages): the outside MCP client connects"); return end() }
            m.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            m.call("open_window", ["url": "\(k.base)/login.html"]) { [self] r, _ in
                let w = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                m.call("wait_for_load", ["window": w]) { [self] _, _ in
                    wait({ AgentAttention.items().contains { $0.kind == .page("Sign in") } }, 8) { [self] in
                        let ext = AgentAttention.items().first { $0.kind == .page("Sign in") }
                        check(ext != nil, "needs you (pages): the outside app's sign-in page waits for the person (\(AgentAttention.items().map(\.title)))")
                        guard let ext else { return end() }
                        c.sidebar.header.agentPill.refresh()
                        check(c.sidebar.header.agentPill.sentence == "agentux3-check needs you", "… its “is using Airc” row says “\(c.sidebar.header.agentPill.sentence)”")
                        // Then the pane task asks for an OK: two wait, the page first.
                        k.front { [self] _ in
                            AgentUI.close(c)
                            k.start("pages", [.tool("navigate", ["url": "\(k.base)/shop.html"]), .tool("left_click", ["coordinate": [100, 180]]), .text("Paid.")],
                                    task: "Pay at the fixture shop")
                            wait({ self.run.approval != nil }, 20) { [self] in
                                let order = AgentAttention.items().map(\.id)
                                check(order.count == 2 && order.first == ext.id, "two wait, the oldest first: the sign-in, then the approval (\(AgentAttention.items().map(\.title)))")
                                // The badge follows the approval one main-queue turn later (AgentAttention's sink receives on
                                // main), so this wait can see the approval first: wait (≤ 3 s, logged) for it to settle.
                                let badgeFrom = CACurrentMediaTime()
                                let badgeBefore = NSApp.dockTile.badgeLabel ?? "none"
                                wait({ NSApp.dockTile.badgeLabel == "2" }, 3) { [self] in
                                check(NSApp.dockTile.badgeLabel == "2", "… the Dock badge says 2 (\(NSApp.dockTile.badgeLabel ?? "none"); \(badgeBefore) when the approval came, settled after \(Int((CACurrentMediaTime() - badgeFrom) * 1000)) ms)")
                                away(.otherApp, home: c.currentSpaceID, other: c.currentSpaceID) { [self] _ in
                                    enter("pill") { [self] how in
                                        landedOnPage(ext, "needs you [the outside app's row, from another app] [\(how)]") { [self] in
                                            // The next click goes to the next one waiting.
                                            enter("dock") { [self] how in
                                                landedOnApproval("needs you [Dock, the next one waiting] [\(how)]", home: nil) { [self] in
                                                    // … and round again (the ✦ button in the same window).
                                                    enter("agentButton") { [self] how in
                                                        landedOnPage(ext, "needs you [✦, round again to the oldest] [\(how)]") { [self] in
                                                            takeOverByReturn(ext) { [self] in
                                                                check(AgentAttention.count == 1, "… one waits now: the approval (\(AgentAttention.items().map(\.title)))")
                                                                run.answerApproval(allow: false)
                                                                k.untilIdle(6) { [self] in
                                                                    m.call("close_window", ["window": w]) { [self] _, _ in paneTaskPage(end) }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The page landing, checked: Watch on its row in front, Take over the default.
    func landedOnPage(_ it: AgentAttention.Item, _ label: String, _ done: @escaping () -> Void) {
        // agentmainview: the Airc Agent's own page is a tab of the window: it lands in the main view, Return takes over.
        let row = it.rowID.flatMap { AgentActivity.shared.model.row($0) }
        let hosted = row.flatMap { r in AgentCenter.shared.windows[r.window]?.tab(r.tab) }.flatMap { AgentMainView.shared.entry($0) }
        if let hosted {
            wait({ NSApp.isActive && self.c.window.isKeyWindow && self.c.shownTabID == hosted.tabID
                   && AgentMainView.shared.chromeView(self.c)?.landed == true && self.c.window.firstResponder === AgentMainView.shared.chromeView(self.c) }, 4) { [self] in
                let v = AgentMainView.shared.chromeView(c)
                check(NSApp.isActive && c.window.isKeyWindow && c.window.isOnActiveSpace, "\(label): Airc in front, the window key on the active Space")
                check(c.shownTabID == hosted.tabID, "\(label): … the agent's page itself in front (the main view)")
                check(v.map { c.window.firstResponder === $0 } == true && v?.landed == true, "\(label): … Take over the default (Return), the keys on it")
                check(AgentAttention.lastLanding?.item.id == it.id, "\(label): … through AgentAttention (\(AgentAttention.lastLanding?.from ?? "none"))")
                done()
            }
            return
        }
        wait({ NSApp.isActive && self.c.window.isKeyWindow && self.c.sidebar.agents.watch?.rowID == it.rowID
               && self.c.sidebar.agents.watch?.isLanded == true && self.c.window.firstResponder === self.c.sidebar.agents.watch }, 4) { [self] in
            let wv = c.sidebar.agents.watch
            check(NSApp.isActive && c.window.isKeyWindow && c.window.isOnActiveSpace, "\(label): Airc in front, the window key on the active Space")
            check(wv?.rowID == it.rowID, "\(label): … the agent's page itself in front (Watch on \(wv?.rowID ?? "nothing"))")
            check(wv.map { c.window.firstResponder === $0 } == true && wv?.landedForTesting == true, "\(label): … Take over the default, the keys on it")
            check(AgentAttention.lastLanding?.item.id == it.id, "\(label): … through AgentAttention (\(AgentAttention.lastLanding?.from ?? "none"))")
            done()
        }
    }

    /// Return in the landed Watch: the page becomes the person's tab.
    func takeOverByReturn(_ it: AgentAttention.Item, _ done: @escaping () -> Void) {
        let before = c.shownTabID
        answerKey("return") { [self] how in
            wait({ self.c.shownTabID != before && self.c.sidebar.agents.watch == nil }, 5) { [self] in
                check(c.shownTabID != before && c.sidebar.agents.watch == nil, "… Return takes over: the sign-in page is the person's tab now [\(how)]")
                done()
            }
        }
    }

    /// The pane task's own page waits (a sign-in): its notification lands on the pane and the page; Return takes over
    /// through the pane (Hand back stays possible).
    func paneTaskPage(_ done: @escaping () -> Void) {
        AgentAttention.resetForTesting()
        k.front { [self] _ in
            AgentUI.close(c)
            k.start("signin", [.tool("navigate", ["url": "\(k.base)/login.html"]), .tool("wait", ["duration": 30]), .text("Never reached.")], task: "Sign in to the fixture mail")
            wait({ AgentAttention.items().contains { $0.kind == .page("Sign in") && $0.rowID == AgentAttention.paneRowID } }, 15) { [self] in
                guard let it = AgentAttention.items().first(where: { $0.kind == .page("Sign in") }) else {
                    check(false, "needs you (pane task): its sign-in page waits for the person"); return stopRun(done)
                }
                after(1.0) { [self] in
                    away(.hidden, home: c.currentSpaceID, other: c.currentSpaceID) { [self] _ in
                        AgentAttention.Notifications.clicked(["agentRow": it.rowID ?? ""])
                        landedOnPage(it, "needs you [the sign-in notification, Airc hidden] [posted: the notification's click handler]") { [self] in
                            check(k.pane?.isShown == true, "… with the task's pane open beside it")
                            answerKey("return") { [self] how in
                                wait({ self.k.model?.takenOver != nil }, 5) { [self] in
                                    check(k.model?.takenOver != nil && c.sidebar.agents.watch == nil, "… Return takes over through the pane (Hand back stays) [\(how)]")
                                    stopRun(done)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif

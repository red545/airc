// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// S03b: Favorites' own badges beyond the dot, on synthetic loopback pages whose titles change, both engines.
/// `--script s03bbadges`:
///   - X: the title's "(N)" draws a count capsule (12, 99+, 20+), no count no badge; it pops in, and not with Reduce Motion;
///   - Slack: "! " (a mention) draws the "@" badge, "* " or "| N new items" the plain dot, nothing else no badge;
///   - Gmail-like pages keep the plain dot;
///   - real hovers and clicks (the UI driver) over the tiles leave every badge in place;
///   - Calendar: the countdown sits on Arc's subtitle pill, bright from five minutes before ("meeting soon"); it fades
///     in, and not with Reduce Motion; Show Time to Next Meeting off hides it (synthetic calendar, no calendar site loads);
///   - calls: a Favorite whose page is in a call shows the camera badge; one shared into a call the shared badge (the
///     engine's capture callback is fed a synthetic row: no getDisplayMedia, by the no-capture rule); both clear;
///   - Show Unread Badge off hides X's count and Slack's mention and is saved; a private window has no Favorites.
/// `--script s03bbadges-relaunch`, same data directory: X's switch is still off, Slack's mention still draws, and
/// X's count draws again once the switch is turned on. Nothing leaves the Mac: 127.0.0.1 only.
extension SnapshotRunner {
    static let s03bMarker = "s03bbadges-favorites.txt"

    private static func s03bServer() -> LocalPageServer? {
        func page(_ title: String) -> LocalPageServer.Page {
            .init(headers: ["Content-Type": "text/html; charset=utf-8"], body: """
            <!doctype html><meta charset=utf-8><title>\(title)</title>
            <body style="font:14px -apple-system;padding:24px">Synthetic page
            <script>function setT(t){document.title=t;return document.title}</script>
            """)
        }
        // A second of zeros: the call page's far-end audio, never audible.
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + 16_000); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(8000); u32(16_000); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(16_000); wav.append(Data(count: 16_000))
        return LocalPageServer(responses: [
            "/x/home": page("(3) Home / X"),
            "/slack/client": page("Slack | general | Fixture"),
            "/inbox": page("Inbox (2) - Fixture Mail"),
            "/doc": page("Fixture doc"),
            "/call": .init(headers: ["Content-Type": "text/html; charset=utf-8"], body: MediaLibServer.callPage),
            "/silence.wav": .init(headers: ["Content-Type": "audio/wav"], body: "", data: wav),
            "/beat": .init(body: "ok"),
        ])
    }

    /// Two colours alike in sRGB (a layer's CGColor never compares equal to an NSColor).
    static func s03bSame(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let x = a?.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        return abs(x.redComponent - y.redComponent) < 0.01 && abs(x.greenComponent - y.greenComponent) < 0.01
            && abs(x.blueComponent - y.blueComponent) < 0.01 && abs(x.alphaComponent - y.alphaComponent) < 0.01
    }

    /// The badge face's last pop: whether it animated, and whether the pop is on the layer now.
    private func s03bPop(_ itemID: String) -> (animated: Bool?, running: Bool) {
        let t = s03bTile(itemID)
        return MainActor.assumeIsolated {
            (t?.unreadFace?.lastChangeAnimated, t?.unreadFace?.layer.animation(forKey: UnreadBadgeFace.popKey) != nil)
        }
    }

    private func s03bTile(_ itemID: String) -> FavoriteTileView? {
        guard let p = c.pageView(for: c.currentSpaceID) else { return nil }
        p.layoutSubtreeIfNeeded()
        return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == itemID }
    }

    private func s03bToggle(_ itemID: String) {
        guard let item = c.store.item(itemID) else { return }
        let m = c.menu(for: .favorite(item, c.store.liveTab(forItem: itemID)))
        m.update()
        if let i = m.items.firstIndex(where: { $0.title == "Show Unread Badge" }) { m.performActionForItem(at: i) }
    }

    private func s03bSwitch(_ itemID: String) -> NSControl.StateValue? {
        guard let item = c.store.item(itemID) else { return nil }
        let m = c.menu(for: .favorite(item, c.store.liveTab(forItem: itemID)))
        m.update()
        return m.items.first { $0.title == "Show Unread Badge" }?.state
    }

    /// The face drawn on a tile, with its text: "dot", "count 12 (12)", "mention (@)", "none".
    private func s03bFace(_ itemID: String) -> String {
        guard let t = s03bTile(itemID) else { return "no tile" }
        return MainActor.assumeIsolated {
            switch t.shownUnreadBadge {
            case .none: return "none"
            case .dot: return "dot"
            case .count(let n, let more): return "count \(n)\(more ? "+" : "") (\(t.unreadFace?.label ?? "-"))"
            case .mention: return "mention (\(t.unreadFace?.label ?? "-"))"
            }
        }
    }

    func s03bBadgesScenario() { s03bRun(relaunch: false) }
    func s03bBadgesRelaunchScenario() { s03bRun(relaunch: true) }

    private func s03bRun(relaunch: Bool) {
        let engine = (app?.engine is WebKitEngine) ? "webkit" : "chromium"
        let tag = relaunch ? "s03b relaunch \(engine)" : "s03b \(engine)"
        var server: LocalPageServer?, base = ""
        var ids: [String: String] = [:]   // name → item ID
        func item(_ n: String) -> String { ids[n] ?? "" }
        func page(_ n: String) -> EngineTab? { c.store.liveTab(forItem: item(n)).flatMap { c.engineTab(for: $0.id) } }
        let motion = { (v: Bool?) in
            MainActor.assumeIsolated {
                AircMotion.reduceMotionOverride = v
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            }
        }
        func setTitle(_ n: String, _ t: String) {
            step { [self] done in
                guard let p = page(n) else { check(false, "\(tag): \(n) has a page"); return done() }
                p.evaluate("setT(\(String(reflecting: t)))") { _ in
                    self.waitUntil({ page(n)?.title == t }, timeout: 4) { done() }
                }
            }
        }
        func expect(_ n: String, _ face: String, _ what: String) {
            step { [self] done in waitUntil({ self.s03bFace(item(n)) == face }, timeout: 3) { done() } }
            run { [self] in check(s03bFace(item(n)) == face, "\(tag): \(what) (\(s03bFace(item(n))), title \(page(n)?.title ?? "-"))") }
        }

        run {
            URLRules.extraUnreadBadgeHosts = ["127.0.0.1"]
            URLRules.extraBadgeApps = ["/x": .x, "/slack": .slack]
            motion(false)
        }
        step { done in
            server = Self.s03bServer()
            server?.start { port in base = port.map { "http://127.0.0.1:\($0)" } ?? ""; done() }
        }

        if relaunch {
            run { [self] in
                let marker = AppPaths.dataDirectory.appendingPathComponent(Self.s03bMarker)
                for line in ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n") {
                    let f = line.split(separator: " ")
                    if f.count == 2 { ids[String(f[0])] = String(f[1]) }
                }
                check(c.store.item(item("x")) != nil && c.store.item(item("slack")) != nil, "\(tag): the first launch's X and Slack Favorites are back")
                check(s03bSwitch(item("x")) == .off && s03bSwitch(item("slack")) == .on,
                      "\(tag): X's Show Unread Badge is still off, Slack's on")
                // The saved pages' port was the first launch's: open each Favorite, then load this launch's page.
                for n in ["x", "slack"] { if let it = c.store.item(item(n)) { c.activate(entry: .favorite(it, c.store.liveTab(forItem: item(n)))) } }
            }
            step { [self] done in waitUntil({ page("x") != nil && page("slack") != nil }, timeout: 10) { done() } }
            run {
                if let u = URL(string: base + "/x/home") { page("x")?.load(u) }
                if let u = URL(string: base + "/slack/client") { page("slack")?.load(u) }
            }
            step { [self] done in waitUntil({ page("x")?.title == "(3) Home / X" && page("slack")?.isLoading == false }, timeout: 15) { done() } }
            setTitle("slack", "! Slack | dm | Fixture")
            expect("x", "none", "X's title counts 3 and, with its switch off, no count draws")
            expect("slack", "mention (@)", "Slack's mention draws after the relaunch")
            run { [self] in s03bToggle(item("x")) }
            expect("x", "count 3 (3)", "Show Unread Badge on again draws X's count")
            capture("s03b-\(engine)-relaunch")
            run { URLRules.extraUnreadBadgeHosts = []; URLRules.extraBadgeApps = [:]; motion(nil); server = nil }
            return
        }

        run { [self] in
            guard !base.isEmpty else { return check(false, "\(tag): the loopback server listens") }
            do {
                let pid = c.store.profile(ofSpace: c.currentSpaceID).id
                for (n, path, title) in [("x", "/x/home", "X"), ("slack", "/slack/client", "Slack"), ("mail", "/inbox", "Mail"), ("doc", "/doc", "Doc")] {
                    let t = try c.store.openTab(url: base + path, inSpace: c.currentSpaceID, activate: false, title: title)
                    try c.store.move(.tab(t.id), to: .favorites(profileID: pid, index: 99))
                    ids[n] = c.store.tab(t.id)?.itemID ?? ""
                }
                // Live Calendar's Favorite: never loaded here (the synthetic calendar feeds it).
                try favorite("https://calendar.google.com/calendar/u/0/r", title: "Google Calendar", icon: nil, profile: pid, space: c.currentSpaceID)
                ids["cal"] = c.store.favorites(ofProfile: pid).first { CalendarSites.isCalendarFavorite($0.savedURL ?? "") }?.id ?? ""
                let marker = ids.map { "\($0.key) \($0.value)" }.joined(separator: "\n")
                try? marker.write(to: AppPaths.dataDirectory.appendingPathComponent(Self.s03bMarker), atomically: true, encoding: .utf8)
                c.reloadAll(animated: false)
            } catch { check(false, "\(tag): setup (\(error))") }
        }
        // A Favorite's page loads when it's opened (Favorites only load once used): open each, ending on Mail.
        for n in ["x", "slack", "doc", "mail"] {
            run { [self] in
                if let it = c.store.item(item(n)) { c.activate(entry: .favorite(it, c.store.liveTab(forItem: item(n)))) }
            }
            step { [self] done in waitUntil({ page(n) != nil && page(n)?.isLoading == false }, timeout: 10) { done() } }
        }
        step { [self] done in
            waitUntil({ ["x", "slack", "mail", "doc"].allSatisfy { page($0) != nil && page($0)?.isLoading == false } && page("x")?.title == "(3) Home / X" },
                      timeout: 15) { done() }
        }

        // 1. X: the count capsule.
        expect("x", "count 3 (3)", "X's \"(3)\" draws a count badge, not the dot")
        run { [self] in
            guard let t = s03bTile(item("x")), let f = t.unreadFace?.layer.frame else { return check(false, "\(tag): X's badge has a frame") }
            let d = AircMetrics.Favorites.unreadDotOffset
            check(abs(f.midY - (t.bounds.height - d.y)) < 0.6 && abs(t.bounds.maxX - f.maxX - UnreadBadgeFace.rightInset) < 0.6
                  && f.height == UnreadBadgeFace.height && f.width >= f.height && t.bounds.contains(f),
                  "\(tag): X's badge sits in the dot's corner, \(UnreadBadgeFace.height) pt tall, inside the tile (\(f), tile \(t.bounds.size))")
            let dark = t.palette?.isDark == true
            let fill = t.unreadFace?.layer.backgroundColor.flatMap { NSColor(cgColor: $0) }
            check(Self.s03bSame(fill, UnreadBadgeFace.twitterGray(dark: dark)), "\(tag): X's badge is Arc's TwitterBadgeGray (\(fill.map { "\($0)" } ?? "-"), dark \(dark))")
        }
        setTitle("x", "(12) Home / X")
        expect("x", "count 12 (12)", "a new count shows at once")
        run { [self] in
            check(s03bPop(item("x")).animated == true, "\(tag): a higher count pops in (Reduce Motion off)")
        }
        setTitle("x", "(120) Home / X")
        expect("x", "count 120 (99+)", "more than 99 prints 99+")
        setTitle("x", "(20+) Notifications / X")
        expect("x", "count 20+ (20+)", "X's \"(20+)\" prints 20+")
        setTitle("x", "Home / X")
        expect("x", "none", "no count, no badge (and no dot)")

        // 2. Slack: mention versus plain unread.
        expect("slack", "none", "Slack with nothing new has no badge")
        setTitle("slack", "* Slack | general | Fixture")
        expect("slack", "dot", "Slack's \"* \" (unread channels) is the plain dot")
        setTitle("slack", "! Slack | dm | Fixture")
        expect("slack", "mention (@)", "Slack's \"! \" (a mention or direct message) draws the @ badge instead")
        run { [self] in
            let fill = s03bTile(item("slack"))?.unreadFace?.layer.backgroundColor.flatMap { NSColor(cgColor: $0) }
            check(Self.s03bSame(fill, UnreadBadgeFace.mentionRed), "\(tag): the mention badge is Arc's badge red (\(fill.map { "\($0)" } ?? "-"))")
        }
        setTitle("slack", "Slack | general | Fixture | 3 new items")
        expect("slack", "dot", "Slack's \"| 3 new items\" without a mention is the dot")
        setTitle("slack", "Slack | general | Fixture")
        expect("slack", "none", "Slack read: the badge goes")
        expect("mail", "dot", "a mail page's \"Inbox (2)\" keeps the plain dot")

        // 3. Reduce Motion: the badge just appears.
        run { motion(true) }
        setTitle("x", "(4) Home / X")
        expect("x", "count 4 (4)", "with Reduce Motion the count still shows")
        run { [self] in
            let f = s03bPop(item("x"))
            check(f.animated == false && f.running == false,
                  "\(tag): Reduce Motion: the badge appears without the pop")
            motion(false)
        }
        setTitle("x", "(9) Home / X")
        expect("x", "count 9 (9)", "Reduce Motion off: a higher count")
        run { [self] in check(s03bPop(item("x")).animated == true, "\(tag): Reduce Motion off: it pops again") }
        setTitle("slack", "! Slack | dm | Fixture")
        expect("slack", "mention (@)", "the mention again, for the screenshot")
        capture("s03b-\(engine)-faces")

        // 4. Real hovers and clicks (UI driver) over the tiles.
        var realInput = false, envFailed = false
        let tileCenter = { [unowned self] (n: String) -> NSPoint? in
            s03bTile(item(n)).map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
        }
        step { [self] done in
            realInput = UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
            guard realInput else {
                envFailed = true
                note("FAIL-ENV \(tag): real input: no UI driver or dedicated session (driver \(UIDriverClient.available))")
                return done()
            }
            if NSApp.isActive, c.window.isKeyWindow { return done() }
            // One real click on the gap under the page (it does nothing else) to bring our window in front.
            let card = c.card.convert(c.card.bounds, to: nil)
            let p = c.window.convertPoint(toScreen: NSPoint(x: card.midX, y: card.minY - AircMetrics.Window.cardInset / 2 - 1))
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            UIDriverClient.run(["--click", String(Double(p.x)), String(Double(top - p.y))]) { _, _ in
                self.waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) {
                    if !(NSApp.isActive && self.c.window.isKeyWindow) {
                        envFailed = true
                        self.note("FAIL-ENV \(tag): real input: our window isn't the active key window (active \(NSApp.isActive))")
                    }
                    done()
                }
            }
        }
        func real(_ what: String, hover n: String) {
            step { [self] done in
                guard !envFailed, let p = tileCenter(n) else { return done() }
                UIDriverClient.hover(p, in: c.window, dwell: 600) { ok, out in
                    if !ok { envFailed = true; self.note("FAIL-ENV \(tag): \(what): driver hover failed: \(out)") }
                    done()
                }
            }
        }
        func real(_ what: String, click n: String) {
            step { [self] done in
                guard !envFailed, let p = tileCenter(n) else { return done() }
                let g = c.window.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
                UIDriverClient.run(["--click", String(Double(g.x)), String(Double(top - g.y))]) { ok, out in
                    if !ok { envFailed = true; self.note("FAIL-ENV \(tag): \(what): driver click failed: \(out)") }
                    self.waitUntil({ self.c.store.liveTab(forItem: item(n))?.id == self.c.displayedTabID(forSpace: self.c.currentSpaceID) }, timeout: 3) { done() }
                }
            }
        }
        real("hover X", hover: "x")
        run { [self] in
            guard !envFailed else { return }
            check(s03bTile(item("x"))?.isHovered == true && s03bFace(item("x")) == "count 9 (9)",
                  "\(tag): a real hover over X's tile keeps its count (hovered \(s03bTile(item("x"))?.isHovered == true), \(s03bFace(item("x"))))")
        }
        real("click X", click: "x")
        run { [self] in
            guard !envFailed else { return }
            let shown = c.store.liveTab(forItem: item("x"))?.id == c.displayedTabID(forSpace: c.currentSpaceID)
            check(shown && s03bFace(item("x")) == "count 9 (9)" && s03bFace(item("slack")) == "mention (@)" && s03bFace(item("mail")) == "dot",
                  "\(tag): a real click opens X and every badge stays (shown \(shown), X \(s03bFace(item("x"))), Slack \(s03bFace(item("slack"))), mail \(s03bFace(item("mail"))))")
        }
        real("hover Slack", hover: "slack")
        real("click Slack", click: "slack")
        run { [self] in
            guard !envFailed else { return }
            let shown = c.store.liveTab(forItem: item("slack"))?.id == c.displayedTabID(forSpace: c.currentSpaceID)
            check(shown && s03bFace(item("slack")) == "mention (@)" && s03bFace(item("x")) == "count 9 (9)",
                  "\(tag): a real click opens Slack, its mention stays on the selected tile (shown \(shown), \(s03bFace(item("slack"))))")
            note("\(tag): real input \(realInput && !envFailed ? "used (driver hovers and clicks)" : "not used")")
        }
        capture("s03b-\(engine)-selected")

        // 5. Calendar: the "meeting soon" pill (synthetic calendar; the Calendar Favorite's page never loads).
        let center = CalendarCenter.shared
        var offset: TimeInterval = 0
        let t0 = Date()
        let meeting = CalendarEvent(id: "s03b", title: "Standup", start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(5400))
        let face = { [unowned self] () -> CalendarTileFace? in s03bTile(item("cal"))?.calendarFace }
        func at(_ before: TimeInterval) { offset = meeting.start.timeIntervalSince(t0) - before; center.clockMoved() }
        run { [self] in
            _ = AppTelemetry.shared.recordOnlyForCheck()
            guard let source = center.source as? SyntheticCalendarSource else { return check(false, "\(tag): the synthetic calendar") }
            center.now = { t0.addingTimeInterval(offset) }
            // The synthetic source stands for the Mac's calendars beside the Google Calendar Favorite (calmeet).
            center.sourceForTesting = .mac
            source.set([meeting])
            center.setEnabled(true)
            at(20 * 60)
        }
        step { [self] done in waitUntil({ face()?.text == "in 20m" }, timeout: 3) { done() } }
        run { [self] in
            let f = face()
            check(f?.text == "in 20m" && f?.pill.isHidden == false && f?.isSoon == false,
                  "\(tag): 20 minutes before, the countdown sits on the faint pill (\(f?.text ?? "-"), soon \(f?.isSoon == true))")
            if let f, let t = s03bTile(item("cal")) {
                check(t.bounds.contains(f.pill.frame) && f.pill.frame.contains(f.label.frame),
                      "\(tag): the pill holds the countdown inside the tile (\(f.pill.frame), label \(f.label.frame))")
            }
            at(4 * 60 + 50)
        }
        step { [self] done in waitUntil({ face()?.isSoon == true }, timeout: 3) { done() } }
        run { [self] in
            let f = face()
            let bright = f?.pill.backgroundColor.flatMap { NSColor(cgColor: $0) }
            check(f?.text == "in 5m" && f?.isSoon == true && f?.lastSoonAnimated == true && (bright?.alphaComponent ?? 0) > 0.8,
                  "\(tag): five minutes before, the bright \"meeting soon\" pill fades in (\(f?.text ?? "-"), animated \(f?.lastSoonAnimated == true))")
        }
        real("hover Calendar", hover: "cal")
        run { [self] in
            guard !envFailed else { return }
            check(face()?.isSoon == true && face()?.pill.isHidden == false, "\(tag): a real hover over the Calendar Favorite keeps its pill")
        }
        capture("s03b-\(engine)-calendar")
        run { [self] in
            CalendarCard.shared.hide()
            motion(true)
            at(30 * 60)
        }
        step { [self] done in waitUntil({ face()?.isSoon == false }, timeout: 3) { done() } }
        run { at(60) }
        step { [self] done in waitUntil({ face()?.isSoon == true }, timeout: 3) { done() } }
        run { [self] in
            check(face()?.isSoon == true && face()?.lastSoonAnimated == false, "\(tag): Reduce Motion: the soon pill just appears (\(face()?.text ?? "-"))")
            motion(false)
            if let id = ids["cal"] { center.set(.countdown, false, for: id, store: c.store) }
        }
        step { [self] done in waitUntil({ face()?.pill.isHidden == true }, timeout: 3) { done() } }
        run { [self] in
            check(face()?.text == nil && face()?.pill.isHidden == true, "\(tag): Show Time to Next Meeting off hides the countdown and its pill")
            if let id = ids["cal"] { center.set(.countdown, true, for: id, store: c.store) }
            at(-10 * 60)   // ten minutes in: past the five late minutes
        }
        step { [self] done in waitUntil({ face()?.text == nil }, timeout: 3) { done() } }
        run { [self] in
            check(face()?.pill.isHidden == true && face()?.isSoon == false, "\(tag): past the meeting's late minutes the pill goes")
            center.setEnabled(false)
            center.now = Date.init
            center.sourceForTesting = nil
            center.clockMoved()
        }

        // 6. Calls: the Favorite that is a call, and the Favorite shared into one.
        let corner = { [unowned self] (n: String) -> AudioBadge.State in
            MainActor.assumeIsolated { s03bTile(item(n))?.audioBadge.map { $0.layer.isHidden ? .none : $0.state } ?? .none }
        }
        run { [self] in
            do {
                let pid = c.store.profile(ofSpace: c.currentSpaceID).id
                let t = try c.store.openTab(url: base + "/call", inSpace: c.currentSpaceID, activate: false, title: "Call")
                try c.store.move(.tab(t.id), to: .favorites(profileID: pid, index: 99))
                ids["call"] = c.store.tab(t.id)?.itemID ?? ""
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            } catch { check(false, "\(tag): the call Favorite (\(error))") }
        }
        step { [self] done in waitUntil({ page("call")?.title.contains("(live)") == true }, timeout: 15) { done() } }
        step { [self] done in waitUntil({ corner("call") == .inCall }, timeout: 6) { done() } }
        run { [self] in
            check(corner("call") == .inCall, "\(tag): a Favorite whose page is in a call shows the camera badge (\(corner("call")), title \(page("call")?.title ?? "-"))")
            check(corner("doc") == .none, "\(tag): the other Favorites have no call badge")
            guard let call = page("call"), let doc = page("doc") else { return check(false, "\(tag): the call and doc pages") }
            // What the engine reports when the call shares a tab (Engine/EngineCallSharing.swift), fed directly.
            CallTools.shared.captureChanged(call.profile, rows: [["capturerID": call.tabID, "capturing": true, "sharedTabID": doc.tabID]])
        }
        step { [self] done in waitUntil({ corner("doc") == .sharedToCall }, timeout: 3) { done() } }
        run { [self] in
            check(corner("doc") == .sharedToCall && corner("call") == .inCall,
                  "\(tag): the Favorite shared into the call shows the shared badge (\(corner("doc"))), the call keeps its own (\(corner("call")))")
        }
        capture("s03b-\(engine)-call")
        run { [self] in if let call = page("call") { CallTools.shared.captureChanged(call.profile, rows: []) } }
        step { [self] done in waitUntil({ corner("doc") == .none }, timeout: 3) { done() } }
        run { [self] in check(corner("doc") == .none, "\(tag): sharing stopped: the shared badge goes (\(corner("doc")))") }
        step { [self] done in
            guard let p = page("call") else { return done() }
            p.evaluate("hangup(); 'left'") { _ in done() }
        }
        step { [self] done in waitUntil({ corner("call") == .none }, timeout: 8) { done() } }
        run { [self] in check(corner("call") == .none, "\(tag): leaving the call clears the camera badge (\(corner("call")), title \(page("call")?.title ?? "-"))") }

        // 7. Show Unread Badge off: X's count and Slack's mention go, and the switch is saved.
        run { [self] in s03bToggle(item("x")); s03bToggle(item("slack")) }
        expect("x", "none", "Show Unread Badge off hides X's count while its title counts 9")
        expect("slack", "none", "Show Unread Badge off hides Slack's mention")
        setTitle("x", "(15) Home / X")
        expect("x", "none", "with the switch off a new count draws nothing")
        run { [self] in
            let saved = AppSettings(directory: AppPaths.dataDirectory).values.sidebarItems.noUnreadBadge
            check(saved.contains(item("x")) && saved.contains(item("slack")) && s03bSwitch(item("x")) == .off,
                  "\(tag): both switches are saved off")
            s03bToggle(item("slack"))   // Slack back on for the relaunch; X stays off
        }
        expect("slack", "mention (@)", "Show Unread Badge on again: the mention is back")

        // 8. A private window has no Favorites, so no badges.
        var priv: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                priv = w
                _ = w?.openPage(URL(string: base + "/x/home"))
                done()
            }
        }
        wait(2)
        run { [self] in
            guard let w = priv?.window else { return check(false, "\(tag): the private window opens") }
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            let views = w.contentView.map(all) ?? []
            check(!views.contains { $0 is FavoriteTileView }, "\(tag): a private window draws no Favorites, so no badge of any kind")
            priv?.closeWindow()
        }
        wait(0.5)
        run { [self] in
            URLRules.extraUnreadBadgeHosts = []
            URLRules.extraBadgeApps = [:]
            motion(nil)
            server = nil
            try? c.store.flush()
        }
    }
}
#endif

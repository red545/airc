// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// The scripted runs' mail and calendar accounts, all on a loopback fixture server: what each account answers (a
/// state, messages, meetings), changed by the check between steps. Never a real service.
final class FakeServiceAccounts: @unchecked Sendable {
    struct Account {
        var state = "signedOut"
        var mail: [[String: Any]] = []
        var events: [[String: Any]] = []
        /// "500 Internal Server Error" for a failing service.
        var status = "200 OK"
        var delay: TimeInterval = 0
    }

    private let lock = NSLock()
    private var accounts: [String: Account] = [:]
    private var log: [String] = []

    static func key(_ a: PreviewAccount) -> String {
        "\(a.service.rawValue)/\(a.key.replacingOccurrences(of: "/", with: "-"))/\(a.profileID)"
    }

    func set(_ a: PreviewAccount, _ change: (inout Account) -> Void) {
        lock.lock()
        change(&accounts[Self.key(a), default: Account()])
        lock.unlock()
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    /// The server's answer for /svc/…, /signin/… and /remove/… (nil: not ours).
    func page(for path: String) -> LocalPageServer.Page? {
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["svc", "signin", "remove"].contains(parts[0]) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        log.append(String(path.dropFirst()))
        var a = accounts[parts[1], default: Account()]
        switch parts[0] {
        case "signin": a.state = "ready"; a.status = "200 OK"
        case "remove": a.state = "signedOut"
        default: break
        }
        accounts[parts[1]] = a
        if parts[0] != "svc" { return .init(headers: ["Content-Type": "application/json"], body: "{}") }
        let body: [String: Any] = ["state": a.state, "mail": a.mail, "events": a.events]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return .init(status: a.status, headers: ["Content-Type": "application/json"], body: "", data: data, delay: a.delay)
    }
}

/// Mail and calendar previews from FakeServiceAccounts, over loopback HTTP (an ephemeral session: no cookies).
final class FakeServiceProvider: ServicePreviewProvider {
    let services: Set<PreviewService> = [.gmail, .outlookMail, .googleCalendar, .outlookCalendar]
    var fetchesRemotely: Bool { true }
    let base: String
    private let session = URLSession(configuration: .ephemeral)

    init(base: String) { self.base = base }

    private func get(_ path: String, _ done: @escaping (Data?, Int) -> Void) {
        guard let u = URL(string: base + path) else { return done(nil, 0) }
        session.dataTask(with: u) { d, r, _ in
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { done(d, code) }
        }.resume()
    }

    func fetch(_ a: PreviewAccount, completion: @escaping (PreviewState) -> Void) {
        get("/svc/" + FakeServiceAccounts.key(a)) { data, code in
            completion(Self.state(data, code, family: a.service.family, now: ServicePreviewCenter.shared.now()))
        }
    }

    func signIn(_ a: PreviewAccount, completion: @escaping () -> Void) { get("/signin/" + FakeServiceAccounts.key(a)) { _, _ in completion() } }
    func remove(_ a: PreviewAccount) { get("/remove/" + FakeServiceAccounts.key(a)) { _, _ in } }

    static func state(_ data: Data?, _ code: Int, family: PreviewService.Family, now: Date) -> PreviewState {
        guard code == 200, let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed(stale: nil) }
        switch o["state"] as? String {
        case "signedOut": return .signedOut
        case "expired": return .expired
        case "ready": break
        default: return .failed(stale: nil)
        }
        let iso = ISO8601DateFormatter()
        func date(_ e: [String: Any], _ name: String) -> Date? {
            if let m = e[name + "Minutes"] as? Double { return now.addingTimeInterval(m * 60) }
            return (e[name] as? String).flatMap(iso.date(from:))
        }
        switch family {
        case .mail:
            let mail = (o["mail"] as? [[String: Any]] ?? []).map { m in
                PreviewMail(id: m["id"] as? String ?? "", sender: m["sender"] as? String ?? "", senderAddress: m["senderAddress"] as? String,
                            subject: m["subject"] as? String ?? "", snippet: m["snippet"] as? String ?? "",
                            date: now.addingTimeInterval(-60 * (m["minutesAgo"] as? Double ?? 0)), url: m["url"] as? String,
                            body: m["body"] as? String)
            }
            return .ready(.mail(mail.sorted { $0.date > $1.date }))
        case .calendar:
            let events = (o["events"] as? [[String: Any]] ?? []).compactMap { e -> CalendarEvent? in
                guard let s = date(e, "start"), let end = date(e, "end") else { return nil }
                return CalendarEvent(id: e["id"] as? String ?? "", title: e["title"] as? String ?? "", start: s, end: end,
                                     isAllDay: e["allDay"] as? Bool ?? false,
                                     link: (e["link"] as? String).flatMap(URL.init(string:)).map { MeetingLink(url: $0, service: .web) })
            }
            return .ready(.calendar(events))
        case .recents:
            return .ready(.recents([]))
        }
    }
}

/// `--script p11a` (both engines): P11a, rich previews and Live Calendar's account seam (parity rows S04, S16, M08), on
/// loopback fixtures only. No real Google, Microsoft, Notion, Figma or Linear page, account or icon is asked for: the
/// service items are pinned and never opened, their icons are loopback PNGs, the accounts are FakeServiceProvider's,
/// and what the cards would open is read from hooks (ServicePreviewCenter.openedForTesting, peekForTesting).
///   - S04, every state of a mail card: loading, signed in with unread mail (newest first), a message and "+" opening
///     in the item's own tab in the same account, signed out (Arc's sentence and Sign In, which signs in), expired
///     (Sign In or Remove), a failure keeping the last mail, a failure with nothing, and Arc's empty sentence;
///   - accounts and profiles never mix: another profile's Gmail shows its own mail, a second account (/u/1/) that was
///     never opened keeps the picture card and is never fetched;
///   - recent pages from the profile's history (Notion, Linear), newest first, opening in a new tab; an empty Figma;
///   - the calendar card (Arc's hour grid, calgrid): opened a quarter hour before now with the now line there,
///     overlapping meetings side by side, a meeting given in another time zone at its moment, the all-day event in the
///     strip above the hours, a big Join for the one moments away with a call (a loopback call), "+" and a meeting
///     opening the calendar in its item;
///   - M08: with EventKit not allowed, the Calendar Favorite's account drives Live Calendar (countdown, Join prompt,
///     ⌃⌘J's target among overlapping meetings) and signing out stops it; Live Calendar's own card is that Favorite's
///     only card;
///   - S16: tab pictures belong to their profile: Settings' Clear Data and deleting a profile take that profile's
///     pictures, cards' content and accounts while the others' stay; a profile that's gone keeps no picture; a private
///     window's pages are never pictured; a page that left the screen still shows its kept picture;
///   - Peek Email: the code from the site's newest email is typed into the focused field; another profile's mail is
///     never used (its inbox opens instead); a sign-in link opens in Peek;
///   - no icon was asked of the network except loopback, and no service item ever got a page.
extension SnapshotRunner {
    func parityP11aScenario() {
        let tp = { self.c.tabPreview }
        let center = ServicePreviewCenter.shared
        let fake = FakeServiceAccounts()
        var server: LocalPageServer?
        var base = ""
        var provider: FakeServiceProvider?
        var home = "", other = "", profileA = "", profileB = ""
        var gmail = "", gmail2 = "", gmailB = "", notion = "", linear = "", figma = "", gcal = "", calFav = ""
        var red = "", blue = "", signin = "", signinA = ""
        var opened: [(URL, String)] = []
        var peeked: [URL] = []
        var lastHovered: NSView?
        let page = { self.c.pageView(for: self.c.currentSpaceID) }

        func account(_ url: String, _ profile: String) -> PreviewAccount { PreviewAccount(url: url, profileID: profile)! }
        let gmailURL = "https://mail.google.com/mail/u/0/#inbox"
        let gmail2URL = "https://mail.google.com/mail/u/1/#inbox"
        let gcalURL = "https://calendar.google.com/calendar/u/0/r"
        // The Calendar Favorite is Outlook's: a Google Calendar Favorite's tile shows Google's date logo, from the network.
        let outCalURL = "https://outlook.live.com/calendar/0/view/day"
        var aGmail: PreviewAccount { account(gmailURL, profileA) }
        var bGmail: PreviewAccount { account(gmailURL, profileB) }
        var aCal: PreviewAccount { account(gcalURL, profileA) }
        var aOutCal: PreviewAccount { account(outCalURL, profileA) }

        func row(_ itemID: String) -> TabRowView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.entry?.item?.id == itemID }
        }
        func todayRow(_ tabID: String) -> TabRowView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.tabID == tabID }
        }
        /// SwiftUI records anchor frames as views appear but never forgets them: a state's anchors are cleared before
        /// it comes, so a check only sees what's on the card now.
        /// The texts a row shows (its title, and the line under it when there is one).
        func rowLines(_ r: TabRowView?) -> [String] {
            MainActor.assumeIsolated {
                r?.subviews.compactMap { v -> String? in
                    guard let l = v as? AircFadingLabel, !l.isHidden, !l.stringValue.isEmpty else { return nil }
                    return l.stringValue
                } ?? []
            }
        }
        func clearAnchors() { TestAnchors.frames = TestAnchors.frames.filter { !$0.key.hasPrefix("svc.") } }
        func tile(_ itemID: String) -> FavoriteTileView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == itemID }
        }
        func centre(_ v: NSView) -> NSPoint { v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }
        func movePointer(to p: NSPoint, over target: NSView?) {
            if lastHovered !== target {
                if let prev = lastHovered, let e = NSEvent.enterExitEvent(with: .mouseExited, location: p, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: 0, userData: nil) { prev.mouseExited(with: e) }
                if let target, let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: 0, userData: nil) { target.mouseEntered(with: e) }
            }
            lastHovered = target
        }
        func hover(_ v: NSView?) {
            guard let v else { return movePointer(to: centre(c.card), over: nil) }
            movePointer(to: centre(v), over: v)
        }
        // Real input (UI driver, a dedicated foreground session with the app key and active) when allowed; else posted
        // events, which on the build Mac never reach the cards' buttons in a background window (the click probe below
        // says why). The log counts each; with the driver requested, a posted one is a FAIL-ENV.
        var realHovers = 0, postedHovers = 0, realClicks = 0, postedClicks = 0, secondClicks = 0
        func realInput() -> Bool {
            UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
                && NSApp.isActive && c.window.isKeyWindow && c.window.isOnActiveSpace
        }
        func screenPoint(_ p: NSPoint) -> (x: Double, y: Double) {
            let g = c.window.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
            return (Double(g.x), Double(top - g.y))
        }
        /// A real pointer move (20 steps over 200 ms, delivered to this app): the row's own tracking area sees it.
        func realMove(_ p: NSPoint, targeted: Bool = true, _ done: @escaping (Bool, String) -> Void) {
            let s = screenPoint(p)
            // `--pid` delivers only to a foreground target (the driver refuses a background one): untargeted when we aren't in front.
            UIDriverClient.run(["--move", String(s.x), String(s.y), "--steps", "20", "--duration", "200"]
                               + (targeted ? ["--pid", String(ProcessInfo.processInfo.processIdentifier)] : []), done)
        }
        func realClick(_ p: NSPoint, _ done: @escaping (Bool, String) -> Void) {
            let s = screenPoint(p)
            UIDriverClient.run(["--click", String(s.x), String(s.y)], done)
        }
        /// The pointer comes to `v` from off the sidebar, and the card has had time to show (and its account to answer).
        func hoverFresh(_ v: @escaping () -> NSView?, settle: Double = 0.9) {
            step { [self] done in
                tp().hide()
                clearAnchors()
                guard realInput() else { hover(nil); return done() }
                realMove(centre(c.card)) { _, _ in done() }
            }
            wait(0.45)   // past the "warm" return
            step { [self] done in
                guard realInput(), let target = v() else { hover(v()); postedHovers += 1; return done() }
                realMove(centre(target)) { [self] ok, out in
                    if ok { realHovers += 1 } else { note("p11a: driver move failed (\(out)); posted hover"); hover(target); postedHovers += 1 }
                    done()
                }
            }
            wait(settle)
        }
        var card: ServicePreviewCardView? { tp().serviceCard?.superview != nil ? tp().serviceCard : nil }
        var model: ServicePreviewModel? { card?.model }
        func mailIDs() -> [String] {
            if case .mail(let m)? = model?.state.content { return m.map(\.id) }
            return []
        }
        func pageTitles() -> [String] {
            if case .recents(let p)? = model?.state.content { return p.map(\.title) }
            return []
        }
        func clickCard(_ anchor: String, until ok: @escaping () -> Bool) {
            step { [self] done in
                guard let h = card?.hostingView else { check(false, "p11a: click \(anchor): no card"); return done() }
                guard realInput(), let p = anchorPoint(anchor, in: h) else {
                    postedClicks += 1
                    if UIDriverClient.requested { note("FAIL-ENV p11a: real click on \(anchor) unavailable (driver \(UIDriverClient.available), key \(c.window.isKeyWindow), active \(NSApp.isActive)); posted instead") }
                    return clickAnchor(anchor, in: h) {
                        self.waitUntil(ok, timeout: 1.5) {
                            guard !ok(), let h = card?.hostingView else { return done() }
                            self.note("p11a: posted \(anchor) missed (\(TestAnchors.lastHit[anchor] ?? "-")), clicking again")
                            self.clickAnchor(anchor, in: h) { self.waitUntil(ok, timeout: 1.5) { done() } }
                        }
                    }
                }
                TestAnchors.lastHit[anchor] = String(format: "(%.0f, %.0f)", p.x, p.y)
                realClick(p) { [self] okay, out in
                    if okay { realClicks += 1 } else { note("p11a: driver click on \(anchor) failed: \(out)") }
                    waitUntil(ok, timeout: 2) { [self] in
                        // A real click that missed is reported, never hidden: one more, counted.
                        guard !ok(), let h = card?.hostingView, let p = anchorPoint(anchor, in: h) else { return done() }
                        note("p11a: real click on \(anchor) missed (\(TestAnchors.lastHit[anchor] ?? "-")), clicking again")
                        secondClicks += 1
                        realClick(p) { _, _ in self.waitUntil(ok, timeout: 2) { done() } }
                    }
                }
            }
        }
        /// Why posted clicks miss: one posted click on the mail card's "+" in the state the run is in, then (real input
        /// only) the same with the app deactivated and a real click, which is what a person does with another app in front.
        /// Logs what the click reached, whether it fired, and whether the card survived.
        func clickProbe(_ anchor: String, fired: @escaping () -> Bool, reset: @escaping () -> Void, row target: @escaping () -> NSView?) {
            var describe = ""
            func state() -> String { "key \(c.window.isKeyWindow), active \(NSApp.isActive), card \(card != nil ? "shown" : "gone"), pressed \(NSEvent.pressedMouseButtons)" }
            step { [self] done in
                guard let h = card?.hostingView else { note("p11a: probe: no card"); return done() }
                describe = state()
                clickAnchor(anchor, in: h) { [self] in
                    waitUntil(fired, timeout: 1.5) { [self] in
                        note("p11a: probe: POSTED click on \(anchor) in the window state (\(describe)): fired \(fired()); after it: \(state()); it reached \(TestAnchors.lastHit[anchor] ?? "-")")
                        reset()
                        done()
                    }
                }
            }
            hoverFresh(target, settle: 0.5)
            step { [self] done in
                guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1", realInput() else {
                    note("p11a: probe: inactive-app real click skipped (real input unavailable)")
                    return done()
                }
                // Another app (Finder, shown again; the preflight hid it) in front: the pointer comes to the row (HID,
                // delivered to this app), then the card's button. Our window always gets key again afterwards.
                func restore(_ then: @escaping () -> Void) {
                    NSApp.activate(ignoringOtherApps: true)
                    c.window.makeKeyAndOrderFront(nil)
                    waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) { then() }
                }
                let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
                finder?.unhide()
                if let finder { NSApp.yieldActivation(to: finder); _ = finder.activate(from: NSRunningApplication.current, options: []) }
                else { NSApp.deactivate() }
                waitUntil({ !NSApp.isActive }, timeout: 3) { [self] in
                    guard !NSApp.isActive else {
                        note("FAIL-ENV p11a: probe: the app would not deactivate (Finder \(finder != nil))")
                        return restore { done() }
                    }
                    guard let v = target() else { note("p11a: probe: no row"); return restore { done() } }
                    tp().hide(); clearAnchors()
                    // Off the row first (the pointer is still on it from the hover above), then back onto it.
                    realMove(centre(c.card), targeted: false) { [self] _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    realMove(centre(v), targeted: false) { [self] moved, out in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [self] in
                            guard let h = card?.hostingView, let p = anchorPoint(anchor, in: h) else {
                                note("FAIL-ENV p11a: probe: with the app inactive the hover showed no card (move \(moved ? "ok" : "failed: " + out); \(state()))")
                                return restore { done() }
                            }
                            let sp = c.window.convertPoint(toScreen: p)
                            let top = NSWindow.windowNumber(at: sp, belowWindowWithWindowNumber: 0)
                            if top != c.window.windowNumber {
                                // Another process's window (a stray Finder window the owner or an earlier run left) covers the card's button:
                                // the click would land on it, so nothing about our card is learned. Not run, with the evidence.
                                let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(top)) as? [[String: Any]])?.first
                                let owner = (info?[kCGWindowOwnerName as String] as? String) ?? "?"
                                let bounds = (info?[kCGWindowBounds as String] as? [String: Any]).map { "\($0)" } ?? "?"
                                note("SKIP p11a: probe: inactive-app real click not run: window \(top) of \(owner) \(bounds) covers the button at \(sp) (front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
                                return restore { done() }
                            }
                            describe = state() + ", front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"), "
                                + (top == c.window.windowNumber ? "our window is the top one at the click point" : "window \(top) is on top at the click point, not ours")
                            realClick(p) { [self] ok1, out1 in
                                waitUntil(fired, timeout: 2.5) { [self] in
                                    let first = fired()
                                    let afterFirst = state() + ", front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"
                                    // A swallowed first click is characterized: does a second one act?
                                    func finishProbe(_ second: Bool?) {
                                        note("p11a: probe: REAL click on \(anchor) with the app inactive (\(describe); driver \(ok1 ? "ok" : "failed: " + out1)): fired \(first); after it: \(afterFirst)"
                                             + (second.map { "; a second real click then fired \($0)" } ?? ""))
                                        check(first, "p11a: a real first click on a service card's button works with another app in front (it activates and acts)")
                                        reset()
                                        restore { done() }
                                    }
                                    guard !first, let h2 = card?.hostingView, let p2 = anchorPoint(anchor, in: h2) else { return finishProbe(nil) }
                                    realClick(p2) { [self] _, _ in waitUntil(fired, timeout: 2) { finishProbe(fired()) } }
                                }
                            }
                        }
                    }
                    }
                    }
                    }
                }
        }
        func iconPNG(_ color: NSColor, _ letter: String) -> Data {
            let img = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { r in
                color.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
                let s = NSAttributedString(string: letter, attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .bold),
                                                                         .foregroundColor: NSColor.white])
                let z = s.size()
                s.draw(at: NSPoint(x: (r.width - z.width) / 2, y: (r.height - z.height) / 2))
                return true
            }
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return Data() }
            return png
        }
        func tinyImage() -> CGImage {
            CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        func colored(_ name: String, _ hex: String) -> String {
            "<title>\(name) page</title><style>html,body{margin:0;height:100%;background:\(hex)}</style><h1>\(name)</h1>"
        }

        let mailA: [[String: Any]] = [
            ["id": "a1", "sender": "Ada Lovelace", "senderAddress": "ada@example.com", "subject": "Notes on the engine",
             "snippet": "I've gone through the diagrams you sent and have a few thoughts on the store.", "minutesAgo": 12,
             "url": "https://mail.google.com/mail/u/0/#inbox/a1"],
            ["id": "a2", "sender": "Grace Hopper", "senderAddress": "grace@example.com", "subject": "Compiler review",
             "snippet": "Friday works for me. Bring the tapes.", "minutesAgo": 60 * 22],
            ["id": "a3", "sender": "Example Weekly", "senderAddress": "news@example.org", "subject": "This week in browsers",
             "snippet": "Tabs, spaces and everything between.", "minutesAgo": 60 * 30],
        ]

        // MARK: Fixtures

        step { [self] done in
            var pages: [String: LocalPageServer.Page] = [
                "/red.html": .init(body: colored("Red", "#d32f2f")),
                "/blue.html": .init(body: colored("Blue", "#1e5fd6")),
                "/signin.html": .init(body: "<title>Sign in</title><p>We emailed you a code.</p><input id=code autofocus autocomplete=one-time-code>"),
                "/call.html": .init(body: "<title>Call</title><h1>Call</h1>"),
            ]
            for (name, color, letter) in [("gmail", NSColor.systemRed, "M"), ("gcal", NSColor.systemBlue, "31"),
                                           ("notion", NSColor.black, "N"), ("linear", NSColor.systemIndigo, "L"),
                                           ("figma", NSColor.systemPurple, "F")] {
                pages["/icon/\(name).png"] = .init(headers: ["Content-Type": "image/png"], body: "", data: iconPNG(color, letter))
            }
            server = LocalPageServer(responses: pages)
            server?.handler = { path in fake.page(for: path) }
            server?.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }
        run { [self] in
            guard !base.isEmpty, let app else { return check(false, "p11a: a loopback server") }
            home = c.currentSpaceID
            profileA = c.store.profile(ofSpace: home).id
            do {
                let pB = try c.store.createProfile(name: "P11a Other")
                profileB = pB.id
                other = try c.store.createSpace(name: "P11a Other", icon: .emoji("🧪"), profileID: profileB, after: home).id
                func item(_ url: String, _ title: String, _ icon: String, space: String) throws -> String {
                    try pin(url, title: title, icon: base + "/icon/\(icon).png", space: space)
                    return c.store.pinnedRoots(ofSpace: space).last { $0.savedURL == url }?.id ?? ""
                }
                gmail = try item(gmailURL, "Gmail", "gmail", space: home)
                gmail2 = try item(gmail2URL, "Gmail (second account)", "gmail", space: home)
                notion = try item("https://www.notion.so/", "Notion", "notion", space: home)
                linear = try item("https://linear.app/acme", "Linear", "linear", space: home)
                figma = try item("https://www.figma.com/files/recents", "Figma", "figma", space: home)
                gcal = try item(gcalURL, "Calendar", "gcal", space: home)
                gmailB = try item(gmailURL, "Gmail", "gmail", space: other)
                try favorite(outCalURL, title: "Calendar", icon: base + "/icon/gcal.png", profile: profileA, space: home)
                calFav = c.store.favorites(ofProfile: profileA).first { $0.savedURL == outCalURL }?.id ?? ""
            } catch { check(false, "p11a: fixtures (\(error))") }
            // The sites "opened" in each profile: their history (no page is loaded for it).
            let h = app.history!
            let t0 = Date()
            var minutesAgo = 40.0
            h.now = { t0.addingTimeInterval(-minutesAgo * 60) }
            h.recordVisit(profileID: profileA, url: gmailURL, title: "Inbox - Gmail")
            h.recordVisit(profileID: profileA, url: gcalURL, title: "Google Calendar")
            h.recordVisit(profileID: profileA, url: outCalURL, title: "Calendar - Outlook")
            h.recordVisit(profileID: profileB, url: gmailURL, title: "Inbox - Gmail")
            let pages: [(String, String)] = [("https://www.notion.so/Roadmap-0001", "Roadmap"),
                                             ("https://www.notion.so/Team-Directory-0002", "Team Directory"),
                                             ("https://www.notion.so/Onboarding-0003", "New Engineer Onboarding"),
                                             ("https://linear.app/acme/team/ENG/active", "Engineering › Active issues"),
                                             ("https://linear.app/acme/my-issues/assigned", "My issues")]
            for (u, t) in pages {
                minutesAgo -= 6
                h.recordVisit(profileID: profileA, url: u, title: t)
            }
            // The newest Notion page first: it's visited again last, just now.
            minutesAgo = 0
            h.recordVisit(profileID: profileA, url: "https://www.notion.so/Team-Directory-0002", title: "Team Directory")
            h.now = Date.init
            // What the accounts answer from the start (the rows ask them as soon as they render).
            fake.set(account(gmailURL, profileA)) { $0.state = "ready"; $0.mail = mailA }
            fake.set(account(gmailURL, profileB)) { $0.state = "ready"; $0.mail = [["id": "b1", "sender": "Bea", "subject": "Other profile",
                                                                                   "snippet": "Only in profile B.", "minutesAgo": 3]] }
            provider = FakeServiceProvider(base: base)
            center.register(provider!)
            center.openedForTesting = { opened.append(($0, $1)) }
            center.peekForTesting = { peeked.append($0) }
            red = (try? c.store.openTab(url: base + "/red.html", inSpace: home, title: "Red page"))?.id ?? ""
            blue = (try? c.store.openTab(url: base + "/blue.html", inSpace: home, title: "Blue page"))?.id ?? ""
            c.reloadAll(animated: false)
            check(row(gmail) != nil && row(notion) != nil && row(gcal) != nil && tile(calFav) != nil,
                  "p11a: the service items are in the sidebar (pinned and a Calendar Favorite), never opened")
        }

        // MARK: S04: a mail card's states

        // The rows' first answers are in; then a slow account, its card asked afresh (registering again forgets it).
        wait(0.6)
        run { [self] in
            fake.set(aGmail) { $0.delay = 1.2 }
            if let provider { center.register(provider) }
        }
        hoverFresh({ row(gmail) }, settle: 0.6)
        run { [self] in
            check(tp().isShowing && tp().thumbnail == .service && model?.account == aGmail,
                  "p11a: a pinned Gmail shows its mail card, not the page's picture (\(tp().thumbnail.rawValue))")
            check(model?.state == .loading && TestAnchors.frames["svc.loading"] != nil, "p11a: loading while the account answers (\(String(describing: model?.state)))")
        }
        step { [self] done in waitUntil({ !mailIDs().isEmpty }, timeout: 3) { done() } }
        wait(0.3)
        run { [self] in
            check(mailIDs() == ["a1", "a2", "a3"], "p11a: signed in: the unread mail, newest first (\(mailIDs()))")
            check(rowLines(row(gmail)).contains("3 Recent"), "p11a: the pinned Gmail row's line says \"3 Recent\" (\(rowLines(row(gmail))))")
            check(TestAnchors.frames["svc.mail.a1"] != nil && TestAnchors.frames["svc.action"] != nil,
                  "p11a: each message is a row, with \"+\" (New Email)")
            check(card.map { $0.frame.minX >= c.sidebar.convert(c.sidebar.bounds, to: c.root).maxX - ServicePreviewCardView.margin } ?? false,
                  "p11a: the card is beside the sidebar")
            fake.set(aGmail) { $0.delay = 0 }
        }
        capture("p11a-mail")
        // Why posted clicks miss, and that a real first click works with another app in front (the probe resets `opened`).
        clickProbe("svc.action", fired: { !opened.isEmpty }, reset: { opened = [] }, row: { row(gmail) })
        hoverFresh({ row(gmail) }, settle: 0.6)
        clickCard("svc.mail.a1") { !peeked.isEmpty || opened.contains { $0.1 == gmail } }
        run { [self] in
            // No page of the account's profile is in front here (and the account's own page isn't loaded), so Peek Email
            // (S04, ParityS04Check) has no page to peek from: the message opens in the item's own tab.
            check(opened.last.map { $0.0.absoluteString == "https://mail.google.com/mail/u/0/#inbox/a1" && $0.1 == gmail } ?? false && peeked.isEmpty,
                  "p11a: a message opens in the Gmail item itself when no page of its profile is in front (\(opened.last.map { "\($0.0) in \($0.1)" } ?? "nothing"); peeked \(peeked.map(\.absoluteString)))")
            opened = []
            peeked = []
        }
        hoverFresh({ row(gmail) }, settle: 0.5)
        clickCard("svc.action") { !opened.isEmpty }
        run { [self] in
            check(opened.last.map { $0.0.absoluteString == "https://mail.google.com/mail/u/0/#inbox?compose=new" && $0.1 == gmail } ?? false,
                  "p11a: \"+\" composes in the same account (\(opened.last?.0.absoluteString ?? "nothing"))")
            opened = []
        }
        // Signed out, and Sign In.
        run { [self] in
            fake.set(aGmail) { $0.state = "signedOut" }
            center.refresh(aGmail, force: true)
        }
        hoverFresh({ row(gmail) }, settle: 0.7)
        run { [self] in
            check(model?.state == .signedOut && TestAnchors.frames["svc.signIn"] != nil,
                  "p11a: signed out: \"\(PreviewService.gmail.signInText ?? "")\" and Sign In")
        }
        capture("p11a-signed-out")
        clickCard("svc.signIn") { mailIDs() == ["a1", "a2", "a3"] }
        run { [self] in
            check(mailIDs() == ["a1", "a2", "a3"] && fake.requests.contains { $0.hasPrefix("signin/gmail/u-0/" + profileA) },
                  "p11a: Sign In signs in (the provider's sign-in, then the mail)")
        }
        // Expired: Remove.
        run { [self] in
            fake.set(aGmail) { $0.state = "expired" }
            clearAnchors()
            center.refresh(aGmail, force: true)
        }
        step { [self] done in waitUntil({ model?.state == .expired }, timeout: 2) { done() } }
        wait(0.3)
        run { [self] in
            check(model?.state == .expired && TestAnchors.frames["svc.remove"] != nil && mailIDs().isEmpty,
                  "p11a: signed out by the service: \"You were signed out of Gmail.\", Sign In or Remove, no mail shown")
        }
        capture("p11a-expired")
        clickCard("svc.remove") { model?.state == .signedOut }
        run { [self] in
            check(model?.state == .signedOut && fake.requests.contains { $0.hasPrefix("remove/gmail/u-0/" + profileA) },
                  "p11a: Remove forgets the account (signed out)")
        }
        // Failures: with the last mail, and with nothing.
        run { [self] in
            fake.set(aGmail) { $0.state = "ready"; $0.status = "200 OK" }
            center.refresh(aGmail, force: true)
        }
        step { [self] done in waitUntil({ !mailIDs().isEmpty }, timeout: 2) { done() } }
        run { [self] in
            fake.set(aGmail) { $0.status = "500 Internal Server Error" }
            center.refresh(aGmail, force: true)
        }
        step { [self] done in waitUntil({ if case .failed? = model?.state { return true }; return false }, timeout: 2) { done() } }
        run { [self] in
            var stale: [String] = []
            if case .failed(let kept?)? = model?.state, case .mail(let m) = kept { stale = m.map(\.id) }
            check(stale == ["a1", "a2", "a3"], "p11a: a failure keeps the last mail, with a warning (\(stale))")
            fake.set(aGmail) { $0.state = "signedOut"; $0.status = "200 OK" }
            center.refresh(aGmail, force: true)
        }
        step { [self] done in waitUntil({ model?.state == .signedOut }, timeout: 2) { done() } }
        run { [self] in
            fake.set(aGmail) { $0.status = "500 Internal Server Error" }
            clearAnchors()
            center.refresh(aGmail, force: true)
        }
        step { [self] done in waitUntil({ model?.state == .failed(stale: nil) }, timeout: 2) { done() } }
        wait(0.3)
        run { [self] in
            check(model?.state == .failed(stale: nil) && TestAnchors.frames["svc.failed"] != nil,
                  "p11a: a failure with nothing to show: \"Airc is having trouble getting new data, but will try again soon.\"")
            fake.set(aGmail) { $0.state = "ready"; $0.status = "200 OK"; $0.mail = [] }
            clearAnchors()
            center.refresh(aGmail, force: true)
        }
        step { [self] done in waitUntil({ model?.state == .ready(.mail([])) }, timeout: 2) { done() } }
        wait(0.3)
        run { [self] in
            check(model?.state == .ready(.mail([])) && TestAnchors.frames["svc.empty"] != nil,
                  "p11a: no unread mail: \"No unread emails, you can exhale!\"")
            fake.set(aGmail) { $0.mail = mailA }
            center.refresh(aGmail, force: true)
        }

        // MARK: Accounts and profiles never mix

        var fetchesBefore = 0
        run { [self] in fetchesBefore = center.stats.remoteFetches.count }
        hoverFresh({ row(gmail2) }, settle: 0.7)
        run { [self] in
            let a2 = account(gmail2URL, profileA)
            check(tp().isShowing && tp().thumbnail != .service && !center.stats.remoteFetches.dropFirst(fetchesBefore).contains(a2)
                  && center.stats.refusedUnopened.contains(a2),
                  "p11a: a second account (/u/1/) never opened here keeps the picture card and is never fetched (\(tp().thumbnail.rawValue))")
        }
        run { [self] in
            hover(nil)
            tp().hide()
            c.switchToSpace(other, animated: false)
        }
        wait(0.4)
        hoverFresh({ row(gmailB) }, settle: 0.4)
        step { [self] done in waitUntil({ mailIDs() == ["b1"] }, timeout: 3) { done() } }
        run { [self] in
            check(model?.account == bGmail && mailIDs() == ["b1"],
                  "p11a: the other profile's Gmail shows its own mail, never this one's (\(mailIDs()))")
            check(center.state(aGmail) != center.state(bGmail), "p11a: one cache entry per profile and account")
        }

        // MARK: Peek Email

        // In profile B: no code from this site in B's mail, so B's inbox opens (A's code is never used).
        var peekResult: PeekEmailResult?
        run { [self] in
            fake.set(aGmail) { $0.mail = mailA + [["id": "code", "sender": "Localhost", "senderAddress": "login@localhost",
                                                   "subject": "Your sign-in code", "snippet": "Your verification code is 482913.",
                                                   "minutesAgo": 2]] }
            hover(nil)
            tp().hide()
            signin = (try? c.store.openTab(url: base + "/signin.html", inSpace: other, title: "Sign in"))?.id ?? ""
            c.reloadAll(animated: false)
        }
        // Profile B's engine profile, loaded before its page is shown.
        step { [self] done in c.profiles.whenLoaded(profileB, { _ in done() }, failed: { self.note("p11a: profile B didn't load"); done() }) }
        run { [self] in c.show(signin, focus: true) }
        step { [self] done in waitUntil({ self.c.engineTab(for: signin)?.isLoading == false && self.c.engineTab(for: signin)?.title == "Sign in" }, timeout: 8) { done() } }
        step { [self] done in
            peeked = []
            c.peekEmail { r in peekResult = r; done() }
        }
        run { [self] in
            check(peekResult == .inbox(URL(string: gmailURL)!) && peeked == [URL(string: gmailURL)!],
                  "p11a: Peek Email in another profile uses only its own mail: no code there, its inbox in Peek (\(String(describing: peekResult)))")
        }
        // In profile A: the code goes into the focused field.
        run { [self] in
            c.switchToSpace(home, animated: false)
            signinA = (try? c.store.openTab(url: base + "/signin.html", inSpace: home, title: "Sign in"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(signinA, focus: true)
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: signinA)?.isLoading == false && self.c.engineTab(for: signinA)?.title == "Sign in" }, timeout: 8) { done() } }
        step { [self] done in
            guard let p = c.engineTab(for: signinA) else { return done() }
            p.evaluate("document.getElementById('code').focus(); document.activeElement && document.activeElement.id") { _ in
                DispatchQueue.main.async { done() }
            }
        }
        step { [self] done in
            peeked = []
            peekResult = nil
            c.peekEmail { r in peekResult = r; done() }
        }
        var typed = ""
        step { [self] done in
            guard let p = c.engineTab(for: signinA) else { return done() }
            p.evaluate("document.getElementById('code').value") { v in
                DispatchQueue.main.async {
                    typed = v as? String ?? ""
                    done()
                }
            }
        }
        run { [self] in
            switch peekResult {
            case .typed("482913")?: check(typed == "482913", "p11a: Peek Email types the site's newest code into the focused field (\(typed))")
            case .copied("482913")?:
                // The field has to have focus in the page; in a background run it can lack it.
                check(NSPasteboard.general.string(forType: .string) == "482913",
                      "p11a: Peek Email copies the site's newest code when no field has focus")
            default: check(false, "p11a: Peek Email finds the code (\(String(describing: peekResult)), field \"\(typed)\")")
            }
        }
        // A sign-in link instead of a code: it opens in Peek.
        step { [self] done in
            fake.set(aGmail) { $0.mail = mailA + [["id": "link", "sender": "Localhost", "senderAddress": "login@localhost",
                                                   "subject": "Sign in", "snippet": "Use this link to sign in.", "minutesAgo": 1,
                                                   "body": "https://localhost/login?token=abc"]] }
            peeked = []
            peekResult = nil
            c.peekEmail { r in peekResult = r; done() }
        }
        run { [self] in
            check(peekResult == .link(URL(string: "https://localhost/login?token=abc")!) && peeked.count == 1,
                  "p11a: a sign-in link from the site opens in Peek (\(String(describing: peekResult)))")
            fake.set(aGmail) { $0.mail = mailA }
        }

        // MARK: Recent pages

        hoverFresh({ row(notion) }, settle: 0.6)
        run { [self] in
            check(tp().thumbnail == .service && pageTitles() == ["Team Directory", "New Engineer Onboarding", "Roadmap"],
                  "p11a: Notion lists the pages visited there in this profile, newest first (\(pageTitles()))")
            check(center.stats.remoteFetches.allSatisfy { $0.service.family != .recents }, "p11a: recent pages are never fetched")
        }
        capture("p11a-notion")
        clickCard("svc.page.https://www.notion.so/Onboarding-0003") { !opened.isEmpty }
        run { [self] in
            check(opened.last.map { $0.0.absoluteString == "https://www.notion.so/Onboarding-0003" && $0.1.isEmpty } ?? false,
                  "p11a: a recent page opens as a new tab (\(opened.last?.0.absoluteString ?? "nothing"))")
            opened = []
        }
        hoverFresh({ row(notion) }, settle: 0.5)
        clickCard("svc.action") { !opened.isEmpty }
        run { [self] in
            check(opened.last.map { $0.0.absoluteString == "https://www.notion.so/new" && $0.1.isEmpty } ?? false,
                  "p11a: Notion's \"+\" opens a new page in a new tab")
            opened = []
        }
        hoverFresh({ row(linear) }, settle: 0.6)
        run { [self] in
            check(pageTitles() == ["My issues", "Engineering › Active issues"], "p11a: Linear lists only Linear's pages (\(pageTitles()))")
        }
        hoverFresh({ row(figma) }, settle: 0.6)
        run { [self] in
            check(model?.state == .ready(.recents([])) && TestAnchors.frames["svc.empty"] != nil,
                  "p11a: Figma with nothing visited: \"Recent Figma files appear here.\"")
        }

        // MARK: The calendar card

        let zone = TimeZone(identifier: "America/Los_Angeles")!
        var tzEvent = ""
        run { [self] in
            // A meeting given in Los Angeles time, three hours from now, rounded to the hour there.
            var la = Calendar(identifier: .gregorian)
            la.timeZone = zone
            let start = la.dateInterval(of: .hour, for: center.now().addingTimeInterval(3 * 3600))!.start
            let iso = ISO8601DateFormatter()
            iso.timeZone = zone
            tzEvent = iso.string(from: start)
            let events: [[String: Any]] = [
                ["id": "standup", "title": "Standup", "startMinutes": 4, "endMinutes": 19, "link": base + "/call.html"],
                ["id": "pairing", "title": "Pairing", "startMinutes": 10, "endMinutes": 50],
                ["id": "review", "title": "Design review", "startMinutes": 30, "endMinutes": 70],
                ["id": "la", "title": "West coast sync", "start": tzEvent, "end": iso.string(from: start.addingTimeInterval(1800))],
                ["id": "holiday", "title": "Company holiday", "startMinutes": -600, "endMinutes": 840, "allDay": true],
            ]
            // The pinned Google Calendar's card, and the Outlook Calendar Favorite's account for Live Calendar (M08).
            for a in [aCal, aOutCal] {
                fake.set(a) { $0.state = "ready"; $0.events = events }
                center.refresh(a, force: true)
            }
        }
        hoverFresh({ row(gcal) }, settle: 0.4)
        step { [self] done in waitUntil({ if case .calendar? = model?.state.content { return true }; return false }, timeout: 3) { done() } }
        wait(0.4)
        run { [self] in
            let f = TestAnchors.frames
            // calgrid: Arc's hour grid. Standup (4–19) and pairing (10–50) overlap, so they share the width; review
            // (30–70) overlaps pairing only and takes standup's column again.
            let s = f["svc.event.standup"], p = f["svc.event.pairing"], r = f["svc.event.review"]
            check(s != nil && p != nil && r != nil && abs((s?.width ?? 0) - (p?.width ?? 1)) < 1 && (s?.maxX ?? 0) <= (p?.minX ?? 0) + 1
                  && abs((r?.minX ?? -1) - (s?.minX ?? 0)) < 1,
                  "p11a: overlapping meetings side by side (standup and pairing share the width; review takes standup's column again)")
            let shown: [CalendarEvent] = { if case .calendar(let e)? = model?.state.content { return e }; return [] }()
            let laEvent = shown.first { $0.id == "la" }, standup = shown.first { $0.id == "standup" }
            // calcard: the hour height the card fits Arc's six hours with (PreviewTimelineTests checks the arithmetic).
            let layout = PreviewTimeline.CardLayout(shown, now: model?.now ?? Date(), cardHeight: Double(model?.cardHeight ?? 0))
            let hourHeight = CGFloat(layout.hourHeight)
            check(laEvent?.start == ISO8601DateFormatter().date(from: tzEvent),
                  "p11a: a meeting given in Los Angeles time is at its moment here (\(laEvent.map { CalendarCard.timeRange($0, now: Date()) } ?? "-"))")
            let want = CGFloat((laEvent?.start ?? Date()).timeIntervalSince(standup?.start ?? Date()) / 3600) * hourHeight
            let laTop = (f["svc.event.la"]?.minY ?? 0) - (s?.minY ?? 0)
            check(f["svc.event.la"] != nil && abs(laTop - want) < 2,
                  String(format: "p11a: and sits at its hour in the grid (%.1f pt below standup, want %.1f)", laTop, want))
            let grid = f["svc.grid"], now = f["svc.nowLine"]
            let nowFromTop = (now?.midY ?? 0) - (grid?.minY ?? 0)
            let wantNow = CGFloat(PreviewTimeline.lead / 3600) * hourHeight + CalendarHourGrid.topInset
            check(grid != nil && now != nil && abs(nowFromTop - wantNow) < 3,
                  String(format: "p11a: the grid opens a quarter hour before now: the now line %.1f pt below its top (want %.1f, Arc's 15 min)", nowFromTop, wantNow))
            let sixHours = CalendarHourGrid.topInset + 6 * hourHeight
            check(layout.join && layout.allDay && (grid?.height ?? 0) >= sixHours - 1,
                  String(format: "p11a: with the Join and the all-day strip, Arc's six hours show without scrolling (grid %.0f pt, six hours %.0f)",
                         grid?.height ?? 0, sixHours))
            check((now?.midY ?? 1) < (s?.minY ?? 0), "p11a: standup, 4 minutes away, sits just under the now line")
            check(f["svc.allDay.holiday"].map { $0.maxY <= (grid?.minY ?? 0) + 1 } ?? false && f["svc.day.Tomorrow"] == nil,
                  "p11a: the all-day event in the strip above the hours; nothing tomorrow, so no Tomorrow list")
            check(f["svc.join.standup"] != nil && f["svc.join.review"] == nil, "p11a: a big Join for the meeting moments away with a call, only that one")
            check(TestAnchors.frames["svc.settings"] != nil && TestAnchors.frames["svc.action"] != nil, "p11a: the calendar's gear and \"+\"")
            let line = rowLines(row(gcal))
            check(line.contains { ["Event in 3m", "Event in 4m", "Event in 5m"].contains($0) },
                  "p11a: the pinned calendar row's line counts down to the next meeting (\(line))")
            check(rowLines(row(notion)).count == 1, "p11a: a recents site's row has no line (\(rowLines(row(notion))))")
        }
        capture("p11a-calendar")
        var tabsBefore = 0
        run { [self] in tabsBefore = c.store.todayRows(ofSpace: home).count }
        clickCard("svc.join.standup") { self.c.store.todayRows(ofSpace: home).compactMap(\.liveTab).contains { $0.url == base + "/call.html" } }
        run { [self] in
            let call = c.store.todayRows(ofSpace: home).compactMap(\.liveTab).first { $0.url == base + "/call.html" }
            check(call != nil && c.store.todayRows(ofSpace: home).count == tabsBefore + 1, "p11a: Join opens the call (a loopback page) in a new tab")
            if let call { _ = try? c.store.closeTab(call.id) }
            c.reloadAll(animated: false)
        }
        hoverFresh({ row(gcal) }, settle: 0.6)
        clickCard("svc.action") { !opened.isEmpty }
        run { [self] in
            check(opened.last.map { $0.0.absoluteString == "https://calendar.google.com/calendar/u/0/r/eventedit" && $0.1 == gcal } ?? false,
                  "p11a: the calendar's \"+\" opens a new event in its item")
            opened = []
        }
        hoverFresh({ row(gcal) }, settle: 0.6)
        clickCard("svc.event.review") { !opened.isEmpty }
        run { [self] in
            check(opened.last.map { $0.0.absoluteString.hasPrefix("https://calendar.google.com/calendar/u/0/r/day/") && $0.1 == gcal } ?? false,
                  "p11a: a meeting opens its day in the calendar's item (\(opened.last?.0.absoluteString ?? "nothing"))")
            opened = []
        }

        // MARK: M08: Live Calendar from the account, without EventKit

        let cal = CalendarCenter.shared
        run { [self] in
            hover(nil)
            tp().hide()
            app?.settings.values.calendar.enabled = true
            cal.accessChanged()
        }
        step { [self] done in waitUntil({ cal.isActive && cal.tileLabel != nil }, timeout: 3) { done() } }
        run { [self] in
            check(cal.access != .granted && cal.isActive && cal.cardState == .events,
                  "p11a: M08: with EventKit not allowed (\(cal.access)), the Calendar Favorite's account makes Live Calendar active")
            check(["in 3m", "in 4m", "in 5m"].contains(cal.tileLabel ?? ""),
                  "p11a: M08: the Favorite counts down to the account's next meeting (\(cal.tileLabel ?? "none"))")
            let target = MeetingSchedule.joinTarget(cal.events, now: cal.now(), lead: 10 * 60)
            check(target?.title == "Standup", "p11a: M08: ⌃⌘J's meeting among overlapping ones is the one with a call (\(target?.title ?? "none"))")
            let mine = cal.events.filter { ["Standup", "Pairing", "Design review", "West coast sync", "Company holiday"].contains($0.title) }
            check(mine.count == 5 && mine.allSatisfy { $0.id.hasPrefix("outlookCalendar/live/") },
                  "p11a: M08: the account's meetings, under the account's own IDs")
        }
        hoverFresh({ tile(calFav) }, settle: 0.7)
        run { [self] in
            // pageread (owner, 2026-11-15): an Outlook or Google calendar Favorite shows its account's own card (its
            // page's day), never Live Calendar's card of the Mac's calendars, even with Live Calendar on.
            check(tp().isShowing && tp().thumbnail == .service && model?.account?.service == .outlookCalendar && CalendarCard.shared.panel == nil,
                  "p11a: the Outlook calendar Favorite shows its account's card, not Live Calendar's, and only one card")
            CalendarCard.shared.hide()
            hover(nil)
        }
        // A meeting that began two and a half minutes ago (absolute times): "Event began 2m ago".
        run { [self] in
            let iso = ISO8601DateFormatter()
            fake.set(aCal) { $0.events = [["id": "started", "title": "Started", "start": iso.string(from: Date().addingTimeInterval(-150)),
                                           "end": iso.string(from: Date().addingTimeInterval(1800))]] }
            center.refresh(aCal, force: true)
        }
        step { [self] done in waitUntil({ rowLines(row(gcal)).contains("Event began 2m ago") }, timeout: 3) { done() } }
        run { [self] in
            check(rowLines(row(gcal)).contains("Event began 2m ago"), "p11a: after a meeting starts, the row says \"Event began 2m ago\" (\(rowLines(row(gcal))))")
            let item = NSMenuItem()
            item.representedObject = aOutCal
            ServicePreviewMenuTarget.shared.signOut(item)
        }
        step { [self] done in waitUntil({ !cal.isActive }, timeout: 3) { done() } }
        run { [self] in
            check(!cal.isActive && cal.tileLabel == nil, "p11a: M08: signing out of the account (the gear's Sign Out) stops Live Calendar's account meetings")
            app?.settings.values.calendar.enabled = false
            cal.accessChanged()
        }

        // MARK: S16: pictures belong to their profile

        run { [self] in
            hover(nil)
            tp().hide()
            c.show(red, focus: false)
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: red)?.isLoading == false }, timeout: 8) { done() } }
        wait(1.6)
        run { [self] in c.show(blue, focus: false) }
        step { [self] done in waitUntil({ self.c.engineTab(for: blue)?.isLoading == false }, timeout: 8) { done() } }
        wait(0.4)
        run { [self] in
            let kept = TabPreviewCache.shared.shot(tab: red, item: nil, url: base + "/red.html", profileID: profileA)
            let undrawn = Self.screenLocked || !c.window.isOnActiveSpace || !c.window.occlusionState.contains(.visible)
            if kept == nil, undrawn { skip("p11a: S16: the red page left the screen with its picture kept (our window can't draw)") } else {
                check(kept != nil && TabPreviewCache.shared.shot(tab: red, item: nil, url: base + "/red.html", profileID: profileB) == nil,
                      "p11a: S16: a page that left the screen keeps its picture, for its own profile only")
            }
            // A picture of a tab in each profile, and of a profile that's gone.
            TabPreviewCache.shared.store(tinyImage(), url: base + "/a.html", tab: "p11a-a", item: nil, profileID: profileA)
            TabPreviewCache.shared.store(tinyImage(), url: base + "/b.html", tab: "p11a-b", item: nil, profileID: profileB)
            TabPreviewCache.shared.store(tinyImage(), url: base + "/gone.html", tab: "p11a-gone", item: nil, profileID: "p11a-deleted-profile")
            center.refresh(bGmail, force: true)
        }
        step { [self] done in waitUntil({ center.state(bGmail)?.content != nil }, timeout: 3) { done() } }
        // Settings → Profiles → Clear Data on profile B: B's pictures, cards and accounts go; A's stay.
        run { [self] in
            guard let app else { return }
            let before = center.hasOpened(bGmail) && center.state(bGmail) != nil && TabPreviewCache.shared.profiles.contains(profileB)
            SettingsActions.clearData(of: profileB, model: SettingsModel(app: app))
            check(before && !TabPreviewCache.shared.profiles.contains(profileB) && center.state(bGmail) == nil
                  && !center.openedAccountsForTesting.contains(bGmail) && !center.hasOpened(bGmail),
                  "p11a: S16: Clear Data on a profile takes its tab pictures, its cards' content and its accounts")
            check(TabPreviewCache.shared.profiles.contains(profileA) && center.state(aGmail) != nil && center.hasOpened(aGmail),
                  "p11a: S16: and the other profile's stay")
        }
        // Deleting a profile (profile C, with a picture, a card and an opened account): the same.
        var profileC = ""
        var cGmail: PreviewAccount { account(gmailURL, profileC) }
        run { [self] in
            guard let app else { return }
            profileC = (try? c.store.createProfile(name: "P11a Deleted"))?.id ?? ""
            app.history.recordVisit(profileID: profileC, url: gmailURL, title: "Inbox - Gmail")
            fake.set(cGmail) { $0.state = "ready"; $0.mail = [["id": "c1", "sender": "Cy", "subject": "Soon gone", "snippet": "…", "minutesAgo": 1]] }
            TabPreviewCache.shared.store(tinyImage(), url: base + "/c.html", tab: "p11a-c", item: nil, profileID: profileC)
            center.refresh(cGmail, force: true)
        }
        step { [self] done in waitUntil({ center.state(cGmail)?.content != nil }, timeout: 3) { done() } }
        var deleted: Bool?
        step { [self] done in
            guard let app else { return done() }
            check(TabPreviewCache.shared.profiles.contains(profileC) && center.openedAccountsForTesting.contains(cGmail),
                  "p11a: S16: profile C has a picture, a card and an opened account")
            app.profiles.deleteProfile(profileC) { ok in deleted = ok; done() }
        }
        run { [self] in
            check(deleted == true && !TabPreviewCache.shared.profiles.contains(profileC) && center.state(cGmail) == nil
                  && !center.openedAccountsForTesting.contains(cGmail),
                  "p11a: S16: deleting a profile takes its tab pictures, its cards' content and its accounts (deleted \(String(describing: deleted)))")
            check(TabPreviewCache.shared.profiles.contains(profileA) && center.state(aGmail) != nil,
                  "p11a: S16: and the other profiles' stay")
        }
        // A private window's pages are never pictured.
        var privateWindow: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in privateWindow = w; done() }
        }
        step { [self] done in
            guard let w = privateWindow else { check(false, "p11a: S16: a private window"); return done() }
            let page = w.openPage(URL(string: base + "/red.html?private"))
            waitUntil({ !page.isLoading && page.title == "Red page" }, timeout: 8) { done() }
        }
        wait(1.6)
        step { [self] done in
            guard let w = privateWindow else { return done() }
            let page = w.openPage(URL(string: base + "/blue.html?private"))
            waitUntil({ !page.isLoading && page.title == "Blue page" }, timeout: 8) { done() }
        }
        wait(1.6)
        run { [self] in
            let kept = TabPreviewCache.shared.urlsForTesting.filter { $0.contains("?private") }
            check(privateWindow != nil && kept.isEmpty, "p11a: S16: a private window's pages are never pictured (\(kept.count) kept)")
            privateWindow?.closeWindow()
            privateWindow = nil
            c.window.makeKeyAndOrderFront(nil)
        }
        wait(0.5)
        hoverFresh({ todayRow(red) }, settle: 0.6)
        run { [self] in
            check(!TabPreviewCache.shared.profiles.contains("p11a-deleted-profile"), "p11a: S16: a profile that no longer exists keeps no picture")
            check(tp().isShowing && tp().thumbnail != .service, "p11a: a Today tab keeps the page-picture card (\(tp().thumbnail.rawValue))")
            hover(nil)
            tp().hide()
        }

        // MARK: Nothing but loopback

        run { [self] in
            let icons = FaviconCache.shared.networkRequests.filter { !["localhost", "127.0.0.1"].contains($0.host ?? "") }
            check(icons.isEmpty, "p11a: no icon asked of the network except loopback (\(icons.map(\.absoluteString)))")
            let services = [gmail, gmail2, notion, linear, figma, gcal, gmailB, calFav]
            let paged = services.filter { id in c.store.liveTab(forItem: id).flatMap { c.engineTab(for: $0.id) } != nil }
            check(paged.isEmpty, "p11a: no service item ever got a page (\(paged.count))")
            let fetched = Set(center.stats.remoteFetches)
            check(fetched.isSubset(of: [aGmail, bGmail, aCal, aOutCal, cGmail]), "p11a: only accounts opened in their profile were fetched (\(fetched.map(\.description).sorted()))")
            let costs = tp().stats.showCost
            note("p11a: \(tp().stats.serviceShows) service cards shown; showing a card \(String(format: "%.2f", (costs.max() ?? 0) * 1000)) ms at most over \(costs.count)")
            center.unregister(provider?.services ?? [])
            center.openedForTesting = nil
            center.peekForTesting = nil
        }
        wait(0.2)
        run { [self] in
            check(!rowLines(row(gmail)).contains { $0.hasSuffix("Recent") }, "p11a: with no mail provider (as in release builds) the row has no line")
            note("p11a: hovers: \(realHovers) real driver pointer moves, \(postedHovers) posted enter events; card clicks: \(realClicks) real driver clicks (\(secondClicks) needed a second click), \(postedClicks) posted")
            if UIDriverClient.requested {
                check(postedHovers == 0 && postedClicks == 0 && secondClicks == 0,
                      "p11a: with the UI driver, every hover and card click was real input, and each real click worked the first time (\(postedHovers) posted hovers, \(postedClicks) posted clicks, \(secondClicks) second clicks)")
            }
            server?.stop()
        }
    }
}
#endif

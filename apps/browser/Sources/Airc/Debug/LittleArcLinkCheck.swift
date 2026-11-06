// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// LA-1 and AT-1 through a real Apple event (owner report 2026-11-06: "the arc mini… i cant seem to click a link"). The
/// link arrives as a GURL Apple event sent to this process, so AppKit's own handler calls `application(_:open:)` with the
/// event current (the engine reads its sender there), as a link from Mail or Slack does once Launch Services has picked
/// the app. Nothing goes through Launch Services, so it can't reach another copy of Airc. The Little Arc window it opens
/// is then checked the way a person meets it:
///   - the page's view is in that window (not just loaded: the old check drew the engine's snapshot), renders
///     (animation frames) and is visible to the page;
///   - a press on the page's link reaches the page in AppKit's hit test and in Chromium's own check, and the window
///     server wouldn't drag the window instead; it's the app's front window;
///   - Links.log has the link (its host, never the path) with its route, and the press;
///   - a posted click on the link follows it while the window is key (real-click runs); otherwise SKIP, since a press
///     on a window that isn't key only activates it (Chromium takes no first click);
///   - with a sheet up on the browser window, a link still opens a Little Arc window.
/// Part of `--script events` (LinkChecks.swift); `--script littlearc` runs just this. With AIRC_LA_EXTERNAL=1 it also
/// writes its server's port to `littlearc-port.txt` and waits for a link sent through Launch Services
/// (`open -g -b <test bundle ID> http://127.0.0.1:<port>/la?from=launchservices`), and `--script littlearc-cold` checks
/// a link that launched the app (the launch queue): the by-hand proofs in artifacts, never against the owner's Airc.
extension SnapshotRunner {
    static let littleArcPage = """
        <!doctype html><title>little arc 0</title>
        <style>body{margin:0;font:15px -apple-system,sans-serif}.t{position:absolute;left:60px;width:220px;height:36px;display:block}</style>
        <a id=link class=t style="top:60px" href="/followed">Follow this link</a>
        <button id=button class=t style="top:130px">Press</button>
        <script>
        var downs=0,frames=0,presses=0;
        document.addEventListener('mousedown',function(){downs++});
        document.getElementById('button').addEventListener('click',function(){presses++;document.title='little arc '+presses});
        (function tick(){frames++;requestAnimationFrame(tick)})();
        </script>
        """

    func littleArcLinkScenario() {
        run { [self] in
            note("little arc: window key \(c.window.isKeyWindow), app active \(NSApp.isActive), on the active Space \(c.window.isOnActiveSpace), "
                 + "screen locked \(Self.screenLocked)")
        }
        waitForPage()
        littleArcAppleEventCheck()
    }

    /// A GURL Apple event to this process, as Launch Services delivers a link from another app. Nil, or why it failed.
    static func sendGetURLEvent(_ url: URL) -> String? {
        // kInternetEventClass / kAEGetURL ('GURL'), keyDirectObject ('----').
        let gurl: FourCharCode = 0x4755_524C
        let event = NSAppleEventDescriptor(eventClass: gurl, eventID: gurl, targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
                                           returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: 0x2D2D_2D2D)
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 2)
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Links.log from byte `offset` on.
    static func linksLog(since offset: Int) -> String {
        guard let data = try? Data(contentsOf: LinkLog.url), data.count > offset else { return "" }
        return String(decoding: data.dropFirst(offset), as: UTF8.self)
    }
    static var linksLogSize: Int { (try? Data(contentsOf: LinkLog.url))?.count ?? 0 }

    func littleArcAppleEventCheck() {
        var server: LocalPageServer?
        var base = ""
        var little: LittleArcController?
        var logStart = 0
        step { [self] done in
            server = LocalPageServer(pages: ["/la": Self.littleArcPage, "/followed": "<title>followed</title><p>Followed</p>"])
            server?.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                if base.isEmpty { self.check(false, "little arc: the loopback server starts") }
                done()
            }
        }
        // Earlier checks' windows go first, so each check counts its own.
        closeLittleArcs()
        run { [self] in
            app?.settings.values.externalLinks = .littleArc
            logStart = Self.linksLogSize
            guard !base.isEmpty else { return }
            let failure = Self.sendGetURLEvent(URL(string: base + "/la?from=appleevent")!)
            check(failure == nil, "little arc (Apple event): a GURL Apple event is sent to the app" + (failure.map { ": \($0)" } ?? ""))
        }
        step { [self] done in
            waitUntil({ self.app?.littleArcs.first?.page?.title == "little arc 0" && self.app?.littleArcs.first?.page?.isLoading == false }, timeout: 8) {
                little = self.app?.littleArcs.first
                let w = little?.window
                self.check(little != nil && self.app?.littleArcs.count == 1 && little?.page?.title == "little arc 0" && w?.isVisible == true,
                           "little arc (Apple event): a link from another app (a real Apple event, through application(_:open:) and the engine's "
                           + "routing policy) opens a Little Arc window with its page (windows \(self.app?.littleArcs.count ?? 0), "
                           + "page \"\(little?.page?.title ?? "-")\", visible \(w?.isVisible == true))")
                let front = "little arc (Apple event): it's the app's front window (front: \(self.app?.windowName(NSApp.orderedWindows.first) ?? "-"))"
                if let w, !w.isOnActiveSpace {
                    // The owner is in a full-screen app or on another desktop: the window opened off their Space.
                    self.skip(front + ": the window isn't on the active Space")
                } else {
                    self.check(w != nil && NSApp.orderedWindows.first === w, front)
                }
                done()
            }
        }
        littleArcWindowChecks({ little }, label: "little arc (Apple event)", logSince: { logStart })

        // A sheet on the browser window (a page's "Leave site?", an alert) doesn't stop links from other apps.
        var alert: NSAlert?
        closeLittleArcs()
        run { [self] in
            let a = NSAlert()
            a.messageText = "A sheet on the browser window"
            a.addButton(withTitle: "OK")
            a.beginSheetModal(for: c.window) { _ in }
            alert = a
        }
        wait(0.4)
        run { [self] in
            guard !base.isEmpty else { return }
            if let failure = Self.sendGetURLEvent(URL(string: base + "/la?from=sheet")!) { check(false, "little arc (sheet up): the Apple event is sent: \(failure)") }
        }
        step { [self] done in
            waitUntil({ self.app?.littleArcs.first?.page?.title == "little arc 0" }, timeout: 8) {
                let l = self.app?.littleArcs.first
                let inWindow = l.map { $0.page?.view.window === $0.window } ?? false
                self.check(l != nil && l?.window.isVisible == true && inWindow,
                           "little arc (sheet up): with a sheet on the browser window (\(self.c.window.attachedSheet != nil)), a link from another app "
                           + "still opens a Little Arc window with its page in it (window \(l != nil), page in it \(inWindow))")
                if let a = alert { self.c.window.endSheet(a.window) }
                done()
            }
        }
        closeLittleArcs()
        run { server?.stop() }

        if ProcessInfo.processInfo.environment["AIRC_LA_EXTERNAL"] == "1" { littleArcLaunchServicesCheck() }
    }

    /// AIRC_LA_EXTERNAL=1: a link sent through Launch Services by `open -b` from a shell (the by-hand proof).
    private func littleArcLaunchServicesCheck() {
        var server: LocalPageServer?
        var base = ""
        var little: LittleArcController?
        var logStart = 0
        step { [self] done in
            server = LocalPageServer(pages: ["/la": Self.littleArcPage, "/followed": "<title>followed</title><p>Followed</p>"])
            server?.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                logStart = Self.linksLogSize
                if let port { try? "\(port)\n".write(to: self.dir.appendingPathComponent("littlearc-port.txt"), atomically: true, encoding: .utf8) }
                self.note("little arc (Launch Services): waiting for open -b … \(base)/la?from=launchservices")
                done()
            }
        }
        step { [self] done in
            let ours = { self.app?.littleArcs.first { $0.page?.url?.query?.contains("from=launchservices") == true } }
            waitUntil({ ours()?.page?.title == "little arc 0" && ours()?.page?.isLoading == false }, timeout: 60) {
                little = ours()
                self.check(little != nil && little?.window.isVisible == true,
                           "little arc (Launch Services): a link sent through Launch Services (open -b) opens a Little Arc window with its page "
                           + "(window \(little != nil), page \"\(little?.page?.title ?? "-")\")")
                done()
            }
        }
        littleArcWindowChecks({ little }, label: "little arc (Launch Services)", logSince: { logStart })
        closeLittleArcs()
        run { server?.stop() }
    }

    /// `--script littlearc-cold`: the app was launched by a link (Launch Services' launch event, before the browser
    /// window exists). It waits in the launch queue and opens Little Arc once the window is up.
    func littleArcColdStartScenario() {
        var little: LittleArcController?
        step { [self] done in
            let ours = { self.app?.littleArcs.first { $0.page?.url?.query?.contains("from=cold") == true } }
            // Links.log's line for the link is written half a second after it was routed.
            waitUntil({ ours()?.page?.isLoading == false && ours()?.page?.title.isEmpty == false
                        && Self.linksLog(since: 0).contains(": Little Arc, window created") }, timeout: 20) {
                little = ours()
                let log = Self.linksLog(since: 0)
                // The launch event can come before the browser window (it waits in the launch queue) or after it.
                let queued = log.contains("waiting for the browser window")
                let routed = log.split(separator: "\n").contains { $0.contains(": Little Arc, window created") }
                self.check(little != nil && little?.window.isVisible == true && little?.page?.title.isEmpty == false && routed,
                           "little arc (cold start): a link that launches the app opens a Little Arc window with its page "
                           + "(window \(little != nil), page \"\(little?.page?.title ?? "-")\", routed \(routed), "
                           + "\(queued ? "held until the browser window was up" : "it came after the browser window"))")
                self.note("little arc (cold start): Links.log:\n" + log.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
                done()
            }
        }
        littleArcWindowChecks({ little }, label: "little arc (cold start)", logSince: { 0 })
    }

    /// The checks of a Little Arc window a link opened, as a person meets it (see the top of the file).
    private func littleArcWindowChecks(_ little: @escaping () -> LittleArcController?, label: String, logSince: @escaping () -> Int) {
        var link: NSPoint?
        var frames = 0
        var visibility = "-"
        // The page's view is in the window, sized to the card, and the page knows it's visible.
        step { [self] done in
            guard let l = little(), let page = l.page else { check(false, "\(label): there is a Little Arc page"); return done() }
            let view = page.view
            let inWindow = view.window === l.window && view.isDescendant(of: l.card)
            let sized = view.bounds.width > 100 && view.bounds.height > 100
            let shown = !view.isHiddenOrHasHiddenAncestor
            page.evaluate("[document.visibilityState, frames, (function(){var r=document.getElementById('link');if(!r)return null;"
                          + "r=r.getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2]})()]") { v in
                let a = v as? [Any] ?? []
                visibility = a.first as? String ?? "-"
                frames = (a.count > 1 ? (a[1] as? NSNumber)?.intValue : nil) ?? 0
                if a.count > 2, let xy = (a[2] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), xy.count == 2 {
                    link = view.convert(NSPoint(x: xy[0], y: view.isFlipped ? xy[1] : Double(view.bounds.height) - xy[1]), to: nil)
                }
                self.check(inWindow && sized && shown,
                           "\(label): the page's view is in the Little Arc window (\(inWindow)), \(Int(view.bounds.width))×\(Int(view.bounds.height)), "
                           + "shown \(shown)")
                let what = "\(label): the page knows it's visible (document \(visibility))"
                if visibility != "visible", !l.window.isOnActiveSpace || !l.window.occlusionState.contains(.visible) {
                    // WebKit hides a page whose window is covered or on another Space; Chromium's test runs don't.
                    self.skip(what + ": the window is covered or not on the active Space")
                } else {
                    self.check(visibility == "visible", what)
                }
                self.note("\(label): \(LinkLog.windowState(l.window)), app active \(NSApp.isActive), first responder "
                          + "\(Self.describe(l.window.firstResponder)), titlebar band \(Int(l.window.frame.height - l.window.contentLayoutRect.maxY)) pt, "
                          + "card top \(Int(l.card.frame.minY)) pt")
                done()
            }
        }
        // It renders.
        step { [self] done in
            guard let page = little()?.page else { return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                page.evaluate("frames") { v in
                    let n = ((v as? NSNumber)?.intValue ?? frames) - frames
                    if n < 5, little()?.window.occlusionState.contains(.visible) == false {
                        self.skip("\(label): the page renders (\(n) animation frames in 0.6 s): the window is covered")
                    } else {
                        self.check(n >= 5, "\(label): the page renders (\(n) animation frames in 0.6 s)")
                    }
                    done()
                }
            }
        }
        // A press on the link reaches the page (AppKit's hit test, Chromium's own check, the window server).
        run { [self] in
            guard let l = little(), let page = l.page, let p = link else { return check(false, "\(label): the page's link is on screen") }
            let (ok, text) = littleArcHit(at: p, page: page.view, in: l.window)
            let what = "\(label): a press on the page's link reaches the page (\(text))"
            // Chromium: the press must land on the page's render view (it drops a press that hit-tests anywhere else). A
            // hidden page (its window covered or off the active Space, in WebKit or here) has no render view to hit.
            let chromium = app?.engine.name.hasPrefix("Chromium") == true
            let renderView = text.contains("RenderWidgetHostView")
            if visibility != "visible", !l.window.isOnActiveSpace || !l.window.occlusionState.contains(.visible) {
                skip(what + ": the page is hidden (window covered or off the active Space)")
            } else {
                check(ok && (!chromium || renderView), what)
            }
        }
        // A posted click on the link: followed while the window is key; a window that isn't key only activates.
        step { [self] done in
            guard let l = little(), let p = link else { return done() }
            click(at: p, in: l.window) {
                self.waitUntil({ l.page?.url?.path.hasPrefix("/followed") == true }, timeout: 3) {
                    let followed = l.page?.url?.path.hasPrefix("/followed") == true
                    let what = "\(label): a click on the page's link follows it (now \(l.page?.url?.path ?? "-"))"
                    if followed || l.window.isKeyWindow { self.check(followed, what) } else {
                        self.skip(what + ": the window isn't key (scripted runs never activate the app), so the press only activates it")
                    }
                    done()
                }
            }
        }
        // Links.log: the link's line (host only, its route, the window) and the press.
        wait(0.6)
        run { [self] in
            let lines = Self.linksLog(since: logSince()).split(separator: "\n").map(String.init)
            let link = lines.first { $0.contains(" link 127.0.0.1 from ") && $0.contains(": Little Arc, window created") && $0.contains("0.5 s later") }
            let press = lines.first { $0.contains("Little Arc press 1: hit ") }
            let leaks = lines.filter { $0.contains("/la") || $0.contains("from=") || $0.contains("followed") }
            check(link != nil && press != nil && leaks.isEmpty,
                  "\(label): Links.log has the link (host only) with its route and the press (link \(link != nil), press \(press != nil), "
                  + "lines with a path \(leaks.count))")
            for line in lines { note("\(label): Links.log: \(line)") }
        }
    }

    /// What a press at window point `p` in `w` reaches: PageInputCheck's describeHit, for any window.
    func littleArcHit(at p: NSPoint, page: NSView, in w: NSWindow) -> (Bool, String) {
        var parts: [String] = []
        var ok = true
        let top = NSWindow.windowNumber(at: w.convertPoint(toScreen: p), belowWindowWithWindowNumber: 0)
        if top != w.windowNumber {
            let info = Self.windowInfo(top)
            // Another app's window over ours (the build Mac is in use) isn't the app's fault; one of ours is.
            if info.pid == getpid() { ok = false }
            parts.append("top window at the point is \(info.text), not this one")
        }
        guard let content = w.contentView, let frame = content.superview else { return (false, "no content view") }
        let q = frame.convert(p, from: nil)
        let hit = frame.hitTest(q), contentHit = content.hitTest(q)
        let inPage = { (v: NSView?) in v.map { $0 === page || $0.isDescendant(of: page) } ?? false }
        if !inPage(hit) || !inPage(contentHit) { ok = false }
        parts.append("hit \(Self.chain(hit, to: page))")
        if contentHit !== hit { parts.append("content view's hit \(Self.chain(contentHit, to: page))") }
        if let why = Self.windowServerDrags(at: p, hit: hit, in: w) { ok = false; parts.append("a real click would drag the window: \(why)") }
        return (ok, parts.joined(separator: "; "))
    }

    /// Closes every Little Arc window (the engine closes them after their pages' unload handlers).
    func closeLittleArcs() {
        step { [self] done in
            app?.littleArcs.forEach { $0.closeWindow() }
            waitUntil({ self.app?.littleArcs.isEmpty != false }, timeout: 4) { done() }
        }
    }
}
#endif

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
        // Earlier checks' windows go first, so each check counts its own (and a Settings window an earlier check showed).
        closeLittleArcs()
        run { [self] in
            app?.settingsWindow?.window.orderOut(nil)
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
                done()
            }
        }
        // In front of the browser window, as the window server orders them (the engine's invisible child windows and
        // other apps' windows don't count), once it has settled: it opened behind it on Chromium (ship runs 2026-11-06).
        // While it animates in, the window server's list can show it below for a moment, so this waits up to 2.5 s.
        step { [self] done in
            guard let w = little?.window else { return done() }
            if !w.isOnActiveSpace {
                // The owner is in a full-screen app or on another desktop: the window opened off their Space.
                skip("little arc (Apple event): it's in front of the browser window once it has opened: the window isn't on the active Space")
                return done()
            }
            let started = Date()
            waitUntil({ !LittleArcController.isBehind(w, self.c.window) && Date().timeIntervalSince(started) > 0.6 }, timeout: 2.5) {
                let front = !LittleArcController.isBehind(w, self.c.window)
                self.check(front, "little arc (Apple event): it's in front of the browser window once it has opened "
                           + "(our windows front to back: \(self.ourWindowOrder()))")
                done()
            }
        }
        // The engine's attach, done again by hand, on both engines: an invisible window ordered in just below the
        // browser window (as Chromium shows the anchor), then made Little Arc's child (as the engine attaches it).
        // Attaching moves the parent down to its child: Little Arc must come out of it in front again.
        step { [self] done in
            guard let w = little?.window, w.isOnActiveSpace else {
                skip("little arc (Apple event): a dialog anchor attached as the engine attaches its own leaves it in front: the window isn't on the active Space")
                return done()
            }
            let anchor = NSWindow(contentRect: NSRect(x: w.frame.minX + 20, y: w.frame.minY + 20, width: 40, height: 40), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            anchor.isReleasedWhenClosed = false
            anchor.isOpaque = false
            anchor.backgroundColor = .clear
            anchor.alphaValue = 0
            anchor.ignoresMouseEvents = true
            let wasFront = !LittleArcController.isBehind(w, c.window)
            anchor.order(.below, relativeTo: c.window.windowNumber)
            w.addChildWindow(anchor, ordered: .above)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let front = !LittleArcController.isBehind(w, self.c.window)
                self.check(front, "little arc (Apple event): a dialog anchor attached as the engine attaches its own (ordered in below the "
                           + "browser window, then made a child) leaves it in front (in front before \(wasFront); our windows front to back: "
                           + "\(self.ourWindowOrder()))")
                w.removeChildWindow(anchor)
                anchor.orderOut(nil)
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
        // The row's controls and Spaces (owner report 2026-11-06 17:39).
        littleArcChromeChecks({ base })
        littleArcActiveSpaceCheck({ base })
        run { server?.stop() }

        if ProcessInfo.processInfo.environment["AIRC_LA_EXTERNAL"] == "1" { littleArcLaunchServicesCheck() }
    }

    /// The row: one click on ↗ moves the page into the chip's Space (it used to open the Spaces menu, so it took two);
    /// the chip shows the profile's name and a chevron; its menu lists the profiles, the page's checked, "Reloads the
    /// page" on the others; ↗'s menu lists the Spaces by name, the chip's checked, "Reloads in <profile>" only where
    /// the profile differs. A second profile and Space are made if there's only one (synthetic names).
    func littleArcChromeChecks(_ base: @escaping () -> String) {
        var little: LittleArcController?
        var home = ""
        step { [self] done in
            home = c.currentSpaceID
            guard c.store.state.profiles.count < 2 else { return done() }
            do {
                let p = try c.profiles.createProfile(name: "Links Check", emoji: "", color: nil)
                _ = try c.store.createSpace(name: "Routed", profileID: p.id)
                c.reloadAll(animated: false)
                c.profiles.whenLoaded(p.id, { _ in done() }, failed: { done() })
            } catch {
                check(false, "little arc (row): a second profile and Space (\(error))")
                done()
            }
        }
        step { [self] done in
            guard !base().isEmpty else { return done() }
            little = app?.openLittleArc(url: URL(string: base() + "/la?from=row"), spaceID: home)
            waitUntil({ little?.page?.title == "little arc 0" && little?.page?.isLoading == false }, timeout: 8) { done() }
        }
        // The chip and the button, as a real press finds them.
        run { [self] in
            guard let l = little else { return check(false, "little arc (row): the window opens") }
            l.root.layoutSubtreeIfNeeded()
            let profile = c.store.profile(ofSpace: home)
            check(l.chip.shownName == profile.name && l.chip.showsChevron,
                  "little arc (row): the chip shows the profile's name and a chevron, Arc's profile button (name right \(l.chip.shownName == profile.name), "
                  + "chevron \(l.chip.showsChevron))")
            for (name, view) in [("↗", l.openButton as NSView), ("the chip", l.chip as NSView), ("the address", l.addressField as NSView)] {
                let p = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                let frame = l.window.contentView?.superview
                let hit = frame.flatMap { $0.hitTest($0.convert(p, from: nil)) }
                let drags = Self.windowServerDrags(at: p, hit: hit, in: l.window)
                check((hit === view || hit?.isDescendant(of: view) == true) && view.acceptsFirstMouse(for: nil) && drags == nil,
                      "little arc (row): a first press on \(name) reaches it in a window that isn't key (hit \(Self.describe(hit)), first mouse "
                      + "\(view.acceptsFirstMouse(for: nil))\(drags.map { "; the window server would drag: \($0)" } ?? ""))")
            }
        }
        // The chip's menu and ↗'s menu.
        run { [self] in
            guard let l = little else { return }
            let store = c.store
            let pid = store.space(home)?.profileID
            let profiles = l.profileMenu().items
            let withSpaces = store.orderedProfiles.filter { !store.spaces(usingProfile: $0.id).isEmpty }
            let checked = profiles.filter { $0.state == .on }.map { Self.titleOnly($0.title) }
            let notes = profiles.map { Self.secondLine($0) }
            let profilesOK = profiles.map({ Self.titleOnly($0.title) }) == withSpaces.map(\.name)
                && checked == [store.profile(pid ?? "")?.name ?? "?"]
                && zip(profiles, notes).allSatisfy { ($0.state == .on) == ($1 == nil) && ($1 == nil || $1 == "Reloads the page") }
                && profiles.allSatisfy { $0.image != nil }
            check(profilesOK, "little arc (row): the chip's menu lists the profiles by avatar and name, the page's checked, “Reloads the page” "
                  + "on the others only (\(zip(profiles, notes).map { "\($0.state == .on ? "✓ " : "")\(Self.titleOnly($0.title))\($1.map { " · " + $0 } ?? "")" }))")
            let spaces = l.spacesMenu().items
            let rows = store.orderedSpaces
            let spaceNotes = spaces.map { Self.secondLine($0) }
            let spacesOK = spaces.count == rows.count
                && zip(spaces, rows).allSatisfy { item, space in
                    let other = space.profileID != pid
                    return Self.titleOnly(item.title) == space.name && (item.state == .on) == (space.id == home)
                        && Self.secondLine(item) == (other ? "Reloads in \(store.profile(ofSpace: space.id).name)" : nil)
                }
            check(spacesOK, "little arc (row): ↗'s menu lists the Spaces by icon and name, the chip's checked, “Reloads in <profile>” only where "
                  + "the profile differs (\(zip(spaces, spaceNotes).map { "\($0.state == .on ? "✓ " : "")\(Self.titleOnly($0.title))\($1.map { " · " + $0 } ?? "")" }))")
        }
        // One click on ↗: the page moves into the chip's Space, no menu in between.
        step { [self] done in
            guard let l = little, let page = l.page else { return done() }
            let chromium = app?.engine.name.hasPrefix("Chromium") == true
            let menusBefore = l.menusMade
            // A menu would block this run in its tracking loop: close it (and fail) instead.
            let guardTimer = Timer(timeInterval: 2, repeats: false) { [weak l] _ in l?.shownMenu?.cancelTracking() }
            RunLoop.main.add(guardTimer, forMode: .common)
            let b = l.openButton
            click(at: b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil), in: l.window) {
                self.waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 4) {
                    guardTimer.invalidate()
                    let tab = self.c.store.todayTabs(ofSpace: home).first { $0.url.contains("from=row") }
                    let moved = tab.flatMap { self.c.engineTab(for: $0.id) }
                    let same = !chromium || moved === page
                    self.check(tab != nil && self.app?.littleArcs.isEmpty == true && same && l.menusMade == menusBefore,
                               "little arc (row): one click on ↗ opens the page in the chip's Space (tab \(tab != nil), window closed "
                               + "\(self.app?.littleArcs.isEmpty == true), \(chromium ? "same live page \(same), " : "")menus opened "
                               + "\(l.menusMade - menusBefore))")
                    done()
                }
            }
        }
        closeLittleArcs()
    }

    /// LA-1 in full screen: a Little Arc window joins the active Space when it's shown (`.moveToActiveSpace`,
    /// `.fullScreenAuxiliary`), so a link from an app in full screen opens over it. The windows are invisible and take
    /// no clicks (the owner may be in a full-screen app). Without a full-screen app on the active Space, the window
    /// still has to be on the active Space; the comparison with the old window (no such behaviour) is noted.
    func littleArcActiveSpaceCheck(_ base: @escaping () -> String) {
        var front = ""
        var fullScreen = false
        var before: Bool?
        func open(joining: Bool, _ then: @escaping (LittleArcController?) -> Void) {
            let saved = LittleArcController.joinsActiveSpace
            LittleArcController.joinsActiveSpace = joining
            let l = app?.openLittleArc(url: URL(string: base() + "/la?from=space"), spaceID: c.currentSpaceID)
            LittleArcController.joinsActiveSpace = saved
            l?.window.alphaValue = 0
            l?.window.ignoresMouseEvents = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { then(l) }
        }
        step { [self] done in
            guard !base().isEmpty, !Self.screenLocked else { return done() }
            front = LinkLog.frontApp()
            fullScreen = NSWorkspace.shared.frontmostApplication.map { $0.processIdentifier != getpid() && LinkLog.isFullScreen($0.processIdentifier) } ?? false
            open(joining: false) { l in
                before = l?.window.isOnActiveSpace
                l?.closeWindow()
                self.waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 3) { done() }
            }
        }
        step { [self] done in
            guard !base().isEmpty else { return done() }
            if Self.screenLocked { skip("little arc (Spaces): the screen is locked"); return done() }
            open(joining: true) { l in
                let behaviour = l?.window.collectionBehavior ?? []
                let flags = behaviour.contains(.moveToActiveSpace) && behaviour.contains(.fullScreenAuxiliary)
                self.note("little arc (Spaces): \(front); a window without the behaviour opened on the active Space: \(before.map(LinkLog.yesNo) ?? "-")")
                self.check(flags, "little arc (Spaces): a Little Arc window moves to the active Space when it's made active, and may join a "
                           + "full-screen app's (.moveToActiveSpace \(behaviour.contains(.moveToActiveSpace)), .fullScreenAuxiliary "
                           + "\(behaviour.contains(.fullScreenAuxiliary)))")
                // Made key as a link makes it (the window takes no clicks and is invisible; the app isn't activated).
                l?.window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let onActive = l?.window.isOnActiveSpace == true
                    let what = "little arc (Spaces): made key, it's on the active Space (\(onActive))"
                        + (fullScreen ? ", over the full-screen front app" : "")
                    if onActive || NSApp.isActive { self.check(onActive, what) } else {
                        self.skip(what + ": the app isn't active (scripted runs never activate it), so the window can't become active and "
                                  + "stays where it opened")
                    }
                    l?.closeWindow()
                    self.waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 3) { done() }
                }
            }
        }
    }

    /// A menu row's title without the second line folded into it before macOS 14.4.
    static func titleOnly(_ title: String) -> String { title.components(separatedBy: " — ").first ?? title }
    static func secondLine(_ item: NSMenuItem) -> String? {
        if #available(macOS 14.4, *) { return item.subtitle }
        let parts = item.title.components(separatedBy: " — ")
        return parts.count > 1 ? parts.last : nil
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

    /// This app's windows on screen, front to back, as the window server orders them: number, kind, size.
    func ourWindowOrder() -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return "?" }
        return list.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() }.map { d -> String in
            let n = (d[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
            let w = NSApp.windows.first { $0.windowNumber == n }
            let b = (d[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            return "#\(n) \(app?.windowName(w) ?? "-")\(layer != 0 ? " layer \(layer)" : "") \(Int(b.width))×\(Int(b.height))"
        }.joined(separator: ", ")
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

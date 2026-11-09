// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
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
/// With AIRC_LA_FS=1 (and AIRC_LA_AS_OWNER=1, in a scratch copy) it only runs the real full-screen case
/// (`littleArcFullScreenScenario`): a link from an app in native full screen, by hand while the owner is away.
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
        // The by-hand proof over another app's full screen (AIRC_LA_FS=1; artifacts/lafullscreen/fsproof): only that.
        if ProcessInfo.processInfo.environment["AIRC_LA_FS"] == "1" { return littleArcFullScreenScenario() }
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
                           + "routing policy) opens a Little Airc window with its page (windows \(self.app?.littleArcs.count ?? 0), "
                           + "page \"\(little?.page?.title ?? "-")\", visible \(w?.isVisible == true))")
                // Not from a full-screen app (and never in the suite): today's window, not the full-screen panel.
                let ordinary = w.map { !($0 is NSPanel) && $0.level == .normal && !$0.styleMask.contains(.nonactivatingPanel) } ?? false
                self.check(ordinary && little?.overFullScreen == false,
                           "little arc (Apple event): a link from an app that isn't in full screen opens the ordinary window, not the full-screen "
                           + "panel (\(w.map { String(describing: type(of: $0)) } ?? "-"), level \(w?.level.rawValue ?? -1))")
                done()
            }
        }
        // In front of the browser window, as the window server orders them (the engine's invisible child windows and
        // other apps' windows don't count), once it has settled: it opened behind it on Chromium (ship runs 2026-11-06).
        // While it animates in, the window server's list can show it below for a moment, so this waits up to 2.5 s.
        uiCase(window: { little?.window }) {
            run { [self] in uiAttempt?.needsKeyWindow = false; uiAttempt?.needsUncoveredWindow = false }
            step { [self] done in
                guard let w = little?.window else { return done() }
                if !w.isOnActiveSpace {
                    // The owner is in a full-screen app or on another desktop: the window opened off their Space.
                    check(false, "little arc (Apple event): it's in front of the browser window once it has opened: the window isn't on the active Space")
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
        }
        // The engine's attach, done again by hand, on both engines: an invisible window ordered in just below the
        // browser window (as Chromium shows the anchor), then made Little Arc's child (as the engine attaches it).
        // Attaching moves the parent down to its child: Little Arc must come out of it in front again.
        uiCase(window: { little?.window }) {
            run { [self] in uiAttempt?.needsKeyWindow = false; uiAttempt?.needsUncoveredWindow = false }
            step { [self] done in
                guard let w = little?.window, w.isOnActiveSpace else {
                    check(false, "little arc (Apple event): a dialog anchor attached as the engine attaches its own leaves it in front: the window isn't on the active Space")
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
                           + "still opens a Little Airc window with its page in it (window \(l != nil), page in it \(inWindow))")
                if let a = alert { self.c.window.endSheet(a.window) }
                done()
            }
        }
        closeLittleArcs()
        // The row's controls and Spaces (owner report 2026-11-06 17:39).
        littleArcChromeChecks({ base })
        littleArcActiveSpaceCheck({ base })
        littleArcPanelChecks({ base })
        run { server?.stop() }

        if ProcessInfo.processInfo.environment["AIRC_LA_EXTERNAL"] == "1" { littleArcLaunchServicesCheck() }
    }

    /// The row (owner reports 2026-11-06 17:39 and 2026-11-07): no ↗ button any more; Arc's Open in button is the one
    /// control. A press on it moves the page into its Space (one click, no menu); only its chevron opens Arc's Open In
    /// menu (LittleArcOpenInMenu, owner 2026-11-07): the short list of Spaces in sidebar order, each tinted with its
    /// Space's colours, the chip's with ⌘O, "Reloads in <profile>" only where the profile differs; Search Spaces, which
    /// filters every Space as you type; Profile ▸ (the profiles by avatar and name, the page's checked, "Reloads the page"
    /// on the others) and Copy Link (⇧⌘C). Real clicks (posted into our own windows) open and close it and pick a row;
    /// the keys (↑ ↓ Return Esc, typing, ⌘O, ⇧⌘O, ⌥⌘O) go to `handleKey`, as the app's key monitor hands Little Arc's keys
    /// there (a test window is never key). A second profile and Space, and a second Space of the first profile, are made
    /// if missing (synthetic names). Writes littlearc-chevron-menu.png (the menu as the app draws it, under the chip).
    func littleArcChromeChecks(_ base: @escaping () -> String) {
        var little: LittleArcController?
        var home = ""
        var sibling = ""
        typealias M = AircMetrics.LittleArc
        step { [self] done in
            home = c.currentSpaceID
            let pid = c.store.profile(ofSpace: home).id
            if let s = c.store.orderedSpaces.first(where: { $0.id != home && $0.profileID == pid }) {
                sibling = s.id
            } else {
                // Its own colours and icon, so Open In's tints differ from row to row.
                sibling = (try? c.store.createSpace(name: "Moved", icon: .emoji("🌿"), theme: SpaceTheme(colors: [RGBA(hex: "73E49B")!]),
                                                    profileID: pid, after: home))?.id ?? ""
                c.reloadAll(animated: false)
            }
            guard c.store.state.profiles.count < 2 else { return done() }
            do {
                let p = try c.profiles.createProfile(name: "Links Check", emoji: "", color: nil)
                _ = try c.store.createSpace(name: "Routed", icon: .symbol("briefcase.fill"), theme: SpaceTheme(colors: [RGBA(hex: "9E749B")!]),
                                            profileID: p.id)
                c.reloadAll(animated: false)
                c.profiles.whenLoaded(p.id, { _ in done() }, failed: { done() })
            } catch {
                check(false, "little arc (row): a second profile and Space (\(error))")
                done()
            }
        }
        func openLittle(_ tag: String) {
            step { [self] done in
                guard !base().isEmpty else { return done() }
                little = app?.openLittleArc(url: URL(string: base() + "/la?from=\(tag)"), spaceID: home)
                waitUntil({ little?.page?.title == "little arc 0" && little?.page?.isLoading == false }, timeout: 8) { done() }
            }
        }
        /// After a move: the page is a Today tab of `space` (the same live page on Chromium) and the window closed.
        func moved(_ what: String, tag: String, into space: @escaping () -> String, page: @escaping () -> EngineTab?, menusBefore: @escaping () -> Int,
                   detail: (() -> String)? = nil) {
            step { [self] done in
                waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 4) {
                    let chromium = self.app?.engine.name.hasPrefix("Chromium") == true
                    let tab = self.c.store.todayTabs(ofSpace: space()).first { $0.url.contains("from=\(tag)") }
                    let live = tab.flatMap { self.c.engineTab(for: $0.id) }
                    let same = !chromium || (live != nil && live === page())
                    let menus = (little?.menusMade ?? 0) - menusBefore()
                    let ok = tab != nil && self.app?.littleArcs.isEmpty == true && same && menus == 0
                    self.check(ok, "little arc (row): \(what) moves the page into \(self.c.store.space(space())?.name ?? "?") (tab \(tab != nil), window closed "
                               + "\(self.app?.littleArcs.isEmpty == true), \(chromium ? "same live page \(same), " : "")menus opened \(menus))"
                               + (ok ? "" : detail.map { "; " + $0() } ?? ""))
                    done()
                }
            }
            closeLittleArcs()
        }
        func keyEvent(_ l: LittleArcController, _ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: l.window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)
        }

        openLittle("row")
        // The row as drawn, and the parts as a real press finds them.
        run { [self] in
            guard let l = little else { return check(false, "little arc (row): the window opens") }
            l.root.layoutSubtreeIfNeeded()
            let space = c.store.space(home)
            let buttons = l.bar.subviews.filter { $0 is GlyphButton || $0 is NSButton }
            check(buttons.isEmpty && Set(l.bar.subviews.map(ObjectIdentifier.init)) == Set([l.addressField, l.titleLabel, l.chip].map { ObjectIdentifier($0 as NSView) }),
                  "little arc (row): no ↗ button: the row holds the address, the title and the Open in chip only (\(l.bar.subviews.map { Self.describe($0) }))")
            let wide = l.root.bounds.width >= 560
            check(l.chip.shownName == space?.name && l.chip.showsChevron && (!wide || l.chip.shownText == "Open in \(space?.name ?? "")"),
                  "little arc (row): the chip is Arc's Open in button with a chevron (“\(l.chip.shownText)”, chevron \(l.chip.showsChevron))")
            // Centred on the row's middle, the page card under it, concentric corners.
            let mid = M.barHeight / 2
            let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { l.window.standardWindowButton($0) }
                .map { b -> CGFloat in l.window.frame.height - b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil).y }
            let aligned = lights.count == 3 && lights.allSatisfy { abs($0 - mid) <= 1 } && abs(l.chip.frame.midY - mid) <= 0.5
                && abs(l.addressField.frame.midY - (mid + 1)) <= 0.5
            check(aligned, "little arc (row): lights, address and chip centred on the \(Int(M.barHeight)) pt row (the field 1 pt down, its cell's "
                  + "text sits high; lights at \(lights.map { Int($0.rounded()) }), "
                  + "chip \(l.chip.frame.midY), address \(l.addressField.frame.midY))")
            let card = l.card.frame
            check(card.minY == M.barHeight && card.minX == M.cardInset && abs(l.root.bounds.maxX - card.maxX - M.cardInset) < 0.5
                  && abs(l.root.bounds.maxY - card.maxY - M.cardInset) < 0.5 && l.card.cornerRadius == M.cardRadius,
                  "little arc (row): the page card sits under the row, inset \(Int(M.cardInset)) pt, radius \(Int(l.card.cornerRadius)) (\(card))")
            check(l.favicon.contents != nil && !l.titleLabel.isHidden && l.titleLabel.stringValue == "little arc 0",
                  "little arc (row): the favicon and the page's title follow the host (title “\(l.titleLabel.stringValue)”, shown \(!l.titleLabel.isHidden))")
            for (name, view, point) in [("the Open in part", l.chip as NSView, NSPoint(x: l.chip.openRect.midX, y: l.chip.openRect.midY)),
                                        ("the chevron", l.chip as NSView, NSPoint(x: l.chip.chevronRect.midX, y: l.chip.chevronRect.midY)),
                                        ("the address", l.addressField as NSView, NSPoint(x: l.addressField.bounds.midX, y: l.addressField.bounds.midY))] {
                let p = view.convert(point, to: nil)
                let frame = l.window.contentView?.superview
                let hit = frame.flatMap { $0.hitTest($0.convert(p, from: nil)) }
                let drags = Self.windowServerDrags(at: p, hit: hit, in: l.window)
                check((hit === view || hit?.isDescendant(of: view) == true) && view.acceptsFirstMouse(for: nil) && drags == nil,
                      "little arc (row): a first press on \(name) reaches it in a window that isn't key (hit \(Self.describe(hit)), first mouse "
                      + "\(view.acceptsFirstMouse(for: nil))\(drags.map { "; the window server would drag: \($0)" } ?? ""))")
            }
        }
        // Hover and pressed: each part its own plate.
        run { [self] in
            guard let l = little else { return }
            let chip = l.chip, p = l.palette
            chip.hover(at: NSPoint(x: chip.openRect.midX, y: chip.openRect.midY))
            let openHover = chip.hovered == .open && chip.partFill == p.hover.cgColor
            chip.hover(at: NSPoint(x: chip.chevronRect.midX, y: chip.chevronRect.midY))
            let chevronHover = chip.hovered == .chevron && chip.partFill == p.hover.cgColor
            chip.hover(at: nil)
            let rest = chip.hovered == nil && chip.partFill == nil && chip.plateFill == p.urlFieldFill.cgColor
            check(openHover && chevronHover && rest, "little arc (row): the Open in part and the chevron light up on their own under the pointer, "
                  + "the chip rests on the field fill (open \(openHover), chevron \(chevronHover), rest \(rest))")
            let at = { (x: CGFloat) in chip.convert(NSPoint(x: x, y: chip.bounds.midY), to: nil) }
            func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: l.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            }
            let before = l.menusMade
            if let e = mouse(.leftMouseDown, at(chip.openRect.midX)) { chip.mouseDown(with: e) }
            let pressed = chip.pressed == .open && chip.partFill == p.tileHover.cgColor
            if let e = mouse(.leftMouseDragged, at(chip.bounds.minX - 40)) { chip.mouseDragged(with: e) }
            let draggedOff = chip.pressed == nil
            if let e = mouse(.leftMouseUp, at(chip.bounds.minX - 40)) { chip.mouseUp(with: e) }
            let nothing = app?.littleArcs.contains { $0 === l } == true && l.page != nil && l.menusMade == before
            check(pressed && draggedOff && nothing, "little arc (row): pressed, the Open in part takes the pressed fill; dragged off it lets go, and a "
                  + "release outside does nothing (pressed \(pressed), let go \(draggedOff), window kept and no menu \(nothing))")
        }
        // Arc's Open In menu (LittleArcOpenInMenu): a real click on the chevron opens it under the chip; a second one closes it.
        uiCase(window: { little?.window }) {
            run { [self] in
                uiAttempt?.needsKeyWindow = false
                uiAttempt?.needsUncoveredWindow = false
                little?.openInMenu?.close()
            }
            var before = 0
            step { [self] done in
                guard let l = little else { return done() }
                before = l.menusMade
                let r = l.chip.chevronRect
                click(at: l.chip.convert(NSPoint(x: r.midX, y: r.midY), to: nil), in: l.window) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let m = l.openInMenu
                        let first = m?.rows.first?.titleText ?? "-"
                        let firstSpace = self.c.store.orderedSpaces.first?.name ?? "-"
                        let kept = self.app?.littleArcs.contains { $0 === l } == true && l.page != nil
                        let under = m.map { $0.panel.parent === l.window && abs($0.panel.frame.maxX - l.window.convertToScreen(l.chip.convert(l.chip.bounds, to: nil)).maxX) < 1 } ?? false
                        self.check(l.menusMade == before + 1 && m?.isShown == true && m?.panel.isVisible == true && under && first == firstSpace
                                   && kept && l.chip.menuShown,
                                   "little arc (Open In): a click on the chevron opens Arc's Open In menu under the chip, the Spaces first, and the page "
                                   + "stays (menus \(l.menusMade - before), shown \(m?.panel.isVisible == true), under the chip \(under), first row “\(first)”, "
                                   + "first Space “\(firstSpace)”, window kept \(kept), chevron pressed \(l.chip.menuShown))")
                        done()
                    }
                }
            }
            step { [self] done in
                guard let l = little else { return done() }
                let r = l.chip.chevronRect
                click(at: l.chip.convert(NSPoint(x: r.midX, y: r.midY), to: nil), in: l.window) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.check(l.openInMenu == nil && !l.chip.menuShown && l.menusMade == before + 1,
                                   "little arc (Open In): a second click on the chevron closes it and doesn't open it again (menus \(l.menusMade - before), "
                                   + "shown \(l.openInMenu?.isShown == true))")
                        done()
                    }
                }
            }
        }
        // A click anywhere else (here: the row between the title and the chip) closes it.
        uiCase(window: { little?.window }) {
            run { [self] in
                uiAttempt?.needsKeyWindow = false
                uiAttempt?.needsUncoveredWindow = false
                little?.openInMenu?.close()
                little?.showOpenInMenu()
            }
            step { [self] done in
                guard let l = little else { return done() }
                let p = l.bar.convert(NSPoint(x: l.chip.frame.minX - 4, y: l.chip.frame.midY), to: nil)
                click(at: p, in: l.window) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let kept = self.app?.littleArcs.contains { $0 === l } == true && l.page != nil
                        self.check(l.openInMenu == nil && kept, "little arc (Open In): a click elsewhere in the window closes it, and nothing else happens "
                                   + "(shown \(l.openInMenu?.isShown == true), window kept \(kept))")
                        done()
                    }
                }
            }
        }
        // The menu as drawn, under the chip, for reviews (our own views, rendered here; a Space row under the pointer).
        step { [self] done in
            guard let l = little else { return done() }
            l.openInMenu?.close()
            l.showOpenInMenu()
            guard let m = l.openInMenu else { return done() }
            if let other = m.rows.first(where: { if case .space(let id) = $0.item { return id != home } else { return false } }) { m.highlight(other.item) }
            m.content.layoutSubtreeIfNeeded()
            let menuImage = render(m.content)
            let wf = l.window.frame, pf = m.panel.frame
            let dark = m.palette.isDark
            mkLittleArcImage(l) { window in
                if let menuImage {
                    self.writeMenuShot("littlearc-chevron-menu", window: window, size: l.root.bounds.size, menu: menuImage,
                                       at: NSPoint(x: pf.minX - wf.minX, y: wf.maxY - pf.maxY), dark: dark, radius: LittleArcOpenInMenu.Metrics.radius)
                }
                // Search Spaces with a letter typed.
                m.expand(query: "o")
                m.content.layoutSubtreeIfNeeded()
                let pf2 = m.panel.frame
                if let search = self.render(m.content) {
                    self.writeMenuShot("littlearc-open-in-search", window: window, size: l.root.bounds.size, menu: search,
                                       at: NSPoint(x: pf2.minX - wf.minX, y: wf.maxY - pf2.maxY), dark: dark, radius: LittleArcOpenInMenu.Metrics.radius)
                }
                m.close()
                done()
            }
        }
        // What it lists: the Spaces (their icons, tiles and tints), Search Spaces, Profile and Copy Link; VoiceOver's names.
        run { [self] in
            guard let l = little else { return }
            l.showOpenInMenu()
            guard let m = l.openInMenu else { return check(false, "little arc (Open In): ⇧⌘O's menu opens") }
            defer { m.close() }
            let store = c.store
            let pid = store.space(home)?.profileID
            let limit = LittleArcOpenInMenu.collapsedLimit
            var expected = Array(store.orderedSpaces.prefix(limit))
            if store.orderedSpaces.count > limit, !expected.contains(where: { $0.id == home }), let h = store.space(home) { expected[limit - 1] = h }
            let spaceRows = m.rows.filter { if case .space = $0.item { return true } else { return false } }
            let others = m.rows.filter { if case .space = $0.item { return false } else { return true } }
            let rowsOK = spaceRows.map(\.titleText) == expected.map(\.name)
                && zip(spaceRows, expected).allSatisfy { row, s in
                    row.trailingText == (s.id == home ? "⌘O" : "") && row.isEnabled
                        && row.subtitleText == (s.profileID != pid ? "Reloads in \(store.profile(ofSpace: s.id).name)" : nil)
                }
                && others.map(\.item) == [.search, .profile, .copyLink] && others.map(\.titleText) == ["Search Spaces", "Profile", "Copy Link"]
                && others[1].trailingText == store.profile(pid ?? "")?.name && others[1].hasTileImage && others[2].trailingText == "⇧⌘C"
            check(rowsOK, "little arc (Open In): the short list of Spaces in sidebar order (the chip's with ⌘O, “Reloads in <profile>” only where the "
                  + "profile differs), then Search Spaces, Profile ▸ and Copy Link ⇧⌘C (\(m.rows.map(Self.rowText)))")
            check(m.highlighted == .space(home), "little arc (Open In): the keyboard starts on the chip's Space (\(String(describing: m.highlighted)))")
            // Each Space row in its own colours: the tile is its theme, the highlight its accent.
            var tints: [String] = []
            let tinted = zip(spaceRows, expected).allSatisfy { row, s in
                let r = Palette(theme: s.theme, systemDark: LittleArcController.systemDark).resolved
                let colors = r.gradient.map { $0.color.nsColor.cgColor }
                let want = colors.isEmpty ? [r.background.nsColor.cgColor, r.background.nsColor.cgColor] : colors.count == 1 ? [colors[0], colors[0]] : colors
                m.highlight(row.item)
                let tint = r.accent.nsColor.withAlphaComponent(m.palette.isDark ? 0.32 : 0.18).cgColor
                tints.append("\(s.name) \(Self.hex(tint))")
                return row.tileColors == want && row.plateFill == tint && row.hasTileImage
                    && spaceRows.allSatisfy { $0 === row || $0.plateFill == nil }
            }
            m.highlight(.space(home))
            // Spaces of different colours, rows of different tints.
            let themes = expected.map(\.theme)
            let distinct = zip(expected.indices, expected).allSatisfy { i, s in
                expected.indices.allSatisfy { j in j == i || themes[j] == s.theme || spaceRows[j].tint != spaceRows[i].tint }
            }
            check(tinted && distinct, "little arc (Open In): each Space row is tinted with its Space's colours: its tile is the theme, its "
                  + "highlight the Space's accent, one row lit at a time, Spaces of other colours in other tints (\(tints))")
            // VoiceOver: a named group of buttons; the search field is named too.
            let labels = m.rows.map { $0.accessibilityLabel() ?? "" }
            let wantLabels = expected.map { "Open in \($0.name)" } + ["Search Spaces", "Profile: \(store.profile(pid ?? "")?.name ?? "")", "Copy Link"]
            let a11y = m.content.accessibilityRole() == .group && m.content.accessibilityLabel() == "Open In"
                && m.rows.allSatisfy { $0.accessibilityRole() == .button && $0.isAccessibilityElement() } && labels == wantLabels
                && m.field.accessibilityLabel() == "Search Spaces"
                && zip(spaceRows, expected).allSatisfy { row, s in row.accessibilityHelp() == (s.profileID != pid ? row.subtitleText : (s.id == home ? "⌘O" : nil)) }
            check(a11y, "little arc (Open In): VoiceOver names it “Open In” and each row as a button (\(labels)), the field “Search Spaces”")
        }
        // The keyboard: ↓ ↑ move the highlight, round the ends; Esc closes; ⇧⌘O toggles it; ⌥⌘O goes straight to Search Spaces.
        run { [self] in
            guard let l = little else { return }
            l.showOpenInMenu()
            guard let m = l.openInMenu else { return }
            let items = m.rows.filter(\.isEnabled).map(\.item)
            let start = items.firstIndex(of: .space(home)) ?? 0
            let down = keyEvent(l, "\u{F701}", 125, [.numericPad, .function]).map(l.handleKey) ?? false
            let afterDown = m.highlighted
            let up = keyEvent(l, "\u{F700}", 126, [.numericPad, .function]).map(l.handleKey) ?? false
            let afterUp = m.highlighted
            for _ in 0..<items.count { _ = keyEvent(l, "\u{F701}", 125, [.numericPad, .function]).map(l.handleKey) }
            let round = m.highlighted == .space(home)
            let esc = keyEvent(l, "\u{1B}", 53, []).map(l.handleKey) ?? false
            check(down && up && afterDown == items[(start + 1) % items.count] && afterUp == .space(home) && round && esc && l.openInMenu == nil
                  && l.page != nil, "little arc (Open In): ↓ ↑ move the highlight and go round the ends; Esc closes it (↓ \(String(describing: afterDown)), "
                  + "↑ \(String(describing: afterUp)), round \(round), closed \(l.openInMenu == nil))")
            let before = l.menusMade
            _ = keyEvent(l, "o", 31, [.command, .shift]).map(l.handleKey)
            let opened = l.openInMenu?.isShown == true && l.openInMenu?.isExpanded == false
            _ = keyEvent(l, "o", 31, [.command, .shift]).map(l.handleKey)
            let closed = l.openInMenu == nil
            _ = keyEvent(l, "o", 31, [.command, .option]).map(l.handleKey)
            let searching = l.openInMenu.map { $0.isExpanded && !$0.field.isHidden && $0.rows.count == min(c.store.orderedSpaces.count, LittleArcOpenInMenu.resultLimit) } ?? false
            l.openInMenu?.close()
            check(opened && closed && searching && l.menusMade == before + 2,
                  "little arc (Open In): ⇧⌘O opens the short list and closes it again; ⌥⌘O opens straight into Search Spaces with every Space "
                  + "(short list \(opened), closed \(closed), search \(searching), menus \(l.menusMade - before))")
        }
        // Search Spaces: the short list cut to one Space (the chip's), the row expands into the field; typing filters, Delete undoes.
        run { [self] in
            guard let l = little else { return }
            let saved = LittleArcOpenInMenu.collapsedLimit
            LittleArcOpenInMenu.collapsedLimit = 1
            defer { LittleArcOpenInMenu.collapsedLimit = saved }
            l.showOpenInMenu()
            guard let m = l.openInMenu else { return }
            let short = m.rows.compactMap { if case .space(let id) = $0.item { return id } else { return nil } }
            m.activate(.search)
            let all = m.rows.map(\.titleText)
            let siblingName = c.store.space(sibling)?.name ?? "?"
            m.setQuery(String(siblingName.dropFirst()).uppercased())
            let filtered = m.rows.first?.titleText == siblingName && m.highlighted == .space(sibling)
            m.setQuery("zzz qqq")
            let none = m.rows.isEmpty
            m.close()
            // Typing in the short list starts the search with what's typed; Delete takes it back.
            l.showOpenInMenu()
            let first = String(siblingName.prefix(1))
            _ = keyEvent(l, first, 0, []).map(l.handleKey)
            let typed = l.openInMenu.map { $0.isExpanded && $0.query == first && $0.field.stringValue == first } ?? false
            _ = keyEvent(l, "\u{7F}", 51, []).map(l.handleKey)
            let deleted = l.openInMenu?.query == ""
            l.openInMenu?.close()
            check(short == [home] && all == c.store.orderedSpaces.prefix(LittleArcOpenInMenu.resultLimit).map(\.name) && filtered && none && typed && deleted,
                  "little arc (Open In): Search Spaces: a short list of one keeps the chip's Space; the row expands into a field listing every Space; "
                  + "typing filters them, ignoring case (“\(siblingName)” first and highlighted \(filtered)), nothing matches: no rows (\(none)); typing in "
                  + "the short list starts the search (\(typed)), Delete takes it back (\(deleted)) (short \(short.count), all \(all))")
        }
        // Profile ▸: another profile opens the page again in it, in the same window; back again.
        step { [self] done in
            guard let l = little, let old = l.page, let homePID = c.store.space(home)?.profileID else { return done() }
            let sub = l.profileMenu(counted: false)
            guard let other = sub.items.firstIndex(where: { $0.state != .on }) else {
                check(false, "little arc (row): Profile ▸ has another profile"); return done()
            }
            let profiles = sub.items
            let withSpaces = c.store.orderedProfiles.filter { !c.store.spaces(usingProfile: $0.id).isEmpty }
            let checked = profiles.filter { $0.state == .on }.map { Self.titleOnly($0.title) }
            let notes = profiles.map { Self.secondLine($0) }
            let profilesOK = profiles.map({ Self.titleOnly($0.title) }) == withSpaces.map(\.name)
                && checked == [c.store.profile(homePID)?.name ?? "?"]
                && zip(profiles, notes).allSatisfy { ($0.state == .on) == ($1 == nil) && ($1 == nil || $1 == "Reloads the page") }
                && profiles.allSatisfy { $0.image != nil }
            check(profilesOK, "little arc (row): Profile ▸ lists the profiles by avatar and name, the page's checked, “Reloads the page” "
                  + "on the others only (\(zip(profiles, notes).map { "\($0.state == .on ? "✓ " : "")\(Self.titleOnly($0.title))\($1.map { " · " + $0 } ?? "")" }))")
            sub.performActionForItem(at: other)
            waitUntil({ l.page?.title == "little arc 0" && l.page !== old }, timeout: 8) {
                let switched = l.profileID != homePID && l.page !== old && self.app?.littleArcs.contains { $0 === l } == true
                self.check(switched && l.chip.shownName == self.c.store.space(l.spaceID)?.name,
                           "little arc (row): Profile ▸ another profile opens the page again in it, in this window (profile changed \(l.profileID != homePID), "
                           + "page reopened \(l.page !== old), chip “\(l.chip.shownText)”)")
                // Back to the home profile's Space for the rest.
                l.switchSpace(home)
                self.waitUntil({ l.page?.title == "little arc 0" && l.profileID == homePID }, timeout: 8) { done() }
            }
        }
        // Copy Link and ⇧⌘C: the page's address, on a pasteboard of the run's own.
        run { [self] in
            guard let l = little, let url = l.page?.url?.absoluteString else { return }
            let saved = WindowController.linkPasteboard
            let board = NSPasteboard.withUniqueName()
            WindowController.linkPasteboard = board
            defer { WindowController.linkPasteboard = saved; board.releaseGlobally() }
            l.showOpenInMenu()
            l.openInMenu?.activate(.copyLink)
            let menuCopied = board.string(forType: .string) == url && l.openInMenu == nil
            board.clearContents()
            let handled = keyEvent(l, "c", 8, [.command, .shift]).map(l.handleKey) ?? false
            let keyCopied = board.string(forType: .string) == url
            check(menuCopied && handled && keyCopied, "little arc (row): Copy Link and ⇧⌘C copy the page's address (menu \(menuCopied), ⇧⌘C \(keyCopied))")
        }
        // A real click on another Space's row of the same profile: the same live page moves there. A person can only click
        // the menu once it's on screen, so the press waits until the window server has it at the row: a press posted in
        // the same turn as it opened went to the window still shown there, and AppKit dropped it (nightly 2026-11-08).
        // Another app's window over the row is the UI case's FAIL-ENV evidence; a press the row got and didn't act on
        // stays a FAIL. Failing, it says where the press went and what the menu was sent.
        func rowClick(_ what: String, tag: String) {
            var page: EngineTab?
            var menusBefore = 0
            var probe = ""
            uiCase(window: { little?.window }) {
                run { [self] in
                    uiAttempt?.needsKeyWindow = false
                    uiAttempt?.needsUncoveredWindow = false
                }
                step { [self] done in
                    guard let l = little else { return done() }
                    page = l.page
                    LittleArcOpenInMenu.trace = []
                    l.openInMenu?.close()
                    l.showOpenInMenu()
                    menusBefore = l.menusMade
                    guard let m = l.openInMenu, let row = m.row(.space(sibling)) else {
                        check(false, "little arc (Open In): the menu lists a second Space of the profile")
                        return done()
                    }
                    let p = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
                    let screen = m.panel.convertPoint(toScreen: p)
                    uiAttempt?.point = l.window.convertPoint(fromScreen: screen)
                    uiAttempt?.needsUncoveredWindow = true
                    let opened = ProcessInfo.processInfo.systemUptime
                    let onScreen = { NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == m.panel.windowNumber }
                    waitUntil(onScreen, timeout: 2) {
                        let ms = Int((ProcessInfo.processInfo.systemUptime - opened) * 1000)
                        let what = "little arc (Open In): the menu is on screen at its rows soon after it opens, for a click"
                        if onScreen() {
                            self.check(true, what + " (within \(ms) ms)")
                        } else {
                            // Another app's window over the row is the environment's, whatever the press does next (it's posted
                            // straight to the menu, so it can still get through and doesn't excuse this). A window of ours there,
                            // or none, is ours.
                            let n = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
                            let why = "not after 2 s: the window there is \(Self.windowOwner(at: screen))"
                            if n > 0, Self.windowInfo(n).pid != getpid() { self.failEnv(what, why) } else { self.check(false, what + " (\(why))") }
                        }
                        probe = Self.openInProbe(m, p)
                        self.click(at: p, in: m.panel) {
                            // The row got the press: the input reached us, so a FAIL is ours whatever else is on screen.
                            uiAttempt?.recordInputDelivery(LittleArcOpenInMenu.trace.contains { $0.hasPrefix("down ") })
                            done()
                        }
                    }
                }
                moved(what, tag: tag, into: { sibling }, page: { page }, menusBefore: { menusBefore },
                      detail: { probe + "; menu: " + LittleArcOpenInMenu.trace.joined(separator: " · ") })
            }
        }
        rowClick("a click on another Space's row in Open In", tag: "row")
        // AIRC_LA_ROW_REPEAT=N (by hand, for the nightly FAIL of 2026-11-08): the row click N times in each of two ways,
        // after the cases before it (Profile ▸ there and back, Copy Link) and on a fresh window, with a Space of another
        // profile (a two-line row) before the row, as in `--script events`.
        let repeats = Int(ProcessInfo.processInfo.environment["AIRC_LA_ROW_REPEAT"] ?? "") ?? 0
        if repeats > 0 {
            run { [self] in
                let pid = c.store.profile(ofSpace: home).id
                guard let other = c.store.orderedProfiles.first(where: { $0.id != pid }),
                      !c.store.orderedSpaces.contains(where: { $0.name == "Other click" }) else { return }
                _ = try? c.store.createSpace(name: "Other click", icon: .symbol("cursorarrow"), theme: SpaceTheme(colors: [RGBA(hex: "E4B373")!]),
                                             profileID: other.id, after: home)
                c.reloadAll(animated: false)
            }
        }
        func profileThereAndBack() {
            step { [self] done in
                guard let l = little, let old = l.page, let homePID = c.store.space(home)?.profileID else { return done() }
                let sub = l.profileMenu(counted: false)
                guard let other = sub.items.firstIndex(where: { $0.state != .on }) else { return done() }
                sub.performActionForItem(at: other)
                waitUntil({ l.page?.title == "little arc 0" && l.page !== old }, timeout: 8) {
                    l.switchSpace(home)
                    self.waitUntil({ l.page?.title == "little arc 0" && l.profileID == homePID }, timeout: 8) { done() }
                }
            }
        }
        func copyLinkQuietly() {
            run {
                guard let l = little else { return }
                let saved = WindowController.linkPasteboard
                let board = NSPasteboard.withUniqueName()
                WindowController.linkPasteboard = board
                defer { WindowController.linkPasteboard = saved; board.releaseGlobally() }
                l.showOpenInMenu()
                l.openInMenu?.activate(.copyLink)
                _ = keyEvent(l, "c", 8, [.command, .shift]).map(l.handleKey)
            }
        }
        for i in 0..<repeats {
            openLittle("ra\(i)z")
            profileThereAndBack()
            copyLinkQuietly()
            rowClick("repeat \(i + 1) after Profile ▸ and Copy Link: a click on another Space's row in Open In", tag: "ra\(i)z")
            openLittle("rb\(i)z")
            rowClick("repeat \(i + 1) on a fresh window: a click on another Space's row in Open In", tag: "rb\(i)z")
        }
        var page: EngineTab?
        var menusBefore = 0
        // Return on the highlighted row, the chip's Space.
        openLittle("first")
        run { [self] in
            guard let l = little else { return }
            page = l.page
            l.showOpenInMenu()
            menusBefore = l.menusMade
            guard l.openInMenu?.highlighted == .space(home) else { return check(false, "little arc (Open In): the chip's Space is highlighted") }
            _ = keyEvent(l, "\r", 36, []).map(l.handleKey)
        }
        moved("Return in Open In (the chip's Space, highlighted)", tag: "first", into: { home }, page: { page }, menusBefore: { menusBefore })
        // ⌘O.
        openLittle("key")
        run {
            guard let l = little, let e = keyEvent(l, "o", 31, .command) else { return }
            page = l.page
            menusBefore = l.menusMade
            _ = l.handleKey(e)
        }
        moved("⌘O", tag: "key", into: { home }, page: { page }, menusBefore: { menusBefore })
        // ⌥⌘O, the Space's name typed, Return.
        openLittle("search")
        run { [self] in
            guard let l = little else { return }
            page = l.page
            _ = keyEvent(l, "o", 31, [.command, .option]).map(l.handleKey)
            menusBefore = l.menusMade
            for ch in (c.store.space(sibling)?.name ?? "") { _ = keyEvent(l, String(ch), 0, []).map(l.handleKey) }
            _ = keyEvent(l, "\r", 36, []).map(l.handleKey)
        }
        moved("⌥⌘O, the Space's name typed and Return", tag: "search", into: { sibling }, page: { page }, menusBefore: { menusBefore })
        // One real click on the chip (not its chevron): the page moves, no menu in between (the owner's one click).
        uiCase(window: { little?.window }) {
            run { [self] in
                uiAttempt?.needsKeyWindow = false
                uiAttempt?.needsUncoveredWindow = false
            }
            openLittle("click")
            step { [self] done in
                guard let l = little else { return done() }
                page = l.page
                menusBefore = l.menusMade
                let r = l.chip.openRect
                click(at: l.chip.convert(NSPoint(x: r.midX, y: r.midY), to: nil), in: l.window) { done() }
            }
            moved("one click on the chip", tag: "click", into: { home }, page: { page }, menusBefore: { menusBefore })
        }
        // A Space of another profile (VoiceOver's press on its row): the page opens again there (a page can't change profile).
        openLittle("other")
        var otherSpace = ""
        run { [self] in
            guard let l = little else { return }
            page = l.page
            l.showOpenInMenu()
            guard let m = l.openInMenu, let row = m.rows.first(where: { r in
                if case .space(let id) = r.item { return c.store.space(id)?.profileID != l.profileID } else { return false }
            }), case .space(let id) = row.item else { return check(false, "little arc (Open In): the menu lists a Space of another profile") }
            otherSpace = id
            _ = row.accessibilityPerformPress()
        }
        step { [self] done in
            waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 4) {
                let tab = self.c.store.todayTabs(ofSpace: otherSpace).first { $0.url.contains("from=other") }
                let reopened = page?.isClosed != false && tab.flatMap { self.c.engineTab(for: $0.id) } !== page
                self.check(tab != nil && self.app?.littleArcs.isEmpty == true && reopened,
                           "little arc (Open In): another profile's Space (VoiceOver's press on its row) opens the page again there "
                           + "(\(self.c.store.space(otherSpace)?.name ?? "?"): tab \(tab != nil), window closed \(self.app?.littleArcs.isEmpty == true), "
                           + "old page closed and a new one \(reopened))")
                self.c.switchToSpace(home, animated: false)
                done()
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
                self.check(flags, "little arc (Spaces): a Little Airc window moves to the active Space when it's made active, and may join a "
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

    /// LA-1 over another app's full screen (LittleArcFullScreen), what a suite run can check without a full-screen app and
    /// without taking the owner's focus: a link from a full-screen app opens Little Arc as a non-activating floating panel
    /// (invisible here, never made key). It loads its page there and doesn't activate the app, Esc doesn't close it, ⌘O
    /// moves its live page into the Space, and it's the ordinary window again once its full-screen app has left full
    /// screen. Test copies never use the panel for real links. The real full screen is the by-hand proof
    /// (`littleArcFullScreenScenario`).
    func littleArcPanelChecks(_ base: @escaping () -> String) {
        var little: LittleArcController?
        var home = ""
        var activeBefore = false
        func openPanel(_ tag: String) {
            step { [self] done in
                guard !base().isEmpty else { return done() }
                home = c.currentSpaceID
                activeBefore = NSApp.isActive
                LittleArcController.startsHidden = true
                // As a link from a full-screen app opens it (that app here: this one; a suite run hands nothing anywhere).
                little = app?.openLittleArc(url: URL(string: base() + "/la?from=\(tag)"), spaceID: home, overFullScreenOf: getpid())
                LittleArcController.startsHidden = false
                waitUntil({ little?.page?.title == "little arc 0" && little?.page?.isLoading == false }, timeout: 8) { done() }
            }
        }
        run { [self] in
            // Its cost: event-driven (no timer), a look at the window list as Airc is about to become active and as a link
            // is routed.
            let t0 = CACurrentMediaTime()
            for _ in 0..<20 { _ = LinkLog.isFullScreen(getpid()) }
            let each = (CACurrentMediaTime() - t0) / 20 * 1000
            check(each < 5, "little arc (full-screen panel): telling a full-screen app costs \(String(format: "%.2f", each)) ms a look, "
                  + "on activations and links only")
            check(!LittleArcFullScreen.enabled && LittleArcFullScreen.shared.takeLinkSource() == nil,
                  "little arc (full-screen panel): a test run never opens links over the owner's full-screen app and routes them as before "
                  + "(enabled \(LittleArcFullScreen.enabled))")
        }
        openPanel("panel")
        run { [self] in
            guard let l = little, let page = l.page else { return check(false, "little arc (full-screen panel): the panel opens with its page") }
            let w = l.window
            let b = w.collectionBehavior
            check(w is LittleArcPanel && w.styleMask.contains(.nonactivatingPanel) && w.level == .floating && (w as? NSPanel)?.isFloatingPanel == true
                  && b == LittleArcFullScreen.panelBehaviour && !w.hidesOnDeactivate && w.canBecomeKey && w.canBecomeMain
                  && !w.isExcludedFromWindowsMenu && l.overFullScreen,
                  "little arc (full-screen panel): a link from a full-screen app opens a non-activating floating panel on that Space that stays "
                  + "when the app deactivates and can be key and main (\(type(of: w)), level \(w.level.rawValue), behaviour \(b.rawValue), "
                  + "hides on deactivate \(w.hidesOnDeactivate))")
            check(page.view.window === w && page.view.isDescendant(of: l.card) && page.title == "little arc 0" && w.isVisible,
                  "little arc (full-screen panel): its page is loaded in the panel (title “\(page.title)”, in it \(page.view.window === w))")
            check(NSApp.isActive == activeBefore && !w.isKeyWindow,
                  "little arc (full-screen panel): opening it doesn't activate the app (active \(activeBefore) → \(NSApp.isActive); a suite run "
                  + "never makes it key)")
            w.cancelOperation(nil)
        }
        wait(0.3)
        run { [self] in
            guard let l = little else { return }
            check(l.window.isVisible && app?.littleArcs.contains { $0 === l } == true,
                  "little arc (full-screen panel): Esc that nothing in it uses doesn't close it (the panel's cancel)")
        }
        // ⌘O moves its page: the same live page on Chromium.
        var page: EngineTab?
        run {
            guard let l = little, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: l.window.windowNumber,
                                                           context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31)
            else { return }
            page = l.page
            _ = l.handleKey(e)
        }
        step { [self] done in
            waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 4) {
                let chromium = self.app?.engine.name.hasPrefix("Chromium") == true
                let tab = self.c.store.todayTabs(ofSpace: home).first { $0.url.contains("from=panel") }
                let live = tab.flatMap { self.c.engineTab(for: $0.id) }
                let same = !chromium || (live != nil && live === page)
                self.check(tab != nil && self.app?.littleArcs.isEmpty == true && same,
                           "little arc (full-screen panel): ⌘O moves its page into the Space (tab \(tab != nil), panel closed "
                           + "\(self.app?.littleArcs.isEmpty == true)\(chromium ? ", same live page \(same)" : ""))")
                done()
            }
        }
        closeLittleArcs()
        // Its full-screen app left full screen: the ordinary window's level and Spaces behaviour again.
        openPanel("settle")
        run { [self] in
            guard let l = little else { return check(false, "little arc (full-screen panel): a second panel opens") }
            l.settleOverFullScreen()
            let w = l.window, b = w.collectionBehavior
            check(!l.overFullScreen && w.level == .normal && (w as? NSPanel)?.isFloatingPanel == false && !w.styleMask.contains(.nonactivatingPanel)
                  && b.contains(.moveToActiveSpace) && b.contains(.fullScreenAuxiliary) && !b.contains(.canJoinAllSpaces) && w.isVisible,
                  "little arc (full-screen panel): once its full-screen app has left full screen it's an ordinary window again: normal level, "
                  + "activating, moving to the active Space when shown (level \(w.level.rawValue), behaviour \(b.rawValue))")
        }
        closeLittleArcs()
    }

    static let littleArcTypePage = """
        <!doctype html><title>little arc 0</title>
        <style>body{margin:0;font:15px -apple-system,sans-serif}#field{position:absolute;left:60px;top:60px;width:260px;height:30px;font-size:16px}</style>
        <input id=field autocomplete=off>
        <script>var loadID=Math.random().toString(36).slice(2);</script>
        """

    /// Key presses posted to the app's queue for window `w`, with the key codes this Mac's layout types them with (Chromium
    /// rebuilds a key from its code).
    func postLittleArcKeys(_ text: String, to w: NSWindow) {
        let near: [Character: UInt16] = ["a": 0, "i": 34, "r": 15, "c": 8, "q": 12, "x": 7, "o": 31]
        for ch in text {
            let s = String(ch)
            postLittleArcKey(s, code: Self.Layout.code(typing: s, near: near[ch] ?? 0)?.code ?? near[ch] ?? 0, to: w)
        }
    }

    func postLittleArcKey(_ chars: String, code: UInt16, mods: NSEvent.ModifierFlags = [], to w: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// LA-1 over another app's full screen, for real (by hand: `--script littlearc` with AIRC_LA_FS=1 and
    /// AIRC_LA_AS_OWNER=1 in a scratch copy; the runner in artifacts/lafullscreen/fsproof waits for an idle owner and takes
    /// the UI-check lock; never in the suite). A scratch app is in native full screen in front, and a link comes through
    /// Launch Services (`open -b`), which activates this copy. Checked, with every Space change timed from the activation:
    ///   - Little Arc ends on the full-screen Space, in front of that app's window; the app stays in full screen; the
    ///     browser window's desktop isn't shown; no Space change on the way (no round trip);
    ///   - with the full-screen app active again (as a click on it makes it), Little Arc stays over it;
    ///   - a click into the page's field makes the panel key without activating Airc, and typing reaches the field; a
    ///     click into the address row, and typing reaches it;
    ///   - ⌘O moves the page into the browser window without a reload, and the browser window comes forward.
    /// AIRC_LA_FS_NOLINK=1: the app is activated with no link (as ⌘-Tab does): the browser window comes forward on its
    /// desktop, as before.
    func littleArcFullScreenScenario() {
        var server: LocalPageServer?
        var base = ""
        var observers: [NSObjectProtocol] = []
        let start = Date()
        var activation: Date?
        var spaceChanges: [TimeInterval] = []
        var other: pid_t = 0
        var fsPID: pid_t = 0
        var fsAtActivation: Bool?
        // Activations of this app (the clicks into the panel mustn't add one).
        var activations = 0
        var activationsAfterHandBack = 0
        var little: LittleArcController?
        var loadID = ""
        func stamp() -> String { String(format: "+%.3f s", Date().timeIntervalSince(activation ?? start)) }
        func fsName() -> String { NSRunningApplication(processIdentifier: fsPID)?.bundleIdentifier ?? "pid \(fsPID)" }
        let ws = NSWorkspace.shared.notificationCenter
        run { [self] in
            if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid() { other = f.processIdentifier }
            observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if let pid = a?.processIdentifier, pid != getpid() { other = pid }
                self?.note("little arc (full screen): \(stamp()) \(a?.bundleIdentifier ?? "?") came to the front")
            })
            observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                if let a = activation { spaceChanges.append(Date().timeIntervalSince(a)) }
                self?.note("little arc (full screen): \(stamp()) the active Space changed (\(LinkLog.frontApp()))")
            })
            for (name, what) in [(NSApplication.willBecomeActiveNotification, "will become active"), (NSApplication.didBecomeActiveNotification, "became active"),
                                 (NSApplication.didResignActiveNotification, "resigned active")] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    if name == NSApplication.willBecomeActiveNotification { activations += 1 }
                    if name == NSApplication.willBecomeActiveNotification, activation == nil {
                        activation = Date()
                        fsPID = other
                        fsAtActivation = other != 0 && LinkLog.isFullScreen(other)
                    }
                    let browser = self?.app?.controllers.first?.window
                    self?.note("little arc (full screen): \(stamp()) app \(what); key \(self?.app?.windowName(NSApp.keyWindow) ?? "-"), browser window on "
                               + "the active Space \(browser?.isOnActiveSpace == true), Little Aircs \(self?.app?.littleArcs.count ?? 0)")
                })
            }
        }
        step { [self] done in
            server = LocalPageServer(pages: ["/la": Self.littleArcTypePage, "/followed": "<title>followed</title><p>Followed</p>"])
            server?.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                if let port { try? "\(port)\n".write(to: self.dir.appendingPathComponent("littlearc-port.txt"), atomically: true, encoding: .utf8) }
                self.note("little arc (full screen): owner mode \(LittleArcController.actsAsOwner), full-screen handling \(LittleArcFullScreen.enabled), "
                          + "panel behaviour \(LittleArcFullScreen.panelBehaviour.rawValue); "
                          + "waiting for open -b … \(base)/la?from=fullscreen")
                done()
            }
        }
        let fsWindowOrder = { (w: NSWindow) -> (mine: Int?, theirs: Int?) in
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let numbers = list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
            let theirs = list.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == fsPID && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
                .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }.compactMap { numbers.firstIndex(of: $0) }.min()
            return (numbers.firstIndex(of: w.windowNumber), theirs)
        }
        if ProcessInfo.processInfo.environment["AIRC_LA_FS_NOLINK"] == "1" {
            // How long from the activation until the browser window is on the active Space (the delay ⌘-Tab, a Dock click
            // or another activation without a link sees), polled every 10 ms.
            step { [self] done in
                waitUntil({ activation != nil }, timeout: 90) {
                    let browser = self.app?.browserWindow()?.window
                    var forward: TimeInterval?
                    func poll() {
                        guard let a = activation else { return done() }
                        let t = Date().timeIntervalSince(a)
                        if browser?.isOnActiveSpace == true, browser?.isVisible == true { forward = t }
                        if forward == nil, t < 4 { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            // As before this change: macOS switches by itself (0.30 to 0.41 s in the runs before it).
                            let quick = forward.map { $0 <= 0.6 } ?? false
                            self.check(fsAtActivation == true && forward != nil && browser?.isKeyWindow == true && self.app?.littleArcs.isEmpty == true && quick,
                                       "little arc (full screen, no link): activated from \(fsName()) in full screen with no link, the browser window comes "
                                       + "forward on its desktop, \(forward.map { String(format: "%.3f s", $0) } ?? "never") after the activation "
                                       + "(“\(LittleArcFullScreen.shared.lastAction)”, browser key \(browser?.isKeyWindow == true), "
                                       + "Space changes at \(spaceChanges.map { String(format: "%.3f s", $0) }))")
                            done()
                        }
                    }
                    poll()
                }
            }
        } else {
            step { [self] done in
                let ours = { self.app?.littleArcs.first { $0.page?.url?.query?.contains("from=fullscreen") == true } }
                waitUntil({ ours()?.page?.isLoading == false || base.isEmpty }, timeout: 90) {
                    little = ours()
                    self.note("little arc (full screen): \(stamp()) Little Airc open and loaded")
                    little?.page?.evaluate("loadID") { v in loadID = v as? String ?? "" }
                    // Long enough for the fallback's hand-back (0.8 s) and its Space switch.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: done)
                }
            }
            run { [self] in
                guard let l = little else { return check(false, "little arc (full screen): a link sent through Launch Services opens Little Airc") }
                let w = l.window
                let (mine, theirs) = fsWindowOrder(w)
                let inFront = mine != nil && theirs != nil && mine! < theirs!
                let stillFull = fsPID != 0 && LinkLog.isFullScreen(fsPID)
                let browserShown = app?.controllers.contains { $0.window.isOnActiveSpace } == true
                note("little arc (full screen): \(stamp()) \(LinkLog.windowState(w)), app active \(NSApp.isActive), \(type(of: w)), level \(w.level.rawValue), "
                     + "behaviour \(w.collectionBehavior.rawValue), “\(LittleArcFullScreen.shared.lastAction)”")
                check(fsAtActivation == true, "little arc (full screen): \(fsName()) was in native full screen as Airc became active "
                      + "(\(fsAtActivation.map(LinkLog.yesNo) ?? "-"))")
                check(w.isOnActiveSpace && stillFull && inFront && !browserShown && l.overFullScreen,
                      "little arc (full screen): Little Airc ends on the full-screen Space, in front of \(fsName())'s window, without the browser "
                      + "window's desktop (on the active Space \(w.isOnActiveSpace), in front \(inFront), browser window shown \(browserShown), panel "
                      + "\(l.overFullScreen))")
                check(stillFull, "little arc (full screen): \(fsName()) stays in full screen, its Space on screen (\(stillFull))")
                check(spaceChanges.isEmpty, "little arc (full screen): no round trip: no Space change from the activation on (changes at "
                      + "\(spaceChanges.map { String(format: "%.3f s", $0) }))")
            }
            // The person goes back to the full-screen app (a click on it): Little Arc stays over it.
            step { [self] done in
                guard let fs = NSRunningApplication(processIdentifier: fsPID), little != nil else { return done() }
                if NSApp.isActive {
                    if #available(macOS 14.0, *) { NSApp.yieldActivation(to: fs); fs.activate(from: .current, options: []) } else { fs.activate(options: []) }
                }
                waitUntil({ NSWorkspace.shared.frontmostApplication?.processIdentifier == fsPID && !NSApp.isActive }, timeout: 3) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        guard let w = little?.window else { return done() }
                        let (mine, theirs) = fsWindowOrder(w)
                        let inFront = mine != nil && theirs != nil && mine! < theirs!
                        activationsAfterHandBack = activations
                        self.check(!NSApp.isActive && w.isVisible && w.isOnActiveSpace && inFront && LinkLog.isFullScreen(fsPID),
                                   "little arc (full screen): with \(fsName()) in front again, Little Airc stays over it (app active \(NSApp.isActive), "
                                   + "on the active Space \(w.isOnActiveSpace), in front \(inFront), \(LinkLog.frontApp()))")
                        done()
                    }
                }
            }
            // A click into the page's field: key without activating Airc; then typing.
            var field: NSPoint?
            step { [self] done in
                guard let l = little, let page = l.page else { return done() }
                page.evaluate("(function(){var r=document.getElementById('field').getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2]})()") { v in
                    let xy = (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                    if xy.count == 2 {
                        let view = page.view
                        field = view.convert(NSPoint(x: xy[0], y: view.isFlipped ? xy[1] : Double(view.bounds.height) - xy[1]), to: nil)
                    }
                    guard let p = field else { self.check(false, "little arc (full screen): the page's field is on screen"); return done() }
                    self.click(at: p, in: l.window) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done) }
                }
            }
            step { [self] done in
                guard let l = little, let page = l.page else { return done() }
                let w = l.window
                page.evaluate("(document.activeElement||{}).id||''") { v in
                    let focused = v as? String ?? ""
                    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == fsPID
                    let browserShown = self.app?.controllers.contains { $0.window.isOnActiveSpace } == true
                    // AppKit says the app is active once a non-activating panel is key; the system doesn't activate it (no
                    // activation notification, the full-screen app stays the front app).
                    let activated = activations != activationsAfterHandBack
                    self.check(w.isKeyWindow && !activated && front && LinkLog.isFullScreen(fsPID) && !browserShown && focused == "field",
                               "little arc (full screen): a click into its page's field makes the panel key without activating Airc or showing the "
                               + "browser window (key \(w.isKeyWindow), activations \(activations - activationsAfterHandBack), \(fsName()) in front \(front), "
                               + "focused “\(focused)”, browser window shown \(browserShown), NSApp.isActive \(NSApp.isActive))")
                    self.postLittleArcKeys("airc", to: w)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        page.evaluate("document.getElementById('field').value") { v in
                            let typed = v as? String ?? "-"
                            self.check(typed == "airc", "little arc (full screen): typing reaches the page's field in the panel "
                                       + "(“\(typed)”, \(self.app?.engine.name ?? "?"), app active \(NSApp.isActive))")
                            done()
                        }
                    }
                }
            }
            // The address row.
            step { [self] done in
                guard let l = little else { return done() }
                let f = l.addressField
                click(at: f.convert(NSPoint(x: f.bounds.midX, y: f.bounds.midY), to: nil), in: l.window) {
                    self.postLittleArcKeys("qxqxq", to: l.window)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let text = f.currentEditor()?.string ?? f.stringValue
                        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == fsPID
                        self.check(text.contains("qxqxq") && l.window.isKeyWindow && activations == activationsAfterHandBack && front,
                                   "little arc (full screen): a click into the address row and typing reach it in the panel (“\(text)”, key "
                                   + "\(l.window.isKeyWindow), activations \(activations - activationsAfterHandBack), \(fsName()) in front \(front))")
                        // Esc: back to the page, the address as it was.
                        self.postLittleArcKey("\u{1b}", code: 53, to: l.window)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                    }
                }
            }
            // ⌘O: the page moves into the browser window, the same page (not reloaded), and that window comes forward.
            var moved: EngineTab?
            step { [self] done in
                guard let l = little else { return done() }
                moved = l.page
                postLittleArcKey("o", code: Self.Layout.code(typing: "o", near: 31)?.code ?? 31, mods: .command, to: l.window)
                waitUntil({ self.app?.littleArcs.contains { $0 === l } == false }, timeout: 4) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: done)
                }
            }
            step { [self] done in
                let chromium = app?.engine.name.hasPrefix("Chromium") == true
                let browser = app?.browserWindow()
                let tab = browser.flatMap { b in b.store.todayTabs(ofSpace: b.currentSpaceID).first { $0.url.contains("from=fullscreen") } }
                let live = tab.flatMap { browser?.engineTab(for: $0.id) }
                let same = !chromium || (live != nil && live === moved)
                guard let page = live ?? moved else {
                    check(false, "little arc (full screen): ⌘O moves the page into the browser window (no page)"); return done()
                }
                page.evaluate("loadID") { v in
                    let kept = !loadID.isEmpty && (v as? String) == loadID
                    let w = browser?.window
                    self.check(tab != nil && self.app?.littleArcs.isEmpty == true && same && kept,
                               "little arc (full screen): ⌘O in the panel moves its page into the browser window without a reload (tab \(tab != nil), "
                               + "panel closed \(self.app?.littleArcs.isEmpty == true), \(chromium ? "same live page \(same), " : "")same load \(kept))")
                    self.check(w?.isKeyWindow == true && w?.isOnActiveSpace == true && NSApp.isActive,
                               "little arc (full screen): …and the browser window comes forward (key \(w?.isKeyWindow == true), on the active Space "
                               + "\(w?.isOnActiveSpace == true), app active \(NSApp.isActive), Space changes at \(spaceChanges.map { String(format: "%.2f", $0) }))")
                    done()
                }
            }
        }
        run { [self] in
            // Links.log goes with the ephemeral data folder: its lines here.
            for line in Self.linksLog(since: 0).split(separator: "\n") { note("little arc (full screen): Links.log: \(line)") }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.forEach(ws.removeObserver)
        }
        closeLittleArcs()
        run { server?.stop() }
    }

    /// A menu row's title without the second line folded into it before macOS 14.4.
    static func titleOnly(_ title: String) -> String { title.components(separatedBy: " — ").first ?? title }
    static func secondLine(_ item: NSMenuItem) -> String? {
        if #available(macOS 14.4, *) { return item.subtitle }
        let parts = item.title.components(separatedBy: " — ")
        return parts.count > 1 ? parts.last : nil
    }
    /// A colour as #RRGGBBAA (sRGB), for logs.
    static func hex(_ c: CGColor) -> String {
        guard let s = NSColor(cgColor: c)?.usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255), Int(s.alphaComponent * 255))
    }
    /// An Open In row as the checks log it: its title, second line and what's at its right.
    static func rowText(_ row: LittleArcOpenInRow) -> String {
        row.titleText + (row.subtitleText.map { " · " + $0 } ?? "") + (row.trailingText.isEmpty ? "" : " " + row.trailingText) + (row.isEnabled ? "" : " (off)")
    }

    /// `menu` under the chip of a Little Arc window drawn as `window` (`at`: the menu's top left in the window's flipped
    /// coordinates), with a menu's fill and shadow, as `<name>.png` at 2×.
    func writeMenuShot(_ name: String, window: NSImage?, size: NSSize, menu: NSImage, at: NSPoint, dark: Bool, radius: CGFloat = SnapshotRunner.mkMenuRadius) {
        let m = menu.size
        let canvas = NSSize(width: max(size.width, at.x + m.width + 24), height: max(size.height, at.y + m.height + 24))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        window?.draw(in: NSRect(x: 0, y: canvas.height - size.height, width: size.width, height: size.height))
        let r = NSRect(x: at.x, y: canvas.height - at.y - m.height, width: m.width, height: m.height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.965, alpha: 1)).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        menu.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        note("wrote \(name).png")
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
                           "little arc (Launch Services): a link sent through Launch Services (open -b) opens a Little Airc window with its page "
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
                           "little arc (cold start): a link that launches the app opens a Little Airc window with its page "
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
            guard let l = little(), let page = l.page else { check(false, "\(label): there is a Little Airc page"); return done() }
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
                           "\(label): the page's view is in the Little Airc window (\(inWindow)), \(Int(view.bounds.width))×\(Int(view.bounds.height)), "
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
        // Inspect this window and this point, never the main browser window's Space or focus.
        uiCase(window: { little()?.window }) {
            run { [self] in
                uiAttempt?.needsKeyWindow = false
                guard let l = little(), let page = l.page, let p = link else { return check(false, "\(label): the page's link is on screen") }
                uiAttempt?.point = p
                let (ok, text) = littleArcHit(at: p, page: page.view, in: l.window)
                let chromium = app?.engine.name.hasPrefix("Chromium") == true
                check(ok && (!chromium || text.contains("RenderWidgetHostView")),
                      "\(label): a press on the page's link reaches the page (\(text))")
            }
        }
        // A posted click on the link: followed while key; background windows may only activate.
        uiCase(window: { little()?.window }) {
            step { [self] done in
                guard let l = little(), let p = link else { return done() }
                self.uiAttempt?.point = p
                click(at: p, in: l.window) {
                    self.waitUntil({ l.page?.url?.path.hasPrefix("/followed") == true }, timeout: 3) {
                        let followed = l.page?.url?.path.hasPrefix("/followed") == true
                        self.check(followed, "\(label): a click on the page's link follows it (now \(l.page?.url?.path ?? "-"))")
                        done()
                    }
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
            ok = false
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
    /// For a failing Open In click: where the press goes as AppKit hit-tests it in the menu's window, and which window the
    /// window server has at that point (where a real click would go).
    static func openInProbe(_ m: LittleArcOpenInMenu, _ p: NSPoint) -> String {
        let w = m.panel
        let frame = w.contentView?.superview
        let hit = frame.flatMap { $0.hitTest($0.convert(p, from: nil)) }
        return String(format: "press (%.0f, %.0f) in the menu (visible %@, alpha %.2f, frame %@) hits %@; the window server's window there: %@",
                      p.x, p.y, "\(w.isVisible)", w.alphaValue, NSStringFromRect(w.frame), describe(hit), windowOwner(at: w.convertPoint(toScreen: p)))
    }

    /// The window the window server has at a screen point: ours by class, another app's by its name only (never a title).
    static func windowOwner(at screen: NSPoint) -> String {
        let n = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
        let pid = windowInfo(n).pid
        if pid == getpid() { return NSApp.windows.first { $0.windowNumber == n }.map { "our \(String(describing: type(of: $0)))" } ?? "our window \(n)" }
        return "\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "another app")'s (pid \(pid))"
    }

    func closeLittleArcs() {
        step { [self] done in
            app?.littleArcs.forEach { $0.closeWindow() }
            waitUntil({ self.app?.littleArcs.isEmpty != false }, timeout: 4) { done() }
        }
    }
}
#endif

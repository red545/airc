// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AppKit
import AircKit

/// Part of `--script events`: AT-1 Air Traffic Control and LA-1 Little Arc, on loopback pages. Links "from another
/// app" go through the app's own entry point for them (`application(_:open:)`, which asks the engine's routing policy
/// first), never through a real Apple event: that could reach the owner's own Airc.
///   - a rule ("URL contains /routed → Routed") sends the link to its Space, in that Space's profile;
///   - no rule: a Little Arc window in the most recent Space's profile;
///   - ⌘O in Little Arc moves the page into the Space as a Today tab: on Chromium the same live page (its script state
///     and typed text kept, no reload); WebKit can't move pages and opens it again;
///   - ⌥⌘N opens an empty Little Arc window; one left alone past its archive time goes to the Archive.
extension SnapshotRunner {
    func linkRoutingCheck() {
        var server: LocalPageServer?
        var base = ""
        var home = "", routed = "", routedProfile = ""
        var little: LittleArcController?
        var moved: EngineTab?
        var token = ""
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let state = "<title>state</title><input id=\"f\"><script>window.__token=Math.random().toString(36).slice(2)</script>"

        step { [self] done in
            server = LocalPageServer(responses: ["/state": .init(body: state), "/routed": .init(body: "<title>routed</title><p>Routed</p>")])
            server?.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                if base.isEmpty { self.check(false, "links: the loopback server starts") }
                done()
            }
        }
        step { [self] done in
            guard let app = c.app else { return done() }
            home = c.currentSpaceID
            do {
                let p = try c.profiles.createProfile(name: "Links Check", emoji: "", color: nil)
                routedProfile = p.id
                routed = try c.store.createSpace(name: "Routed", profileID: p.id).id
                c.reloadAll(animated: false)
                app.settings.values.linkRules = [LinkRule(match: .contains, pattern: "/routed", spaceID: routed)]
                app.settings.values.externalLinks = .littleArc
                c.profiles.whenLoaded(p.id, { _ in done() }, failed: { self.check(false, "links: the Routed profile loads"); done() })
            } catch {
                check(false, "links: a second profile and Space (\(error))")
                done()
            }
        }

        // 1. A rule routes the link to its Space, in that Space's profile.
        run { [self] in c.app?.application(NSApp, open: [URL(string: base + "/routed?from=mail")!]) }
        step { [self] done in
            let tab = { self.c.store.todayTabs(ofSpace: routed).first { $0.url.contains("/routed") } }
            waitUntil({ tab() != nil && self.c.currentSpaceID == routed }, timeout: 5) {
                let t = tab()
                let page = t.flatMap { self.c.engineTab(for: $0.id) }
                let profileOK = page != nil && page?.profile === self.c.profiles.engineProfile(for: routedProfile)
                self.check(t != nil && self.c.currentSpaceID == routed && self.c.shownTabID == t?.id && profileOK,
                           "links: a rule sends a link from another app to its Space (tab \(t != nil), Space shown \(self.c.currentSpaceID == routed)), "
                           + "loaded in that Space's profile (\(profileOK))")
                done()
            }
        }

        // 2. No rule: Little Arc, in the most recent Space's profile.
        run { [self] in
            c.switchToSpace(home, animated: false)
            c.app?.application(NSApp, open: [URL(string: base + "/state")!])
        }
        step { [self] done in
            waitUntil({ (self.c.app?.littleArcs.first?.page?.title ?? "") == "state" }, timeout: 8) {
                little = self.c.app?.littleArcs.first
                let homeProfile = self.c.store.space(home).flatMap { self.c.profiles.engineProfile(for: $0.profileID) }
                let ok = little != nil && little?.spaceID == home && little?.page?.profile === homeProfile && little?.window.isVisible == true
                self.check(ok && self.c.app?.littleArcs.count == 1,
                           "links: no rule: a Little Arc window in the most recent Space's profile (window \(little != nil), "
                           + "Space \(little?.spaceID == home), profile \(little?.page?.profile === homeProfile), page \"\(little?.page?.title ?? "-")\")")
                done()
            }
        }
        captureLittleArc({ little }, "little-arc")
        // Script state and typed text, which a reload would lose.
        step { [self] done in
            guard let page = little?.page else { return done() }
            page.evaluate("var f=document.getElementById('f');f.focus();f.value='kept by the move';window.__token") { v in
                token = v as? String ?? ""
                moved = page
                done()
            }
        }

        // 3. ⌘O: into the Space as a Today tab, the same live page.
        step { [self] done in
            guard let l = little else { return done() }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: l.window.windowNumber, context: nil, characters: "o", charactersIgnoringModifiers: "o",
                                            isARepeat: false, keyCode: 31) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            waitUntil({ self.c.app?.littleArcs.isEmpty == true }, timeout: 4) { done() }
        }
        step { [self] done in
            let tab = c.store.todayTabs(ofSpace: home).first { $0.url.contains("/state") }
            let page = tab.flatMap { c.engineTab(for: $0.id) }
            let shown = tab != nil && c.shownTabID == tab?.id && c.currentSpaceID == home
            let closed = c.app?.littleArcs.isEmpty == true && little?.window.isVisible != true
            guard chromium else {
                check(tab != nil && shown && closed, "links: ⌘O in Little Arc opens the page in the Space and closes the window "
                      + "(WebKit can't move a live page, so it loads again; tab \(tab != nil), shown \(shown), window closed \(closed))")
                return done()
            }
            guard let page else {
                check(false, "links: ⌘O in Little Arc: the page arrives in the Space (tab \(tab != nil), window closed \(closed))")
                return done()
            }
            page.evaluate("[window.__token, document.getElementById('f').value]") { v in
                let values = v as? [String] ?? []
                let same = page === moved
                self.check(same && values == [token, "kept by the move"] && shown && closed,
                           "links: ⌘O in Little Arc moves the same live page into the Space as a Today tab (same page \(same), "
                           + "script state and typed text kept \(values.first == token && values.last == "kept by the move"), shown \(shown), "
                           + "window closed \(closed))")
                done()
            }
        }
        capture("little-arc-moved")

        // 4. ⌥⌘N: an empty Little Arc window, its address field ready; ⌘W closes it.
        run { [self] in
            postKey("n", keyCode: 45, modifiers: [.command, .option])
        }
        step { [self] done in
            waitUntil({ self.c.app?.littleArcs.count == 1 }, timeout: 3) {
                let l = self.c.app?.littleArcs.first
                if l == nil, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.c.window.windowNumber,
                                                      context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45) {
                    let handled = NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
                    self.note("links: the posted ⌥⌘N didn't arrive (window key \(self.c.window.isKeyWindow)); sent it to the main menu (handled \(handled))")
                }
                self.waitUntil({ self.c.app?.littleArcs.count == 1 }, timeout: 2) {
                    let l = self.c.app?.littleArcs.first
                    self.check(l != nil && l?.page != nil && l?.window.isVisible == true,
                               "links: ⌥⌘N opens an empty Little Arc window (\(l != nil))")
                    l?.closeWindow()
                    self.waitUntil({ self.c.app?.littleArcs.isEmpty == true }, timeout: 3) { done() }
                }
            }
        }

        // 5. Left alone past its archive time (6 h; a second here), it goes to the Archive.
        var before = 0
        run { [self] in
            before = c.store.archivedEntries.count
            LittleArcController.archiveAfter = 1
            c.app?.openLittleArc(url: URL(string: base + "/routed?archive=1")!)
        }
        step { [self] done in
            waitUntil({ self.c.app?.littleArcs.isEmpty == true }, timeout: 6) {
                let entry = self.c.store.archivedEntries.first { $0.tab.url.contains("archive=1") }
                self.check(self.c.app?.littleArcs.isEmpty == true && entry?.reason == .auto && self.c.store.archivedEntries.count == before + 1,
                           "links: a Little Arc window left alone past its archive time goes to the Archive (\(entry?.reason.rawValue ?? "not archived"))")
                LittleArcController.archiveAfter = 6 * 3600
                server?.stop()
                done()
            }
        }
        // Settings → Links with the rule, rendered.
        step { [self] done in
            guard let app = c.app else { return done() }
            app.settings.values.linkRules.append(LinkRule(match: .equals, pattern: "https://calendar.example.com", spaceID: home))
            app.showSettings(page: .links)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                if let w = app.settingsWindow?.window, let v = w.contentView {
                    v.layoutSubtreeIfNeeded()
                    if let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: dir.appendingPathComponent("settings-links.png"))
                        note("wrote settings-links.png")
                    }
                    w.orderOut(nil)
                }
                done()
            }
        }
        // 6. The same through a real Apple event, and the Little Arc window as a person meets it (LittleArcLinkCheck.swift).
        littleArcAppleEventCheck()
    }

    /// A Little Arc window as the screen shows it: our views, and the page from the engine's snapshot.
    func captureLittleArc(_ controller: @escaping () -> LittleArcController?, _ name: String) {
        step { [self] done in
            guard let l = controller(), let page = l.page else { return done() }
            l.root.layoutSubtreeIfNeeded()
            let base = render(l.root.superview ?? l.root)
            let cardFrame = l.card.frame, size = l.root.bounds.size
            page.snapshot { img in
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                base?.draw(in: NSRect(origin: .zero, size: size))
                if let img {
                    let r = NSRect(x: cardFrame.minX, y: size.height - cardFrame.maxY, width: cardFrame.width, height: cardFrame.height)
                    NSBezierPath(roundedRect: r, xRadius: AircMetrics.Window.cardRadius, yRadius: AircMetrics.Window.cardRadius).addClip()
                    img.draw(in: r)
                }
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: self.dir.appendingPathComponent(name + ".png"))
                self.note("wrote \(name).png")
                done()
            }
        }
    }
}
#endif

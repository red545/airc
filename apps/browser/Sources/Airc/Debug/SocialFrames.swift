// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// `--script social`: frame sequences for the social studio's short videos (tools/social/). Not a check and not part of
/// the suite: tools/social/mac-frames.sh runs it, the way scripts/marketing-shots.sh runs `--script marketing`.
///
/// The marketing demo is seeded as for the shots (`AIRC_MARKETING_PART=social`, a part the marketing scenario has no
/// shots for, so it only prepares and seeds), then one motion (`AIRC_SOCIAL_MOTION`) is rendered frame by frame by the
/// app's own views: each frame's state is set from the motion's curve and drawn with `captureNow`, the window off
/// screen. Nothing is recorded from the screen, and no device is asked for. Each frame is `<motion>-NNNN.png` (2×);
/// `<motion>.json` lists them with how long each shows, the window's size and its traffic lights.
///   - swipe: Personal → Travel → Studio → Work (socialSpacesPages), three two-finger swipes. The finger's part is a
///     tracked position; at the lift the pager does what `SpacePagerView.track` does (the next Space's page shows) and
///     settles on its own spring (`AircSpring.settle`), sampled at 60 fps.
///   - capture: ⇧⌘2 on the demo trip page (MarketingCapture.swift): the dimmed page, a selection dragged open over its
///     hero card, then Copy, Save and Share under it.
/// More motions, one per feature, are in SocialMotions.swift (0.1.2's features), SocialMotions013.swift (0.1.3's) and
/// SocialNext.swift (no release yet). A build of a release's source leaves out the files of features after it
/// (tools/social/mac-frames.sh --rev), so those two are found through these protocols.
protocol Social013Motions {
    /// Queues `motion`'s steps if it's one of these; false if not.
    func social013Motion(_ motion: String) -> Bool
}

protocol SocialNextMotions {
    /// Queues `motion`'s steps if it's one of these; false if not.
    func socialNextMotion(_ motion: String) -> Bool
}

extension SnapshotRunner {
    func socialScenario() {
        let motion = ProcessInfo.processInfo.environment["AIRC_SOCIAL_MOTION"] ?? "swipe"
        marketingScenario()
        // The marketing scenario hands the appearance back to the Mac's at its end; the frames are light.
        run { NSApp.appearance = NSAppearance(named: .aqua) }
        // No "Sign in to Google" card in any frame: each fresh demo profile has it put away, as its Not now does.
        run { [self] in
            for s in c.store.orderedSpaces where c.showsSignInCard(space: s) { c.dismissSignInCard(spaceID: s.id) }
        }
        wait(0.3)
        let started = Date()
        switch motion {
        case "swipe": socialSwipe()
        case "capture": socialCapture()
        case "multiselect": socialMultiSelect()
        case "boosts": socialBoosts()
        case "commandbar": socialCommandBar()
        case "intro": socialIntro()
        case "import": socialImport()
        case "sidebarright": socialSidebarRight()
        case "private": socialPrivate()
        case "split": socialSplit()
        default:
            // Motions of features after the release a build is made from are in files its build leaves out.
            if (self as Any as? Social013Motions)?.social013Motion(motion) == true { break }
            if (self as Any as? SocialNextMotions)?.socialNextMotion(motion) != true { note("social: unknown motion \(motion)") }
        }
        run { [self] in note(String(format: "social: %@ done in %.0f s", motion, Date().timeIntervalSince(started))) }
    }

    /// The frames of one motion, in order, each with how long it shows.
    final class SocialReel {
        let name: String
        var frames: [[String: Any]] = []
        /// Set when the frames are of another window than the browser's (socialWindowFrame): its size in points, its
        /// traffic lights and its corner radius.
        var window: (size: NSSize, lights: [NSPoint], radius: CGFloat)?
        init(_ name: String) { self.name = name }
        var nextFile: String { String(format: "%@-%04d", name, frames.count + 1) }
    }

    /// The window as it is now, as the next frame, shown for `hold` seconds (one 60 fps frame unless said).
    func socialFrame(_ reel: SocialReel, hold: Double = 1.0 / 60, label: String = "") {
        step { [self] done in
            mkActiveLook(c.window)
            let file = reel.nextFile
            captureNow(file) { [self] in
                reel.frames.append(["file": file + ".png", "hold": hold, "dark": mkIsDark(), "label": label])
                done()
            }
        }
    }

    /// The window with Capture's overlay drawn over it (the overlay's layers, as MarketingCapture.swift draws them), and
    /// `extra` layers (window points, origin bottom left) with a panel's shadow: what a capture of the window can't take,
    /// such as a context menu drawn from the app's own items (MultiSelectShots.swift).
    func socialOverlayFrame(_ reel: SocialReel, hold: Double = 1.0 / 60, label: String = "",
                            extra: (() -> [(image: NSImage, rect: NSRect)])? = nil) {
        step { [self] done in
            mkWindowImage { [self] img in
                let file = reel.nextFile
                guard let img else { note("social: MISSING \(file): no capture"); return done() }
                let size = c.root.bounds.size
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: NSRect(origin: .zero, size: size))
                if let o = CaptureSession.active(in: c.window)?.overlay, let overlay = Self.mkOverlayImage(o) {
                    overlay.draw(in: o.convert(o.bounds, to: nil))
                }
                for layer in extra?() ?? [] {
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
                    shadow.shadowBlurRadius = 18
                    shadow.shadowOffset = NSSize(width: 0, height: -8)
                    shadow.set()
                    layer.image.draw(in: layer.rect)
                    NSGraphicsContext.restoreGraphicsState()
                }
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(file + ".png"))
                reel.frames.append(["file": file + ".png", "hold": hold, "dark": mkIsDark(), "label": label])
                done()
            }
        }
    }

    /// Another window than the browser's as the next frame (onboarding, a private window), drawn by its own views:
    /// `image` gives it and its size in points. The reel takes that window's size, its traffic lights (none with
    /// `lights: false`) and its corner radius.
    func socialWindowFrame(_ reel: SocialReel, _ window: @escaping () -> NSWindow?, hold: Double = 1.0 / 60, label: String = "",
                           dark: Bool = false, lights: Bool = true, radius: CGFloat = MarketingStudio.windowRadius,
                           image: @escaping (NSWindow, @escaping (NSImage?, NSSize) -> Void) -> Void) {
        step { [self] done in
            let file = reel.nextFile
            guard let w = window() else { note("social: MISSING \(file): no window"); return done() }
            mkActiveLook(w)
            image(w) { [self] img, size in
                guard let img, size.width > 0 else { note("social: MISSING \(file): no capture"); return done() }
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: NSRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(file + ".png"))
                if reel.window == nil { reel.window = (size, lights ? mkLights(w) : [], radius) }
                reel.frames.append(["file": file + ".png", "hold": hold, "dark": dark, "label": label])
                done()
            }
        }
    }

    func socialWrite(_ reel: SocialReel) {
        run { [self] in
            let size = reel.window?.size ?? c.root.bounds.size
            var manifest: [String: Any] = [
                "motion": reel.name, "fps": 60, "scale": 2, "width": Double(size.width), "height": Double(size.height),
                "lights": (reel.window?.lights ?? mkLights(c.window)).map { [Double($0.x), Double($0.y)] }, "frames": reel.frames,
            ]
            if let r = reel.window?.radius { manifest["radius"] = Double(r) }
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent(reel.name + ".json"))
            }
            note("social: \(reel.name) \(reel.frames.count) frames")
        }
    }

    /// The demo pages' server again (the marketing scenario stops it at its end), for motions on our own pages.
    final class SocialBox<T> { var value: T?; init() {} }
    func socialServer() -> SocialBox<MarketingServer> {
        let box = SocialBox<MarketingServer>()
        step { [self] done in
            let port = UInt16(ProcessInfo.processInfo.environment["AIRC_MARKETING_PORT"] ?? "") ?? 0
            guard port > 0, let s = MarketingServer(port: port) else { note("social: MISSING demo pages: no AIRC_MARKETING_PORT"); return done() }
            box.value = s
            s.start { ok in
                if !ok { self.note("social: MISSING demo pages: their server didn't start") }
                done()
            }
        }
        return box
    }

    // MARK: Spaces

    /// The Spaces' pages for the swipe and the intro, in the pager's order: public pages that read at a glance logged out,
    /// with nobody's face or name and no product's logo up front (Wikipedia's articles), and Work on the demo's own
    /// shared folder (its server). The demo's tabs where it has them, else opened as Today tabs.
    static let socialSpacesPages: [(space: String, url: String, title: String)] = [
        ("Personal", "https://en.wikipedia.org/wiki/Kyoto", "Kyoto – Wikipedia"),
        ("Travel", "https://en.wikipedia.org/wiki/Lisbon", "Lisbon – Wikipedia"),
        ("Studio", "https://en.wikipedia.org/wiki/Color_theory", "Color theory – Wikipedia"),
        ("Work", MarketingDemo.site("files", "/shared"), "Launch assets – Shared folder"),
    ]

    /// Each Space's page (socialSpacesPages) loaded and settled, the last first, so the pager ends on the first with its
    /// page shown. The demo pages' server runs until the caller stops it.
    func socialSpacesReady() -> SocialBox<MarketingServer> {
        let server = socialServer()
        for p in Self.socialSpacesPages.reversed() {
            run { [self] in
                guard let s = socialSpace(p.space) else { return note("social: MISSING Space \(p.space)") }
                c.switchToSpace(s, animated: false)
                var id = c.store.todayTabs(ofSpace: s).first { $0.url == p.url }?.id
                if id == nil {
                    id = (try? c.store.openTab(url: p.url, inSpace: s, activate: false, title: p.title))?.id
                    c.reloadAll(animated: false)
                }
                if let id { c.show(id, focus: false) } else { note("social: MISSING \(p.space) page \(p.url)") }
            }
            mkSettleShown(timeout: 20, extra: 2.0)
        }
        return server
    }

    private func socialSwipe() {
        let reel = SocialReel("swipe")
        let server = socialSpacesReady()
        let names = Self.socialSpacesPages.map { $0.space }
        socialFrame(reel, hold: 1.4, label: names[0])
        for i in 0..<(names.count - 1) {
            socialSwipeStep(reel, from: i)
            socialFrame(reel, hold: 1.2, label: names[i + 1])
        }
        socialWrite(reel)
        run { server.value?.stop() }
    }

    /// One swipe from page `page` to the next: the finger's 0.2 s (0.38 of a page, speeding up as a trackpad reports it),
    /// the lift, and the settle on the pager's spring with the finger's speed.
    func socialSwipeStep(_ reel: SocialReel, from page: Int, label: String = "") {
        let fps = 60.0, reach = 0.38, lift = 0.2
        let tracked = Int((lift * fps).rounded())
        run { [self] in c.pagerDidBeginTracking() }
        for k in 1...tracked {
            run { [self] in c.sidebar.pager.apply(Double(page) + reach * pow(Double(k) / Double(tracked), 1.5)) }
            socialFrame(reel, label: label)
        }
        // SpacePagerView.track at the lift: the target's page shows now, while the spring settles.
        run { [self] in c.pagerWillSettle(on: page + 1) }
        wait(0.6)   // the new page paints before its first snapshot
        let spring = Spring(AircSpring.settle)
        let x0 = Double(page) + reach - Double(page + 1), v0 = 1.5 * reach / lift
        var t = 1.0 / fps
        while t < 2 {
            let s = spring.state(at: t, x0: x0, v0: v0)
            if abs(s.x) < 0.0005 && abs(s.v) < 0.01 { break }   // FrameAnimator.spring's own end
            run { [self] in c.sidebar.pager.apply(Double(page + 1) + s.x) }
            socialFrame(reel, label: label)
            t += 1.0 / fps
        }
        run { [self] in
            c.sidebar.pager.go(to: page + 1, animated: false)
            c.pagerDidSettle(on: page + 1)
        }
    }

    // MARK: Capture

    private func socialCapture() {
        let reel = SocialReel("capture")
        var tabID = ""
        let server = socialServer()
        run { [self] in
            guard let personal = c.store.orderedSpaces.first(where: { $0.name == "Personal" }) else { return }
            c.switchToSpace(personal.id, animated: false)
            tabID = (try? c.store.openTab(url: MarketingDemo.site("trips", "/lisbon"), inSpace: personal.id, title: "Lisbon, four days"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(tabID, focus: false)
        }
        mkSettleShown()
        socialOverlayFrame(reel, hold: 1.0, label: "page")
        run { [self] in c.startCapture() }
        step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
        wait(0.5)
        socialOverlayFrame(reel, hold: 0.9, label: "dimmed")
        // The hero card, with room under it for the bar, as the still shot selects it.
        var card = CGRect.zero
        step { [self] done in
            guard let s = CaptureSession.active(in: c.window), let page = s.shots.first else {
                note("social: MISSING capture: Capture didn't start")
                return done()
            }
            s.tab(page.tab, evaluate: "(function(){var r=document.querySelectorAll('.card')[0].getBoundingClientRect();return [r.left,r.top,r.width,r.height]})()") { box in
                let o = s.overlay
                let fallback = CGRect(x: page.frame.minX + 50, y: page.frame.minY + 150, width: page.frame.width * 0.5, height: 400)
                card = (box.flatMap { CaptureGeometry.elementRect(css: $0, in: page.frame, zoom: page.tab.zoomFactor, bounds: o.bounds) } ?? fallback)
                    .insetBy(dx: -14, dy: -14).integral
                done()
            }
        }
        // Dragged open from its top-left corner (the overlay is flipped) over 0.7 s, easing out as a hand slows.
        let dragFrames = 42
        for k in 1...dragFrames {
            run { [self] in
                guard let o = CaptureSession.active(in: c.window)?.overlay, card.width > 0 else { return }
                let p = Double(k) / Double(dragFrames)
                let e = CGFloat(1 - pow(1 - p, 3))
                o.selection = CGRect(x: card.minX, y: card.minY, width: max(1, card.width * e), height: max(1, card.height * e)).integral
                o.update()
            }
            socialOverlayFrame(reel, hold: k == dragFrames ? 0.35 : 1.0 / 60)
        }
        run { [self] in CaptureSession.active(in: c.window)?.confirm() }
        wait(0.4)
        socialOverlayFrame(reel, hold: 2.2, label: "confirmed")
        socialWrite(reel)
        run { [self] in
            CaptureSession.active(in: c.window)?.cancel()
            if !tabID.isEmpty { c.closeTab(tabID) }
            server.value?.stop()
        }
        wait(0.4)
    }
}
#endif

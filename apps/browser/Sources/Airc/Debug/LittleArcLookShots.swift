// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script littlearc-look`: Little Arc windows drawn by the app's own view rendering (never a screen capture), for the
/// design pass: a light and a dark Space theme; at rest, with the pointer on the Open in part and on the chevron,
/// pressed, loading, and a narrow window. Writes `littlearc-look-<theme>-<state>.png`. A synthetic page of our own
/// (recipes.aircbrowser.com with build-app.sh's host rule, else the loopback address); no network, nobody's data.
extension SnapshotRunner {
    static let littleArcLookPage = """
        <!doctype html><html><head><meta charset=utf-8><title>Pastel de nata – Weekend Recipes</title>
        <link rel=icon href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%23E8743B'/%3E%3Ccircle cx='16' cy='16' r='8' fill='%23FFD27A'/%3E%3C/svg%3E">
        <style>
        body{margin:0;font:16px/1.55 -apple-system,system-ui,sans-serif;color:#2b2622;background:#fffdf9}
        header{display:flex;align-items:center;gap:10px;padding:18px 36px;border-bottom:1px solid #eee4d8;font-weight:600}
        header i{width:22px;height:22px;border-radius:6px;background:#E8743B;display:inline-block}
        main{max-width:640px;margin:0 auto;padding:28px 36px}
        h1{font:700 34px/1.15 ui-serif,Georgia,serif;margin:6px 0 10px}
        .meta{color:#8a7d70;font-size:14px}
        .hero{height:190px;border-radius:14px;margin:22px 0;background:radial-gradient(circle at 30% 40%,#ffd27a 0 18%,#e8a04b 19% 30%,transparent 31%),radial-gradient(circle at 68% 58%,#ffd27a 0 16%,#d9852f 17% 28%,transparent 29%),linear-gradient(135deg,#f6e3c9,#efc9a0)}
        </style></head><body>
        <header><i></i>Weekend Recipes</header>
        <main><div class=meta>Baking · 45 minutes</div><h1>Pastel de nata</h1>
        <p>Crisp, flaky pastry around a just-set custard, blistered on top in a very hot oven. The secret is patience with
        the dough and a little more heat than seems reasonable.</p><div class=hero></div>
        <p>Roll the pastry into a tight log, slice it into rounds and press each one into the tin with a wet thumb.</p></main>
        SLOW</body></html>
        """

    func littleArcLookScenario() {
        var server: LocalPageServer?
        var base = ""
        var spaces: [(name: String, id: String)] = []
        step { [self] done in
            let slow = LocalPageServer.Page(headers: ["Content-Type": "image/png"], body: "", delay: 30)
            server = LocalPageServer(responses: [
                "/nata": .init(body: Self.littleArcLookPage.replacingOccurrences(of: "SLOW", with: "")),
                "/loading": .init(body: Self.littleArcLookPage.replacingOccurrences(of: "SLOW", with: "<img src=/slow.png width=1 height=1>")),
                "/slow.png": slow,
            ])
            server?.start { port in
                let chromium = self.app?.engine.name.hasPrefix("Chromium") == true
                base = port.map { "http://\(chromium ? "recipes.aircbrowser.com" : "127.0.0.1"):\($0)" } ?? ""
                done()
            }
        }
        run { [self] in
            let pid = c.store.selectedSpace.profileID
            // A light and a dark Space theme (Arc's Green on auto, Purple forced dark).
            for (name, theme) in [("Recipes", SpaceTheme(colors: [RGBA(hex: "73E49B")!])),
                                  ("Evening", SpaceTheme(colors: [RGBA(hex: "9E749B")!], appearance: .dark))] {
                if let s = try? c.store.createSpace(name: name, icon: .emoji(name == "Recipes" ? "🥐" : "🌙"), theme: theme, profileID: pid) {
                    spaces.append((name == "Recipes" ? "light" : "dark", s.id))
                }
            }
            c.reloadAll(animated: false)
            if base.isEmpty { check(false, "littlearc-look: the loopback server starts") }
        }
        for i in 0..<2 {
            var little: LittleArcController?
            step { [self] done in
                guard i < spaces.count, !base.isEmpty else { return done() }
                little = app?.openLittleArc(url: URL(string: base + "/nata"), spaceID: spaces[i].id)
                waitUntil({ little?.page?.isLoading == false && little?.page?.title.isEmpty == false }, timeout: 10) {
                    // The favicon comes a moment after the load.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
                }
            }
            lookShot({ little }, { "\(spaces[i].name)-rest" })
            lookState({ little }, hover: .open)
            lookShot({ little }, { "\(spaces[i].name)-hover-open" })
            lookState({ little }, hover: .chevron)
            lookShot({ little }, { "\(spaces[i].name)-hover-chevron" })
            lookState({ little }, pressed: true)
            lookShot({ little }, { "\(spaces[i].name)-pressed" })
            lookState({ little }, pressed: false)
            // Loading: a page whose last image takes 30 s.
            run { little?.page?.load(URL(string: base + "/loading")!) }
            wait(1.2)
            lookShot({ little }, { "\(spaces[i].name)-loading" })
            run { [self] in
                let n = (little?.page?.isLoading == true, little?.page?.progress ?? -1)
                note("littlearc-look \(i < spaces.count ? spaces[i].name : "-"): loading \(n.0), progress \(String(format: "%.2f", n.1))")
                if let l = little { note("littlearc-look: loading line hidden \(l.progress.isHidden), frame \(l.progress.frame), in the row \(l.progress.superlayer === l.bar.layer), flipped \(l.bar.layer?.contentsAreFlipped() ?? false)") }
                little?.page?.stop()
            }
            // Narrow: 460 pt wide.
            run {
                guard let w = little?.window else { return }
                w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: 460, height: w.frame.height), display: true)
            }
            wait(0.4)
            lookShot({ little }, { "\(spaces[i].name)-narrow" })
            closeLittleArcs()
        }
        run { server?.stop() }
    }

    private enum LookPart { case open, chevron }

    /// The pointer on a part of the chip, as its tracking area tells it (posted moves never reach tracking areas).
    private func lookState(_ little: @escaping () -> LittleArcController?, hover part: LookPart) {
        run {
            guard let l = little() else { return }
            let chip = l.chip as NSView
            let x = part == .open ? chip.bounds.minX + 12 : chip.bounds.maxX - 8
            let p = chip.convert(NSPoint(x: x, y: chip.bounds.midY), to: nil)
            if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: l.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                chip.mouseEntered(with: e)
            }
        }
        wait(0.1)
    }

    /// The Open in part held down (then let go outside it, so nothing happens). Only the new chip has the state: the
    /// old one opened its menu on a press.
    private func lookState(_ little: @escaping () -> LittleArcController?, pressed: Bool) {
        run {
            guard let l = little() else { return }
            let chip = l.chip as NSView
            guard String(describing: type(of: chip)).contains("OpenChip") else { return }
            let p = chip.convert(NSPoint(x: pressed ? chip.bounds.minX + 12 : chip.bounds.minX - 200, y: chip.bounds.midY), to: nil)
            if let e = NSEvent.mouseEvent(with: pressed ? .leftMouseDown : .leftMouseUp, location: p, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: l.window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: pressed ? 1 : 0) {
                if pressed { chip.mouseDown(with: e) } else { chip.mouseUp(with: e) }
            }
            if !pressed, let e = NSEvent.enterExitEvent(with: .mouseExited, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: l.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                chip.mouseExited(with: e)
            }
        }
        wait(0.1)
    }

    /// The window on the marketing desktop (MarketingStudio: macOS's corner, shadow and coloured lights), at 2×.
    private func lookShot(_ little: @escaping () -> LittleArcController?, _ name: @escaping () -> String) {
        step { [self] done in
            guard let l = little() else { note("littlearc-look: MISSING \(name()): no window"); return done() }
            mkActiveLook(l.window)
            mkLittleArcImage(l) { img in
                guard let img else { self.note("littlearc-look: MISSING \(name()): no image"); return done() }
                let (canvas, origin) = MarketingStudio.canvas(around: img.size)
                let dark = l.palette.isDark
                let layer = MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: img.size), dark: dark, lights: self.mkLights(l.window))
                let file = self.dir.appendingPathComponent("littlearc-look-\(name()).png")
                let ok = MarketingStudio.write(MarketingStudio.render(canvas: canvas, dark: dark, layers: [layer]), to: file)
                self.note(ok ? "wrote \(file.lastPathComponent) (\(Int(img.size.width))×\(Int(img.size.height)))" : "littlearc-look: MISSING \(name())")
                done()
            }
        }
    }
}
#endif

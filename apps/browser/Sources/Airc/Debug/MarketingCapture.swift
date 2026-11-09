// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// The marketing shot of Capture (CB-5), the marketing scenario's part "capture" (`scripts/marketing-shots.sh --parts
/// capture`):
///   - capture: Personal on a synthetic trip-planning page of our own (MarketingServer's trips.aircbrowser.com/lisbon,
///     no site's content), the page dimmed around its hero card and the Copy, Save and Share bar under it.
///   - capture-full-page: Capture Full Page of a long synthetic itinerary (trips.aircbrowser.com/lisbon/days, four days
///     of cards): the whole page shown scaled to fit over the dimmed card, its size above it, Copy, Save and Share under.
///   - capture-portrait: Capture in Portrait Mode of the trip page: framed on Arc's cyan gradient with Airc's mark,
///     its controls (website colour, the colour slider, the desktop picture, the mark) and Copy, Save and Share under it.
///     The choices go to a preferences suite of the run's own; the desktop picture isn't picked (never read).
/// The overlay is drawn from its own layers over the window picture (the page card's pixels come from the engine).
extension SnapshotRunner {
    static let mkCapturePage = """
    <!doctype html><title>Lisbon, four days</title><style>
    body{margin:0;font:16px -apple-system,system-ui,sans-serif;color:#1d2a33;background:#f6f1ea}
    header{padding:56px 64px 28px}h1{font:700 44px ui-rounded,-apple-system,sans-serif;margin:0 0 8px;letter-spacing:-.6px}
    header p{margin:0;color:#6b747a;font-size:18px}
    main{display:grid;grid-template-columns:1.25fr 1fr;gap:24px;padding:0 64px 64px}
    .card{background:#fff;border-radius:18px;padding:24px 26px;box-shadow:0 1px 2px rgba(0,0,0,.06),0 8px 24px rgba(0,0,0,.06)}
    .hero{grid-row:span 2;padding:0;overflow:hidden}
    .sky{height:300px;background:linear-gradient(160deg,#ffb88c 0%,#f7797d 45%,#6a5acd 100%);position:relative}
    .sun{position:absolute;left:62%;top:46%;width:120px;height:120px;border-radius:50%;background:#ffe29f;box-shadow:0 0 80px #ffd27f}
    .roofs{position:absolute;bottom:0;left:0;right:0;height:120px;background:
      linear-gradient(90deg,#c0533b 0 12%,#d9714e 12% 22%,#b84a36 22% 37%,#e08a5a 37% 49%,#c45a40 49% 63%,#d36b4a 63% 78%,#b64634 78% 100%);
      clip-path:polygon(0 40%,6% 20%,12% 40%,18% 10%,24% 38%,31% 22%,37% 42%,44% 15%,50% 40%,57% 25%,63% 45%,70% 12%,77% 38%,84% 20%,90% 42%,96% 18%,100% 35%,100% 100%,0 100%)}
    .hero .body{padding:22px 26px}h2{margin:0 0 6px;font-size:22px}.muted{color:#6b747a}
    .days{display:flex;gap:10px;margin-top:16px}.day{flex:1;border-radius:12px;padding:12px;background:#f3ede6;font-size:14px}
    .day b{display:block;font-size:13px;color:#c0533b;margin-bottom:4px}
    .bars{display:flex;align-items:flex-end;gap:12px;height:140px;margin-top:18px}
    .bar{flex:1;border-radius:8px 8px 4px 4px;background:linear-gradient(#7aa7ff,#4f6df5)}
    .labels{display:flex;gap:12px;margin-top:8px;font-size:12px;color:#6b747a}.labels span{flex:1;text-align:center}
    ul{margin:14px 0 0;padding:0;list-style:none}li{display:flex;justify-content:space-between;padding:10px 0;border-top:1px solid #eee8e1}
    </style>
    <header><h1>Lisbon, four days</h1><p>Trams, tiles and the long light over the Tagus</p></header>
    <main>
    <section class="card hero"><div class="sky"><div class="sun"></div><div class="roofs"></div></div>
    <div class="body"><h2>Alfama at golden hour</h2><div class="muted">Miradouro de Santa Luzia, 18:40</div>
    <div class="days"><div class="day"><b>Thu</b>Belém and the river</div><div class="day"><b>Fri</b>Alfama, tram 28</div>
    <div class="day"><b>Sat</b>Sintra by train</div><div class="day"><b>Sun</b>LX Factory</div></div></div></section>
    <section class="card"><h2>Sunshine</h2><div class="muted">Hours a day, this week</div>
    <div class="bars"><div class="bar" style="height:62%"></div><div class="bar" style="height:78%"></div><div class="bar" style="height:90%"></div>
    <div class="bar" style="height:70%"></div><div class="bar" style="height:84%"></div></div>
    <div class="labels"><span>Wed</span><span>Thu</span><span>Fri</span><span>Sat</span><span>Sun</span></div></section>
    <section class="card"><h2>Packing</h2><ul><li>Walking shoes<span class="muted">✓</span></li><li>Linen shirt<span class="muted">✓</span></li>
    <li>Sunglasses<span class="muted">—</span></li></ul></section>
    </main>
    """

    /// A long page of our own for Capture Full Page: the trip day by day.
    static let mkCaptureDaysPage: String = {
        let days: [(String, String, String, [(String, String)])] = [
            ("Thursday", "Belém and the river", "linear-gradient(160deg,#8fd3f4 0%,#84fab0 100%)",
             [("09:30", "Jerónimos Monastery"), ("11:00", "Pastéis de Belém, the original"), ("13:00", "Lunch by the water"), ("16:00", "Belém Tower at low tide")]),
            ("Friday", "Alfama and tram 28", "linear-gradient(160deg,#ffb88c 0%,#f7797d 50%,#6a5acd 100%)",
             [("08:45", "Tram 28 from Martim Moniz"), ("10:30", "Sé Cathedral"), ("12:30", "Grilled sardines, Rua de São Pedro"), ("18:40", "Golden hour at Santa Luzia")]),
            ("Saturday", "Sintra by train", "linear-gradient(160deg,#a8e063 0%,#56ab2f 100%)",
             [("09:11", "Train from Rossio"), ("10:30", "Pena Palace"), ("13:30", "Travesseiros at Piriquita"), ("15:00", "Quinta da Regaleira")]),
            ("Sunday", "LX Factory and the bridge", "linear-gradient(160deg,#c3cfe2 0%,#7f8cff 100%)",
             [("10:00", "Brunch at LX Factory"), ("12:00", "Ler Devagar bookshop"), ("15:30", "Walk under the 25 de Abril bridge"), ("20:00", "Fado in Mouraria")]),
        ]
        var html = """
        <!doctype html><title>Lisbon, day by day</title><style>
        body{margin:0;font:16px -apple-system,system-ui,sans-serif;color:#1d2a33;background:#f6f1ea}
        header{padding:56px 64px 20px}h1{font:700 44px ui-rounded,-apple-system,sans-serif;margin:0 0 8px;letter-spacing:-.6px}
        header p{margin:0;color:#6b747a;font-size:18px}main{padding:8px 64px 72px;display:grid;gap:28px}
        .day{background:#fff;border-radius:18px;overflow:hidden;box-shadow:0 1px 2px rgba(0,0,0,.06),0 8px 24px rgba(0,0,0,.06)}
        .art{height:220px}.body{padding:22px 28px 10px}h2{margin:0 0 4px;font-size:24px}.muted{color:#6b747a}
        ul{margin:14px 0 8px;padding:0;list-style:none}li{display:flex;gap:18px;padding:12px 0;border-top:1px solid #eee8e1}
        li b{width:56px;color:#c0533b;font-weight:600}
        </style><header><h1>Lisbon, day by day</h1><p>Four days of trams, tiles and long light</p></header><main>
        """
        for (day, title, art, stops) in days {
            html += "<section class=day><div class=art style=\"background:\(art)\"></div><div class=body><h2>\(day)</h2><div class=muted>\(title)</div><ul>"
            for (time, what) in stops { html += "<li><b>\(time)</b>\(what)</li>" }
            html += "</ul></div></section>"
        }
        return html + "</main>"
    }()

    func mkCaptureShots(_ d: MarketingDemo) {
        var tabID = ""
        mkShow(d, "personal", nil)
        run { [self] in
            let url = MarketingDemo.site("trips", "/lisbon")
            tabID = (try? c.store.openTab(url: url, inSpace: c.currentSpaceID, title: "Lisbon, four days"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(tabID, focus: false)
        }
        mkSettleShown()
        run { [self] in c.startCapture() }
        step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
        // The hero card (the left column), with room under it for the bar.
        step { [self] done in
            guard let s = CaptureSession.active(in: c.window), let page = s.shots.first else {
                note("marketing: MISSING capture: Capture didn't start")
                return done()
            }
            s.tab(page.tab, evaluate: "(function(){var r=document.querySelectorAll('.card')[0].getBoundingClientRect();return [r.left,r.top,r.width,r.height]})()") { box in
                let o = s.overlay
                let fallback = CGRect(x: page.frame.minX + 50, y: page.frame.minY + 150, width: page.frame.width * 0.5, height: 400)
                let card = box.flatMap { CaptureGeometry.elementRect(css: $0, in: page.frame, zoom: page.tab.zoomFactor, bounds: o.bounds) } ?? fallback
                o.selection = card.insetBy(dx: -14, dy: -14).integral
                o.update()
                s.confirm()
                done()
            }
        }
        wait(0.4)
        mkWindowShot("capture") { [self] frame in
            guard let o = CaptureSession.active(in: c.window)?.overlay, let image = Self.mkOverlayImage(o) else { return [] }
            let r = o.convert(o.bounds, to: nil)
            return [MarketingStudio.Layer(image: image, frame: NSRect(x: frame.minX + r.minX, y: frame.minY + r.minY, width: r.width, height: r.height),
                                          radius: AircMetrics.Window.cardRadius, dark: mkIsDark())]
        }
        run { [self] in
            CaptureSession.active(in: c.window)?.cancel()
            if !tabID.isEmpty { c.closeTab(tabID) }
        }
        wait(0.4)

        // Capture Full Page of the trip day by day.
        var daysTab = ""
        run { [self] in
            MarketingServer.extraPages["/lisbon/days"] = Self.mkCaptureDaysPage
            daysTab = (try? c.store.openTab(url: MarketingDemo.site("trips", "/lisbon/days"), inSpace: c.currentSpaceID, title: "Lisbon, day by day"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(daysTab, focus: false)
        }
        mkSettleShown()
        run { [self] in c.startCapture(fullPage: true) }
        step { [self] done in
            waitUntil({ CaptureSession.active(in: self.c.window).map { $0.picturesReady && $0.phase != .capturing } ?? true }, timeout: 40) { done() }
        }
        run { [self] in
            if CaptureSession.active(in: c.window)?.fullPagePicture == nil { note("marketing: MISSING capture-full-page: no full page picture") }
        }
        wait(0.4)
        mkWindowShot("capture-full-page") { [self] frame in
            guard let o = CaptureSession.active(in: c.window)?.overlay, let image = Self.mkOverlayImage(o) else { return [] }
            let r = o.convert(o.bounds, to: nil)
            return [MarketingStudio.Layer(image: image, frame: NSRect(x: frame.minX + r.minX, y: frame.minY + r.minY, width: r.width, height: r.height),
                                          radius: AircMetrics.Window.cardRadius, dark: mkIsDark())]
        }
        run { [self] in
            CaptureSession.active(in: c.window)?.cancel()
            MarketingServer.extraPages["/lisbon/days"] = nil
            if !daysTab.isEmpty { c.closeTab(daysTab) }
        }
        wait(0.4)

        // Capture in Portrait Mode of the trip page, in Arc's default cyan.
        let suite = "org.airc.marketing.portrait.\(getpid())"
        run { [self] in
            UserDefaults().removePersistentDomain(forName: suite)
            PortraitStyle.storage = { UserDefaults(suiteName: suite)! }
            tabID = (try? c.store.openTab(url: MarketingDemo.site("trips", "/lisbon"), inSpace: c.currentSpaceID, title: "Lisbon, four days"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(tabID, focus: false)
        }
        mkSettleShown()
        run { [self] in c.startCapture(portrait: true) }
        step { [self] done in
            waitUntil({ CaptureSession.active(in: self.c.window).map { $0.picturesReady && $0.portrait != nil } ?? true }, timeout: 20) { done() }
        }
        run { [self] in
            if CaptureSession.active(in: c.window)?.portrait == nil { note("marketing: MISSING capture-portrait: no portrait") }
        }
        wait(0.4)
        mkWindowShot("capture-portrait") { [self] frame in
            guard let o = CaptureSession.active(in: c.window)?.overlay, let image = Self.mkOverlayImage(o) else { return [] }
            let r = o.convert(o.bounds, to: nil)
            return [MarketingStudio.Layer(image: image, frame: NSRect(x: frame.minX + r.minX, y: frame.minY + r.minY, width: r.width, height: r.height),
                                          radius: AircMetrics.Window.cardRadius, dark: mkIsDark())]
        }
        run { [self] in
            CaptureSession.active(in: c.window)?.cancel()
            UserDefaults().removePersistentDomain(forName: suite)
            PortraitStyle.storage = { .standard }
            if !tabID.isEmpty { c.closeTab(tabID) }
        }
        wait(0.4)
    }

    /// The overlay's layers (the still page, the dim, the selection and its bar) as a 2× image.
    static func mkOverlayImage(_ o: CaptureOverlayView) -> NSImage? {
        guard let layer = o.layer else { return nil }
        o.layoutSubtreeIfNeeded()
        let size = o.bounds.size, s: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width * s), height: Int(size.height * s), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        MainActor.assumeIsolated { AircSnapshot.withoutDuplicates(in: o) { layer.render(in: ctx) } }
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: size)
    }
}

extension CaptureSession {
    /// A page script's [left, top, width, height] as a CSS rect (the marketing shot finds its card with it).
    func tab(_ tab: EngineTab, evaluate script: String, _ done: @escaping (CGRect?) -> Void) {
        tab.evaluate(script) { value in
            guard let a = (value as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), a.count == 4 else { return done(nil) }
            done(CGRect(x: a[0], y: a[1], width: a[2], height: a[3]))
        }
    }
}
#endif

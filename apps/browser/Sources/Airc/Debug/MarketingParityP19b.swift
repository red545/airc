// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircKit
import AppKit

/// P19b's shot, `--script marketing` part `parityp19b`:
///   - easel-live: Travel with an Easel "Getting there": two live Captures (a flight's status card and the week's
///     forecast, synthetic pages of ours at flights.aircbrowser.com and weather.aircbrowser.com) taken with Capture's
///     Add to Easel, refreshed, each with its Live chip, beside a heading and a note. Fixture content only.
extension SnapshotRunner {
    static let mkFlightPage = """
    <!doctype html><title>TP 1351 · Flight status</title><style>
    body{margin:0;font:16px -apple-system,system-ui;background:#eef2f7;color:#14213d}
    header{background:#14213d;color:#fff;padding:18px 40px;font-weight:600;letter-spacing:.02em}
    .card{position:absolute;left:40px;top:96px;width:520px;height:250px;background:#fff;border-radius:18px;box-shadow:0 8px 30px rgba(20,33,61,.12);padding:28px 32px;box-sizing:border-box}
    .row{display:flex;justify-content:space-between;align-items:baseline}.code{font-size:15px;color:#6b7a99}.big{font-size:44px;font-weight:700}
    .status{display:inline-block;margin-top:18px;background:#d8f5e3;color:#11733f;font-weight:700;padding:6px 14px;border-radius:999px}
    .meta{margin-top:22px;display:flex;gap:44px;color:#6b7a99;font-size:14px}.meta b{display:block;color:#14213d;font-size:22px;margin-top:4px}
    </style><header>Departures</header><div class=card>
    <div class=row><div><div class=code>BER → LIS</div><div class=big>TP 1351</div></div><div style="text-align:right"><div class=code>Departs</div><div class=big>09:40</div></div></div>
    <div class=status>● On time</div><div class=meta><div>Terminal<b>1</b></div><div>Gate<b>A14</b></div><div>Boarding<b>09:05</b></div><div>Seat<b>12A</b></div></div></div>
    """

    static let mkForecastPage = """
    <!doctype html><title>Lisbon · 7-day forecast</title><style>
    body{margin:0;font:16px -apple-system,system-ui;background:linear-gradient(180deg,#ffe8c7,#fff7ec 60%);color:#3a2a14}
    h1{margin:0;padding:24px 40px 0;font-size:20px;font-weight:600;color:#8a5a1f}
    .card{position:absolute;left:40px;top:76px;width:620px;height:210px;background:rgba(255,255,255,.75);border-radius:18px;padding:24px;box-sizing:border-box;display:flex;gap:10px}
    .d{flex:1;text-align:center;border-radius:12px;padding:12px 0}.d:first-child{background:#ffd79a}.n{font-size:13px;color:#8a6a3f;font-weight:600}
    .i{font-size:34px;margin:10px 0}.t{font-size:22px;font-weight:700}.l{font-size:14px;color:#a08a6a}
    </style><h1>Lisbon this week</h1><div class=card>
    <div class=d><div class=n>Fri</div><div class=i>☀️</div><div class=t>21°</div><div class=l>13°</div></div>
    <div class=d><div class=n>Sat</div><div class=i>☀️</div><div class=t>22°</div><div class=l>14°</div></div>
    <div class=d><div class=n>Sun</div><div class=i>⛅️</div><div class=t>19°</div><div class=l>13°</div></div>
    <div class=d><div class=n>Mon</div><div class=i>🌦</div><div class=t>17°</div><div class=l>12°</div></div>
    <div class=d><div class=n>Tue</div><div class=i>☀️</div><div class=t>20°</div><div class=l>13°</div></div></div>
    """

    func mkParityP19bShots(_ d: MarketingDemo) {
        var easelID = ""
        var tabs: [String] = []
        MarketingServer.extraPages["/tp1351"] = Self.mkFlightPage
        MarketingServer.extraPages["/lisbon-week"] = Self.mkForecastPage
        mkShow(d, "travel", nil)
        run { [self] in
            easelID = newID()
            try? EaselCenter.shared.files.save(EaselDocument(id: easelID, title: "Getting there"))
            _ = try? c.store.createEasel(easelID, inSpace: c.currentSpaceID, title: "Getting there")
            CaptureSession.addsLive = true
        }
        /// One live Capture of the page's card (CSS `x, y, w, h`).
        func liveCapture(_ url: String, _ title: String, _ r: (Double, Double, Double, Double)) {
            run { [self] in
                guard let t = try? c.store.openTab(url: url, inSpace: c.currentSpaceID, title: title) else { return }
                tabs.append(t.id)
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            mkSettleShown()
            run { [self] in c.startCapture() }
            step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
            run { [self] in
                guard let s = CaptureSession.active(in: c.window), let tab = tabs.last.flatMap({ c.engineTab(for: $0) }) else {
                    return note("marketing: MISSING easel-live: Capture didn't start on \(title)")
                }
                let v = tab.view, z = CGFloat(tab.zoomFactor)
                func p(_ x: Double, _ y: Double) -> NSPoint {
                    let py = CGFloat(y) * z
                    return NSPoint(x: CGFloat(x) * z, y: v.isFlipped ? py : v.bounds.height - py)
                }
                let a = s.overlay.convert(p(r.0, r.1), from: v), b = s.overlay.convert(p(r.0 + r.2, r.1 + r.3), from: v)
                s.overlay.selection = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                if s.addToEasel(easelID) == nil { note("marketing: MISSING easel-live: Add to Easel refused on \(title)") }
            }
            wait(1.0)
        }
        liveCapture(MarketingDemo.site("flights", "/tp1351"), "TP 1351 · Flight status", (40, 96, 520, 250))
        liveCapture(MarketingDemo.site("weather", "/lisbon-week"), "Lisbon · 7-day forecast", (40, 76, 620, 210))
        run { [self] in
            guard let e = EaselCenter.shared.existingEditor(easelID) else { return note("marketing: MISSING easel-live: no Easel") }
            let caps = e.document.stacked.filter { $0.content.type == "capture" }
            if caps.count != 2 || e.document.liveBlocks.count != 2 { note("marketing: MISSING easel-live: \(e.document.liveBlocks.count) of 2 Captures live") }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> EaselRect { EaselRect(x: x, y: y, width: w, height: h) }
            e.change("Layout") { doc in
                if caps.count == 2 {
                    doc.update(caps[0].id) { $0.frame = r(40, 120, 520, 250) }
                    doc.update(caps[1].id) { $0.frame = r(600, 150, 620, 210); $0.rotation = 0.015 }
                }
                let heading = NoteDocument(blocks: [NoteBlock(kind: .heading1, runs: [NoteRun("Getting there")])])
                doc.add(EaselBlock(frame: r(40, 30, 420, 60), content: .text(EaselText(heading, font: .fancy, size: 22))))
                doc.add(EaselBlock(frame: r(44, 92, 300, 0), content: .line(EaselLine(from: EaselPoint(44, 96), to: EaselPoint(300, 92), endHead: false, color: .red, width: 4))))
                let note = NoteDocument(blocks: [
                    NoteBlock(kind: .paragraph, runs: [NoteRun("These stay live:", marks: [.bold]), NoteRun(" the gate and the forecast update on their own.")]),
                ])
                doc.add(EaselBlock(frame: r(600, 400, 380, 120), rotation: -0.02, content: .shape(EaselShape(.rectangle, fill: .yellow, cornerRadius: 12))))
                doc.add(EaselBlock(frame: r(620, 418, 340, 90), rotation: -0.02, content: .text(EaselText(note, font: .hip, size: 17))))
                doc.add(EaselBlock(frame: r(0, 0, 0, 0), content: .line(EaselLine(from: EaselPoint(700, 404), to: EaselPoint(760, 372), endHead: true, color: .darkBlue, width: 3))))
            }
            e.selection = []
            for t in tabs { c.closeTab(t) }
            if let t = c.store.tabs(showingEasel: easelID).first { c.show(t.id, focus: false) }
            c.window.makeFirstResponder(nil)
            c.reloadAll(animated: false)
            e.view.canvas.zoomToFit(animated: false)
            e.refreshLive()
        }
        // The refreshes land (the chips go from Refreshing… to Live), and "Added to …" fades.
        step { [self] done in waitUntil({ EaselLiveCenter.shared.activeCount == 0 && EaselCenter.shared.existingEditor(easelID)?.refreshing.isEmpty == true }, timeout: 30) { done() } }
        run { [self] in
            let ok = EaselCenter.shared.existingEditor(easelID)?.document.liveBlocks.allSatisfy { b in
                if case .capture(let c) = b.content { return c.live?.status == .ok }
                return false
            } ?? false
            if !ok { note("marketing: MISSING easel-live: a refresh didn't work") }
            EaselCenter.shared.existingEditor(easelID)?.view.canvas.zoomToFit(animated: false)
        }
        wait(2.5)
        mkWindowShot("easel-live")
        run { [self] in
            if let t = c.store.tabs(showingEasel: easelID).first, let item = t.itemID {
                c.forgetPage(t.id, close: true)
                try? c.store.deleteItem(item)
            }
            MarketingServer.extraPages["/tp1351"] = nil
            MarketingServer.extraPages["/lisbon-week"] = nil
        }
        wait(0.4)
    }
}
#endif

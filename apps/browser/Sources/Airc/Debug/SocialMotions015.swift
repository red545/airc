// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

// social-needs: cabfbaac (Airc 0.1.5's source: tools/social/mac-frames.sh builds this file into that release and later)

/// The social studio's motions of features that came in Airc 0.1.5 (the earlier releases' are in SocialMotions.swift,
/// SocialMotions013.swift and SocialMotions014.swift):
///   - easellive: Live Captures. The demo flight page (MarketingParityP19b.swift's, at flights.aircbrowser.com on the demo
///     server) is captured to an Easel in Travel, the forecast too; on the Easel both carry their Live chips; then the
///     flight page changes (On time → Boarding, gate A14 → A16) and a refresh brings the change onto the board. Fixture
///     pages only, nothing of anyone's.
extension SnapshotRunner: Social015Motions {
    func social015Motion(_ motion: String) -> Bool {
        switch motion {
        case "easellive": socialEaselLive()
        default: return false
        }
        return true
    }

    /// The flight page after the change: boarding, at another gate.
    static var socialFlightBoarding: String {
        mkFlightPage
            .replacingOccurrences(of: "● On time", with: "● Boarding")
            .replacingOccurrences(of: "background:#d8f5e3;color:#11733f", with: "background:#fde7c8;color:#9a5300")
            .replacingOccurrences(of: "Gate<b>A14</b>", with: "Gate<b>A16</b>")
    }

    func socialEaselLive() {
        let reel = SocialReel("easellive")
        let server = socialServer()
        var easelID = ""
        var tabs: [String] = []
        run { [self] in
            MarketingServer.extraPages["/tp1351"] = Self.mkFlightPage
            MarketingServer.extraPages["/lisbon-week"] = Self.mkForecastPage
            guard let s = socialSpace("Travel") else { return note("social: MISSING easellive: no Travel Space") }
            c.switchToSpace(s, animated: false)
            easelID = newID()
            try? EaselCenter.shared.files.save(EaselDocument(id: easelID, title: "Getting there"))
            _ = try? c.store.createEasel(easelID, inSpace: c.currentSpaceID, title: "Getting there")
            CaptureSession.addsLive = true
        }
        /// One live Capture of the page's card (CSS `x, y, w, h`); with `frames`, the page and the selection as frames.
        func liveCapture(_ url: String, _ title: String, _ r: (Double, Double, Double, Double), frames: Bool) {
            run { [self] in
                guard let t = try? c.store.openTab(url: url, inSpace: c.currentSpaceID, title: title) else { return }
                tabs.append(t.id)
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            mkSettleShown()
            if frames { socialOverlayFrame(reel, hold: 1.3, label: "page") }
            run { [self] in c.startCapture() }
            step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
            run { [self] in
                guard let s = CaptureSession.active(in: c.window), let tab = tabs.last.flatMap({ c.engineTab(for: $0) }) else {
                    return note("social: MISSING easellive: Capture didn't start on \(title)")
                }
                let v = tab.view, z = CGFloat(tab.zoomFactor)
                func p(_ x: Double, _ y: Double) -> NSPoint {
                    let py = CGFloat(y) * z
                    return NSPoint(x: CGFloat(x) * z, y: v.isFlipped ? py : v.bounds.height - py)
                }
                let a = s.overlay.convert(p(r.0, r.1), from: v), b = s.overlay.convert(p(r.0 + r.2, r.1 + r.3), from: v)
                s.overlay.selection = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            }
            wait(0.4)
            if frames { socialOverlayFrame(reel, hold: 1.5, label: "select") }
            run { [self] in
                if CaptureSession.active(in: c.window)?.addToEasel(easelID) == nil {
                    note("social: MISSING easellive: Add to Easel refused on \(title)")
                }
            }
            wait(1.0)
        }
        liveCapture(MarketingDemo.site("flights", "/tp1351"), "TP 1351 · Flight status", (40, 96, 520, 250), frames: true)
        liveCapture(MarketingDemo.site("weather", "/lisbon-week"), "Lisbon · 7-day forecast", (40, 76, 620, 210), frames: false)
        // The board as MarketingParityP19b.swift lays it out: the two Captures, a heading and a note.
        run { [self] in
            guard let e = EaselCenter.shared.existingEditor(easelID) else { return note("social: MISSING easellive: no Easel") }
            let caps = e.document.stacked.filter { $0.content.type == "capture" }
            if caps.count != 2 || e.document.liveBlocks.count != 2 { note("social: MISSING easellive: \(e.document.liveBlocks.count) of 2 Captures live") }
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
        socialWaitLive(easelID)
        wait(2.5)   // "Added to …" fades
        socialFrame(reel, hold: 2.0, label: "easel")
        // The flight page changes; the board's refresh brings it in.
        run { [self] in
            MarketingServer.extraPages["/tp1351"] = Self.socialFlightBoarding
            EaselCenter.shared.existingEditor(easelID)?.refreshLive()
        }
        wait(0.2)
        socialFrame(reel, hold: 0.8, label: "refresh")
        socialWaitLive(easelID)
        wait(0.6)
        socialFrame(reel, hold: 2.6, label: "live")
        socialWrite(reel)
        run { [self] in
            if let t = c.store.tabs(showingEasel: easelID).first, let item = t.itemID {
                c.forgetPage(t.id, close: true)
                try? c.store.deleteItem(item)
            }
            MarketingServer.extraPages["/tp1351"] = nil
            MarketingServer.extraPages["/lisbon-week"] = nil
            server.value?.stop()
        }
    }

    /// Until the Easel's live refreshes are done, each Capture's status checked.
    func socialWaitLive(_ easelID: @autoclosure @escaping () -> String) {
        step { [self] done in
            waitUntil({ EaselLiveCenter.shared.activeCount == 0 && EaselCenter.shared.existingEditor(easelID())?.refreshing.isEmpty == true }, timeout: 30) { done() }
        }
        run { [self] in
            let ok = EaselCenter.shared.existingEditor(easelID())?.document.liveBlocks.allSatisfy { b in
                if case .capture(let c) = b.content { return c.live?.status == .ok }
                return false
            } ?? false
            if !ok { note("social: MISSING easellive: a refresh didn't work") }
            EaselCenter.shared.existingEditor(easelID())?.view.canvas.zoomToFit(animated: false)
        }
    }
}
#endif

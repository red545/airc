// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircKit
import AppKit

/// P19a's shot, `--script marketing` part `parityp19a`:
///   - easel: Travel with an Easel pinned, "Lisbon, March": the synthetic trip page (MarketingServer's
///     trips.aircbrowser.com/lisbon, the Capture shot's page) Captured onto it with Capture's "Add to Easel", a heading,
///     a plan on a coloured card, an arrow to the Capture, a red underline and a link card. Fixture content only.
extension SnapshotRunner {
    func mkParityP19aShots(_ d: MarketingDemo) {
        var pageTab = "", easelID = ""
        mkShow(d, "travel", nil)
        run { [self] in
            pageTab = (try? c.store.openTab(url: MarketingDemo.site("trips", "/lisbon"), inSpace: c.currentSpaceID, title: "Lisbon, four days"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(pageTab, focus: false)
        }
        mkSettleShown()
        run { [self] in
            // The Easel first, so Capture's menu has it.
            easelID = newID()
            try? EaselCenter.shared.files.save(EaselDocument(id: easelID, title: "Lisbon, March"))
            _ = try? c.store.createEasel(easelID, inSpace: c.currentSpaceID, title: "Lisbon, March")
            c.show(pageTab, focus: false)
            c.startCapture()
        }
        step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
        run { [self] in
            guard let s = CaptureSession.active(in: c.window) else { return note("marketing: MISSING easel: Capture didn't start") }
            s.toggleFullPage()
            _ = s.addToEasel(easelID)
            guard let e = EaselCenter.shared.existingEditor(easelID) else { return note("marketing: MISSING easel: no Easel") }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> EaselRect { EaselRect(x: x, y: y, width: w, height: h) }
            e.change("Layout") { doc in
                if let cap = doc.blocks.first(where: { $0.content.type == "capture" }) {
                    let aspect = cap.frame.height / max(0.0001, cap.frame.width)
                    doc.update(cap.id) { $0.frame = r(470, 40, 500, 500 * aspect); $0.rotation = 0.02 }
                }
                let heading = NoteDocument(blocks: [NoteBlock(kind: .heading1, runs: [NoteRun("Lisbon, March")])])
                doc.add(EaselBlock(frame: r(40, 30, 380, 60), content: .text(EaselText(heading, font: .fancy, size: 22))))
                doc.add(EaselBlock(frame: r(40, 112, 300, 0), content: .line(EaselLine(from: EaselPoint(44, 104), to: EaselPoint(300, 100), endHead: false, color: .red, width: 4))))
                doc.add(EaselBlock(frame: r(40, 140, 360, 230), rotation: -0.025, content: .shape(EaselShape(.rectangle, fill: .pink, cornerRadius: 14))))
                let plan = NoteDocument(blocks: [
                    NoteBlock(kind: .paragraph, runs: [NoteRun("Day 1", marks: [.bold]), NoteRun("  Alfama at golden hour")]),
                    NoteBlock(kind: .paragraph, runs: [NoteRun("Day 2", marks: [.bold]), NoteRun("  Tram 28 before nine")]),
                    NoteBlock(kind: .paragraph, runs: [NoteRun("Day 3", marks: [.bold]), NoteRun("  Sintra by train")]),
                    NoteBlock(kind: .paragraph, runs: [NoteRun("Day 4", marks: [.bold]), NoteRun("  Pastéis de Belém, then home")]),
                ])
                doc.add(EaselBlock(frame: r(64, 166, 320, 180), rotation: -0.025, content: .text(EaselText(plan, size: 17))))
                doc.add(EaselBlock(frame: r(0, 0, 0, 0), content: .line(EaselLine(from: EaselPoint(392, 230), to: EaselPoint(462, 190), endHead: true, color: .darkBlue, width: 3))))
                doc.add(EaselBlock(frame: r(40, 410, 340, 96), content: .link(EaselLink(url: "https://en.wikipedia.org/wiki/Lisbon", title: "Lisbon", detail: "Capital of Portugal, on the Tagus"))))
                doc.add(EaselBlock(frame: r(40, 530, 150, 110), content: .shape(EaselShape(.ellipse, fill: .yellow))))
                doc.add(EaselBlock(frame: r(56, 568, 120, 34), content: .text(EaselText(NoteDocument(blocks: [NoteBlock(runs: [NoteRun("Book it!", marks: [.bold])])]), font: .hip, size: 18, alignment: .center))))
            }
            e.selection = []
            if !pageTab.isEmpty { c.closeTab(pageTab); pageTab = "" }
            if let t = c.store.tabs(showingEasel: easelID).first { c.show(t.id, focus: false) }
            c.window.makeFirstResponder(nil)
            c.reloadAll(animated: false)
            e.view.canvas.zoomToFit(animated: false)
        }
        // "Added to …" fades first.
        wait(3.0)
        mkWindowShot("easel")
        run { [self] in
            if let t = c.store.tabs(showingEasel: easelID).first, let item = t.itemID {
                c.forgetPage(t.id, close: true)
                try? c.store.deleteItem(item)
            }
        }
        wait(0.4)
    }
}
#endif

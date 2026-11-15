// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import WebKit

/// P19c's shot, `--script marketing` part `parityp19c`:
///   - easel-share: the Travel Space's Easel "Lisbon weekend" (a postcard picture drawn here, a checklist, a plan on a
///     yellow card, an arrow, two link cards), Share Link… over it: the page exactly as it would be published on
///     aircbrowser.com/e/…, what's never in a link, and Create Link. Nothing is published. Fixture content only.
extension SnapshotRunner {
    /// A postcard: a sunset over the river, "Lisboa".
    private static func mkPostcard() -> Data? {
        let w = 960, h = 620
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            NSColor(srgbRed: 0.98, green: 0.55, blue: 0.36, alpha: 1).cgColor, NSColor(srgbRed: 0.99, green: 0.78, blue: 0.52, alpha: 1).cgColor,
            NSColor(srgbRed: 0.62, green: 0.76, blue: 0.93, alpha: 1).cgColor] as CFArray, locations: [0, 0.45, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 220), end: CGPoint(x: 0, y: CGFloat(h)), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0.93, blue: 0.7, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: 600, y: 190, width: 150, height: 150))
        ctx.setFillColor(NSColor(srgbRed: 0.2, green: 0.36, blue: 0.55, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 240))
        ctx.setFillColor(NSColor(srgbRed: 0.98, green: 0.72, blue: 0.5, alpha: 0.55).cgColor)
        for i in 0..<7 { ctx.fill(CGRect(x: 560 + i * 9 - i * i, y: 200 - i * 26, width: 230 - i * 22, height: 6)) }
        // Hills and roofs.
        ctx.setFillColor(NSColor(srgbRed: 0.55, green: 0.33, blue: 0.3, alpha: 1).cgColor)
        ctx.addPath(CGPath(rect: CGRect(x: 0, y: 240, width: 380, height: 70), transform: nil))
        ctx.fillPath()
        for (x, rh) in [(20, 120), (90, 150), (170, 100), (240, 170), (310, 130)] {
            ctx.setFillColor(NSColor(srgbRed: 0.93, green: 0.88, blue: 0.8, alpha: 1).cgColor)
            ctx.fill(CGRect(x: x, y: 240, width: 60, height: rh))
            ctx.setFillColor(NSColor(srgbRed: 0.8, green: 0.38, blue: 0.27, alpha: 1).cgColor)
            ctx.move(to: CGPoint(x: x - 6, y: 240 + rh)); ctx.addLine(to: CGPoint(x: x + 30, y: 270 + rh)); ctx.addLine(to: CGPoint(x: x + 66, y: 240 + rh))
            ctx.fillPath()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "Lisboa", attributes: [.font: NSFont(descriptor: NSFont.systemFont(ofSize: 86, weight: .bold).fontDescriptor.withDesign(.serif)!, size: 86)!,
                                                         .foregroundColor: NSColor.white]).draw(at: NSPoint(x: 56, y: 470))
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    func mkParityP19cShots(_ d: MarketingDemo) {
        var easelID = ""
        mkShow(d, "travel", nil)
        run { [self] in
            easelID = newID()
            try? EaselCenter.shared.files.save(EaselDocument(id: easelID, title: "Lisbon weekend"))
            guard let t = try? c.store.createEasel(easelID, inSpace: c.currentSpaceID, title: "Lisbon weekend") else {
                return note("marketing: MISSING easel-share: no Easel")
            }
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        wait(0.6)
        run { [self] in
            guard let e = EaselCenter.shared.existingEditor(easelID) else { return note("marketing: MISSING easel-share: no editor") }
            let postcard = Self.mkPostcard().flatMap { EaselCenter.shared.storePicture($0, ext: "png", in: easelID) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> EaselRect { EaselRect(x: x, y: y, width: w, height: h) }
            e.change("Layout") { doc in
                let heading = NoteDocument(blocks: [NoteBlock(kind: .heading1, runs: [NoteRun("Lisbon weekend")])])
                doc.add(EaselBlock(frame: r(40, 20, 460, 60), content: .text(EaselText(heading, font: .fancy, size: 22))))
                if let p = postcard { doc.add(EaselBlock(frame: r(560, 40, 420, 271), rotation: 0.025, content: .image(p))) }
                let list = NoteDocument(blocks: [
                    NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("Pastéis de nata in Belém")]),
                    NoteBlock(kind: .checkbox, runs: [NoteRun("Tram 28 before 9")]),
                    NoteBlock(kind: .checkbox, runs: [NoteRun("Sunset at Miradouro da Graça")]),
                ])
                doc.add(EaselBlock(frame: r(44, 104, 420, 110), content: .text(EaselText(list, size: 18))))
                doc.add(EaselBlock(frame: r(44, 236, 380, 112), rotation: -0.02, content: .shape(EaselShape(.rectangle, fill: .yellow, cornerRadius: 12))))
                let plan = NoteDocument(blocks: [NoteBlock(kind: .paragraph, runs: [NoteRun("Saturday:", marks: [.bold]), NoteRun(" Alfama in the morning, the river at lunch, then up the hill for the light.")])])
                doc.add(EaselBlock(frame: r(62, 252, 344, 84), rotation: -0.02, content: .text(EaselText(plan, font: .hip, size: 16))))
                doc.add(EaselBlock(frame: r(0, 0, 0, 0), content: .line(EaselLine(from: EaselPoint(430, 280), to: EaselPoint(548, 222), endHead: true, color: .darkBlue, width: 3))))
                doc.add(EaselBlock(frame: r(44, 380, 340, 96), content: .link(EaselLink(url: "https://www.visitlisboa.com/", title: "Visit Lisboa", detail: "The city's own guide: neighbourhoods, museums, events"))))
                doc.add(EaselBlock(frame: r(410, 380, 340, 96), content: .link(EaselLink(url: "https://en.wikivoyage.org/wiki/Lisbon", title: "Lisbon – Wikivoyage", detail: "Getting around, eating, the miradouros"))))
            }
            e.selection = []
            c.window.makeFirstResponder(nil)
            e.view.canvas.zoomToFit(animated: false)
            e.shareLink()
        }
        step { [self] done in waitUntil({ EaselShareSheet.active[ObjectIdentifier(self.c.window)]?.phase == .preview }, timeout: 10) { done() } }
        wait(1.5)
        var preview: NSImage?
        step { [self] done in
            guard let web = EaselShareSheet.active[ObjectIdentifier(c.window)]?.preview else { return done() }
            web.takeSnapshot(with: nil) { image, _ in
                preview = image
                done()
            }
        }
        mkWindowShot("easel-share") { [self] frame in
            guard let sheet = EaselShareSheet.active[ObjectIdentifier(c.window)], let card = mkContentImage(sheet.sheet) else {
                note("marketing: MISSING easel-share: no sheet")
                return []
            }
            let sf = sheet.sheet.frame, wf = c.window.frame
            let origin = NSPoint(x: frame.minX + sf.minX - wf.minX, y: frame.minY + sf.minY - wf.minY)
            var layers = [MarketingStudio.Layer(image: card, frame: NSRect(origin: origin, size: sf.size), radius: 16, shadow: .panel)]
            // The page preview is drawn by WebKit's own process: its snapshot goes where the view is.
            if let preview {
                let r = sheet.preview.convert(sheet.preview.bounds, to: nil)
                layers.append(MarketingStudio.Layer(image: preview, frame: NSRect(x: origin.x + r.minX, y: origin.y + r.minY, width: r.width, height: r.height),
                                                    radius: 10, shadow: .none))
            } else {
                note("marketing: MISSING easel-share: no preview snapshot")
            }
            return layers
        }
        run { [self] in
            EaselShareSheet.active[ObjectIdentifier(c.window)]?.close()
            if let t = c.store.tabs(showingEasel: easelID).first, let item = t.itemID {
                c.forgetPage(t.id, close: true)
                try? c.store.deleteItem(item)
            }
        }
        wait(0.4)
    }
}
#endif

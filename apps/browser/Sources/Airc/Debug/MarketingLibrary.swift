// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircKit
import AppKit

/// Library › Media and the Library button's recent files (LIB-1), for `--script marketing` part `library`: the Work
/// Space downloads synthetic illustrations and two short films from MarketingServer's files.aircbrowser.com/media/ (made
/// here: flat landscapes, a moodboard, a palette; nobody's photos) and an itinerary PDF, saves a Capture of the trips
/// demo page, then shows the grid and the hover card. Everything goes to the run's own downloads folder.
extension SnapshotRunner {
    struct MarketingMediaFile { let type: String; let data: Data }

    /// The demo files by name, made once (the server asks from its own queue).
    static let mkLibraryMedia: [String: MarketingMediaFile] = {
        var out: [String: MarketingMediaFile] = [:]
        func jpeg(_ name: String, _ draw: (CGContext, CGFloat, CGFloat) -> Void) {
            guard let png = LibraryFixtures.png(width: 1200, height: 900, draw), let rep = NSBitmapImageRep(data: png),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
            out[name] = MarketingMediaFile(type: "image/jpeg", data: data)
        }
        func png(_ name: String, _ draw: (CGContext, CGFloat, CGFloat) -> Void) {
            if let data = LibraryFixtures.png(width: 1200, height: 900, draw) { out[name] = MarketingMediaFile(type: "image/png", data: data) }
        }
        jpeg("Alfama rooftops.jpg") { mkLandscape($0, $1, $2, sky: [0xFFB37A, 0xF2797B, 0x7D5BA6], sun: (0.68, 0.42), hills: [0xB0567C, 0x7A3E6E, 0x41284F]) }
        jpeg("Coast at dusk.jpg") { mkLandscape($0, $1, $2, sky: [0xF9D29D, 0x9FB8E0, 0x4A5C9A], sun: (0.3, 0.38), hills: [0x5E79B5, 0x3D5590, 0x22325E]) }
        jpeg("Desert road.jpg") { mkLandscape($0, $1, $2, sky: [0xFFE3A3, 0xFFB26B, 0xE0794C], sun: (0.5, 0.5), hills: [0xD9825B, 0xB25E43, 0x6E3A2E]) }
        png("Studio moodboard.png") { mkMoodboard($0, $1, $2) }
        png("Brand palette.png") { mkPalette($0, $1, $2) }
        for (name, sky, hills) in [("Launch teaser.mov", [0xA8E6CF, 0x56C2B6, 0x2A7F8E], [0x2F8F83, 0x1F6B6A, 0x13434A]),
                                   ("Product walkthrough.mp4", [0xD7C4F2, 0x9D8BE0, 0x5B4BB0], [0x6C5BC0, 0x4A3C94, 0x2C2462])] {
            let data = LibraryFixtures.movie(width: 960, height: 540, frames: 36) { ctx, w, h, i in
                mkLandscape(ctx, w, h, sky: sky, sun: (0.22 + 0.012 * Double(i), 0.46 + 0.004 * Double(i)), hills: hills)
            }
            if let data { out[name] = MarketingMediaFile(type: name.hasSuffix(".mp4") ? "video/mp4" : "video/quicktime", data: data) }
        }
        return out
    }()

    static func mkColor(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }

    /// A flat landscape: a sky gradient, a sun with a glow, three layers of hills.
    static func mkLandscape(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, sky: [Int], sun: (Double, Double), hills: [Int]) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let g = CGGradient(colorsSpace: space, colors: sky.reversed().map { mkColor($0) } as CFArray, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }
        let c = CGPoint(x: w * sun.0, y: h * sun.1)
        if let glow = CGGradient(colorsSpace: space, colors: [mkColor(0xFFF4D6, 0.7), mkColor(0xFFF4D6, 0)] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: h * 0.32, options: [])
        }
        ctx.setFillColor(mkColor(0xFFF6E0))
        ctx.fillEllipse(in: CGRect(x: c.x - h * 0.08, y: c.y - h * 0.08, width: h * 0.16, height: h * 0.16))
        for (i, hex) in hills.enumerated() {
            let base = h * (0.42 - 0.12 * CGFloat(i)), amp = h * (0.07 - 0.012 * CGFloat(i))
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            for step in 0...60 {
                let x = w * CGFloat(step) / 60
                let t = Double(x / w) * .pi * 2
                let y = base + amp * CGFloat(sin(t * (1.3 + Double(i) * 0.4) + Double(i) * 1.7) + 0.45 * sin(t * 3.1 + Double(i)))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: w, y: 0))
            path.closeSubpath()
            ctx.setFillColor(mkColor(hex))
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    static func mkMoodboard(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
        ctx.setFillColor(mkColor(0xF6F1EA))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cards: [(CGRect, Int)] = [
            (CGRect(x: 0.06, y: 0.52, width: 0.42, height: 0.40), 0xF2B5A0), (CGRect(x: 0.52, y: 0.62, width: 0.42, height: 0.30), 0x9CC5B9),
            (CGRect(x: 0.06, y: 0.08, width: 0.26, height: 0.38), 0x2F3E57), (CGRect(x: 0.36, y: 0.08, width: 0.58, height: 0.48), 0xE9C46A),
        ]
        for (r, hex) in cards {
            let rect = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)
            ctx.setFillColor(mkColor(hex))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil))
            ctx.fillPath()
        }
        ctx.setFillColor(mkColor(0xF6F1EA, 0.9))
        ctx.fillEllipse(in: CGRect(x: w * 0.55, y: h * 0.18, width: h * 0.26, height: h * 0.26))
        ctx.setFillColor(mkColor(0xE76F51))
        ctx.fillEllipse(in: CGRect(x: w * 0.14, y: h * 0.62, width: h * 0.18, height: h * 0.18))
    }

    static func mkPalette(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
        ctx.setFillColor(mkColor(0xFFFFFF))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let colors = [0x264653, 0x2A9D8F, 0xE9C46A, 0xF4A261, 0xE76F51]
        let pad = w * 0.05, gap = w * 0.02
        let sw = (w - 2 * pad - gap * CGFloat(colors.count - 1)) / CGFloat(colors.count)
        for (i, hex) in colors.enumerated() {
            let rect = CGRect(x: pad + CGFloat(i) * (sw + gap), y: h * 0.12, width: sw, height: h * 0.76)
            ctx.setFillColor(mkColor(hex))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil))
            ctx.fillPath()
        }
    }

    func mkLibraryShots(_ d: MarketingDemo) {
        let center = { MediaLibrary.shared.downloads }
        var aborted = false
        var tabID = ""
        func complete(_ name: String) -> Bool { center()?.items.contains { $0.download.fileName == name && $0.download.state == .complete } == true }
        step { done in DispatchQueue.global(qos: .userInitiated).async { _ = Self.mkLibraryMedia; DispatchQueue.main.async(execute: done) } }
        run { [self] in
            guard d.serverUp, let sid = d.space["work"], let folder = d.downloads,
                  let t = try? c.store.openTab(url: MarketingDemo.site("trips", "/lisbon"), inSpace: sid, title: "Lisbon, four days") else {
                aborted = true
                return note("marketing: MISSING library-media: no demo pages")
            }
            tabID = t.id
            DownloadCenter.finishedLinger = 0.3
            CaptureSession.downloadsDirectory = { folder }
            c.switchToSpace(sid, animated: false)
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        mkSettleShown(timeout: 8, extra: 0.4)
        func download(_ path: String, _ name: String) {
            run { [self] in
                guard !aborted, let page = c.engineTab(for: tabID) else { return }
                page.load(URL(string: MarketingDemo.site("files", path + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)))!)
            }
            step { [self] done in
                waitUntil({ aborted || complete(name) }, timeout: 8) {
                    guard !aborted else { return done() }
                    let row = center()?.items.first { $0.download.fileName == name }
                    guard complete(name), let p = row?.download.path, let folder = d.downloads?.path, p.hasPrefix(folder) else {
                        // Never into anyone's folders: stop it and everything after.
                        if let row, row.download.state == .inProgress { _ = center()?.perform(.cancel, row) }
                        aborted = true
                        self.note("marketing: MISSING library-media: \(name) didn't download into the run's folder (\(row?.download.path ?? "no row"))")
                        return done()
                    }
                    done()
                }
            }
            wait(0.25)
        }
        for name in ["Desert road.jpg", "Brand palette.png", "Coast at dusk.jpg", "Product walkthrough.mp4", "Studio moodboard.png",
                     "Alfama rooftops.jpg", "Launch teaser.mov"] {
            download("/media/", name)
        }
        // A Capture of the trip page (the whole visible page), saved with the downloads.
        run { [self] in if !aborted { c.engineTab(for: tabID)?.load(URL(string: MarketingDemo.site("trips", "/lisbon"))!) } }
        mkSettleShown(timeout: 8, extra: 0.6)
        run { [self] in if !aborted { c.startCapture() } }
        step { [self] done in waitUntil({ aborted || CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
        run { [self] in
            guard !aborted, let s = CaptureSession.active(in: c.window) else { return }
            s.toggleFullPage()
            s.confirm()
            s.save()
        }
        wait(0.5)
        download("/files/", "Lisbon itinerary.pdf")
        run { [self] in
            guard !aborted else { return }
            if c.library == nil { c.toggleLibrary() }
            c.library?.model.section = .media
        }
        step { done in LibraryFiles.shared.refresh(done) }
        step { [self] done in
            waitUntil({ aborted || LibraryFiles.shared.media.allSatisfy { LibraryThumbnails.shared.pictured.contains($0.path) } }, timeout: 10) {
                self.note("marketing: library-media: \(LibraryFiles.shared.media.count) tiles, \(LibraryFiles.shared.media.filter { LibraryThumbnails.shared.pictured.contains($0.path) }.count) pictured")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
            }
        }
        // Capture's "Saved to Downloads" isn't part of this shot.
        run { [self] in c.toast.isHidden = true }
        step { [self] done in if aborted { return done() }; mkWindowShotNow("library-media", dark: mkIsDark(), done) }
        run { [self] in if c.library != nil { c.toggleLibrary() } }
        wait(0.6)
        run { [self] in if !aborted { hoverLibraryButton(true) } }
        step { [self] done in waitUntil({ aborted || self.c.recentFiles.isShowing }, timeout: 3) { done() } }
        wait(0.5)
        step { [self] done in
            guard !aborted, c.recentFiles.isShowing else { note("marketing: MISSING library-recent: no card"); return done() }
            mkWindowShotNow("library-recent", dark: mkIsDark(), done)
        }
        run { [self] in
            hoverLibraryButton(false)
            c.recentFiles.hide()
            CaptureSession.downloadsDirectory = { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
            if !tabID.isEmpty { c.closeTab(tabID) }
        }
        wait(0.4)
    }
}
#endif

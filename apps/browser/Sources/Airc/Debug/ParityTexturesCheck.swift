// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// `--script paritytextures` (TH-4, both engines; arctextures): a Space's texture (grain, sand, denim, tweed) draws in
/// the window background at Arc's strength, light and dark, and the theme picker offers it.
///   1. For each texture and appearance, one Space (Arc's blue swatch, grain dial at full) is drawn as the active window
///      with translucency off. The window background's layers are rendered with `CALayer.render(in:)` (cacheDisplay
///      ignores layer opacity) and compared with the same Space at grain 0:
///        - grain, sand, denim, tweed: the mean luminance falls by Arc's multiply, strength × (1 − mean of Arc's image),
///          within 0.008, light and dark, and (light) the spread is Arc's, strength × its spread, within 25 %.
///          Grain is Arc's multiply since grainmatch (before, Airc's speck tile measured × 0.952 light, × 1.18 dark).
///      Inactive (the window not main): the same texture at ¼ strength.
///   2. The theme picker (Edit Theme Color…) shows Grain, Sand, Denim and Tweed; pressing Denim (accessibility press,
///      posted) sets the Space's texture.
/// Shots: paritytextures-<engine>-<texture>-<light|dark>.png (sidebar crop, 2x) and a strip of all eight,
/// paritytextures-strip-<engine>.png. No real input. Zero-guard: the run fails if it made too few assertions.
extension SnapshotRunner {
    @MainActor func parityTexturesScenario() {
        let engine = app?.engine is WebKitEngine ? "webkit" : "chromium"
        let tag = "paritytextures (\(engine == "webkit" ? "WebKit" : "Chromium"))"
        var asserted = 0
        func expect(_ ok: Bool, _ what: String) { asserted += 1; check(ok, "\(tag): \(what)") }
        func f(_ v: Double) -> String { String(format: "%.4f", v) }
        var spaceID = ""
        var originalTranslucency: AircTranslucency = .default
        var strip: [CGImage] = []
        let blue = RGBA(hex: "7EB6D5")!

        func background() -> SpaceBackgroundView? {
            var views: [NSView] = [c.background]
            while let v = views.popLast() {
                if let b = v as? SpaceBackgroundView { return b }
                views += v.subviews
            }
            return nil
        }
        /// `view`'s layer tree at 2x, as Core Animation composites it (layer opacity included), the right way up.
        func renderLayers(_ view: NSView) -> CGImage? {
            guard let layer = view.layer else { return nil }
            let w = Int(view.bounds.width * 2), h = Int(view.bounds.height * 2)
            guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.scaleBy(x: 2, y: 2)
            if view.isFlipped {
                // render(in:) draws a flipped view's layer upside down (real-input notes); flip it back.
                ctx.translateBy(x: 0, y: view.bounds.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            layer.render(in: ctx)
            return ctx.makeImage()
        }
        /// Mean and standard deviation of encoded (sRGB) luma.
        func luma(_ image: CGImage) -> (mean: Double, sd: Double) {
            let w = image.width, h = image.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sum = 0.0, sq = 0.0
            for i in 0..<(w * h) {
                let l = (0.2126 * Double(px[i * 4]) + 0.7152 * Double(px[i * 4 + 1]) + 0.0722 * Double(px[i * 4 + 2])) / 255
                sum += l; sq += l * l
            }
            let n = Double(w * h), m = sum / n
            return (m, max(0, sq / n - m * m).squareRoot())
        }
        func write(_ image: CGImage, _ name: String) {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
        func setTheme(grain: Double, texture: SpaceTexture, appearance: Appearance) {
            try? c.store.updateSpace(spaceID) { $0.theme = SpaceTheme(colors: [blue], grain: grain, texture: texture, appearance: appearance) }
            c.reloadAll(animated: false)
        }

        run { [self] in
            originalTranslucency = app?.settings.translucency ?? .default
            c.applyTranslucency(.off)
            do {
                spaceID = try c.store.createSpace(name: "Textures", theme: SpaceTheme(colors: [blue], grain: 0)).id
            } catch { return expect(false, "fixture: the Space (\(error))") }
            c.switchToSpace(spaceID, animated: false)
        }
        wait(0.8)

        // 1. Each texture, light and dark.
        for appearance in [Appearance.light, .dark] {
            for texture in SpaceTexture.allCases {
                var baseline: (mean: Double, sd: Double) = (0, 0)
                run { setTheme(grain: 0, texture: texture, appearance: appearance) }
                wait(0.4)
                run { [self] in
                    guard let bg = background() else { return expect(false, "\(texture.rawValue) \(appearance.rawValue): the window background") }
                    bg.isWindowActiveOverride = true
                    bg.layoutSubtreeIfNeeded()
                    guard let image = renderLayers(bg) else { return expect(false, "\(texture.rawValue) \(appearance.rawValue): baseline render") }
                    baseline = luma(image)
                }
                run { setTheme(grain: 1, texture: texture, appearance: appearance) }
                wait(0.4)
                run { [self] in
                    let name = "\(texture.rawValue) \(appearance.rawValue)"
                    guard let bg = background(), let design = DesignTheme.Texture(rawValue: texture.rawValue) else {
                        return expect(false, "\(name): the window background")
                    }
                    bg.isWindowActiveOverride = true
                    bg.layoutSubtreeIfNeeded()
                    expect(bg.theme.isDark == (appearance == .dark), "\(name): the window is \(appearance.rawValue)")
                    guard let image = renderLayers(bg), baseline.mean > 0 else { return expect(false, "\(name): render") }
                    let got = luma(image)
                    let ratio = got.mean / baseline.mean
                    let opacity = design.strength
                    let arc = AircTextures.arcTarget(design)
                    let arcRatio = 1 - design.strength * arc.darkening
                    expect(abs(ratio - arcRatio) < 0.008,
                           "\(name): mean luminance × \(f(ratio)) (\(f(baseline.mean)) → \(f(got.mean))), Arc's × \(f(arcRatio)) (strength \(design.strength) × darkening \(f(arc.darkening)))")
                    let relSD = got.sd / got.mean
                    let arcSD = opacity * arc.spread / arcRatio
                    if appearance == .light {
                        expect(abs(relSD - arcSD) < 0.25 * arcSD, "\(name): spread \(f(relSD)) of the mean, Arc's \(f(arcSD)) (± 25 %)")
                    } else {
                        note("\(tag): \(name): spread \(f(relSD)) of the mean, Arc's \(f(arcSD)) (not asserted in dark: 8-bit steps)")
                    }
                    // Shots: the sidebar's top, 240 × 360 pt, as the window composites it (no page: that's the engine's).
                    if let full = renderLayers(c.root), let crop = full.cropping(to: CGRect(x: 0, y: 0, width: min(480, full.width), height: min(720, full.height))) {
                        write(crop, "paritytextures-\(engine)-\(texture.rawValue)-\(appearance.rawValue).png")
                        strip.append(crop)
                    } else {
                        expect(false, "\(name): shot")
                    }
                    // Inactive: ¼ strength.
                    bg.isWindowActiveOverride = false
                    bg.layoutSubtreeIfNeeded()
                    if let dim = renderLayers(bg) {
                        let r = luma(dim).mean / baseline.mean
                        let want = 1 - 0.25 * design.strength * arc.darkening
                        expect(abs(r - want) < 0.006, "\(name): inactive window × \(f(r)), ¼ strength × \(f(want))")
                    }
                    bg.isWindowActiveOverride = true
                }
            }
        }
        run { [self] in
            guard let first = strip.first else { return expect(false, "the shot strip") }
            let w = first.width, h = first.height, gap = 8
            guard let ctx = CGContext(data: nil, width: strip.count * (w + gap) - gap, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: h))
            for (i, image) in strip.enumerated() { ctx.draw(image, in: CGRect(x: i * (w + gap), y: 0, width: w, height: h)) }
            if let image = ctx.makeImage() { write(image, "paritytextures-strip-\(engine).png") }
            expect(strip.count == 8, "eight shots in the strip (grain, sand, denim, tweed; light then dark)")
        }

        // 2. The picker.
        run { [self] in
            setTheme(grain: 0.6, texture: .sand, appearance: .light)
            c.editTheme(spaceID)
        }
        wait(0.8)
        run { [self] in
            guard let view = c.themePopover?.contentView else { return expect(false, "picker: Edit Theme Color… opened") }
            // SwiftUI's accessibility nodes are private classes: reach their NSAccessibility methods dynamically.
            var found: [String: AnyObject] = [:]
            var queue: [AnyObject] = [view]
            var seen = 0
            while let e = queue.popLast(), seen < 4000 {
                seen += 1
                if let label = e.accessibilityLabel?() ?? nil, ["Grain", "Sand", "Denim", "Tweed"].contains(label) { found[label] = e }
                if let children = e.accessibilityChildren?() ?? nil { queue += children.map { $0 as AnyObject } }
            }
            var rep: NSBitmapImageRep?
            if let r = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: r)
                try? r.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("paritytextures-picker-\(engine).png"))
                rep = r
            }
            if found.count == 4, let denim = found["Denim"] {
                expect(true, "picker: offers Grain, Sand, Denim and Tweed (accessibility: \(found.keys.sorted()))")
                _ = denim.accessibilityPerformPress?()
                note("\(tag): picker: Denim pressed (accessibility press, posted)")
                return
            }
            // SwiftUI builds its accessibility tree only while an assistive client is active, so it can be empty here.
            // Then the swatches are found in the picker's pixels: a 2 × 2 grid of 18 pt discs (22 pt cells, 4 pt apart),
            // left of the 46 pt grain dial (12 pt gap), inside the panel's 8.5 pt padding and shadow margin.
            note("\(tag): picker: no accessibility tree (\(found.keys.sorted())); finding the swatches in the pixels")
            guard let rep else { return expect(false, "picker: render the picker") }
            let m = ThemePickerPanel.margin, cell: CGFloat = 22, gap: CGFloat = 4
            let left = m + AircMetrics.ThemePicker.size.width - 8.5 - 46 - 12 - (2 * cell + gap)
            let sx = CGFloat(rep.pixelsWide) / view.bounds.width
            func luma(_ x: CGFloat, _ y: CGFloat) -> Double {   // view points, from the top
                guard let c = rep.colorAt(x: Int(x * sx), y: Int(y * sx))?.usingColorSpace(.sRGB) else { return 1 }
                return Double(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
            }
            // The two rows: dark runs (the discs, on the near-white light surface) down the left column's centre, below
            // the preset row (field 340, then the 30 pt button and preset rows, 10 pt apart).
            let colX = left + cell / 2
            var rows: [CGFloat] = [], start: CGFloat?
            for y in stride(from: m + 8.5 + 340 + 10 + 30 + 10 + 30 + 2, to: view.bounds.height - m, by: 0.5) {
                let dark = luma(colX, y) < 0.85
                if dark, start == nil { start = y }
                if !dark, let s0 = start { if y - s0 >= 10 { rows.append((s0 + y) / 2) }; start = nil }
            }
            guard rows.count == 2 else { return expect(false, "picker: the swatch rows in the pixels (\(rows))") }
            let centres: [String: CGPoint] = ["Grain": CGPoint(x: colX, y: rows[0]), "Sand": CGPoint(x: colX + cell + gap, y: rows[0]),
                                              "Denim": CGPoint(x: colX, y: rows[1]), "Tweed": CGPoint(x: colX + cell + gap, y: rows[1])]
            let discs = centres.filter { luma($0.value.x, $0.value.y) < 0.85 }.keys.sorted()
            expect(discs.count == 4, "picker: offers Grain, Sand, Denim and Tweed (pixels: \(discs), rows at \(rows.map { Int($0) }) pt)")
            guard let window = view.window, let p = centres["Denim"] else { return expect(false, "picker: the Denim swatch") }
            let at = view.convert(NSPoint(x: p.x, y: view.isFlipped ? p.y : view.bounds.height - p.y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            note("\(tag): picker: Denim pressed (posted click at \(Int(at.x)), \(Int(at.y)) in the panel)")
        }
        wait(0.6)
        run { [self] in
            let t = c.store.space(spaceID)?.theme
            expect(t?.texture == .denim && t?.grain == 0.6, "picker: Denim set the Space's texture (\(t?.texture.rawValue ?? "-"), grain \(t?.grain ?? -1))")
            c.themePopover?.close()
            c.applyTranslucency(originalTranslucency)
            // 8 × (appearance + mean) + 4 light spreads + 8 inactive + strip + 2 picker = 31, then this one.
            expect(asserted >= 31, "zero-guard: \(asserted + 1) assertions made (32 expected)")
        }
    }
}
#endif

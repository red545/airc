// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script parityfavbacking` (both engines): dark site icons get a small light plate on dark surfaces (favbacking),
/// as Arc does. Loopback pages serve two synthetic icons: a black "T" on transparency (dark) and a white disc (light).
///   - dark Space: the dark icon's pinned row and Favorite tile show the plate, the light icon's don't; from the pixels,
///     the dark row's icon corner (where the glyph has no ink) is light and the light row's is the sidebar;
///   - Increase Contrast: the plate turns opaque white; Reduce Transparency: opaque grey; both follow the settings live;
///   - the Command Bar's row and a hover card (the same favicon view) back the dark icon only, and only on dark;
///   - light Space: no plate anywhere, and the corner pixels of both rows match;
///   - each icon image is classified once.
/// Shots: favbacking-before (plate off: how it looked), favbacking-dark, favbacking-light.
extension SnapshotRunner {
    func parityFavBackingScenario() {
        let tag = UUID().uuidString.prefix(8).lowercased()
        var server: LocalPageServer?
        var base = "", sid = "", profile = ""
        var darkPin = "", lightPin = "", darkFav = "", lightFav = ""
        let darkIcon = "/dark-\(tag).png", lightIcon = "/light-\(tag).png"
        let darkTheme = AircKit.SpaceTheme(colors: [RGBA(0.16, 0.17, 0.20, 1)], intensity: 0.8, grain: 0, appearance: .dark)
        let lightTheme = AircKit.SpaceTheme(colors: [RGBA(0.86, 0.88, 0.91, 1)], intensity: 0.8, grain: 0, appearance: .light)

        func page() -> SpacePageView? { c.pageView(for: sid) }
        func rowIcon(_ itemID: String) -> FaviconView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.kind == .pinned(itemID: itemID) }?.faviconViewForTesting
        }
        func tileIcon(_ itemID: String) -> FaviconView? {
            page()?.tileView(itemID).flatMap { Self.favBackingIcons(in: $0).first }
        }
        func shows(_ f: FaviconView?) -> Bool { f?.shownImage != nil && f?.iconLayerHasContents == true }
        func describe(_ f: FaviconView?) -> String {
            guard let f else { return "no view" }
            return "icon \(shows(f)), plate \(f.showsBacking)" + (f.backingFill.flatMap { NSColor(cgColor: $0) }.map { " \(Self.favBackingColor($0).hexString)" } ?? "")
        }
        func accessibility(contrast: Bool?, transparency: Bool?) {
            MainActor.assumeIsolated {
                AircTranslucency.increaseContrastOverride = contrast
                AircTranslucency.reduceTransparencyOverride = transparency
            }
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        /// Mean relative luminance of a 3×3 pt patch at the icon's lower-left corner (the "T" has no ink there), from the
        /// window's pixels at 2x.
        func corner(_ f: FaviconView?, _ rep: NSBitmapImageRep?) -> Double? {
            guard let f, let rep else { return nil }
            let root = c.root
            let r = f.convert(f.bounds, to: root)
            let scale = Double(rep.pixelsWide) / Double(root.bounds.width)
            // 2.5…5.5 pt in from the corner the glyph leaves empty (bottom-left of the icon on screen), clear of the
            // plate's rounded corner and of the stem.
            let topY = root.isFlipped ? r.maxY - 5.5 : root.bounds.height - r.minY - 5.5
            var sum = 0.0, n = 0
            for py in Int(topY * scale)..<Int((topY + 3) * scale) {
                for px in Int((r.minX + 2.5) * scale)..<Int((r.minX + 5.5) * scale) {
                    guard let col = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                    sum += Self.favBackingColor(col).relativeLuminance
                    n += 1
                }
            }
            return n > 0 ? sum / Double(n) : nil
        }
        func pixels() -> NSBitmapImageRep? {
            c.root.layoutSubtreeIfNeeded()
            return themeBitmap(c.root, scale: 2)
        }
        func f3(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }

        step { [self] done in
            server = LocalPageServer(responses: [
                darkIcon: .init(headers: ["Content-Type": "image/png"], body: "", data: Self.favBackingPNG(dark: true)),
                lightIcon: .init(headers: ["Content-Type": "image/png"], body: "", data: Self.favBackingPNG(dark: false)),
                "/dark.html": .init(body: "<!doctype html><title>Dark icon</title><link rel='icon' href='\(darkIcon)'><h1>Dark</h1>"),
                "/light.html": .init(body: "<!doctype html><title>Light icon</title><link rel='icon' href='\(lightIcon)'><h1>Light</h1>"),
            ])
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "parityfavbacking: a loopback server") }
                done()
            }
        }
        run { [self] in
            guard !base.isEmpty else { return }
            let home = c.currentSpaceID
            profile = c.store.profile(ofSpace: home).id
            guard let s = try? c.store.createSpace(name: "Icons", profileID: profile, after: home) else {
                return check(false, "parityfavbacking: a Space for the checks")
            }
            sid = s.id
            try? c.store.updateSpace(sid) { $0.theme = darkTheme }
            do {
                try pin(base + "/dark.html", title: "Fav Dark \(tag)", icon: base + darkIcon, space: sid)
                darkPin = c.store.children(of: .pinned(spaceID: sid), parent: nil).last?.id ?? ""
                try pin(base + "/light.html", title: "Fav Light \(tag)", icon: base + lightIcon, space: sid)
                lightPin = c.store.children(of: .pinned(spaceID: sid), parent: nil).last?.id ?? ""
                let before = Set(c.store.children(of: .favorites(profileID: profile), parent: nil).map(\.id))
                try favorite(base + "/dark.html?f", title: "Dark tile", icon: base + darkIcon, profile: profile, space: sid)
                darkFav = c.store.children(of: .favorites(profileID: profile), parent: nil).map(\.id).first { !before.contains($0) } ?? ""
                try favorite(base + "/light.html?f", title: "Light tile", icon: base + lightIcon, profile: profile, space: sid)
                lightFav = c.store.children(of: .favorites(profileID: profile), parent: nil).map(\.id)
                    .first { !before.contains($0) && $0 != darkFav } ?? ""
            } catch { check(false, "parityfavbacking: the rows (\(error))") }
            c.switchToSpace(sid, animated: false)
            c.reloadAll(animated: false)
        }
        step { [self] done in
            waitUntil({ [darkPin, lightPin].allSatisfy { shows(rowIcon($0)) } && [darkFav, lightFav].allSatisfy { shows(tileIcon($0)) } },
                      timeout: 10) { done() }
        }

        // 1. Dark Space: the dark icon only.
        var classifiedAfterDark = 0
        run { [self] in
            let dr = rowIcon(darkPin), lr = rowIcon(lightPin), dt = tileIcon(darkFav), lt = tileIcon(lightFav)
            check(page()?.palette.isDark == true, "parityfavbacking: the Space is dark")
            check(dr?.showsBacking == true && dt?.showsBacking == true,
                  "parityfavbacking: dark: the dark icon's pinned row and Favorite tile show the plate (row \(describe(dr)); tile \(describe(dt)))")
            check(lr?.showsBacking == false && lt?.showsBacking == false && shows(lr) && shows(lt),
                  "parityfavbacking: dark: the light icon's row and tile show no plate (row \(describe(lr)); tile \(describe(lt)))")
            if let dr {
                let f = dr.backingFrame, b = dr.bounds
                check(f.insetBy(dx: -0.01, dy: -0.01).contains(b) && f.width <= b.width + 1.01 && dr.backingFill.map { $0.alpha < 1 && $0.alpha > 0.6 } == true,
                      "parityfavbacking: the plate is small and subtle: \(NSStringFromRect(f)) for a \(NSStringFromRect(b)) icon, translucent fill")
            }
            classifiedAfterDark = FaviconTone.classified
            FaviconTone.disabledForTesting = true
        }
        capture("favbacking-before")
        var before: (Double?, Double?) = (nil, nil)
        run { [self] in
            let rep = pixels()
            before = (corner(rowIcon(darkPin), rep), corner(rowIcon(lightPin), rep))
            FaviconTone.disabledForTesting = false
        }
        capture("favbacking-dark")
        run { [self] in
            let rep = pixels()
            let d = corner(rowIcon(darkPin), rep), l = corner(rowIcon(lightPin), rep)
            // The plate against the bare sidebar: at least 3:1 (WCAG's floor for icons), so the glyph's silhouette shows.
            let ratio = d.flatMap { d in before.0.map { (max(d, $0) + 0.05) / (min(d, $0) + 0.05) } } ?? 0
            check((d ?? 0) > (before.0 ?? 1) && ratio >= 3,
                  "parityfavbacking: dark, pixels: the plate lights the dark icon's empty corner (\(f3(before.0)) without → \(f3(d)) with, "
                  + String(format: "%.2f:1)", ratio))
            check(l != nil && before.1 != nil && abs(l! - before.1!) < 0.01 && (l ?? 1) < 0.1,
                  "parityfavbacking: dark, pixels: the light icon's corner stays the sidebar (\(f3(before.1)) → \(f3(l)))")
            check(before.0.map { $0 < 0.1 } == true,
                  "parityfavbacking: with the plate off the dark icon's corner is the dark sidebar (\(f3(before.0))): black on black before")
        }

        // 2. Increase Contrast and Reduce Transparency, live.
        var normal: Double?
        run { [self] in
            normal = corner(rowIcon(darkPin), pixels())
            accessibility(contrast: true, transparency: nil)
        }
        wait(0.2)
        run { [self] in
            let f = rowIcon(darkPin)
            let c1 = corner(f, pixels())
            let fill = f?.backingFill.flatMap { NSColor(cgColor: $0) }.map { Self.favBackingColor($0) }
            check(fill.map { $0.alpha == 1 && $0.relativeLuminance > 0.99 } == true && (c1 ?? 0) > (normal ?? 1),
                  "parityfavbacking: Increase Contrast: the plate is opaque white (\(fill?.hexString ?? "-")), brighter in the pixels (\(f3(normal)) → \(f3(c1)))")
            accessibility(contrast: nil, transparency: true)
        }
        wait(0.2)
        run { [self] in
            let fill = rowIcon(darkPin)?.backingFill.flatMap { NSColor(cgColor: $0) }.map { Self.favBackingColor($0) }
            check(fill.map { $0.alpha == 1 && $0.relativeLuminance < 0.99 && $0.relativeLuminance > 0.5 } == true,
                  "parityfavbacking: Reduce Transparency: the plate is opaque light grey (\(fill?.hexString ?? "-"))")
            accessibility(contrast: nil, transparency: nil)
        }
        wait(0.2)
        run { [self] in
            let fill = rowIcon(darkPin)?.backingFill.flatMap { NSColor(cgColor: $0) }.map { Self.favBackingColor($0) }
            check(fill.map { $0.alpha < 1 } == true, "parityfavbacking: both settings off again: the subtle plate is back (\(fill?.hexString ?? "-"))")
        }

        // 3. The Command Bar's rows and a hover card use the same favicon view.
        var visitTab = ""
        run { [self] in
            guard let t = try? c.store.openItem(darkPin, inSpace: sid, activate: true) else { return check(false, "parityfavbacking: the dark page opens") }
            visitTab = t.id
            c.show(t.id, focus: false)
        }
        wait(2.5)
        step { [self] done in
            c.closeCommandBar()
            c.openCommandBar(mode: .newTab)
            c.commandBar?.type("Dark icon")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { done() }
        }
        run { [self] in
            let b = c.commandBar
            let pairs = zip(b?.results ?? [], b?.rowViewsForTesting ?? []).map { r, v in
                (page: r.page ?? "", icons: Self.favBackingIcons(in: v).filter { shows($0) })
            }
            let titles = b?.resultTitles ?? []
            let darkRows = pairs.filter { $0.page.contains("/dark.html") && !$0.icons.isEmpty }
            let others = pairs.filter { !$0.page.contains("/dark.html") }.flatMap(\.icons)
            if darkRows.isEmpty {
                check(false, "parityfavbacking: the Command Bar shows the dark page's row with its icon (rows \(titles), pages \(pairs.map(\.page)))")
            } else {
                check(darkRows.allSatisfy { $0.icons.contains(where: \.showsBacking) } && b?.palette.isDark != false,
                      "parityfavbacking: the Command Bar's row for the dark page backs its icon (\(darkRows.flatMap(\.icons).map(describe)); "
                      + "other rows' icons \(others.map(\.showsBacking)); rows \(titles))")
            }
            c.closeCommandBar()
            if !visitTab.isEmpty { c.forgetPage(visitTab, close: true) }
            let dark = Palette(theme: darkTheme, systemDark: true), light = Palette(theme: lightTheme, systemDark: false)
            guard let darkImage = rowIcon(darkPin)?.shownImage, let lightImage = rowIcon(lightPin)?.shownImage else {
                return check(false, "parityfavbacking: the rows' images for the hover card")
            }
            func card(_ img: NSImage, _ p: Palette) -> [FaviconView] {
                let v = TabPreviewCardView(frame: NSRect(x: 0, y: 0, width: TabPreviewCardView.width, height: 240))
                v.apply(.init(title: "Card", host: "127.0.0.1", favicon: img, faviconURL: nil, pageURL: base + "/dark.html",
                              isPinned: true, isFavorite: false, canSplit: false, canPeek: false), palette: p)
                v.layoutSubtreeIfNeeded()
                return Self.favBackingIcons(in: v).filter { $0.shownImage != nil }
            }
            let cd = card(darkImage, dark), cl = card(lightImage, dark), ld = card(darkImage, light)
            check(!cd.isEmpty && cd.allSatisfy(\.showsBacking) && cl.allSatisfy { !$0.showsBacking } && ld.allSatisfy { !$0.showsBacking },
                  "parityfavbacking: a hover card backs the dark icon on a dark card only (dark/dark \(cd.map(\.showsBacking)), "
                  + "light icon \(cl.map(\.showsBacking)), light card \(ld.map(\.showsBacking)))")
            // A tinted symbol is never backed.
            let sym = FaviconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            sym.set(image: nil, url: nil, fallbackPage: nil, palette: dark, symbol: "globe")
            check(!sym.showsBacking, "parityfavbacking: a symbol icon on a dark surface gets no plate")
            let n = FaviconTone.classified
            for _ in 0..<20 { _ = FaviconTone.isDark(darkImage) }
            check(FaviconTone.classified == n,
                  "parityfavbacking: each icon is classified once (\(classifiedAfterDark) images after the sidebar, none more on 20 asks)")
        }

        // 4. Light Space: nothing changes.
        run { [self] in
            try? c.store.updateSpace(sid) { $0.theme = lightTheme }
            c.reloadAll(animated: false)
        }
        wait(0.8)
        run { [self] in
            let dr = rowIcon(darkPin), lr = rowIcon(lightPin), dt = tileIcon(darkFav), lt = tileIcon(lightFav)
            check(page()?.palette.isDark == false, "parityfavbacking: the Space is light")
            check([dr, lr, dt, lt].allSatisfy { $0?.showsBacking == false } && shows(dr) && shows(dt),
                  "parityfavbacking: light: no plate on any icon (rows \(describe(dr)) / \(describe(lr)); tiles \(describe(dt)) / \(describe(lt)))")
            let rep = pixels()
            let d = corner(dr, rep), l = corner(lr, rep)
            FaviconTone.disabledForTesting = true
            let off = pixels()
            let d0 = corner(dr, off), l0 = corner(lr, off)
            FaviconTone.disabledForTesting = false
            check(d != nil && l != nil && d0 != nil && l0 != nil && abs(d! - d0!) < 0.005 && abs(l! - l0!) < 0.005,
                  "parityfavbacking: light, pixels: both icons' corners are exactly as without favbacking (dark \(f3(d0)) → \(f3(d)), light \(f3(l0)) → \(f3(l)))")
        }
        capture("favbacking-light")
        // Back to dark: the plate returns with the theme.
        run { [self] in
            try? c.store.updateSpace(sid) { $0.theme = darkTheme }
            c.reloadAll(animated: false)
        }
        wait(0.8)
        run { [self] in
            check(rowIcon(darkPin)?.showsBacking == true && rowIcon(lightPin)?.showsBacking == false,
                  "parityfavbacking: dark again: the plate is back on the dark icon only (\(describe(rowIcon(darkPin))))")
            accessibility(contrast: nil, transparency: nil)
            FaviconTone.disabledForTesting = false
            server?.stop()
        }
    }

    static func favBackingColor(_ c: NSColor) -> AircColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return AircColor(red: Double(s.redComponent), green: Double(s.greenComponent), blue: Double(s.blueComponent), alpha: Double(s.alphaComponent))
    }

    /// The favicon views under `v`.
    static func favBackingIcons(in v: NSView) -> [FaviconView] {
        v.subviews.flatMap { s -> [FaviconView] in (s as? FaviconView).map { [$0] } ?? favBackingIcons(in: s) }
    }

    /// The fixture icons, 32 px: a black "T" on transparency, or a white disc.
    static func favBackingPNG(dark: Bool) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        if dark {
            NSColor.black.setFill()
            // Origin bottom-left: the bar at the top, the stem down the middle; the bottom corners stay empty.
            NSBezierPath(rect: NSRect(x: 4, y: 22, width: 24, height: 6)).fill()
            NSBezierPath(rect: NSRect(x: 13, y: 4, width: 6, height: 18)).fill()
        } else {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 9, y: 9, width: 14, height: 14)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
#endif

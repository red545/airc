// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// On-screen checks for things offscreen rendering can't show: the behind-window blur, window shadows and
// corners, and the onboarding expansion. Run through scripts/onscreen.sh, which wraps the gallery in a
// background app (`open -g`), so nothing takes focus. Only this app's own windows are captured
// (CGWindowListCreateImage with our window IDs; no Screen Recording permission needed for them).
import AircDesign
import AppKit
import SwiftUI

typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

/// CGWindowListCreateImage is unavailable to Swift in the macOS 15+ SDK but still works at runtime.
let windowListCreateImage: WindowListCreateImage? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: WindowListCreateImage.self)
}()

enum Capture {
    static let onScreenOnly: UInt32 = 1 << 0
    static let onScreenBelowWindow: UInt32 = 1 << 2
    static let includingWindow: UInt32 = 1 << 3
    static let boundsIgnoreFraming: UInt32 = 1 << 0
    static let bestResolution: UInt32 = 1 << 3
}

@MainActor
final class Onscreen {
    let out: URL
    var log: [String] = []
    var windows: [NSWindow] = []
    let origin: CGPoint

    init(out: URL) {
        self.out = out
        let vf = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        origin = CGPoint(x: vf.minX + 40, y: vf.minY + 40)
    }

    /// Runs the AppKit event loop (not just the run loop): window ordering, including orderOut, is committed there.
    func pump(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let e = NSApp.nextEvent(matching: .any, until: min(until, Date().addingTimeInterval(0.02)), inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
    }

    func note(_ s: String) {
        print(s)
        log.append(s)
    }

    /// Captures one of our windows (with its shadow unless `framing` is false).
    func capture(_ window: NSWindow, framing: Bool = true) -> CGImage? {
        guard let fn = windowListCreateImage else { note("CGWindowListCreateImage not found"); return nil }
        let opts = Capture.bestResolution | (framing ? 0 : Capture.boundsIgnoreFraming)
        return fn(.null, Capture.includingWindow, UInt32(window.windowNumber), opts)?.takeRetainedValue()
    }

    /// Captures a screen rectangle as composited, restricted by the system to windows we may see (ours).
    func captureRect(_ rect: CGRect, below window: NSWindow? = nil) -> CGImage? {
        guard let fn = windowListCreateImage, let screen = NSScreen.screens.first else { return nil }
        // Quartz rects are top-left based.
        let q = CGRect(x: rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        if let window {
            return fn(q, Capture.onScreenBelowWindow | Capture.includingWindow, UInt32(window.windowNumber), Capture.bestResolution)?.takeRetainedValue()
        }
        return fn(q, Capture.onScreenOnly, 0, Capture.bestResolution)?.takeRetainedValue()
    }

    func save(_ image: CGImage?, _ name: String) {
        guard let image else { note("capture failed: \(name)"); return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
        note("wrote \(name).png (\(image.width)×\(image.height))")
    }

    func pixel(_ image: CGImage, x: Int, y: Int) -> AircColor {
        let rep = NSBitmapImageRep(cgImage: image)
        let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .black
        return AircColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }

    func plainWindow(_ frame: CGRect, view: NSView, opaque: Bool) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = opaque
        w.backgroundColor = opaque ? .black : .clear
        w.hasShadow = false
        w.contentView = view
        w.orderFrontRegardless()
        windows.append(w)
        return w
    }

    func closeAll() {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows = []
        pump(0.15)
    }

    /// Our windows the window server still shows.
    func onscreenCount() -> Int {
        let pid = ProcessInfo.processInfo.processIdentifier
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.count
    }

    // MARK: 1. The material's response to the desktop

    /// Puts a solid "desktop" window behind the bare blur material and reads what the material outputs, for
    /// each appearance. This bounds what a busy wallpaper can contribute through the blur.
    func measureMaterial() {
        let desktops: [(String, AircColor)] = [
            ("black", .black()), ("white", .white()), ("grey", AircColor(0x808080)), ("red", AircColor(0xFF0000)),
            ("green", AircColor(0x00FF00)), ("blue", AircColor(0x0000FF)), ("yellow", AircColor(0xFFFF00)),
            ("cyan", AircColor(0x00FFFF)), ("magenta", AircColor(0xFF00FF)),
        ]
        var json: [String: [String: String]] = [:]
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            var row: [String: String] = [:]
            for (name, color) in desktops {
                let frame = CGRect(origin: origin, size: CGSize(width: 160, height: 160))
                let backdrop = NSView(frame: CGRect(origin: .zero, size: frame.size))
                backdrop.wantsLayer = true
                backdrop.layer?.backgroundColor = color.cgColor
                _ = plainWindow(frame, view: backdrop, opaque: true)
                let material = AircMaterialView(frame: CGRect(origin: .zero, size: CGSize(width: 120, height: 120)))
                material.appearance = NSAppearance(named: appearance)
                let top = plainWindow(CGRect(x: frame.minX + 20, y: frame.minY + 20, width: 120, height: 120), view: material, opaque: false)
                pump(0.5)
                if let img = capture(top, framing: false) {
                    let c = pixel(img, x: img.width / 2, y: img.height / 2)
                    row[name] = c.hexString + String(format: " a%.2f L%.3f", c.alpha, c.oklab.l)
                    note("material \(appearanceName) over \(name): \(row[name]!)")
                    if name == "white" || name == "red" { save(img, "material-\(appearanceName)-over-\(name)") }
                }
                closeAll()
            }
            json[appearanceName] = row
        }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("material-response.json"))
        }
    }

    // MARK: 2. Themed windows over a busy wallpaper

    func themedWindows() {
        let wallFrame = CGRect(origin: origin, size: CGSize(width: 1180, height: 700))
        let wallpaper = plainWindow(wallFrame, view: BusyWallpaperView(frame: CGRect(origin: .zero, size: wallFrame.size)), opaque: true)
        let cases: [(String, SpaceTheme, Bool, AircTranslucency, Bool?)] = [
            ("mint-subtle", SpaceTheme.preset("mint")!, false, .subtle, true),
            ("mint-more", SpaceTheme.preset("mint")!, false, .more, true),
            ("mint-off", SpaceTheme.preset("mint")!, false, .off, true),
            ("mint-inactive", SpaceTheme.preset("mint")!, false, .subtle, false),
            ("ocean-subtle", SpaceTheme.preset("ocean")!, true, .subtle, true),
            ("ocean-more", SpaceTheme.preset("ocean")!, true, .more, true),
            ("paper-light-subtle", SpaceTheme.default, false, .subtle, true),
            ("paper-dark-subtle", SpaceTheme.default, true, .subtle, true),
            ("grape-subtle", SpaceTheme.preset("grape")!, true, .subtle, true),
            ("lilac-more", SpaceTheme.preset("lilac")!, false, .more, true),
        ]
        let size = CGSize(width: 340, height: 300)
        for (i, c) in cases.enumerated() {
            let col = i % 5, row = i / 5
            let frame = CGRect(x: wallFrame.minX + 20 + CGFloat(col) * 230, y: wallFrame.maxY - 30 - size.height - CGFloat(row) * 330,
                               width: size.width, height: size.height)
            let r = c.1.resolved(systemIsDark: c.2)
            let bg = SpaceBackgroundView(theme: r, translucency: c.3)
            bg.isWindowActiveOverride = c.4
            let container = NSView(frame: CGRect(origin: .zero, size: size))
            bg.frame = container.bounds
            bg.autoresizingMask = [.width, .height]
            container.addSubview(bg)
            let text = NSHostingView(rootView: SidebarSample(theme: r, label: c.0, underlay: bg.currentUnderlayOpacity))
            text.frame = container.bounds
            container.addSubview(text)
            let w = plainWindow(frame, view: container, opaque: false)
            w.hasShadow = true
            pump(0.4)
            let reread = NSHostingView(rootView: SidebarSample(theme: r, label: c.0, underlay: bg.currentUnderlayOpacity))
            reread.frame = container.bounds
            text.removeFromSuperview()
            container.addSubview(reread)
            pump(0.3)
            save(capture(w, framing: false), "window-\(c.0)")
            note(String(format: "%@: underlay %.2f, desktop fraction %.3f", c.0, bg.currentUnderlayOpacity, r.desktopFraction(underlayOpacity: bg.currentUnderlayOpacity)))
        }
        pump(0.3)
        save(captureRect(wallFrame), "translucency-overview")
        _ = wallpaper
        closeAll()
    }

    // MARK: 3. The floating onboarding window and its expansion

    func floatingWindow() {
        let wallFrame = CGRect(origin: origin, size: CGSize(width: 1240, height: 780))
        _ = plainWindow(wallFrame, view: BusyWallpaperView(frame: CGRect(origin: .zero, size: wallFrame.size), calm: true), opaque: true)
        let theme = SpaceTheme.preset("sky")!.resolved(systemIsDark: false)
        let w = AircFloatingWindow(theme: theme)
        w.background.isWindowActiveOverride = true
        w.setContent(OnboardingStepSample().aircTheme(theme))
        let f = CGRect(x: wallFrame.midX - 380, y: wallFrame.midY - 270 + 20, width: 760, height: 540)
        w.setFrame(f, display: true)
        w.orderFrontRegardless()
        windows.append(w)
        pump(0.8)
        w.invalidateShadow()
        pump(0.3)
        save(capture(w), "floating-onboarding")
        save(captureRect(f.insetBy(dx: -60, dy: -60)), "floating-onboarding-on-desktop")
        note("floating window buttons: close \(w.standardWindowButton(.closeButton) == nil ? "none" : "present")")

        // Expansion into a browser-sized window.
        let target = NSWindow(contentRect: wallFrame.insetBy(dx: 40, dy: 40), styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        target.titlebarAppearsTransparent = true
        target.titleVisibility = .hidden
        let tbg = SpaceBackgroundView(theme: theme, translucency: .subtle)
        tbg.isWindowActiveOverride = true
        let targetContent = NSView(frame: CGRect(origin: .zero, size: target.frame.size))
        tbg.frame = targetContent.bounds
        targetContent.addSubview(tbg)
        let sidebar = NSHostingView(rootView: SidebarSample(theme: theme, label: "Personal", underlay: tbg.currentUnderlayOpacity))
        sidebar.frame = CGRect(x: 0, y: 0, width: 228, height: targetContent.bounds.height - 40)
        targetContent.addSubview(sidebar)
        let page = NSView(frame: CGRect(x: 228, y: 10, width: targetContent.bounds.width - 238, height: targetContent.bounds.height - 20))
        page.wantsLayer = true
        page.layer?.backgroundColor = AircColor(0xFBFAF7).cgColor
        page.layer?.cornerRadius = AircRadius.card
        targetContent.addSubview(page)
        target.contentView = targetContent
        windows.append(target)
        var done = false
        w.expand(into: target, reduceMotion: false) { done = true }
        // A background app's plain orderFront goes behind our own wallpaper (raised with orderFrontRegardless);
        // raise the target and the overlay the same way. In the real app, which is active, this isn't needed.
        target.orderFrontRegardless()
        let overlay = NSApp.windows.first { String(describing: type(of: $0)).contains("ExpansionOverlay") && $0.isVisible }
        overlay?.orderFrontRegardless()
        let start = Date()
        var frame = 0
        for t in [0.06, 0.14, 0.24] {
            pump(max(0, t - Date().timeIntervalSince(start)))
            save(captureRect(wallFrame), "expansion-\(frame)-\(Int(t * 1000))ms")
            if let overlay { save(capture(overlay, framing: false), "expansion-overlay-\(frame)-\(Int(t * 1000))ms") }
            frame += 1
        }
        let deadline = Date().addingTimeInterval(5)
        while !done, Date() < deadline { pump(0.05) }
        pump(0.3)
        save(captureRect(wallFrame), "expansion-end")
        note("expansion finished: \(done)")
        closeAll()
        target.orderOut(nil)
    }

    // MARK: 4. A titled window's corner radius

    func measureWindowCorner() {
        let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: origin.x + 40, y: origin.y + 40), size: CGSize(width: 300, height: 200)),
                         styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemRed.cgColor
        w.contentView = v
        w.orderFrontRegardless()
        windows.append(w)
        pump(0.6)
        guard let img = capture(w, framing: false) else { return }
        save(img, "titled-window-corner")
        let scale = Double(img.width) / 300
        // Walk the top edge from the left until the first mostly opaque pixel.
        var firstOpaque = 0
        for x in 0..<img.width where pixel(img, x: x, y: 0).alpha > 0.5 { firstOpaque = x; break }
        // Along the left edge from the top as well.
        var firstOpaqueY = 0
        for y in 0..<img.height where pixel(img, x: 0, y: y).alpha > 0.5 { firstOpaqueY = y; break }
        note(String(format: "titled window: scale %.0f, top edge opaque from x=%d px, left edge from y=%d px ⇒ radius ≈ %.1f pt (continuous corners extend further than circular)",
                    scale, firstOpaque, firstOpaqueY, Double(max(firstOpaque, firstOpaqueY)) / scale))
        closeAll()
    }

    /// Visual review #5 on screen: Mint sidebar labels in `text`, `textSecondary`, `textTertiary` (stock NSTextField,
    /// a full-block glyph so the darkest pixel is fully covered), captured by the window server and offscreen.
    func sidebarInk() {
        let r = SpaceTheme.preset("mint")!.resolved(systemIsDark: false)
        let bg = r.background
        let size = NSSize(width: 330, height: 70)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = bg.cgColor
        let inks = [("text", r.text), ("textSecondary", r.textSecondary), ("textTertiary", r.textTertiary)]
        for (i, (_, ink)) in inks.enumerated() {
            let l = NSTextField(labelWithString: "█")
            l.font = .systemFont(ofSize: 40)
            l.textColor = ink.nsColor
            l.frame = NSRect(x: 10 + CGFloat(i) * 105, y: 8, width: 100, height: 54)
            root.addSubview(l)
        }
        let w = plainWindow(CGRect(x: 120, y: 120, width: size.width, height: size.height), view: root, opaque: true)
        pump(0.6)
        func alphas(_ img: CGImage, scale: Int) -> [Double] {
            (0..<3).map { i in
                var best = AircColor.white()
                for y in stride(from: 10 * scale, to: 60 * scale, by: 2) {
                    for x in stride(from: (14 + i * 105) * scale, to: (100 + i * 105) * scale, by: 2) where x < img.width && y < img.height {
                        let c = pixel(img, x: x, y: y)
                        if c.green < best.green { best = c }
                    }
                }
                return (bg.green - best.green) / (bg.green - AircColor.inkLight.green)
            }
        }
        let screen = capture(w, framing: false)
        save(screen, "ink-onscreen")
        let scale = Int(w.backingScaleFactor)
        if let screen {
            let a = alphas(screen, scale: scale)
            note("ink on screen (window server): " + zip(inks, a).map { "\($0.0.0) token \(String(format: "%.2f", $0.0.1.alpha)) → \(String(format: "%.2f", $0.1))" }.joined(separator: ", "))
        }
        if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: rep)
            note("ink via cacheDisplay: " + alphas(rep.cgImage!, scale: scale).map { String(format: "%.2f", $0) }.joined(separator: ", "))
        }
        if let rep = AircSnapshot.bitmap(of: root) {
            note("ink via AircSnapshot: " + alphas(rep.cgImage!, scale: scale).map { String(format: "%.2f", $0) }.joined(separator: ", "))
        }
        closeAll()
    }

    func run() {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSApp.finishLaunching()
        if CommandLine.arguments.contains("ink") {
            sidebarInk()
            try? log.joined(separator: "\n").write(to: out.appendingPathComponent("onscreen.log"), atomically: true, encoding: .utf8)
            return
        }
        if CommandLine.arguments.contains("floating") {
            floatingWindow()
            try? log.joined(separator: "\n").write(to: out.appendingPathComponent("onscreen.log"), atomically: true, encoding: .utf8)
            return
        }
        note("screen \(NSScreen.main?.frame ?? .zero) scale \(NSScreen.main?.backingScaleFactor ?? 0); reduce transparency \(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)")
        measureMaterial()
        note("after material: \(onscreenCount()) windows on screen")
        measureWindowCorner()
        themedWindows()
        note("after themed: \(onscreenCount()) windows on screen")
        floatingWindow()
        note("after floating: \(onscreenCount()) windows on screen")
        sidebarInk()
        try? log.joined(separator: "\n").write(to: out.appendingPathComponent("onscreen.log"), atomically: true, encoding: .utf8)
    }
}

/// A deliberately busy, high-contrast synthetic wallpaper: saturated diagonal bands, white and black blobs,
/// and lines of text. The worst thing a desktop can put behind a translucent window.
final class BusyWallpaperView: NSView {
    let calm: Bool

    init(frame: NSRect, calm: Bool = false) {
        self.calm = calm
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if calm {
            // A soft dusk gradient with a few large shapes, like a stock wallpaper.
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
                AircColor(0x1E2A5A).cgColor, AircColor(0x6A3D8F).cgColor, AircColor(0xE07A5F).cgColor, AircColor(0xF2C57C).cgColor,
            ] as CFArray, locations: [0, 0.4, 0.75, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: bounds.maxX, y: 0), options: [])
            for (x, y, r, c) in [(0.2, 0.3, 0.35, AircColor(0x2E86AB, alpha: 0.55)), (0.75, 0.7, 0.3, AircColor(0xF6AE2D, alpha: 0.5)),
                                 (0.55, 0.15, 0.25, AircColor(0x33658A, alpha: 0.6))] {
                ctx.setFillColor(c.cgColor)
                let rr = r * bounds.height
                ctx.fillEllipse(in: CGRect(x: x * bounds.width - rr, y: y * bounds.height - rr, width: rr * 2, height: rr * 2))
            }
            return
        }
        let colors: [AircColor] = [AircColor(0xFF2D55), AircColor(0xFFCC00), AircColor(0x34C759), AircColor(0x007AFF), AircColor(0xAF52DE), .white(), .black()]
        ctx.saveGState()
        ctx.rotate(by: -.pi / 7)
        for i in -10..<40 {
            ctx.setFillColor(colors[(i + 20) % colors.count].cgColor)
            ctx.fill(CGRect(x: CGFloat(i) * 46 - 400, y: -600, width: 46, height: 2400))
        }
        ctx.restoreGState()
        for (x, y, r, c) in [(0.15, 0.25, 90.0, AircColor.white()), (0.62, 0.62, 120.0, AircColor.black()), (0.85, 0.2, 70.0, AircColor.white())] {
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: CGRect(x: x * bounds.width - r, y: y * bounds.height - r, width: r * 2, height: r * 2))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .heavy), .foregroundColor: NSColor.black]
        for i in 0..<12 {
            ("Busy desktop · text behind the window · " as NSString).draw(at: CGPoint(x: 10, y: CGFloat(i) * 60 + 8), withAttributes: attrs)
        }
    }
}

/// A slice of sidebar on a theme: the ink tokens at their real sizes, a selected and a hovered row.
struct SidebarSample: View {
    let theme: ResolvedTheme
    let label: String
    let underlay: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).aircFont(AircFont.spaceName).foregroundStyle(theme.textSecondary.color).padding(.leading, 18).frame(height: 36)
            row("Pinned tab title", fill: .clear)
            row("Selected tab", fill: theme.selectedFill, shadow: theme.selectedHasShadow)
            row("Hovered tab", fill: theme.hoverFill)
            HStack {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                Text("New Tab").aircFont(AircFont.row)
            }
            .foregroundStyle(theme.textTertiary.color).padding(.leading, 18).frame(height: 36)
            Spacer()
            Text(String(format: "underlay %.2f · see-through %.0f %%", underlay, theme.desktopFraction(underlayOpacity: underlay) * 100))
                .aircFont(AircFont.mono).foregroundStyle(theme.textSecondary.color).padding(14)
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func row(_ title: String, fill: AircColor, shadow: Bool = false) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4).fill(theme.accent.color).frame(width: 16, height: 16).padding(.leading, 9)
            Text(title).aircFont(AircFont.row).foregroundStyle(theme.text.color).padding(.leading, 10)
            Spacer()
        }
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(fill.color).aircShadow(shadow ? .rowSelected : .none))
        .padding(.horizontal, 8)
        .frame(height: 41)
    }
}

/// Onboarding step 2 in the floating window: the live sidebar preview on the left, the card on the right.
struct OnboardingStepSample: View {
    @Environment(\.aircTheme) private var theme

    var body: some View {
        AircOnboardingPage(step: 2, of: 5, title: "Bring your Arc with you.",
                           subtitle: "We found Arc on this Mac. Your Spaces come over as they are, profiles and all.",
                           drawsBackground: false) {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(theme.fieldFill.color)
                    .overlay(Text("papertrail.blog").aircFont(AircFont.urlField).foregroundStyle(theme.textSecondary.color).padding(.leading, 12), alignment: .leading)
                    .frame(height: 36).padding(.horizontal, 8).padding(.top, 46)
                HStack(spacing: 8) {
                    ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: AircRadius.tile, style: .continuous).fill(theme.tileFill.color).frame(height: 47) }
                }
                .padding(.horizontal, 8).padding(.top, 8)
                Text("🏡  Personal").aircFont(AircFont.spaceName).foregroundStyle(theme.textSecondary.color).padding(.leading, 16).frame(height: 41)
                ForEach(["Budget 2027", "Lisbon, March", "papertrail/web", "The case for a calmer browser"], id: \.self) { t in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 4).fill(theme.accent.color.opacity(0.7)).frame(width: 16, height: 16)
                        Text(t).aircFont(AircFont.row).foregroundStyle(theme.text.color).lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, 17).frame(height: 41)
                }
            }
        } content: {
            AircGroup {
                AircToggleRow("Spaces, pinned tabs and folders", isOn: .constant(true))
                AircToggleRow("Favorites, per profile", isOn: .constant(true))
                AircToggleRow("Logins and saved passwords", subtitle: "macOS asks for your Mac password once.", isOn: .constant(true))
            }
        } actions: {
            Button("Start fresh") {}.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            Button("Import everything") {}.buttonStyle(.airc(.primary, size: .large))
        }
    }
}

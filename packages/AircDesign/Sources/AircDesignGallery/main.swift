// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Renders AircDesign components and Space themes to PNGs, offscreen (no window is shown, no screen
// recording needed). Usage: swift run aircdesign-gallery [output-dir]
import AircDesign
import AppKit
import SwiftUI
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// `aircdesign-gallery --html in.html out.png WIDTH HEIGHT [--transparent]` snapshots a mockup with WebKit (real SF
// fonts) at 2×. With --transparent the page background stays clear (app icons).
if CommandLine.arguments.count >= 6, CommandLine.arguments[1] == "--html" {
    let a = CommandLine.arguments
    snapshotHTML(URL(fileURLWithPath: a[2]), to: URL(fileURLWithPath: a[3]), width: Double(a[4])!, height: Double(a[5])!,
                 transparent: a.contains("--transparent"))
    exit(0)
}

// `aircdesign-gallery --onscreen out-dir` shows small test windows on screen (run via scripts/onscreen.sh).
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--onscreen" {
    app.setActivationPolicy(.accessory)
    Onscreen(out: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)).run()
    exit(0)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/gallery", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

@MainActor
func snapshot<V: View>(_ name: String, size: CGSize, _ view: V) {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap for \(name)") }
    host.cacheDisplay(in: host.bounds, to: rep)
    let url = outDir.appendingPathComponent("\(name).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}

@MainActor
func snapshotLayer(_ name: String, view: NSView, size: CGSize) {
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    view.frame = CGRect(origin: .zero, size: size)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    view.layer?.layoutIfNeeded()
    view.layer?.sublayers?.forEach { $0.layoutIfNeeded() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    let scale: CGFloat = 2
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    view.layer!.render(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let url = outDir.appendingPathComponent("\(name).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path) (\(w)×\(h))")
}

/// An AppKit view captured the way the screen shows it (labels once: AircSnapshot).
@MainActor
func snapshotView(_ name: String, view: NSView) {
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    view.displayIfNeeded()
    guard let rep = AircSnapshot.bitmap(of: view) else { fatalError("no bitmap for \(name)") }
    let url = outDir.appendingPathComponent("\(name).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}

@MainActor
func snapshotHTML(_ file: URL, to out: URL, width: Double, height: Double, transparent: Bool = false) {
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height))
    if transparent { web.setValue(false, forKey: "drawsBackground") }
    let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = web
    if transparent {
        window.isOpaque = false
        window.backgroundColor = .clear
    }
    web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    let deadline = Date().addingTimeInterval(20)
    while web.isLoading, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    // Wait until every image (data URIs included) has decoded.
    var imagesReady = false
    while !imagesReady, Date() < deadline {
        var answered = false
        web.evaluateJavaScript("Array.from(document.images).every(i => i.complete && i.naturalWidth > 0)") { result, _ in
            imagesReady = (result as? Bool) ?? true
            answered = true
        }
        while !answered, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        if !imagesReady { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let config = WKSnapshotConfiguration()
    config.rect = web.bounds
    var done = false
    web.takeSnapshot(with: config) { image, error in
        if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out)
            print("wrote \(out.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        } else {
            print("snapshot failed: \(String(describing: error))")
        }
        done = true
    }
    while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

// MARK: - Component sheet

struct ComponentSheet: View {
    let theme: ResolvedTheme
    @State private var name = ""
    @State private var filled = "Work"
    @State private var a = true
    @State private var b = false
    @State private var c = true

    var body: some View {
        ZStack {
            SpaceBackground(theme)
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text("AircDesign").aircFont(AircFont.title2).foregroundStyle(theme.surfaceText.color)
                    Text(theme.isDark ? "dark" : "light").aircFont(AircFont.mono).foregroundStyle(theme.surfaceTextTertiary.color)
                    Spacer()
                    AircStepIndicator(step: 2, of: 5)
                }
                section("Buttons") {
                    HStack(spacing: 10) {
                        Button("Create Space") {}.buttonStyle(.airc(.primary, size: .large))
                        Button("Cancel") {}.buttonStyle(.airc(.secondary, size: .large))
                        Button("Skip for now") {}.buttonStyle(.airc(.plain, size: .large))
                        Button("Delete Space") {}.buttonStyle(.airc(.destructive, size: .large))
                    }
                    HStack(spacing: 10) {
                        Button("Continue") {}.buttonStyle(.aircPrimary)
                        Button("Choose…") {}.buttonStyle(.aircSecondary)
                        Button("Back") {}.buttonStyle(.aircPlain)
                        Button("Disabled") {}.buttonStyle(.aircPrimary).disabled(true)
                        Button { } label: { Label("Import", systemImage: "square.and.arrow.down") }.buttonStyle(.airc(.secondary, size: .small))
                        Button("Undo") {}.buttonStyle(.airc(.primary, size: .small))
                    }
                }
                section("Text fields") {
                    HStack(alignment: .top, spacing: 14) {
                        AircTextField("Space name", text: $name, placeholder: "Work", icon: "square.grid.2x2")
                        AircTextField("Profile", text: $filled, message: "Its own logins, history and extensions.")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Focused").aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.surfaceTextSecondary.color)
                            Text("personal|").aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .background(AircFieldBackground(isFocused: true))
                        }
                    }
                }
                section("Toggles") {
                    AircGroup {
                        AircToggleRow("Archive tabs after 12 hours", subtitle: "Tabs you haven't viewed move to the Archive.", icon: "archivebox", isOn: $a)
                        AircToggleRow("Show the sidebar on the right", icon: "sidebar.right", isOn: $b)
                        AircToggleRow("Haptics while dragging", isOn: $c)
                    }
                }
                section("Toast") {
                    HStack(spacing: 14) {
                        AircToast("Copied Current URL", systemImage: "link")
                        AircToast("Space deleted", systemImage: "trash", actionTitle: "Undo") {}
                    }
                }
            }
            .padding(32)
            .frame(width: 760)
            .background(RoundedRectangle(cornerRadius: AircRadius.panel, style: .continuous).fill(theme.surface.color))
            .overlay(RoundedRectangle(cornerRadius: AircRadius.panel, style: .continuous).inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
            .aircShadow(.panel)
        }
        .aircTheme(theme)
    }

    @ViewBuilder func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
            content()
        }
    }
}

// MARK: - Theme sheet: the window, drawn with tokens only

struct ThemeSheet: View {
    let name: String
    let theme: ResolvedTheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpaceBackground(theme)
            HStack(spacing: 0) {
                sidebar.frame(width: AircMetrics.Sidebar.defaultWidth)
                page
                    .padding(.vertical, AircMetrics.Window.cardInset)
                    .padding(.trailing, AircMetrics.Window.cardInset)
                    .padding(.leading, AircMetrics.Window.cardInset - AircMetrics.Window.cardInset)
            }
        }
        .aircTheme(theme)
    }

    var sidebar: some View {
        let inset = AircMetrics.Sidebar.inset
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([AircColor(0xFF5F57), AircColor(0xFEBC2E), AircColor(0x28C840)], id: \.self) { c in
                    Circle().fill(c.color).frame(width: 12, height: 12)
                }
                Spacer()
                ForEach(["chevron.left", "chevron.right", "arrow.clockwise"], id: \.self) { s in
                    Image(systemName: s).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary.color).frame(width: 28)
                }
            }
            .padding(.leading, 14).padding(.trailing, 6).frame(height: 46)
            HStack {
                Text("airc.dev").aircFont(AircFont.urlField).foregroundStyle(theme.textSecondary.color)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: AircMetrics.Sidebar.urlFieldHeight)
            .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(theme.fieldFill.color))
            .padding(.horizontal, inset)
            HStack(spacing: AircMetrics.Favorites.gap) {
                ForEach(["envelope.fill", "calendar", "message.fill"], id: \.self) { s in
                    RoundedRectangle(cornerRadius: AircRadius.tile, style: .continuous).fill(theme.tileFill.color)
                        .frame(height: AircMetrics.Favorites.tileHeight)
                        .overlay(Image(systemName: s).font(.system(size: 16)).foregroundStyle(theme.text.color))
                }
            }
            .padding(.horizontal, inset).padding(.top, 10)
            Text(name).aircFont(AircFont.spaceName).foregroundStyle(theme.textSecondary.color)
                .padding(.leading, 18).frame(height: 40)
            row("Roadmap", selected: false)
            row("Design review notes", selected: false)
            Rectangle().fill(theme.separator.color).frame(height: 0.5).padding(.horizontal, AircMetrics.Divider.inset).padding(.vertical, 8)
            HStack(spacing: 0) {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 18).padding(.leading, AircMetrics.Row.faviconX - inset)
                Text("New Tab").aircFont(AircFont.row).padding(.leading, AircMetrics.Row.titleX - AircMetrics.Row.faviconX - 18)
                Spacer()
            }
            .foregroundStyle(theme.textTertiary.color).frame(height: 36).padding(.horizontal, inset)
            row("AircDesign — tokens", selected: true)
            row("Arc behaviour spec", selected: false)
            row("Hover state", selected: false, hovered: true)
            Spacer()
            HStack {
                Image(systemName: "archivebox").foregroundStyle(theme.textSecondary.color)
                Spacer()
                ForEach(0..<3) { i in Circle().fill(theme.text.opacity(i == 0 ? 1 : 0.35).color).frame(width: 6, height: 6) }
                Spacer()
                Image(systemName: "plus").foregroundStyle(theme.textSecondary.color)
            }
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 16).frame(height: AircMetrics.Footer.height)
        }
    }

    func row(_ title: String, selected: Bool, hovered: Bool = false) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4).fill(theme.accent.color).frame(width: 16, height: 16)
                .padding(.leading, AircMetrics.Row.faviconX - AircMetrics.Sidebar.inset)
            Text(title).aircFont(AircFont.row).foregroundStyle(theme.text.color).lineLimit(1)
                .padding(.leading, AircMetrics.Row.titleX - AircMetrics.Row.faviconX - 16)
            Spacer()
        }
        .frame(height: AircMetrics.Row.plateHeight)
        .background(
            RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous)
                .fill((selected ? theme.selectedFill : hovered ? theme.hoverFill : .clear).color)
                .aircShadow(selected && theme.selectedHasShadow ? .rowSelected : .none)
        )
        .padding(.horizontal, AircMetrics.Sidebar.inset)
        .frame(height: AircMetrics.Row.pitch)
    }

    var page: some View {
        let shape = RoundedRectangle(cornerRadius: AircMetrics.Window.cardRadius)
        return VStack(alignment: .leading, spacing: 14) {
            Text(name).aircFont(AircFont.display).foregroundStyle(AircColor.inkLight.alpha(0.9).color)
            Text("The colour is the room; the page is the object.").aircFont(AircFont.lead).foregroundStyle(AircColor.inkLight.alpha(0.6).color)
            HStack(spacing: 8) {
                ForEach(Array(theme.gradient.enumerated()).filter { $0.offset % 3 == 0 }, id: \.offset) { _, stop in
                    RoundedRectangle(cornerRadius: 6).fill(stop.color.color).frame(width: 34, height: 34)
                }
                RoundedRectangle(cornerRadius: 6).fill(theme.accent.color).frame(width: 34, height: 34)
                    .overlay(Text("Aa").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.onAccent.color))
            }
            VStack(alignment: .leading, spacing: 4) {
                stat("text", theme.text.contrast(on: theme.background))
                stat("text on selected", theme.text.contrast(on: theme.selectedFill.over(theme.background)))
                stat("secondary", theme.textSecondary.contrast(on: theme.background))
                stat("tertiary", theme.textTertiary.contrast(on: theme.background))
                stat("label on accent", theme.onAccent.contrast(on: theme.accent))
                Text(String(format: "layer opacity %.3f · accent %@", theme.layerOpacity, theme.accent.hexString))
                    .aircFont(AircFont.mono).foregroundStyle(AircColor.inkLight.alpha(0.5).color)
            }
            Spacer()
            AircToast("Copied Current URL", systemImage: "link")
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Color.white))
        .overlay(shape.inset(by: 0.25).stroke(AircColor.black(0.08).color, lineWidth: 0.5))
        .aircShadow(theme.isDark ? .cardDark : .card)
    }

    func stat(_ label: String, _ v: Double) -> some View {
        Text(String(format: "%-18@ %5.2f : 1", label as NSString, v))
            .aircFont(AircFont.mono).foregroundStyle(AircColor.inkLight.alpha(0.7).color)
    }
}

struct PresetGrid: View {
    var body: some View {
        let cols = Array(repeating: GridItem(.fixed(250), spacing: 14), count: 4)
        LazyVGrid(columns: cols, spacing: 14) {
            ForEach(SpaceTheme.presets) { p in
                let r = p.theme.resolved(systemIsDark: false)
                ZStack(alignment: .bottomLeading) {
                    SpaceBackground(r)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.name).aircFont(AircFont.title3).foregroundStyle(r.text.color)
                        Text("\(p.theme.colors.count) colour\(p.theme.colors.count == 1 ? "" : "s") · \(r.isDark ? "dark" : "light")")
                            .aircFont(AircFont.mono).foregroundStyle(r.textSecondary.color)
                    }
                    .padding(14)
                    Capsule().fill(r.accent.color).frame(width: 28, height: 8).padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .frame(width: 250, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(20)
        .background(AircColor.Stone.s100.color)
    }
}

struct OnboardingSample: View {
    let theme: ResolvedTheme
    @State private var name = "Personal"

    var body: some View {
        AircOnboardingPage(step: 4, of: 5, title: "Make it yours.",
                           subtitle: "Pick a colour for each Space. The window behind re-tints as you choose.") {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    ForEach(SpaceTheme.presets.prefix(8)) { p in
                        let r = p.theme.resolved(systemIsDark: false)
                        SpaceBackground(r).frame(width: 52, height: 52).clipShape(Circle())
                            .overlay(Circle().inset(by: -3).stroke((p.id == "sky" ? theme.accent : .clear).color, lineWidth: 2))
                    }
                }
                AircTextField("Space name", text: $name, icon: "face.smiling")
            }
        } actions: {
            Button("Back") {}.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            Button("Skip") {}.buttonStyle(.airc(.secondary, size: .large))
            Button("Continue") {}.buttonStyle(.airc(.primary, size: .large))
        }
        .aircTheme(theme)
    }
}

// MARK: - Resolved themes as CSS values (feeds docs/design/mockups/build.py)

func css(_ c: AircColor) -> String {
    String(format: "rgba(%d, %d, %d, %.3f)", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()), Int((c.blue * 255).rounded()), c.alpha)
}

func exportThemes() {
    var out: [String: [String: [String: Any]]] = [:]
    for p in SpaceTheme.presets {
        var modes: [String: [String: Any]] = [:]
        for (mode, dark) in [("light", false), ("dark", true)] {
            let r = p.theme.resolved(systemIsDark: dark)
            modes[mode] = [
                "isDark": r.isDark, "layerOpacity": r.layerOpacity, "grain": r.grainOpacity(),
                "colors": p.theme.colors.map { $0.hexString }, "underlay": css(r.underlay), "background": css(r.background),
                "text": css(r.text), "textSecondary": css(r.textSecondary), "textTertiary": css(r.textTertiary), "textDisabled": css(r.textDisabled),
                "hoverFill": css(r.hoverFill), "pressedFill": css(r.pressedFill), "selectedFill": css(r.selectedFill), "selectedHasShadow": r.selectedHasShadow,
                "tileFill": css(r.tileFill), "tileHoverFill": css(r.tileHoverFill), "fieldFill": css(r.fieldFill), "separator": css(r.separator),
                "surface": css(r.surface), "surfaceText": css(r.surfaceText), "surfaceTextSecondary": css(r.surfaceTextSecondary),
                "surfaceTextTertiary": css(r.surfaceTextTertiary), "surfaceBorder": css(r.surfaceBorder), "surfaceHover": css(r.surfaceHover),
                "surfaceSelected": css(r.surfaceSelected), "inlineCompletionText": css(r.inlineCompletionText),
                "inlineCompletionHighlight": css(r.inlineCompletionHighlight), "accent": css(r.accent), "onAccent": css(r.onAccent), "focusRing": css(r.focusRing),
                "gradient": r.gradient.map { ["color": css($0.color), "location": $0.location] },
                "overlay": r.overlay.map(css) ?? NSNull(),
                "underlaySubtle": r.underlayOpacity(for: .subtle), "underlayMore": r.underlayOpacity(for: .more),
                "materialTint": css(AircTranslucency.materialTint(isDark: r.isDark)),
                "materialPassThrough": AircTranslucency.materialPassThrough,
                "inactiveText": css(r.forWindow(isActive: false).text), "inactiveTextSecondary": css(r.forWindow(isActive: false).textSecondary),
            ]
        }
        out[p.id] = modes
    }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: outDir.appendingPathComponent("resolved-themes.json"))
    print("wrote resolved-themes.json")
}

// MARK: - Run

exportThemes()

let light = SpaceTheme.default.resolved(systemIsDark: false)
let dark = SpaceTheme.default.resolved(systemIsDark: true)
snapshot("components-light", size: CGSize(width: 900, height: 760), ComponentSheet(theme: light))
snapshot("components-dark", size: CGSize(width: 900, height: 760), ComponentSheet(theme: dark))
for id in ["mint", "ocean", "grape", "lemon"] {
    let t = SpaceTheme.preset(id)!.resolved(systemIsDark: false)
    snapshot("theme-\(id)", size: CGSize(width: 960, height: 600), ThemeSheet(name: SpaceTheme.presets.first { $0.id == id }!.name, theme: t))
}
snapshot("presets", size: CGSize(width: 1082, height: 532), PresetGrid())
snapshot("onboarding", size: AircMetrics.Onboarding.windowSize, OnboardingSample(theme: SpaceTheme.preset("sky")!.resolved(systemIsDark: false)))
snapshot("onboarding-import", size: AircMetrics.Onboarding.windowSize,
         ZStack { SpaceBackground(SpaceTheme.preset("sky")!.resolved(systemIsDark: false)); OnboardingStepSample() }
             .aircTheme(SpaceTheme.preset("sky")!.resolved(systemIsDark: false)))
snapshot("profiles", size: CGSize(width: 1260, height: 960), ProfilesSheet())
snapshot("pass4-light", size: CGSize(width: 1300, height: 748), Pass4Sheet(dark: false))
snapshot("pass4-dark", size: CGSize(width: 1300, height: 748), Pass4Sheet(dark: true))
for dark in [false, true] {
    snapshotView("pass4-appkit-\(dark ? "dark" : "light")", view: pass4AppKitSheet(dark: dark))
}
snapshotLayer("appkit-background-grape", view: SpaceBackgroundView(theme: SpaceTheme.preset("grape")!.resolved(systemIsDark: true)), size: CGSize(width: 720, height: 450))
let inactive = SpaceBackgroundView(theme: SpaceTheme.preset("sky")!.resolved(systemIsDark: false))
inactive.isWindowActiveOverride = false
snapshotLayer("appkit-background-sky-inactive", view: inactive, size: CGSize(width: 720, height: 450))
print("done")

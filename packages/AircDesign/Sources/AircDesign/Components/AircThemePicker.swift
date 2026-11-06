// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import SwiftUI

// Arc's theme picker (Arc ref §4.1; docs/design.md §7 "Theme picker"; mockup profiles-theme-picker.png): a
// popover beside the Create a Space card or the sidebar, 357 × 509, radius 20. Everything updates the window live.

/// The geometry of the colour field: a disc of radius `radius` centred in a square. Hue is the angle, clockwise
/// from the right; lightness grows from 0.12 at the centre to 0.92 at the edge; saturation is 1 (Arc).
public struct AircColorFieldGeometry: Sendable {
    public var radius: CGFloat
    public var center: CGPoint

    public static let lightnessRange: ClosedRange<Double> = 0.12...0.92

    public init(side: CGFloat = AircMetrics.ThemePicker.field) {
        radius = side / 2 - 10
        center = CGPoint(x: side / 2, y: side / 2)
    }

    /// The colour under a point (y grows downward). Points outside the disc clamp to its edge.
    public func color(at p: CGPoint) -> AircColor {
        let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
        let r = min(1, (dx * dx + dy * dy).squareRoot() / Double(radius))
        var hue = atan2(dy, dx) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let l = Self.lightnessRange.lowerBound + (Self.lightnessRange.upperBound - Self.lightnessRange.lowerBound) * r
        return AircColor(hue: hue, saturation: 1, lightness: l)
    }

    /// Where a colour sits (its hue and lightness; saturation is ignored).
    public func point(for color: AircColor) -> CGPoint {
        let (h, _, l) = color.hsl
        let lr = Self.lightnessRange
        let r = min(1, max(0, (l - lr.lowerBound) / (lr.upperBound - lr.lowerBound))) * Double(radius)
        let a = h * 2 * .pi
        return CGPoint(x: center.x + CGFloat(r * cos(a)), y: center.y + CGFloat(r * sin(a)))
    }

    /// Hues for 1–3 colours placed from a first one: the second is the complement, the third two sit at +150°
    /// and +210° (Arc).
    public static func companions(of first: AircColor, count: Int) -> [AircColor] {
        let (h, s, l) = first.hsl
        let offsets: [Double] = switch count {
        case 2: [0, AircMetrics.ThemePicker.secondHueOffset]
        case 3: [0, AircMetrics.ThemePicker.thirdHueOffsets.0, AircMetrics.ThemePicker.thirdHueOffsets.1]
        default: [0]
        }
        return offsets.map { AircColor(hue: (h + $0 / 360).truncatingRemainder(dividingBy: 1), saturation: max(s, 0.6), lightness: l) }
    }
}

extension AircColor {
    /// sRGB from HSL (all 0…1).
    public init(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
        func f(_ n: Double) -> Double {
            let k = (n + hue * 12).truncatingRemainder(dividingBy: 12)
            let a = saturation * min(lightness, 1 - lightness)
            return lightness - a * max(-1, min(k - 3, 9 - k, 1))
        }
        self.init(red: f(0), green: f(8), blue: f(4), alpha: alpha)
    }

    /// Hue, saturation and lightness (0…1).
    public var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let mx = max(red, green, blue), mn = min(red, green, blue)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        switch mx {
        case red: h = (green - blue) / d + (green < blue ? 6 : 0)
        case green: h = (blue - red) / d + 2
        default: h = (red - green) / d + 4
        }
        h /= 6
        return (h, s, l)
    }
}

/// The colour field: a grid of dots, each in the colour at its point, with 1–3 handles. The main handle is 44 pt
/// with a 3 pt white ring, the others 26 pt; a pressed handle grows (48 / 28). Dragging the main handle moves all
/// of them together; the others move alone. Empty, it reads "Tap to pick a color for this space".
public struct AircColorField: View {
    @Binding private var colors: [AircColor]
    private let side: CGFloat
    private let onEditingEnded: (() -> Void)?
    @State private var dragging: Int?
    @State private var dragStart: [CGPoint] = []
    @Environment(\.aircTheme) private var theme

    public init(colors: Binding<[AircColor]>, side: CGFloat = AircMetrics.ThemePicker.field, onEditingEnded: (() -> Void)? = nil) {
        _colors = colors
        self.side = side
        self.onEditingEnded = onEditingEnded
    }

    public var body: some View {
        let g = AircColorFieldGeometry(side: side)
        let m = AircMetrics.ThemePicker.self
        let points = colors.prefix(SpaceTheme.maxColors).map(g.point(for:))
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surfaceHover.color)
            Canvas { ctx, _ in
                let pitch: CGFloat = 12
                var y = -g.radius
                while y <= g.radius {
                    var x = -g.radius
                    while x <= g.radius {
                        let p = CGPoint(x: g.center.x + x, y: g.center.y + y)
                        if x * x + y * y <= g.radius * g.radius {
                            let near = points.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? .infinity
                            let r = 3 + 1.6 * max(0, 1 - near / 60)
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(g.color(at: p).color))
                        }
                        x += pitch
                    }
                    y += pitch
                }
            }
            if points.count > 1 {
                Path { p in
                    for q in points.dropFirst() { p.move(to: points[0]); p.addLine(to: q) }
                }
                .stroke(Color.white.opacity(0.75), lineWidth: 2)
                .shadow(color: .black.opacity(0.25), radius: 1)
            }
            ForEach(Array(points.enumerated()).reversed(), id: \.offset) { i, p in
                let base = i == 0 ? m.mainHandle : m.handle
                let size = dragging == i ? (i == 0 ? m.handlePressed.main : m.handlePressed.other) : base
                Circle().fill(colors[i].color)
                    .frame(width: size, height: size)
                    .overlay(Circle().inset(by: -m.handleRing / 2).stroke(Color.white, lineWidth: m.handleRing))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .position(p)
                    .aircAnimation(AircSpring.toggle, value: dragging)
            }
            if colors.isEmpty {
                Text("Tap to pick a color for this space").aircFont(AircFont.callout.weight(.medium))
                    .foregroundStyle(theme.surfaceTextSecondary.color)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(theme.surface.alpha(0.9).color))
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            if dragging == nil {
                dragStart = points
                let hit = points.enumerated().min { hypot($0.element.x - v.startLocation.x, $0.element.y - v.startLocation.y) < hypot($1.element.x - v.startLocation.x, $1.element.y - v.startLocation.y) }
                if let hit, hypot(hit.element.x - v.startLocation.x, hit.element.y - v.startLocation.y) < m.mainHandle {
                    dragging = hit.offset
                } else {
                    // A tap on empty field moves the main colour there (or picks the first one).
                    if colors.isEmpty { colors = [g.color(at: v.location)] } else { colors[0] = g.color(at: v.location) }
                    dragStart = colors.map(g.point(for:))
                    dragging = 0
                }
            }
            guard let i = dragging else { return }
            let d = CGSize(width: v.location.x - v.startLocation.x, height: v.location.y - v.startLocation.y)
            if i == 0 {
                colors = dragStart.map { g.color(at: CGPoint(x: $0.x + d.width, y: $0.y + d.height)) }
            } else if i < colors.count {
                colors[i] = g.color(at: CGPoint(x: dragStart[i].x + d.width, y: dragStart[i].y + d.height))
            }
        }.onEnded { _ in
            dragging = nil
            onEditingEnded?()
        })
        .accessibilityElement()
        .accessibilityLabel("Theme colours")
        .accessibilityValue(colors.map(\.hexString).joined(separator: ", "))
    }
}

/// Arc's intensity "wave": a sine track (7 periods), coloured up to the knob.
public struct AircIntensityWave: View {
    @Binding private var value: Double
    private let tint: AircColor?
    @Environment(\.aircTheme) private var theme

    public init(value: Binding<Double>, tint: AircColor? = nil) {
        _value = value
        self.tint = tint
    }

    private func wave(width: CGFloat, height: CGFloat, upTo end: CGFloat) -> Path {
        Path { p in
            let mid = height / 2, amp: CGFloat = 6
            let periods = CGFloat(AircMetrics.ThemePicker.wavePeriods)
            var x: CGFloat = 0
            p.move(to: CGPoint(x: 0, y: mid))
            while x <= end {
                p.addLine(to: CGPoint(x: x, y: mid + amp * sin(x / width * periods * 2 * .pi)))
                x += 1
            }
        }
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let kx = w * value
            ZStack(alignment: .topLeading) {
                wave(width: w, height: h, upTo: w).stroke(theme.surfaceText.alpha(0.16).color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                wave(width: w, height: h, upTo: kx).stroke((tint ?? theme.accent).color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                AircKnob().position(x: kx, y: h / 2 + 6 * sin(kx / w * CGFloat(AircMetrics.ThemePicker.wavePeriods) * 2 * .pi))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in value = min(1, max(0, v.location.x / max(w, 1))) })
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Intensity")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { d in value = min(1, max(0, value + (d == .increment ? 0.05 : -0.05))) }
    }
}

/// Arc's grain dial: 24 dots around a circle, starting at the top with no grain and turning clockwise.
public struct AircGrainDial: View {
    @Binding private var value: Double
    @Environment(\.aircTheme) private var theme
    public init(value: Binding<Double>) { _value = value }

    public var body: some View {
        let n = AircMetrics.ThemePicker.grainDots
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for k in 0..<n {
                let a = -Double.pi / 2 + Double(k) / Double(n) * 2 * .pi
                let on = Double(k) / Double(n) <= value && value > 0
                let r: CGFloat = on ? 1.9 : 1.4
                let p = CGPoint(x: c.x + 18 * cos(a), y: c.y + 18 * sin(a))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(theme.surfaceText.alpha(on ? 0.75 : 0.22).color))
            }
            let a = -Double.pi / 2 + value * 2 * .pi
            let p = CGPoint(x: c.x + 10 * cos(a), y: c.y + 10 * sin(a))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(theme.surfaceText.color))
        }
        .frame(width: 46, height: 46)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            var a = atan2(v.location.y - 23, v.location.x - 23) + .pi / 2
            if a < 0 { a += 2 * .pi }
            value = min(1, max(0, a / (2 * .pi)))
        })
        .accessibilityElement()
        .accessibilityLabel("Grain")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { d in value = min(1, max(0, value + (d == .increment ? 1.0 / 24 : -1.0 / 24))) }
    }
}

/// The whole picker panel: colour field, − / + (1–3 colours), Auto · Light · Dark, presets, intensity and grain.
/// Bind it to the Space's theme; the window follows every change.
///
/// The panel resolves its own chrome from the theme being edited (so a dark Space gets a dark panel, as in Arc), and
/// the intensity wave is drawn in that theme's accent (contrast-safe on the panel; the raw last colour can vanish on
/// white, e.g. Lemon). Presets come in three whole pages behind ‹ ›: light presets, dark presets, Arc's nine swatches.
/// No disc is ever cut off.
public struct AircThemePicker: View {
    @Binding private var theme: SpaceTheme
    private let systemIsDark: Bool
    @State private var page: Int?

    /// One page of preset discs.
    public struct PresetPage: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let themes: [(name: String, theme: SpaceTheme)]
    }

    /// The three preset pages: Light (Paper and the five light presets), Dark (the six dark presets), Arc (the nine
    /// swatches as one-colour themes).
    public static let presetPages: [PresetPage] = {
        let light = SpaceTheme.presets.filter { $0.theme.appearance != .dark }
        let dark = SpaceTheme.presets.filter { $0.theme.appearance == .dark }
        let arc = SpaceTheme.swatches.enumerated().map { i, c in (name: "Arc \(i + 1)", theme: SpaceTheme(colors: [c])) }
        return [
            PresetPage(id: "light", title: "Light", themes: light.map { ($0.name, $0.theme) }),
            PresetPage(id: "dark", title: "Dark", themes: dark.map { ($0.name, $0.theme) }),
            PresetPage(id: "arc", title: "Arc", themes: arc),
        ]
    }()

    /// Most discs on one page, and the width they need (24 pt discs with their 3 pt ring padding, 4 pt apart).
    public static var maxDiscsPerPage: Int { presetPages.map(\.themes.count).max() ?? 0 }
    public static func presetRowWidth(discs: Int) -> CGFloat {
        let disc = AircMetrics.ThemePicker.swatch + 6
        return CGFloat(discs) * disc + CGFloat(max(0, discs - 1)) * presetGap
    }
    static let presetGap: CGFloat = 2
    /// The room the disc row has between the ‹ › buttons.
    public static var presetRowRoom: CGFloat { AircMetrics.ThemePicker.size.width - 2 * contentPadding - 2 * pagerWidth - 8 }
    static let contentPadding: CGFloat = 8.5
    static let pagerWidth: CGFloat = 18

    public init(theme: Binding<SpaceTheme>, systemIsDark: Bool) {
        _theme = theme
        self.systemIsDark = systemIsDark
    }

    /// The page holding the current theme, else the first.
    private var currentPage: Int {
        if let page { return page }
        return Self.presetPages.firstIndex { $0.themes.contains { $0.theme == theme } } ?? 0
    }

    public var body: some View {
        let m = AircMetrics.ThemePicker.self
        let ui = theme.resolved(systemIsDark: systemIsDark)
        let pages = Self.presetPages
        let p = min(currentPage, pages.count - 1)
        VStack(spacing: 10) {
            AircColorField(colors: $theme.colors)
            HStack(spacing: 8) {
                roundButton("minus", enabled: !theme.colors.isEmpty, ui: ui) { theme.colors.removeLast() }
                roundButton("plus", enabled: theme.colors.count < SpaceTheme.maxColors, ui: ui) {
                    let first = theme.colors.first ?? SpaceTheme.swatches[7]
                    theme.colors = AircColorFieldGeometry.companions(of: first, count: theme.colors.count + 1)
                }
                HStack(spacing: 4) {
                    ForEach(0..<SpaceTheme.maxColors, id: \.self) { i in
                        Circle().fill(ui.surfaceText.alpha(i < theme.colors.count ? 0.6 : 0.16).color).frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 4)
                Spacer()
                AircSegmented(selection: $theme.appearance, segments: [
                    .init(value: .auto, title: "", symbol: "sparkles"),
                    .init(value: .light, title: "", symbol: "sun.max"),
                    .init(value: .dark, title: "", symbol: "moon"),
                ], height: 28)
                .frame(width: 112)
            }
            .frame(height: 30)
            HStack(spacing: 4) {
                pager("chevron.left", enabled: p > 0, ui: ui) { page = p - 1 }
                HStack(spacing: Self.presetGap) {
                    ForEach(Array(pages[p].themes.enumerated()), id: \.offset) { _, entry in
                        AircThemeDisc(theme: entry.theme.resolved(systemIsDark: systemIsDark), selected: entry.theme == theme, size: m.swatch)
                            .onTapGesture { withAircAnimation(AircSpring.toggle) { theme = entry.theme } }
                            .accessibilityLabel(entry.name)
                    }
                }
                .frame(maxWidth: .infinity)
                .id(pages[p].id)
                .transition(.opacity)
                pager("chevron.right", enabled: p < pages.count - 1, ui: ui) { page = p + 1 }
            }
            .frame(height: 30)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(pages[p].title) presets")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Intensity").aircFont(AircFont.caption).foregroundStyle(ui.surfaceTextTertiary.color)
                    AircIntensityWave(value: $theme.intensity, tint: ui.accent)
                }
                AircGrainDial(value: $theme.grain)
            }
        }
        .padding(Self.contentPadding)
        .frame(width: m.size.width, height: m.size.height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: m.radius, style: .continuous).fill(ui.surface.color))
        .overlay(RoundedRectangle(cornerRadius: m.radius, style: .continuous).inset(by: 0.25).stroke(ui.surfaceBorder.color, lineWidth: 0.5))
        .aircShadow(.panel)
        .aircTheme(ui)
        .environment(\.colorScheme, ui.colorScheme)
    }

    private func roundButton(_ symbol: String, enabled: Bool, ui: ResolvedTheme, action: @escaping () -> Void) -> some View {
        Button(action: { withAircAnimation(AircSpring.grow, action) }) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(ui.surfaceTextSecondary.color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(ui.surfaceHover.color))
                .overlay(Circle().inset(by: 0.25).stroke(ui.surfaceBorder.color, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func pager(_ symbol: String, enabled: Bool, ui: ResolvedTheme, action: @escaping () -> Void) -> some View {
        Button(action: { withAircAnimation(AircSpring.toggle, action) }) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(ui.surfaceTextTertiary.color)
                .frame(width: Self.pagerWidth, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

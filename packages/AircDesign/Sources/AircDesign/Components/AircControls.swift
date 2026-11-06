// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// Controls moved here from Airc.app (apps/browser/Sources/Airc/UI/Controls.swift and the Settings and
// onboarding files). Their initialisers match the app's, so switching over is deleting the app's copy: a type
// declared in the app shadows the one imported from here until then.

/// A segmented control: a recessed track (`segmentedTrack`) with the selected segment raised
/// (`segmentedSelection`, hairline and `control` shadow), moving on the `toggle` spring.
public struct AircSegmented<Value: Hashable>: View {
    public struct Segment: Identifiable {
        public var value: Value
        public var title: String
        public var symbol: String?
        public var id: Value { value }

        public init(value: Value, title: String, symbol: String? = nil) {
            self.value = value
            self.title = title
            self.symbol = symbol
        }
    }

    @Binding private var selection: Value
    private let segments: [Segment]
    private let height: CGFloat
    @Environment(\.aircTheme) private var theme
    @Namespace private var ns

    public init(selection: Binding<Value>, segments: [Segment], height: CGFloat = 32) {
        _selection = selection
        self.segments = segments
        self.height = height
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { s in
                let on = s.value == selection
                HStack(spacing: 6) {
                    if let symbol = s.symbol { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
                    if !s.title.isEmpty { Text(s.title).aircFont(AircFont.body.weight(on ? .medium : .regular)) }
                }
                .foregroundStyle((on ? theme.segmentedSelectedText : theme.surfaceTextSecondary).color)
                .frame(maxWidth: .infinity)
                .frame(height: height - 4)
                .background {
                    if on {
                        let shape = RoundedRectangle(cornerRadius: AircRadius.small + 1, style: .continuous)
                        shape.fill(theme.segmentedSelection.color)
                            .overlay(shape.inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
                            .aircShadow(.control)
                            .matchedGeometryEffect(id: "selection", in: ns)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAircAnimation(AircSpring.toggle) { selection = s.value } }
                .accessibilityElement()
                .accessibilityLabel(s.title.isEmpty ? (s.symbol ?? "") : s.title)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: AircRadius.control, style: .continuous).fill(theme.segmentedTrack.color))
    }
}

/// A slider: 4 pt track in ink 0.12 with the filled part in accent, a 20 pt white knob with a soft shadow.
public struct AircSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let onEditingEnded: (() -> Void)?
    @Environment(\.aircTheme) private var theme

    public init(value: Binding<Double>, range: ClosedRange<Double> = 0...1, onEditingEnded: (() -> Void)? = nil) {
        _value = value
        self.range = range
        self.onEditingEnded = onEditingEnded
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 20
            let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surfaceText.alpha(0.12).color).frame(height: 4).padding(.horizontal, 10)
                Capsule().fill(theme.accent.color).frame(width: max(0, w * f), height: 4).padding(.leading, 10)
                AircKnob().offset(x: w * f)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let x = min(max(0, g.location.x - 10), w)
                value = range.lowerBound + (range.upperBound - range.lowerBound) * Double(x / max(w, 1))
            }.onEnded { _ in onEditingEnded?() })
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? step : -step)))
        }
    }
}

/// The 20 pt white knob of sliders and the intensity wave.
public struct AircKnob: View {
    private let size: CGFloat
    public init(size: CGFloat = 20) { self.size = size }
    public var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.08), radius: 0.25)
    }
}

/// An 18 pt checkbox: accent fill with a white check when on, a hairline square when off.
public struct AircCheckbox: View {
    @Binding private var isOn: Bool
    private let isEnabled: Bool
    /// A fixed choice (always included) reads at full strength; a disabled one dims.
    private let dimsWhenDisabled: Bool
    @Environment(\.aircTheme) private var theme

    public init(isOn: Binding<Bool>, isEnabled: Bool = true, dimsWhenDisabled: Bool = true) {
        _isOn = isOn
        self.isEnabled = isEnabled
        self.dimsWhenDisabled = dimsWhenDisabled
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack {
            if isOn {
                shape.fill(theme.accent.color)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.onAccent.color)
            } else {
                shape.fill((theme.isDark ? AircColor.white(0.05) : AircColor.white()).color)
                shape.inset(by: 0.5).stroke(theme.surfaceText.alpha(0.22).color, lineWidth: 1)
            }
        }
        .frame(width: 18, height: 18)
        .opacity(isEnabled || !dimsWhenDisabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { withAircAnimation(AircSpring.toggle) { isOn.toggle() } } }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A Space chip: emoji and name on a soft capsule; selected ones get an accent ring.
public struct AircSpaceChip: View {
    private let emoji: String?
    private let name: String
    private let selected: Bool
    private let compact: Bool
    @Environment(\.aircTheme) private var theme

    public init(emoji: String?, name: String, selected: Bool = false, compact: Bool = false) {
        self.emoji = emoji
        self.name = name
        self.selected = selected
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let emoji { Text(emoji).font(.system(size: compact ? 12 : 13)) }
            Text(name).aircFont(compact ? AircFont.callout : AircFont.body).foregroundStyle(theme.surfaceText.color).lineLimit(1)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: compact ? 22 : 28)
        .background(Capsule().fill((selected ? theme.accent.alpha(theme.isDark ? 0.22 : 0.10) : theme.surfaceText.alpha(0.05)).color))
        .overlay(Capsule().inset(by: 0.5).stroke((selected ? theme.accent : theme.surfaceText.alpha(0.10)).color, lineWidth: selected ? 1.5 : 0.5))
    }
}

/// A Space theme as a disc (presets in the theme picker and onboarding): the real background, clipped round,
/// with an accent ring when selected.
public struct AircThemeDisc: View {
    private let theme: ResolvedTheme
    private let selected: Bool
    private let size: CGFloat
    @Environment(\.aircTheme) private var ui

    public init(theme: ResolvedTheme, selected: Bool = false, size: CGFloat = 40) {
        self.theme = theme
        self.selected = selected
        self.size = size
    }

    public var body: some View {
        SpaceBackground(theme)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().inset(by: 0.25).stroke(AircColor.black(0.10).color, lineWidth: 0.5))
            .padding(3)
            .overlay(Circle().inset(by: 1).stroke((selected ? ui.accent : .clear).color, lineWidth: 2))
            .contentShape(Circle())
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The current theme as a small gradient capsule (the "Choose a Theme" row in Create a Space): 30 × 20, a 1.5 pt
/// white rim and a hairline.
public struct AircThemeChip: View {
    private let theme: ResolvedTheme
    private let size: CGSize
    public init(theme: ResolvedTheme, size: CGSize = CGSize(width: 30, height: 20)) {
        self.theme = theme
        self.size = size
    }

    public var body: some View {
        SpaceBackground(theme)
            .frame(width: size.width, height: size.height)
            .clipShape(Capsule())
            .overlay(Capsule().inset(by: 0.25).stroke(AircColor.black(0.14).color, lineWidth: 0.5))
            .background(Capsule().inset(by: -1.5).fill(AircColor.white(0.7).color))
    }
}

/// A keycap: 18 pt tall, `AircKeycapGlyph` (SF Mono, or the system font or an SF Symbol for key symbols), hairline
/// border.
public struct AircKeycap: View {
    private let text: String
    @Environment(\.aircTheme) private var theme
    public init(_ text: String) { self.text = text }
    public init(text: String) { self.text = text }

    public var body: some View {
        glyph
            .foregroundStyle(theme.surfaceTextSecondary.color)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.surfaceHover.color))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
    }

    @ViewBuilder private var glyph: some View {
        switch AircKeycapGlyph(text) {
        case .text(let s, let style): Text(s).aircFont(style)
        case .symbol(let name): Image(systemName: name).font(AircKeycapGlyph.symbolStyle.font)
        }
    }
}

/// A Settings section: `title3` heading 24 pt above an `AircGroup`, optional help under it.
public struct AircSettingsSection<Content: View>: View {
    private let title: String
    private let help: String?
    private let content: Content
    @Environment(\.aircTheme) private var theme

    public init(title: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
            AircGroup { content }
            if let help {
                Text(help).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 24)
    }
}

/// A Settings row: title (and subtitle) leading, a control trailing. At least 44 pt tall.
public struct AircSettingsRow<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing
    @Environment(\.aircTheme) private var theme

    public init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                if let subtitle {
                    Text(subtitle).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

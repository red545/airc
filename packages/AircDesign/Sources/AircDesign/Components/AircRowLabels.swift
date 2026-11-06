// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore
import SwiftUI

// Loading rows (owner feedback P2, spec SB-44; docs/design.md §7 "Loading rows"):
// - a title never runs under a trailing control and never ends in "…": it fades out over its last 24 pt;
// - the loading ring sits in the favicon slot, appears only after 150 ms and fades in over 120 ms, so fast loads
//   never flicker and nothing ever draws over text.

// MARK: - Trailing fade

/// A single-line label that fades out at its trailing edge when it doesn't fit (no "…", no hard clip). Short
/// text draws plainly. Give it the width up to the trailing control minus `AircMetrics.Row.titleFadeGap`.
public struct AircFadingText: View {
    private let text: String
    private let style: AircTextStyle
    private let fade: CGFloat
    @State private var overflows = false

    public init(_ text: String, style: AircTextStyle = AircFont.row, fade: CGFloat = AircMetrics.Row.titleFade) {
        self.text = text
        self.style = style
        self.fade = fade
    }

    public var body: some View {
        GeometryReader { geo in
            Text(text)
                .aircFont(style)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { t in
                    Color.clear.preference(key: AircFadeWidthKey.self, value: t.size.width)
                })
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
                .mask(AircFadeMask(fade: overflows ? fade : 0))
                .onPreferenceChange(AircFadeWidthKey.self) { w in overflows = w > geo.size.width + 0.5 }
        }
        .frame(height: style.lineHeight)
        .accessibilityElement()
        .accessibilityLabel(text)
    }
}

private struct AircFadeWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Opaque, then a linear fade to clear over the last `fade` points.
public struct AircFadeMask: View {
    private let fade: CGFloat
    public init(fade: CGFloat = AircMetrics.Row.titleFade) { self.fade = fade }
    public var body: some View {
        GeometryReader { g in
            let start = max(0, (g.size.width - fade) / max(g.size.width, 1))
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: start), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// The AppKit label for sidebar and Command Bar rows: a one-line `NSTextField` that clips instead of truncating
/// and fades its last `fadeWidth` points through a gradient mask, only while the text overflows.
@MainActor
public final class AircFadingLabel: NSTextField {
    /// Width of the fade. 24 pt (`AircMetrics.Row.titleFade`).
    public var fadeWidth: CGFloat = AircMetrics.Row.titleFade { didSet { needsLayout = true } }
    private let fadeMask = CAGradientLayer()

    public convenience init(style: AircTextStyle = AircFont.row) {
        self.init(frame: .zero)
        font = style.nsFont
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        cell?.truncatesLastVisibleLine = false
        cell?.lineBreakMode = .byClipping
        maximumNumberOfLines = 1
        wantsLayer = true
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull()]
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var stringValue: String { didSet { textChanged() } }
    public override var attributedStringValue: NSAttributedString { didSet { textChanged() } }
    public override var font: NSFont? { didSet { textChanged() } }

    /// The text's measured sizes, kept until the text or font changes: every layout pass used to measure the string
    /// again (twice in a Command Bar row), which was most of a keystroke's label work (§2.12).
    private var measuredWidth: CGFloat?
    private var measuredFit: NSSize?

    private func textChanged() {
        measuredWidth = nil
        measuredFit = nil
        needsLayout = true
    }

    /// The text's width (`NSAttributedString.size()`).
    public var textWidth: CGFloat {
        if let w = measuredWidth { return w }
        let w = attributedStringValue.size().width
        measuredWidth = w
        return w
    }

    /// What `sizeToFit()` would make the frame's size (the cell's size for this text), without measuring it again.
    public var fittingCellSize: NSSize {
        if let s = measuredFit { return s }
        let s = cell?.cellSize ?? .zero
        measuredFit = s
        return s
    }

    /// True while the text is wider than the label (so the fade shows).
    public var isOverflowing: Bool { textWidth > bounds.width - 2 }

    public override func layout() {
        super.layout()
        guard let layer else { return }
        if isOverflowing, bounds.width > 0 {
            fadeMask.frame = layer.bounds
            let start = max(0, (bounds.width - fadeWidth) / bounds.width)
            fadeMask.locations = [0, NSNumber(value: Double(start)), 1]
            layer.mask = fadeMask
        } else {
            layer.mask = nil
        }
    }
}

// MARK: - Loading ring

/// The loading ring for a favicon slot (SwiftUI): 14 pt, 1.75 pt stroke, a 0.28 arc in `textSecondary` on an ink
/// 0.14 track, one turn per 0.9 s. It stays invisible for `AircMetrics.Loading.showDelay` (150 ms) after
/// `isLoading` turns on, then fades in over 120 ms. Put it in the favicon's frame, in place of the favicon.
public struct AircLoadingRing: View {
    private let isLoading: Bool
    private let size: CGFloat
    private let color: AircColor?
    @State private var visible = false
    @State private var task: Task<Void, Never>?
    @Environment(\.aircTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isLoading: Bool = true, size: CGFloat = AircMetrics.Loading.ring, color: AircColor? = nil) {
        self.isLoading = isLoading
        self.size = size
        self.color = color
    }

    public var body: some View {
        let m = AircMetrics.Loading.self
        TimelineView(.animation(paused: !visible || reduceMotion)) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: m.period) / m.period
            ZStack {
                Circle().inset(by: m.stroke / 2).stroke(theme.text.alpha(0.14).color, lineWidth: m.stroke)
                Circle().inset(by: m.stroke / 2).trim(from: 0, to: m.arc)
                    .stroke((color ?? theme.textSecondary).color, style: StrokeStyle(lineWidth: m.stroke, lineCap: .round))
                    .rotationEffect(.degrees(reduceMotion ? -90 : phase * 360 - 90))
            }
        }
        .frame(width: size, height: size)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: m.fade), value: visible)
        .onAppear { schedule(isLoading) }
        .onChange(of: isLoading) { _, now in schedule(now) }
        .onDisappear { task?.cancel() }
        .accessibilityHidden(!visible)
        .accessibilityLabel("Loading")
    }

    private func schedule(_ loading: Bool) {
        task?.cancel()
        guard loading else { visible = false; return }
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(AircMetrics.Loading.showDelay))
            if !Task.isCancelled { visible = true }
        }
    }
}

/// The same ring for AppKit rows, as a Core Animation layer tree (`layer`, 14 × 14; centre it in the favicon
/// slot). Call `setLoading(_:)`: it handles the 150 ms delay, the 120 ms fades and the rotation (a CA animation, so
/// spinning costs nothing on the main thread). `onVisibilityChange` tells the row when to hide its favicon (true)
/// and when to fade it back in (false).
@MainActor
public final class AircLoadingIndicator {
    public let layer = CALayer()
    public private(set) var isShowing = false
    public var onVisibilityChange: ((Bool) -> Void)?
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var pending: Task<Void, Never>?

    public init(theme: ResolvedTheme? = nil) {
        let m = AircMetrics.Loading.self
        layer.bounds = CGRect(x: 0, y: 0, width: m.ring, height: m.ring)
        layer.opacity = 0
        layer.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        let path = CGPath(ellipseIn: layer.bounds.insetBy(dx: m.stroke / 2, dy: m.stroke / 2), transform: nil)
        for l in [track, arc] {
            l.fillColor = nil
            l.lineWidth = m.stroke
            l.lineCap = .round
            l.frame = layer.bounds
            l.path = path
            l.actions = ["strokeColor": NSNull()]
            layer.addSublayer(l)
        }
        arc.strokeEnd = m.arc
        if let theme { apply(theme) }
    }

    /// Colours from the row's theme (`textSecondary` arc on an ink 0.14 track).
    public func apply(_ theme: ResolvedTheme) {
        track.strokeColor = theme.text.alpha(0.14).cgColor
        arc.strokeColor = theme.textSecondary.cgColor
    }

    public func setLoading(_ loading: Bool) {
        pending?.cancel()
        pending = nil
        if loading {
            guard !isShowing else { return }
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(AircMetrics.Loading.showDelay))
                guard !Task.isCancelled else { return }
                self?.show(true)
            }
        } else if isShowing {
            show(false)
        }
    }

    private func show(_ on: Bool) {
        isShowing = on
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = on ? 1 : 0
        fade.duration = AircMetrics.Loading.fade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
        layer.opacity = on ? 1 : 0
        if on, !AircMotion.prefersReducedMotion {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = AircMetrics.Loading.period
            spin.repeatCount = .infinity
            arc.add(spin, forKey: "spin")
        } else if !on {
            arc.removeAnimation(forKey: "spin")
        }
        onVisibilityChange?(on)
    }
}

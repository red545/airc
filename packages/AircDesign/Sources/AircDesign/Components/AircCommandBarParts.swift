// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// Command bar row parts (docs/design.md §7 "Command bar"; docs/qa/visual-review.md #8, #9). The app's command bar is
// AppKit, so each part comes as an AppKit view drawn in one pass (no NSTextField) and as SwiftUI for the gallery.
//
// - The selected row's action ("Open", "Switch to Tab") is in the accent, followed by a ↵ keycap. Other rows show no
//   action. Shortcut keycaps (⌘ D in actions mode) are `AircKeycap`s.
// - The inline completion has explicit colours (`inlineCompletionAttributes`), never the system selection colour.
// - The search row reads "‹query›  Search Google": query in `surfaceText`, engine in `surfaceTextTertiary`, no dash.

extension AircMetrics.CommandBar {
    /// Keycaps: 18 pt tall, radius 5, 11 pt medium (`AircKeycapGlyph`), 5 pt side padding.
    public static let keycapHeight: CGFloat = 18
    public static let keycapRadius: CGFloat = 5
    public static let keycapPadding: CGFloat = 5
    /// Gap between the action label and its keycap, and between keycaps.
    public static let actionGap: CGFloat = 6
    public static let keycapGap: CGFloat = 3
    /// The action sits 14 pt from the row's trailing edge.
    public static let actionTrailing: CGFloat = 14
}

/// The action at the trailing end of a command bar row: the label in the accent, then its keycaps (↵ by default).
/// Draws nothing unless `isSelected` (Arc and the design keep keycaps on the selected row only).
public struct AircCommandAction: View {
    private let title: String
    private let keys: [String]
    private let isSelected: Bool
    @Environment(\.aircTheme) private var theme

    public init(_ title: String, keys: [String] = ["↵"], isSelected: Bool = true) {
        self.title = title
        self.keys = keys
        self.isSelected = isSelected
    }

    public var body: some View {
        HStack(spacing: AircMetrics.CommandBar.actionGap) {
            Text(title).aircFont(AircCommandText.actionStyle).foregroundStyle(theme.accent.color).lineLimit(1)
            AircShortcutKeys(keys)
        }
        .opacity(isSelected ? 1 : 0)
        .accessibilityHidden(!isSelected)
    }
}

/// A row of keycaps for a shortcut ("⌘", "D").
public struct AircShortcutKeys: View {
    private let keys: [String]
    public init(_ keys: [String]) { self.keys = keys }
    public var body: some View {
        HStack(spacing: AircMetrics.CommandBar.keycapGap) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in AircKeycap(k) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined())
    }
}

/// Text styles for command bar rows and the input, from the theme (AppKit attribute dictionaries).
public enum AircCommandText {
    /// The action label: `callout` medium.
    public static let actionStyle = AircFont.callout.weight(.medium)

    /// "Search Google": no dash. Show it after the query in `subtitleAttributes`.
    public static func searchSubtitle(engine: String) -> String { "Search \(engine)" }
}

extension ResolvedTheme {
    /// The command bar input's typed text: `commandInput` 18 pt in `surfaceText`.
    public var commandInputAttributes: [NSAttributedString.Key: Any] {
        [.font: AircFont.commandInput.nsFont, .foregroundColor: surfaceText.nsColor]
    }

    /// The field editor's `selectedTextAttributes` while an inline completion is shown: `inlineCompletionText` on
    /// `inlineCompletionHighlight`. Independent of the system accent and selection colours.
    public var inlineCompletionAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: inlineCompletionText.nsColor, .backgroundColor: inlineCompletionHighlight.nsColor]
    }

    /// The field editor's `selectedTextAttributes` for an ordinary selection (no completion): the theme's highlight,
    /// text unchanged. Use instead of `NSColor.selectedTextBackgroundColor`.
    public var textSelectionAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: surfaceText.nsColor, .backgroundColor: accent.alpha(isDark ? 0.36 : 0.22).nsColor]
    }

    /// The typed part followed by the completion as one attributed string, for a field that draws the completion as a
    /// separate run instead of a selection.
    public func inlineCompletionString(typed: String, completion: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: typed, attributes: commandInputAttributes)
        var rest = commandInputAttributes
        rest[.foregroundColor] = inlineCompletionText.nsColor
        rest[.backgroundColor] = inlineCompletionHighlight.nsColor
        s.append(NSAttributedString(string: completion, attributes: rest))
        return s
    }

    /// A row title: `row` 14 pt in `surfaceText`.
    public var commandRowTitleAttributes: [NSAttributedString.Key: Any] {
        [.font: AircFont.row.nsFont, .foregroundColor: surfaceText.nsColor]
    }

    /// A row's URL or subtitle ("Search Google"): 13 pt in `surfaceTextTertiary`.
    public var commandRowSubtitleAttributes: [NSAttributedString.Key: Any] {
        [.font: AircFont.urlField.nsFont, .foregroundColor: surfaceTextTertiary.nsColor]
    }
}

// MARK: - AppKit

/// What a keycap shows and in which face. Letters, digits and ASCII punctuation are `mono` 11 (SF Mono); key
/// symbols (⌘ ⌥ ⇧ ⌃, arrows) are the system font at the same size and weight, which has them; the few keys neither
/// font has (↵ ↩ ⇥) are SF Symbols. So CoreText never falls back to another font for a keycap.
public enum AircKeycapGlyph: Equatable, Sendable {
    case text(String, AircTextStyle)
    case symbol(String)

    /// The system font at `mono`'s size and weight.
    public static let symbolStyle = AircTextStyle(size: AircFont.mono.size, weight: AircFont.mono.weight, lineHeight: AircFont.mono.lineHeight)
    /// Keys neither SF Mono nor SF Pro has a glyph for.
    public static let symbolNames: [String: String] = ["↵": "return", "↩": "return", "⏎": "return", "⇥": "arrow.right.to.line"]

    public init(_ key: String) {
        if let name = Self.symbolNames[key] {
            self = .symbol(name)
        } else if key.unicodeScalars.allSatisfy({ $0.isASCII || $0 == "–" }) {
            self = .text(key, AircFont.mono)
        } else {
            self = .text(key, Self.symbolStyle)
        }
    }

}

/// A keycap drawn in one pass: 18 pt tall, radius 5, `AircKeycapGlyph` in `surfaceTextSecondary`, `surfaceHover` fill
/// and a 0.5 pt `surfaceBorder` hairline. Size it with `intrinsicContentSize`.
@MainActor
public final class AircKeycapView: NSView {
    public var text: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var theme: ResolvedTheme { didSet { needsDisplay = true } }

    public init(_ text: String, theme: ResolvedTheme) {
        self.text = text
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// Widths by key: the command bar measures its keycaps on every layout and draw.
    private static var widths: [String: CGFloat] = [:]
    /// Tinted symbol images by name and colour.
    private struct SymbolKey: Hashable { let name: String; let color: AircColor }
    private static var symbols: [SymbolKey: NSImage] = [:]

    public static func size(for text: String) -> NSSize {
        let m = AircMetrics.CommandBar.self
        let w: CGFloat
        if let known = widths[text] {
            w = known
        } else {
            switch AircKeycapGlyph(text) {
            case .text(let s, let style): w = ceil((s as NSString).size(withAttributes: [.font: style.nsFont]).width)
            case .symbol(let name): w = ceil(symbol(name, color: AircColor(red: 0, green: 0, blue: 0))?.size.width ?? 0)
            }
            widths[text] = w
        }
        return NSSize(width: max(m.keycapHeight, w + 2 * m.keycapPadding), height: m.keycapHeight)
    }

    /// The SF Symbol `name` in `color`, cached; nil if this macOS doesn't have it.
    static func symbol(_ name: String, color: AircColor) -> NSImage? {
        let key = SymbolKey(name: name, color: color)
        if let cached = symbols[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: AircKeycapGlyph.symbolStyle.size, weight: .medium)
            .applying(.init(paletteColors: [color.nsColor]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        symbols[key] = image
        return image
    }

    public override var intrinsicContentSize: NSSize { Self.size(for: text) }

    public override func draw(_ dirtyRect: NSRect) {
        Self.draw(text, in: bounds, theme: theme)
    }

    public override func accessibilityLabel() -> String? { text }

    /// Draws a keycap into the current graphics context (for custom row drawing).
    public static func draw(_ text: String, in rect: NSRect, theme: ResolvedTheme) {
        let m = AircMetrics.CommandBar.self
        let plate = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: m.keycapRadius, yRadius: m.keycapRadius)
        theme.surfaceHover.nsColor.setFill()
        plate.fill()
        theme.surfaceBorder.nsColor.setStroke()
        plate.lineWidth = 0.5
        plate.stroke()
        switch AircKeycapGlyph(text) {
        case .text(let s, let style):
            let attrs: [NSAttributedString.Key: Any] = [.font: style.nsFont, .foregroundColor: theme.surfaceTextSecondary.nsColor]
            let size = (s as NSString).size(withAttributes: attrs)
            (s as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        case .symbol(let name):
            guard let image = symbol(name, color: theme.surfaceTextSecondary) else { return }
            let r = NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                           width: image.size.width, height: image.size.height)
            image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// The trailing action of a command bar row in AppKit: the accent label and its keycaps, right-aligned in its bounds.
/// Hidden unless `isSelected`. `intrinsicContentSize` gives the width to reserve (lay the title out to end
/// `AircMetrics.Row.titleFadeGap` before `frame.minX`).
@MainActor
public final class AircCommandActionView: NSView {
    public var title: String { didSet { changed() } }
    public var keys: [String] { didSet { changed() } }
    public var theme: ResolvedTheme { didSet { changed() } }
    public var isSelected = false { didSet { isHidden = !isSelected } }

    public init(title: String, keys: [String] = ["↵"], theme: ResolvedTheme) {
        self.title = title
        self.keys = keys
        self.theme = theme
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: AircCommandText.actionStyle.nsFont, .foregroundColor: theme.accent.nsColor]
    }

    /// The title's measured size, until the title or theme changes: rows ask for the intrinsic size on every layout
    /// and the selected row draws on every selection change (§2.12).
    private var measuredTitle: NSSize?
    private var titleSize: NSSize {
        if let s = measuredTitle { return s }
        let s = (title as NSString).size(withAttributes: titleAttributes)
        measuredTitle = s
        return s
    }

    private func changed() {
        measuredTitle = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    public override var intrinsicContentSize: NSSize {
        let m = AircMetrics.CommandBar.self
        let tw = ceil(titleSize.width)
        let kw = keys.map { AircKeycapView.size(for: $0).width }.reduce(0, +) + CGFloat(max(0, keys.count - 1)) * m.keycapGap
        return NSSize(width: tw + (keys.isEmpty ? 0 : m.actionGap + kw), height: m.keycapHeight)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let m = AircMetrics.CommandBar.self
        var x = bounds.maxX
        let y = (bounds.height - m.keycapHeight) / 2
        for k in keys.reversed() {
            let w = AircKeycapView.size(for: k).width
            x -= w
            AircKeycapView.draw(k, in: NSRect(x: x, y: y, width: w, height: m.keycapHeight), theme: theme)
            x -= m.keycapGap
        }
        if !keys.isEmpty { x += m.keycapGap - m.actionGap }
        let s = titleSize
        (title as NSString).draw(at: NSPoint(x: x - s.width, y: (bounds.height - s.height) / 2), withAttributes: titleAttributes)
    }

    public override func accessibilityLabel() -> String? { ([title] + keys).joined(separator: " ") }
}

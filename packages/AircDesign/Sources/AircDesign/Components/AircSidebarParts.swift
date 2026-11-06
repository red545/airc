// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore
import SwiftUI

// Sidebar pieces the app draws itself today (design pass 4, docs/qa/visual-review.md #3, #6, #14, #17). Each comes as
// a SwiftUI view and, where the sidebar is AppKit, a drop-in AppKit form.

// MARK: - Sign in to Google (SP-12, review #3)

extension AircMetrics.Profile {
    /// The sign-in card is the sidebar's width minus its 8 pt insets: 212 at the default 228.
    public static let signInCardWidth: CGFloat = 212
}

/// The designed copy of the "Sign in to Google" card.
public enum AircSignInCopy {
    public static let title = "Sign in to Google"
    public static let message = "A fresh profile. Sign in once and Google stays signed in here."
    public static let signIn = "Sign in"
    public static let notNow = "Not now"
}

extension AircSidebarCard where Icon == AircGoogleMark {
    /// The "Sign in to Google" card: the G, the designed copy, Sign in (primary small, in the Space's accent) and
    /// Not now (plain small). Put it under + New Tab in a new profile's Today list, 212 × 112.
    /// `isDark` puts the G on its white disc (pass the sidebar theme's `isDark`).
    public static func signInToGoogle(isDark: Bool = false, onSignIn: @escaping () -> Void, onNotNow: @escaping () -> Void,
                                      onDismiss: (() -> Void)? = nil) -> Self {
        AircSidebarCard(title: AircSignInCopy.title, message: AircSignInCopy.message, primary: AircSignInCopy.signIn,
                        secondary: AircSignInCopy.notNow, onPrimary: onSignIn, onSecondary: onNotNow, onDismiss: onDismiss) {
            AircGoogleMark(size: 16, onDisc: isDark)
        }
    }
}

/// The sign-in card for an AppKit sidebar: an `NSHostingView` that takes first clicks (the window may not be key),
/// sized `AircMetrics.Profile.signInCardWidth` × `signInCardHeight`. Set `theme` from the sidebar palette.
@MainActor
public final class AircSignInCardView: NSView {
    public var theme: ResolvedTheme { didSet { if theme != oldValue { update() } } }
    public var onSignIn: () -> Void = {}
    public var onNotNow: () -> Void = {}
    public var onDismiss: (() -> Void)? { didSet { update() } }
    private let host: AircFirstClickHostingView<AnyView>

    public init(theme: ResolvedTheme) {
        self.theme = theme
        host = AircFirstClickHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: AircMetrics.Profile.signInCardWidth,
                                                               height: AircMetrics.Profile.signInCardHeight)))
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
        update()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: AircMetrics.Profile.signInCardWidth, height: AircMetrics.Profile.signInCardHeight)
    }

    private func update() {
        let dismiss: (() -> Void)? = onDismiss == nil ? nil : { [weak self] in self?.onDismiss?() }
        host.rootView = AnyView(
            AircSidebarCard.signInToGoogle(isDark: theme.isDark, onSignIn: { [weak self] in self?.onSignIn() },
                                           onNotNow: { [weak self] in self?.onNotNow() }, onDismiss: dismiss)
                .aircTheme(theme)
                // Room for the selected-row shadow below the 112 pt card.
                .padding(.bottom, 0)
        )
    }
}

/// An `NSHostingView` that acts on the first click, so SwiftUI buttons work in a window that isn't key yet.
public final class AircFirstClickHostingView<Content: View>: NSHostingView<Content> {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Folder glyph (review #6)

/// Arc's folder: the outline `folder` in the theme's accent; open, `folder.fill` at 0.9. 15 pt medium in an 18 pt slot.
public struct AircFolderGlyph: View {
    private let isOpen: Bool
    private let size: CGFloat
    @Environment(\.aircTheme) private var theme

    public init(isOpen: Bool = false, size: CGFloat = 15) {
        self.isOpen = isOpen
        self.size = size
    }

    public var body: some View {
        Image(systemName: isOpen ? "folder.fill" : "folder")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(theme.folderTint(isOpen: isOpen).color)
            .frame(width: AircMetrics.Row.favicon, height: AircMetrics.Row.favicon)
            .accessibilityHidden(true)
    }

    /// The glyph as a ready-tinted image for an `NSImageView` (no `contentTintColor` needed).
    @MainActor
    public static func image(isOpen: Bool, theme: ResolvedTheme, size: CGFloat = 15) -> NSImage {
        let base = NSImage(systemSymbolName: isOpen ? "folder.fill" : "folder", accessibilityDescription: isOpen ? "Open folder" : "Folder")
            ?? NSImage(size: NSSize(width: size, height: size))
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [theme.folderTint(isOpen: isOpen).nsColor]))
        return base.withSymbolConfiguration(config) ?? base
    }
}

extension ResolvedTheme {
    /// The folder glyph's colour: the accent, at 0.9 while open (Arc's outline folder tinted by the theme).
    public func folderTint(isOpen: Bool) -> AircColor { isOpen ? accent.opacity(0.9) : accent }
}

// MARK: - Address field label (review #17)

/// The sidebar URL field's text: the host in `urlField` 13 pt `textSecondary`, or "Search or enter URL…" in
/// `textTertiary` when there's no page. It fades over 24 pt instead of truncating with "…". Lay it out with
/// `AircAddressFieldLabel.frame(inField:trailingControlMinX:)` so the fade ends 4 pt before the first hover button.
@MainActor
public final class AircAddressFieldLabel: NSView {
    public static let placeholder = "Search or enter URL…"
    /// Text inset from the field's leading edge (design.md §7 "URL field").
    public static let leadingInset: CGFloat = 12

    public var theme: ResolvedTheme { didSet { if theme != oldValue { restyle() } } }
    /// The host to show, or nil for the placeholder.
    public var host: String? { didSet { if host != oldValue { restyle() } } }
    public let label = AircFadingLabel(style: AircFont.urlField)

    public init(theme: ResolvedTheme) {
        self.theme = theme
        super.init(frame: .zero)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        restyle()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var showsPlaceholder: Bool { (host ?? "").isEmpty }

    private func restyle() {
        label.stringValue = showsPlaceholder ? Self.placeholder : host!
        label.textColor = (showsPlaceholder ? theme.textTertiary : theme.textSecondary).nsColor
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let h = AircFont.urlField.lineHeight
        label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        label.needsLayout = true
    }

    /// The label's frame inside a URL field of `field` bounds: 12 pt in, ending `AircMetrics.Row.titleFadeGap` before
    /// the first trailing control (or 12 pt before the field's end when none shows).
    public static func frame(inField field: CGRect, trailingControlMinX: CGFloat?) -> CGRect {
        let end = trailingControlMinX.map { $0 - AircMetrics.Row.titleFadeGap } ?? (field.maxX - leadingInset)
        return CGRect(x: field.minX + leadingInset, y: field.minY, width: max(0, end - field.minX - leadingInset), height: field.height)
    }
}

/// The same in SwiftUI (onboarding preview, mockup sheets).
public struct AircAddressFieldText: View {
    private let host: String?
    @Environment(\.aircTheme) private var theme
    public init(host: String?) { self.host = host }

    public var body: some View {
        let empty = (host ?? "").isEmpty
        AircFadingText(empty ? AircAddressFieldLabel.placeholder : host!, style: AircFont.urlField)
            .foregroundStyle((empty ? theme.textTertiary : theme.textSecondary).color)
    }
}

// MARK: - Profile colours (review #14)

extension AircProfileColor {
    /// Names for the nine `choices`, in order (accessibility, menus).
    public static let names = ["Blue", "Green", "Teal", "Violet", "Pink", "Red", "Orange", "Gold", "Graphite"]

    /// The designed colour closest to any stored one (Arc's pastel swatches, older builds): the nearest OKLab hue among
    /// the chromatic choices, or Graphite for greys. Use it once to migrate stored profile colours.
    public static func nearestChoice(to color: AircColor) -> Int {
        let lab = color.alpha(1).oklab
        if lab.chroma < 0.04 { return choices.count - 1 }
        var best = 0
        var bestD = Double.infinity
        for (i, c) in choices.enumerated().dropLast() {
            var d = abs(c.oklab.hue - lab.hue).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            if d < bestD { bestD = d; best = i }
        }
        return best
    }
}

/// The Colour row of Create Profile and Settings → Profiles: the nine `AircProfileColor.choices` as 20 pt discs, the
/// chosen one ringed in its own colour with a 2 pt gap.
public struct AircProfileColorPicker: View {
    @Binding private var selection: Int
    private let size: CGFloat
    public init(selection: Binding<Int>, size: CGFloat = 20) {
        _selection = selection
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(AircProfileColor.choices.indices, id: \.self) { i in
                let c = AircProfileColor.choices[i]
                Circle().fill(c.color)
                    .frame(width: size, height: size)
                    .overlay(Circle().inset(by: 0.25).stroke(AircColor.black(0.10).color, lineWidth: 0.5))
                    .padding(3)
                    .overlay(Circle().inset(by: 0.75).stroke((selection == i ? c : .clear).color, lineWidth: 1.5))
                    .contentShape(Circle())
                    .onTapGesture { withAircAnimation(AircSpring.toggle) { selection = i } }
                    .accessibilityLabel(AircProfileColor.names[i])
                    .accessibilityAddTraits(selection == i ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

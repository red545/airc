// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign

/// S03: the sound badge on a Favorite whose page is playing (Arc: "audible music favorites animate musical notes on
/// the icon"). A small round plate on the tile's top-right corner, opposite the unread dot. Playing, its musical note
/// sways and bobs; muted, a still crossed-out speaker. Reduce Motion keeps the note still. Layers only (no views), so
/// a tile costs nothing extra on each layout pass.
/// S03b: the same corner shows a Favorite's call state, which wins over sound (Arc's AppTray item knows
/// `isTabCapturingOrRecording`; RN23: "a badge shows on a Favorite shared to a video call"): a video camera while the
/// Favorite's page is itself in a call, two overlapping windows while it is shared into a call. Both green, as the
/// macOS camera light and the shared tab row's indicator, and both still.
@MainActor
final class AudioBadge: NSObject {
    enum State: Equatable { case none, playing, muted, inCall, sharedToCall }

    let layer = CALayer()
    private let glyph = CALayer()
    private(set) var state: State = .none
    private var palette: Palette?
    private var drawnKey = ""

    /// Plate diameter and glyph size (sized to sit on a 47 pt tile, in the corner above the unread dot).
    nonisolated static let diameter: CGFloat = 15
    /// The plate's centre from the tile's top-right corner (4.5 pt clear of both edges).
    nonisolated static let inset = CGPoint(x: 12, y: 12)
    nonisolated static let glyphSize: CGFloat = 9
    nonisolated static let animationKey = "airc.audioBadge.sway"

    override init() {
        super.init()
        layer.cornerRadius = Self.diameter / 2
        layer.cornerCurve = .continuous
        layer.isHidden = true
        layer.actions = LayerImage.noActions
        glyph.contentsGravity = .center
        glyph.actions = LayerImage.noActions
        layer.addSublayer(glyph)
        // Reduce Motion turned on or off while the tile is up (selector observers go away with the badge).
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @objc private func displayOptionsChanged() { updateMotion() }


    /// Whether the note is moving now (the checks read it).
    var isAnimating: Bool { glyph.animation(forKey: Self.animationKey) != nil }

    func set(_ state: State, palette: Palette, in view: NSView) {
        self.state = state
        self.palette = palette
        layer.isHidden = state == .none
        guard state != .none else { glyph.removeAllAnimations(); return }
        // A plate that reads on a plain, hovered or selected tile in either appearance: the page's text colour at low
        // strength under a full-strength glyph.
        layer.backgroundColor = palette.textPrimary.withAlphaComponent(palette.isDark ? 0.18 : 0.1).cgColor
        layer.borderWidth = 0
        let symbol: String, color: NSColor
        switch state {
        case .muted: symbol = "speaker.slash.fill"; color = palette.textSecondary
        case .inCall: symbol = "video.fill"; color = .systemGreen
        case .sharedToCall: symbol = "rectangle.on.rectangle.fill"; color = .systemGreen
        default: symbol = "music.note"; color = palette.textPrimary
        }
        let key = "\(symbol)|\(color)|\(view.window?.backingScaleFactor ?? 2)"
        if key != drawnKey {
            drawnKey = key
            LayerImage.set(LayerImage.symbol(symbol, size: Self.glyphSize, weight: .semibold, color: color), on: glyph, in: view)
        }
        updateMotion()
    }

    /// `bounds`: the tile's; the plate sits in its top-right corner, above the unread dot.
    func layout(in bounds: NSRect, flipped: Bool) {
        let d = Self.diameter, o = Self.inset
        let cy = flipped ? o.y : bounds.height - o.y
        layer.frame = NSRect(x: bounds.width - o.x - d / 2, y: cy - d / 2, width: d, height: d)
        glyph.frame = layer.bounds
    }

    private func updateMotion() {
        let moving = state == .playing && !AircMotion.prefersReducedMotion
        if !moving { glyph.removeAnimation(forKey: Self.animationKey); return }
        guard !isAnimating else { return }
        // A gentle sway and bob, about one beat a second; slow enough to stay calm beside the page.
        let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sway.values = [-0.14, 0.14, -0.14]
        let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bob.values = [0, 1.2, 0, 1.2, 0]
        let group = CAAnimationGroup()
        group.animations = [sway, bob]
        group.duration = 1.1
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        glyph.add(group, forKey: Self.animationKey)
    }
}

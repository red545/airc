// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

/// S03b: a Favorite's own unread badge beyond the plain dot (Arc RN22: "Slack, Twitter, GCal, and Gmail now have
/// custom badging"). X's notification count sits on a capsule in Arc's TwitterBadgeGray (#444 in light, white in dark);
/// a Slack mention is a red disc with "@", the red of Arc's GMailBadgeRed. It takes the dot's corner, bottom-right, so a
/// tile never shows both. Layers only. It pops in on a short spring when it appears or its count rises, and simply
/// appears with Reduce Motion.
@MainActor
final class UnreadBadgeFace {
    let layer = CALayer()
    private let text = CATextLayer()
    private(set) var badge: URLRules.FavoriteBadge = .none
    /// The text drawn ("3", "99+", "@"); the checks read it.
    var label: String { (text.string as? String) ?? "" }
    /// Whether the last change popped in (false under Reduce Motion); the checks read it.
    private(set) var lastChangeAnimated = false

    /// Capsule height (and the smallest width), its text size, and the space either side of the text.
    nonisolated static let height: CGFloat = 13
    nonisolated static let fontSize: CGFloat = 9
    nonisolated static let padding: CGFloat = 3.5
    /// The capsule's right edge and centre line from the tile's bottom-right corner (the dot's centre line, Arc's
    /// measured 10 pt up; its right edge 4.5 pt in, as the sound badge's top-right inset).
    nonisolated static let rightInset: CGFloat = 4.5
    nonisolated static let popKey = "airc.unreadBadge.pop"
    /// Arc's AppTray colours.
    nonisolated static let mentionRed = NSColor(srgbRed: 0.918, green: 0.263, blue: 0.208, alpha: 1)
    nonisolated static func twitterGray(dark: Bool) -> NSColor {
        dark ? .white : NSColor(srgbRed: 0.267, green: 0.267, blue: 0.267, alpha: 1)
    }

    init() {
        layer.isHidden = true
        layer.cornerCurve = .continuous
        layer.actions = LayerImage.noActions
        text.alignmentMode = .center
        text.actions = LayerImage.noActions
        text.font = NSFont.systemFont(ofSize: Self.fontSize, weight: .bold)
        text.fontSize = Self.fontSize
        layer.addSublayer(text)
    }

    /// Shows `badge` (.count or .mention; anything else hides the face).
    func set(_ badge: URLRules.FavoriteBadge, palette: Palette, in view: NSView) {
        let old = self.badge
        self.badge = badge
        let string: String
        switch badge {
        case .count(let n, let more):
            string = URLRules.badgeCountText(n, more: more)
            let gray = Self.twitterGray(dark: palette.isDark)
            layer.backgroundColor = gray.cgColor
            text.foregroundColor = (palette.isDark ? NSColor(white: 0.1, alpha: 1) : NSColor.white).cgColor
        case .mention:
            string = "@"
            layer.backgroundColor = Self.mentionRed.cgColor
            text.foregroundColor = NSColor.white.cgColor
        case .none, .dot:
            layer.isHidden = true
            layer.removeAnimation(forKey: Self.popKey)
            return
        }
        let scale = view.window?.backingScaleFactor ?? 2
        if label != string || text.contentsScale != scale || layer.isHidden {
            text.string = string
            text.contentsScale = scale
            layer.isHidden = false
            view.needsLayout = true
        }
        // Pop when it first shows, or when there's more than before (a new mention after a count, a higher count).
        let rose: Bool = {
            switch (old, badge) {
            case (.count(let a, _), .count(let b, _)): return b > a
            case (.mention, .mention): return false
            default: return true
            }
        }()
        guard rose else { return }
        lastChangeAnimated = !AircMotion.prefersReducedMotion
        guard lastChangeAnimated else { layer.removeAnimation(forKey: Self.popKey); return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.55
        pop.toValue = 1
        pop.mass = 1
        pop.stiffness = 420
        pop.damping = 26
        pop.duration = pop.settlingDuration
        layer.add(pop, forKey: Self.popKey)
    }

    /// `bounds`: the tile's. Right-aligned in the dot's corner, centred on the dot's line.
    func layout(in bounds: NSRect, flipped: Bool, dotCenterFromBottom: CGFloat) {
        guard !layer.isHidden else { return }
        let h = Self.height
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Self.fontSize, weight: .bold)]).width)
        let w = max(h, textWidth + 2 * Self.padding)
        let cy = flipped ? bounds.height - dotCenterFromBottom : dotCenterFromBottom
        layer.frame = NSRect(x: bounds.width - Self.rightInset - w, y: cy - h / 2, width: w, height: h)
        layer.cornerRadius = h / 2
        // CATextLayer draws from its top: centre the line box in the capsule.
        let lineHeight = ceil(Self.fontSize * 1.25)
        text.frame = NSRect(x: 0, y: (h - lineHeight) / 2 + (flipped ? 0 : 0.5), width: w, height: lineHeight)
    }
}

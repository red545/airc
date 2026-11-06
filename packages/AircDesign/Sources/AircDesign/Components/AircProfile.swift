// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// Profiles as identities (spec SP-10…15, docs/design.md §7 "Profiles"). Mockups:
// docs/design/mockups/profiles.html.

/// What a profile looks like: its name, emoji, colour and, once signed in, the Google account photo.
public struct AircProfileIdentity: Hashable, Sendable {
    public var name: String
    public var emoji: String
    public var color: AircColor
    /// The Google account picture (from ListAccounts). Shown instead of the emoji once signed in.
    public var photo: CGImage?
    /// The signed-in account, shown as the subtitle in the profile menu.
    public var account: String?

    public init(name: String, emoji: String = "", color: AircColor, photo: CGImage? = nil, account: String? = nil) {
        self.name = name
        self.emoji = emoji
        self.color = color
        self.photo = photo
        self.account = account
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.emoji == b.emoji && a.color == b.color && a.photo === b.photo && a.account == b.account
    }

    public func hash(into h: inout Hasher) {
        h.combine(name); h.combine(emoji); h.combine(color); h.combine(account)
        if let photo { h.combine(ObjectIdentifier(photo)) }
    }
}

/// A profile's avatar: the Google photo once signed in; otherwise the emoji (or the initial) on a pastel of the
/// profile colour. 0.5 pt inner hairline. `ring` draws a cut-out ring (e.g. the window colour) around it.
public struct AircProfileAvatar: View {
    private let identity: AircProfileIdentity
    private let size: CGFloat
    private let ring: AircColor?

    public init(_ identity: AircProfileIdentity, size: CGFloat = 16, ring: AircColor? = nil) {
        self.identity = identity
        self.size = size
        self.ring = ring
    }

    /// The app's former `ProfileAvatar(emoji:name:color:size:)`.
    public init(emoji: String, name: String, color: AircColor, size: CGFloat = 36) {
        self.init(AircProfileIdentity(name: name, emoji: emoji, color: color), size: size)
    }

    public var body: some View {
        ZStack {
            if let photo = identity.photo {
                Image(decorative: photo, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(AircProfileColor.pastel(identity.color).color)
                if !identity.emoji.isEmpty {
                    Text(identity.emoji).font(.system(size: size * 0.56))
                } else {
                    Text(String(identity.name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                        .foregroundStyle(identity.color.color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().inset(by: 0.25).stroke(AircColor.black(0.10).color, lineWidth: 0.5))
        .background { if let ring { Circle().inset(by: -1.5).fill(ring.color) } }
        .accessibilityLabel(identity.name)
    }

    /// The avatar as an image, for `NSMenuItem.image` in the native profile menu.
    @MainActor
    public static func image(_ identity: AircProfileIdentity, size: CGFloat = AircMetrics.Profile.menuAvatar, scale: CGFloat = 2) -> NSImage {
        let r = ImageRenderer(content: AircProfileAvatar(identity, size: size))
        r.scale = scale
        let img = r.nsImage ?? NSImage(size: NSSize(width: size, height: size))
        img.size = NSSize(width: size, height: size)
        return img
    }
}

/// The profile pill: avatar 16, name 12 medium, chevron. 22 pt, `pillFill`. Used in the Create a Space card's
/// Profile row (on `fieldFill`) and as the hovered profile indicator.
public struct AircProfilePill: View {
    private let identity: AircProfileIdentity
    private let showsChevron: Bool
    @Environment(\.aircTheme) private var theme

    public init(_ identity: AircProfileIdentity, showsChevron: Bool = true) {
        self.identity = identity
        self.showsChevron = showsChevron
    }

    public var body: some View {
        HStack(spacing: 5) {
            AircProfileAvatar(identity, size: AircMetrics.Profile.pillAvatar)
            Text(identity.name).aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.text.color).lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.textSecondary.color)
            }
        }
        .padding(.leading, 3)
        .padding(.trailing, showsChevron ? 7 : 8)
        .frame(height: AircMetrics.Profile.pillHeight)
        .background(Capsule().fill(theme.pillFill.color))
        .contentShape(Capsule())
    }
}

/// Arc's ProfileIndicatorView in the Space header (SP-15): shown only while several profiles are in use.
/// At rest: avatar + name in `caption`, `textTertiary`, no fill. Hovered: a `tileFill` pill with a chevron that
/// opens Set Profile ›. `condensed` shows only the avatar, used when the Space name needs the room.
public struct AircProfileIndicator: View {
    public enum Size: Sendable { case condensed, full }

    private let identity: AircProfileIdentity
    private let size: Size
    private let isHovered: Bool
    @Environment(\.aircTheme) private var theme

    public init(_ identity: AircProfileIdentity, size: Size = .full, isHovered: Bool = false) {
        self.identity = identity
        self.size = size
        self.isHovered = isHovered
    }

    public var body: some View {
        HStack(spacing: 5) {
            AircProfileAvatar(identity, size: AircMetrics.Profile.pillAvatar)
            if size == .full {
                Text(identity.name).aircFont(AircFont.caption)
                    .foregroundStyle((isHovered ? theme.textSecondary : theme.textTertiary).color).lineLimit(1)
            }
            if isHovered {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.textTertiary.color)
            }
        }
        .padding(.leading, 3)
        .padding(.trailing, isHovered ? 5 : 4)
        .frame(height: AircMetrics.Profile.pillHeight)
        .background(Capsule().fill((isHovered ? theme.tileFill : .clear).color))
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Profile: \(identity.name)")
    }

    /// Arc's rule for the header: the indicator condenses before the Space name has to fade. Pass the room left for
    /// the indicator after the name's natural width.
    public static func size(forAvailableWidth width: CGFloat, nameWidth: CGFloat) -> Size {
        // avatar 16 + gap 5 + name + padding 7 + chevron allowance 12
        width >= nameWidth + 40 ? .full : .condensed
    }
}

/// The dot on a footer Space icon (SP-15): 6 pt in the profile colour with a 1.5 pt cut-out ring in the window
/// colour. Place it 6 pt in from the cell's bottom-right; hide it while only one profile is in use.
public struct AircProfileDot: View {
    private let color: AircColor
    @Environment(\.aircTheme) private var theme
    public init(color: AircColor) { self.color = color }

    public var body: some View {
        Circle().fill(color.color)
            .frame(width: AircMetrics.Profile.footerDot, height: AircMetrics.Profile.footerDot)
            .background(Circle().inset(by: -AircMetrics.Profile.footerDotRing).fill(theme.profileDotRing.color))
            .accessibilityHidden(true)
    }
}

/// A Space tile as a checkbox (Create Profile step 2, "Choose the Spaces for this Profile"): 84 × 64 in the
/// Space's own theme with its emoji and a hint of its sidebar, a round check at the top right, the name below and
/// the profile it uses now under that. Selected: accent check and a 2 pt accent ring with a 2 pt gap.
public struct AircSpaceTile: View {
    private let theme: ResolvedTheme
    private let emoji: String
    private let name: String
    private let currentProfile: AircProfileIdentity?
    @Binding private var isOn: Bool
    @Environment(\.aircTheme) private var ui

    public init(theme: ResolvedTheme, emoji: String, name: String, currentProfile: AircProfileIdentity? = nil, isOn: Binding<Bool>) {
        self.theme = theme
        self.emoji = emoji
        self.name = name
        self.currentProfile = currentProfile
        _isOn = isOn
    }

    public var body: some View {
        let m = AircMetrics.Profile.self
        let shape = RoundedRectangle(cornerRadius: m.spaceTileRadius, style: .continuous)
        VStack(spacing: 7) {
            ZStack(alignment: .topLeading) {
                SpaceBackground(theme)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach([1.0, 0.7, 0.85], id: \.self) { w in
                        Capsule().fill(theme.text.alpha(0.18).color).frame(width: 22 * w, height: 3)
                    }
                }
                .padding(.leading, 8).padding(.top, 9)
                Text(emoji).font(.system(size: 24)).frame(maxWidth: .infinity, maxHeight: .infinity)
                check.frame(maxWidth: .infinity, alignment: .trailing).padding(6)
            }
            .frame(width: m.spaceTile.width, height: m.spaceTile.height)
            .clipShape(shape)
            .overlay(shape.inset(by: 0.25).stroke(AircColor.black(0.10).color, lineWidth: 0.5))
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: m.spaceTileRadius + 4, style: .continuous).inset(by: 1)
                .stroke((isOn ? ui.accent : .clear).color, lineWidth: 2))
            .padding(-4)
            Text(name).aircFont(AircFont.callout.weight(.medium)).foregroundStyle(ui.surfaceText.color).lineLimit(1)
            if let currentProfile {
                HStack(spacing: 4) {
                    AircProfileAvatar(currentProfile, size: 12)
                    Text(currentProfile.name).aircFont(AircFont.caption.weight(.regular)).foregroundStyle(ui.surfaceTextTertiary.color).lineLimit(1)
                }
                .padding(.top, -4)
            }
        }
        .frame(width: m.spaceTile.width)
        .contentShape(Rectangle())
        .onTapGesture { withAircAnimation(AircSpring.toggle) { isOn.toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var check: some View {
        ZStack {
            if isOn {
                Circle().fill(ui.accent.color)
                Circle().inset(by: -0.75).stroke(Color.white, lineWidth: 1.5)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(ui.onAccent.color)
            } else {
                Circle().fill(AircColor.white(0.85).color)
                Circle().inset(by: 0.5).stroke(AircColor.black(0.18).color, lineWidth: 1)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// A card on the sidebar's theme (the "Sign in to Google" card, SP-12, and the Favorites offer after it):
/// 112 pt, radius 12, `sidebarCardFill` with the selected-row shadow. Icon 16 + title (`body` semibold), a
/// `callout` message in `textSecondary`, a small primary and a plain button, and a 20 pt dismiss.
public struct AircSidebarCard<Icon: View>: View {
    private let title: String
    private let message: String
    private let primary: String
    private let secondary: String?
    private let icon: Icon
    private let onPrimary: () -> Void
    private let onSecondary: (() -> Void)?
    private let onDismiss: (() -> Void)?
    @Environment(\.aircTheme) private var theme

    public init(title: String, message: String, primary: String, secondary: String? = "Not now",
                onPrimary: @escaping () -> Void, onSecondary: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil,
                @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.message = message
        self.primary = primary
        self.secondary = secondary
        self.icon = icon()
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onDismiss = onDismiss
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: AircMetrics.Profile.signInCardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                icon.frame(height: 16)
                Text(title).aircFont(AircFont.body.weight(.semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                Spacer(minLength: 20)
            }
            .frame(height: 18)
            Text(message).aircFont(AircFont.callout).foregroundStyle(theme.textSecondary.color)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true).padding(.top, 5)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Button(primary, action: onPrimary).buttonStyle(.airc(.primary, size: .small))
                if let secondary {
                    Button(secondary) { (onSecondary ?? onDismiss)?() }.buttonStyle(.airc(.plain, size: .small))
                }
            }
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 10, trailing: 12))
        .frame(height: AircMetrics.Profile.signInCardHeight)
        .background(shape.fill(theme.sidebarCardFill.color).aircShadow(theme.selectedHasShadow ? .rowSelected : .none))
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textTertiary.color)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(7)
                .accessibilityLabel("Dismiss")
            }
        }
    }
}

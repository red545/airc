// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import SwiftUI

// An empty Space (docs/qa/visual-review.md #2; mockup profiles-sign-in.png): what the page card shows when the Space
// has no tab, including the very first window after onboarding. It sits on `surface` (never black), so dark themes
// read as a calm page, not a broken one.

/// The empty-Space page: the Space's emoji at 40 pt, its name in `title2`, a profile line ("‹Profile› profile · its own
/// logins, history and extensions" with the avatar) while several profiles are in use, and ⌘ T + "New Tab".
/// Fill the page card with it; it draws its own `surface` background.
public struct AircEmptySpaceView: View {
    private let emoji: String?
    private let name: String
    private let profile: AircProfileIdentity?
    private let profileNote: String
    private let onNewTab: (() -> Void)?
    @Environment(\.aircTheme) private var theme

    public static let defaultProfileNote = "its own logins, history and extensions"

    /// - Parameters:
    ///   - profile: the Space's profile, or nil while only one profile is in use (the line is then left out).
    ///   - onNewTab: makes the ⌘ T hint a button.
    public init(emoji: String?, name: String, profile: AircProfileIdentity? = nil,
                profileNote: String = AircEmptySpaceView.defaultProfileNote, onNewTab: (() -> Void)? = nil) {
        self.emoji = emoji
        self.name = name
        self.profile = profile
        self.profileNote = profileNote
        self.onNewTab = onNewTab
    }

    public var body: some View {
        let m = AircMetrics.EmptySpace.self
        VStack(spacing: 0) {
            if let emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: m.emoji)).frame(height: m.emoji + 8)
            } else {
                Circle().fill(theme.surfaceText.alpha(0.6).color).frame(width: 10, height: 10).frame(height: m.emoji + 8)
            }
            Text(name.isEmpty ? "Untitled Space" : name)
                .aircFont(AircFont.title2)
                .foregroundStyle(theme.surfaceText.color)
                .lineLimit(1)
                .padding(.top, m.nameGap)
            if let profile {
                HStack(spacing: 6) {
                    AircProfileAvatar(profile, size: AircMetrics.Profile.pillAvatar)
                    Text("\(profile.name) profile · \(profileNote)")
                        .aircFont(AircFont.body)
                        .foregroundStyle(theme.surfaceTextSecondary.color)
                        .lineLimit(1)
                }
                .padding(.top, m.profileGap)
            }
            hint.padding(.top, m.hintGap)
        }
        .padding(.bottom, m.liftAboveCentre)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.color)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var hint: some View {
        let row = HStack(spacing: 4) {
            AircKeycap("⌘")
            AircKeycap("T")
            Text("New Tab").aircFont(AircFont.body).foregroundStyle(theme.surfaceTextTertiary.color).padding(.leading, 4)
        }
        if let onNewTab {
            Button(action: onNewTab) { row.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            row
        }
    }
}

extension AircMetrics {
    /// The empty-Space page (review #2).
    public enum EmptySpace {
        public static let emoji: CGFloat = 40
        public static let nameGap: CGFloat = 6
        public static let profileGap: CGFloat = 8
        public static let hintGap: CGFloat = 20
        /// The group sits this much above the card's centre (optical centre).
        public static let liftAboveCentre: CGFloat = 24
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AircDesign
import AppKit
import SwiftUI

// The profile-flow pieces drawn with the real SwiftUI components (design pass 3), so the mockups in
// docs/design/mockups/profiles.html can be compared with what AircDesign actually renders.

private let personal = AircProfileIdentity(name: "Personal", emoji: "🏡", color: AircProfileColor.choices[1], account: "alex@example.com")
private let acme = AircProfileIdentity(name: "Acme", emoji: "💼", color: AircProfileColor.choices[0], account: "alex@acme.example")
private let studio = AircProfileIdentity(name: "Studio", emoji: "🎨", color: AircProfileColor.choices[3])
private let freelance = AircProfileIdentity(name: "Freelance", emoji: "🪴", color: AircProfileColor.choices[2])

/// The Create a Space card, built from tokens and components, on a 228 pt sidebar.
struct CreateSpaceCardSample: View {
    let theme: ResolvedTheme
    let preview: ResolvedTheme
    var name = "Side project"
    @Environment(\.aircTheme) private var ui

    var body: some View {
        let m = AircMetrics.CreateSpace.self
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.tileFill.color)
                .frame(width: 36, height: 50).overlay(Text("🗂️").font(.system(size: 22)))
                .frame(width: m.illustration.width, height: m.illustration.height)
            Text("Create a Space").aircFont(AircFont.title3).foregroundStyle(ui.text.color).padding(.top, 14)
            Text("Give each part of your life its own tabs.").aircFont(AircFont.callout)
                .foregroundStyle(ui.textSecondary.color).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 184).padding(.top, 4)
            HStack(spacing: 8) {
                Text("🌱").font(.system(size: 16)).frame(width: m.iconButton, height: m.iconButton)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ui.tileFill.color))
                Text(name.isEmpty ? "Space name" : name).aircFont(AircFont.body)
                    .foregroundStyle((name.isEmpty ? ui.textTertiary : ui.text).color)
                Spacer()
            }
            .padding(.leading, 4)
            .frame(height: m.rowHeight)
            .background(RoundedRectangle(cornerRadius: m.rowRadius, style: .continuous).fill(ui.fieldFill.color))
            .overlay(RoundedRectangle(cornerRadius: m.rowRadius, style: .continuous).inset(by: 0.75).stroke(ui.accent.color, lineWidth: 1.5))
            .padding(.top, 20)
            row("Profile") { AircProfilePill(personal) }
            row("Choose a Theme") {
                HStack(spacing: 8) {
                    AircThemeChip(theme: preview)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(ui.textTertiary.color)
                }
            }
            Text("Create Space").aircFont(AircFont.body.weight(.semibold)).foregroundStyle(ui.onAccent.color)
                .frame(maxWidth: .infinity).frame(height: m.buttonHeight)
                .background(RoundedRectangle(cornerRadius: m.buttonRadius, style: .continuous).fill(ui.accent.color))
                .opacity(name.isEmpty ? m.disabledOpacity : 1)
                .padding(.top, 20)
            Text("Cancel").aircFont(AircFont.body.weight(.medium)).foregroundStyle(ui.textSecondary.color).frame(height: 30).padding(.top, 6)
        }
        .frame(width: m.width)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ trailing: () -> C) -> some View {
        HStack {
            Text(label).aircFont(AircFont.body).foregroundStyle(ui.textSecondary.color)
            Spacer()
            trailing()
        }
        .padding(.leading, 12).padding(.trailing, 7)
        .frame(height: AircMetrics.CreateSpace.rowHeight)
        .background(RoundedRectangle(cornerRadius: AircMetrics.CreateSpace.rowRadius, style: .continuous).fill(ui.fieldFill.color))
        .padding(.top, AircMetrics.CreateSpace.rowGap)
    }
}

struct ProfilesSheet: View {
    @State private var picked: SpaceTheme = SpaceTheme.preset("sky")!
    @State private var on = [false, false, true, false, true]
    @State private var loading = true

    var body: some View {
        let sky = SpaceTheme.preset("sky")!.resolved(systemIsDark: false)
        let lilac = SpaceTheme.preset("lilac")!.resolved(systemIsDark: false)
        let ocean = SpaceTheme.preset("ocean")!.resolved(systemIsDark: true)
        HStack(alignment: .top, spacing: 24) {
            // 1. Create a Space card + header indicators + footer dots + sign-in card, on the sidebar theme
            VStack(spacing: 18) {
                CreateSpaceCardSample(theme: sky, preview: sky).padding(.vertical, 18)
                header("🏡", "Personal", personal, hovered: false)
                header("🏡", "Personal", personal, hovered: true)
                header("🎨", "Studio and brand refresh", studio, hovered: false)
                HStack(spacing: 18) {
                    ForEach([("🏡", personal), ("💼", acme), ("🎨", studio), ("🌱", freelance)], id: \.1.name) { e, p in
                        Text(e).font(.system(size: 16)).frame(width: 34, height: 34)
                            .overlay(alignment: .bottomTrailing) { AircProfileDot(color: p.color).padding(6) }
                    }
                }
                AircSidebarCard.signInToGoogle(onSignIn: {}, onNotNow: {}, onDismiss: {})
                    .padding(.horizontal, 8)
                HStack(spacing: 10) {
                    AircLoadingRing(isLoading: loading).frame(width: 18, height: 18)
                    AircFadingText("TechCrunch | Startup and Technology News", style: AircFont.row)
                        .foregroundStyle(sky.text.color)
                }
                .padding(.leading, 17).padding(.trailing, 17).frame(height: 36)
            }
            .frame(width: 228)
            .padding(.vertical, 10)
            .background(SpaceBackground(sky))
            .aircTheme(sky)

            // 2. Step 2 tiles and the profile avatars, on the dialog surface
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose the Spaces for this Profile").aircFont(AircFont.title2).foregroundStyle(lilac.surfaceText.color)
                HStack(alignment: .top, spacing: AircMetrics.Profile.spaceTileGap) {
                    AircSpaceTile(theme: SpaceTheme.preset("mint")!.resolved(systemIsDark: false), emoji: "🏡", name: "Personal", currentProfile: personal, isOn: $on[0])
                    AircSpaceTile(theme: ocean, emoji: "💼", name: "Work", currentProfile: acme, isOn: $on[1])
                    AircSpaceTile(theme: lilac, emoji: "🎨", name: "Studio", currentProfile: studio, isOn: $on[2])
                    AircSpaceTile(theme: SpaceTheme.preset("peach")!.resolved(systemIsDark: false), emoji: "✈️", name: "Travel", currentProfile: personal, isOn: $on[3])
                    AircSpaceTile(theme: SpaceTheme.preset("lemon")!.resolved(systemIsDark: false), emoji: "🤝", name: "Clients", currentProfile: personal, isOn: $on[4])
                }
                HStack(alignment: .bottom, spacing: 14) {
                    AircProfileAvatar(freelance, size: 64)
                    AircProfileAvatar(studio, size: 28)
                    AircProfileAvatar(acme, size: 22)
                    AircProfileAvatar(AircProfileIdentity(name: "Zoe", color: AircProfileColor.choices[4]), size: 22)
                    AircProfilePill(freelance)
                }
                AircProfileColorPicker(selection: .constant(2))
                AircSegmented(selection: .constant(1), segments: [.init(value: 0, title: "Off"), .init(value: 1, title: "Subtle"), .init(value: 2, title: "More")])
                    .frame(width: 260)
                    .aircTheme(ocean)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(ocean.surface.color))
            }
            .padding(28)
            .frame(width: 520, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(lilac.surface.color))
            .aircTheme(lilac)

            // 3. The theme picker
            AircThemePicker(theme: $picked, systemIsDark: false).aircTheme(sky)
        }
        .padding(24)
        .background(Color(white: 0.08))
    }

    private func header(_ emoji: String, _ name: String, _ p: AircProfileIdentity, hovered: Bool) -> some View {
        HStack(spacing: 2) {
            Text(emoji).font(.system(size: 15)).frame(width: 26, height: 26)
            AircFadingText(name, style: AircFont.spaceName).foregroundStyle(SpaceTheme.preset("sky")!.resolved(systemIsDark: false).textSecondary.color)
            AircProfileIndicator(p, size: hovered || name.count > 12 ? .condensed : .full, isHovered: hovered)
            if hovered { Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).frame(width: 24, height: 24) }
        }
        .padding(.horizontal, 5)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovered ? AircColor.inkLight.alpha(0.05).color : .clear))
        .padding(.horizontal, 8)
    }
}

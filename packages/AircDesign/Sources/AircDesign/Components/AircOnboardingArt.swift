// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// The two performing moments of onboarding (docs/design.md §7), moved here from Airc.app's onboarding files.

/// The welcome step's background: the app icon's pastels (mint, sky, lilac, pink) blooming over white 0.84, with
/// fine grain.
public struct AircWelcomeBloom: View {
    public init() {}
    public var body: some View {
        ZStack {
            Color.white.opacity(0.84)
            RadialGradient(colors: [AircColor(0x9EE6CB).alpha(0.75).color, .clear], center: UnitPoint(x: 0.18, y: 0.18), startRadius: 0, endRadius: 330)
            RadialGradient(colors: [AircColor(0xF6C5DA).alpha(0.75).color, .clear], center: UnitPoint(x: 0.85, y: 0.2), startRadius: 0, endRadius: 340)
            RadialGradient(colors: [AircColor(0xB9D4FA).alpha(0.8).color, .clear], center: UnitPoint(x: 0.28, y: 0.95), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [AircColor(0xD6C4F7).alpha(0.8).color, .clear], center: UnitPoint(x: 0.85, y: 0.92), startRadius: 0, endRadius: 320)
            AircGrainOverlay(opacity: 0.06)
        }
        .allowsHitTesting(false)
    }
}

/// The member card (Arc had one): holographic, wearing the app icon, with the name, the member number, the date, a
/// title earned from the choices made and the Space emojis. 360 × 214, radius 18, tilted −2°.
public struct AircMemberCard: View {
    public static let size = CGSize(width: 360, height: 214)

    private let name: String
    private let number: Int
    private let since: Date
    private let title: String
    private let emojis: [String]
    private let icon: NSImage?
    private let tilt: Bool

    public init(name: String, number: Int, since: Date = Date(), title: String, emojis: [String], icon: NSImage? = nil, tilt: Bool = true) {
        self.name = name
        self.number = number
        self.since = since
        self.title = title
        self.emojis = emojis
        self.icon = icon
        self.tilt = tilt
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [
                .init(color: AircColor(0x7FD8C4).color, location: 0),
                .init(color: AircColor(0x4F8BEA).color, location: 0.38),
                .init(color: AircColor(0x5B63EE).color, location: 0.62),
                .init(color: AircColor(0xA35BEA).color, location: 0.86),
                .init(color: AircColor(0xE25FA8).color, location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            AircGrainOverlay(opacity: 0.22)
            LinearGradient(colors: [.white.opacity(0.22), .clear, .white.opacity(0.08)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 46, height: 46).padding(-4)
                    }
                    Spacer()
                    Text(String(format: "No. %03d %03d", number / 1000 % 1000, number % 1000))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                Text(name.isEmpty ? "Member" : name)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Member since " + since.formatted(.dateTime.day().month(.abbreviated).year()))
                        Text(title)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Text(emojis.prefix(6).joined(separator: " ")).font(.system(size: 13))
                }
                .padding(.top, 6)
            }
            .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(shape)
        .overlay(shape.inset(by: 0.5).stroke(.white.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 14)
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .rotationEffect(.degrees(tilt ? -2 : 0))
        .accessibilityElement(children: .combine)
    }
}

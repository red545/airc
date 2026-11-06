// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// One onboarding step, laid out for the floating onboarding window (`AircFloatingWindow`, 760 × 540, spec
/// ON-5). The live sidebar preview sits on the theme at the left (228 pt, the real sidebar width, 1:1), and the
/// step card is a pane flush with the window's top, right and bottom edges, so the window's own 24 pt corners
/// are its corners and no strip of theme shows around it. Without a preview the pane fills the window.
///
/// The page is exactly the window's size whatever its content: the preview and the card never grow it. A step
/// whose content is taller than the room left scrolls or clips inside the card (`AircOnboardingCard`), and the
/// preview clips its rows, so a hover that changes what the preview lists never moves or resizes anything.
///
/// ```swift
/// window.setContent(
///     AircOnboardingPage(step: 2, of: 5, title: "Bring your Arc with you.",
///                        subtitle: "Spaces, pinned tabs, Favorites and logins, in under a minute.",
///                        drawsBackground: false) {        // the window draws the theme
///         SidebarPreview(plan)
///     } content: {
///         ImportChecklist()
///     } actions: {
///         Button("Start fresh") { … }.buttonStyle(.airc(.plain, size: .large))
///         Spacer()
///         Button("Import everything") { … }.buttonStyle(.airc(.primary, size: .large))
///     }
///     .aircTheme(theme)
/// )
/// ```
public struct AircOnboardingPage<Preview: View, Content: View, Actions: View>: View {
    private let step: Int
    private let total: Int
    private let title: String
    private let subtitle: String?
    private let drawsBackground: Bool
    private let translucency: AircTranslucency
    private let preview: Preview
    private let content: Content
    private let actions: Actions

    @Environment(\.aircTheme) private var theme

    /// A step with a live preview on the left. `drawsBackground: false` when the window already draws the
    /// theme (`AircFloatingWindow.background`).
    public init(step: Int, of total: Int, title: String, subtitle: String? = nil,
                drawsBackground: Bool = true, translucency: AircTranslucency = .off,
                @ViewBuilder preview: () -> Preview,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.step = step
        self.total = total
        self.title = title
        self.subtitle = subtitle
        self.drawsBackground = drawsBackground
        self.translucency = translucency
        self.preview = preview()
        self.content = content()
        self.actions = actions()
    }

    private var hasPreview: Bool { Preview.self != EmptyView.self }

    public var body: some View {
        let size = AircMetrics.Onboarding.windowSize
        ZStack(alignment: .topLeading) {
            if drawsBackground {
                SpaceBackground(theme, translucency: translucency)
            }
            HStack(spacing: 0) {
                if hasPreview {
                    // Fixed frames all the way down: a child that wants more height is clipped, never obeyed (a flexible
                    // frame takes a taller child's height, which pushed the card off the window's top and bottom).
                    preview
                        .frame(width: AircMetrics.Onboarding.previewWidth, height: size.height, alignment: .top)
                        .clipped()
                }
                AircOnboardingCard(step: step, of: total, title: title, subtitle: subtitle, fills: true, leadingEdge: hasPreview) {
                    content
                } actions: {
                    actions
                }
                .frame(width: size.width - (hasPreview ? AircMetrics.Onboarding.previewWidth : 0), height: size.height)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}

extension AircOnboardingPage where Preview == EmptyView {
    /// A step without a preview: the card fills the window.
    public init(step: Int, of total: Int, title: String, subtitle: String? = nil,
                drawsBackground: Bool = true, translucency: AircTranslucency = .off,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(step: step, of: total, title: title, subtitle: subtitle, drawsBackground: drawsBackground,
                  translucency: translucency, preview: { EmptyView() }, content: content, actions: actions)
    }
}

/// The onboarding card: 32 pt padding, step dots, title, subtitle, content, and an actions row pinned to the bottom.
/// The content gets the room that's left and never grows the card, so steps cross-fade in place and the actions
/// stay where they are. In the window (`fills`) it is a pane flush with the window's edges, with a hairline and a soft
/// shadow on its leading edge over the preview; alone it is a 532 × 540 pt card with 14 pt corners.
public struct AircOnboardingCard<Content: View, Actions: View>: View {
    public static var size: CGSize { AircMetrics.Onboarding.cardSize }

    private let step: Int
    private let total: Int
    private let title: String
    private let subtitle: String?
    private let fills: Bool
    private let leadingEdge: Bool
    private let content: Content
    private let actions: Actions

    @Environment(\.aircTheme) private var theme

    public init(step: Int, of total: Int, title: String, subtitle: String? = nil,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(step: step, of: total, title: title, subtitle: subtitle, fills: false, leadingEdge: false,
                  content: content, actions: actions)
    }

    init(step: Int, of total: Int, title: String, subtitle: String?, fills: Bool, leadingEdge: Bool,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.step = step
        self.total = total
        self.title = title
        self.subtitle = subtitle
        self.fills = fills
        self.leadingEdge = leadingEdge
        self.content = content()
        self.actions = actions()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: AircMetrics.Onboarding.cardRadius, style: .continuous)
        let hairline = (theme.isDark ? AircColor.white(0.08) : AircColor.black(0.08)).color
        let card = VStack(alignment: .leading, spacing: 0) {
            AircStepIndicator(step: step, of: total)
                .padding(.bottom, 24)
            Text(title)
                .aircFont(AircFont.title1)
                .foregroundStyle(theme.surfaceText.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .aircFont(AircFont.lead)
                    .foregroundStyle(theme.surfaceTextSecondary.color)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            // The content gets what's left. As an overlay it can't make the card taller; past the room it clips just
            // short of the actions (lists in it scroll). Its own controls keep a few points for focus rings and rings.
            Color.clear
                .overlay(alignment: .topLeading) { content.frame(maxWidth: .infinity, alignment: .topLeading) }
                .clipShape(Rectangle().inset(by: -6))
                .padding(.top, 24)
                .padding(.bottom, 20)
            HStack(spacing: 8) { actions }
        }
        .padding(AircMetrics.Onboarding.cardPadding)
        return Group {
            if fills {
                // A pane: the window's mask rounds its outer corners, so there's nothing of its own to line up.
                card.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Rectangle().fill(theme.surface.color)
                        .shadow(color: leadingEdge ? AircColor.black(theme.isDark ? 0.28 : 0.07).color : .clear, radius: 6, x: -1))
                    .overlay(alignment: .leading) {
                        if leadingEdge { Rectangle().fill(hairline).frame(width: 0.5) }
                    }
            } else {
                card.frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                    .background(shape.fill(theme.surface.color))
                    .overlay(shape.inset(by: 0.25).stroke(hairline, lineWidth: 0.5))
                    .aircShadow(theme.isDark ? .cardDark : .card)
            }
        }
    }
}

/// The welcome and finish steps: art (the app icon, or the member card), a display title in SF Pro Rounded,
/// a lead and centred actions, straight on the window's theme. Text uses the theme's ink, so its contrast
/// floors hold on any theme.
public struct AircOnboardingHero<Art: View, Actions: View>: View {
    private let title: String
    private let subtitle: String?
    private let art: Art
    private let actions: Actions
    @Environment(\.aircTheme) private var theme

    public init(title: String, subtitle: String? = nil, @ViewBuilder art: () -> Art, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.art = art()
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            art
            Text(title)
                .aircFont(AircFont.display)
                .foregroundStyle(theme.text.color)
                .multilineTextAlignment(.center)
                .padding(.top, 28)
            if let subtitle {
                Text(subtitle)
                    .aircFont(AircFont.lead)
                    .foregroundStyle(theme.textSecondary.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .padding(.top, 10)
            }
            HStack(spacing: 10) { actions }
                .padding(.top, 32)
            Spacer(minLength: 0)
        }
        .padding(AircSpacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Step dots: the current step is a 20 × 6 accent capsule, the others 6 pt dots.
public struct AircStepIndicator: View {
    private let step: Int
    private let total: Int
    @Environment(\.aircTheme) private var theme

    /// `step` is 1-based.
    public init(step: Int, of total: Int) {
        self.step = step
        self.total = total
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(1...max(1, total), id: \.self) { i in
                Capsule()
                    .fill((i == step ? theme.accent : theme.surfaceText.alpha(i < step ? 0.30 : 0.14)).color)
                    .frame(width: i == step ? 20 : 6, height: 6)
            }
        }
        .aircAnimation(AircSpring.toggle, value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step) of \(total)")
    }
}

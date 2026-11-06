// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import SwiftUI

/// The live sidebar on the left of the onboarding window (design §7): the browser's sidebar at 1:1 (228 pt, the same
/// AircMetrics as the real one: 41 pt rows, 14 pt titles, 18 pt favicons, 47 pt tiles, the footer), without window
/// buttons, rebuilding as the import is read and as choices change. It draws straight on the window's theme in theme
/// ink.
///
/// Its bounds are fixed (228 × the window's height): the header, URL field, Favorites and footer have the real sidebar's
/// fixed heights, and the Space's rows get what's left and clip there with a short fade, the way the real sidebar's
/// list runs under its footer. Switching the Space it shows (hovering a profile row, a Space chip) recolours and
/// re-lists it in place; nothing outside it moves.
struct SidebarPreview: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.aircTheme) private var theme

    private var space: ImportBlueprint.Space { model.focused }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            urlField
            favorites
            Color.clear
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        spaceHeader
                        rows
                    }
                }
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    }
                }
                .clipped()
                .testAnchor("onboarding.preview.rows")
            footer
        }
        .frame(width: AircMetrics.Sidebar.defaultWidth, height: AircMetrics.Onboarding.windowSize.height, alignment: .top)
        .clipped()
        .allowsHitTesting(false)
        .testAnchor("onboarding.preview")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sidebar preview: \(space.name)")
    }

    // MARK: Header: the background-work pill sits where the browser's buttons will be.

    private var header: some View {
        ZStack(alignment: .leading) {
            if case .running(let label, let p) = model.importState {
                ProgressPill(label: label, progress: p)
                    .transition(.opacity)
            }
        }
        .frame(height: AircMetrics.Sidebar.urlFieldTop)
        .padding(.horizontal, AircMetrics.Sidebar.inset)
        .aircAnimation(AircCurve.previewIn, value: model.isImporting)
    }

    private var urlField: some View {
        let first = firstURL
        return RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous)
            .fill(theme.fieldFill.color)
            .overlay(alignment: .leading) {
                Text(first.map(URLRules.displayHost) ?? "")
                    .aircFont(AircFont.urlField)
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(.leading, 12)
            }
            .frame(height: AircMetrics.Sidebar.urlFieldHeight)
            .padding(.horizontal, AircMetrics.Sidebar.inset)
    }

    private var firstURL: String? {
        if case .tab(let t)? = space.pinned.first { return t.url }
        return model.favorites(of: space).first?.url ?? space.today.first?.url
    }

    // MARK: Favorites

    @ViewBuilder private var favorites: some View {
        let favs = model.favorites(of: space)
        let shown = Array(favs.prefix(model.revealedFavorites))
        if !favs.isEmpty {
            let width = Double(AircMetrics.Sidebar.defaultWidth - 2 * AircMetrics.Sidebar.inset)
            let layout = FavoritesGrid.layout(count: favs.count, width: width)
            ZStack(alignment: .topLeading) {
                ForEach(Array(shown.enumerated()), id: \.element.sourceID) { i, f in
                    let r = FavoritesGrid.frame(index: i, layout: layout)
                    RoundedRectangle(cornerRadius: AircMetrics.Favorites.radius, style: .continuous)
                        .fill(theme.tileFill.color)
                        .overlay(RemoteFavicon(pageURL: f.url, size: AircMetrics.Favorites.favicon))
                        .frame(width: r.w, height: r.h)
                        .offset(x: r.x, y: r.y)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .frame(width: width, height: layout.height, alignment: .topLeading)
            .padding(.horizontal, AircMetrics.Sidebar.inset)
            .padding(.top, AircMetrics.Sidebar.inset)
            .aircAnimation(AircSpring.fold, value: model.revealedFavorites)
        }
    }

    // MARK: Space header and rows

    /// The Space name row, as the sidebar's (SpaceHeaderView): icon and name, and with several profiles in use the
    /// profile indicator at the trailing edge (avatar and name in `caption`, muted). Hovering the profile's row in the
    /// card lights the row and puts the indicator on its pill.
    private var spaceHeader: some View {
        let showsPill = model.hoveredProfile != nil && model.hoveredProfile == space.profileSourceID
        let profile = model.profile(of: space)
            ?? model.profileRows.first { $0.id == space.profileSourceID }?.profile
        let showsIndicator = model.profileRows.count > 1 && profile != nil
        return HStack(spacing: 0) {
            if case .emoji(let e)? = space.icon {
                Text(e).font(.system(size: 16)).frame(width: AircMetrics.SpaceHeader.iconFrame)
                    .padding(.leading, AircMetrics.SpaceHeader.iconCenterX - AircMetrics.SpaceHeader.iconFrame / 2 - AircMetrics.Sidebar.inset)
                Spacer().frame(width: AircMetrics.SpaceHeader.nameX - AircMetrics.SpaceHeader.iconCenterX - AircMetrics.SpaceHeader.iconFrame / 2)
            } else {
                Spacer().frame(width: AircMetrics.SpaceHeader.nameXWithoutIcon - AircMetrics.Sidebar.inset)
            }
            AircFadingText(space.name, style: AircFont.spaceName).foregroundStyle(theme.textSecondary.color)
            if showsIndicator, let p = profile {
                HStack(spacing: 5) {
                    AircProfileAvatar(AircProfileIdentity(name: p.name, emoji: p.emoji, color: p.color?.aircColor ?? theme.accent), size: 16)
                    Text(p.name).aircFont(AircFont.caption).foregroundStyle((showsPill ? theme.textSecondary : theme.textTertiary).color)
                        .lineLimit(1)
                }
                .padding(.horizontal, showsPill ? 6 : 0)
                .frame(height: 22)
                .background(Capsule().fill(showsPill ? theme.tileFill.color : .clear))
                .fixedSize()
                .padding(.leading, 8)
                .padding(.trailing, 3)
            }
        }
        .frame(height: AircMetrics.SpaceHeader.plateHeight)
        .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(showsPill ? theme.hoverFill.color : .clear))
        .padding(.horizontal, AircMetrics.Sidebar.inset)
        .padding(.vertical, (AircMetrics.Row.pitch - AircMetrics.SpaceHeader.plateHeight) / 2)
        .padding(.top, 5)   // the sidebar's header sits 1 pt lower than 4 put it (measured side by side, importux)
        .aircAnimation(AircCurve.previewIn, value: showsPill)
    }

    private struct Line: Identifiable {
        var id: String
        var title: String
        var url: String?
        var depth: Int
        var isFolder: Bool
    }

    private var lines: [Line] {
        var out: [Line] = []
        func walk(_ nodes: [ImportBlueprint.Node], depth: Int) {
            for n in nodes {
                switch n {
                case .tab(let t):
                    out.append(Line(id: t.sourceID, title: t.title ?? t.pageTitle ?? URLRules.displayHost(t.url), url: t.url, depth: depth, isFolder: false))
                case .folder(let f):
                    out.append(Line(id: f.sourceID, title: f.title, url: nil, depth: depth, isFolder: true))
                    walk(f.children, depth: depth + 1)
                case .split(let x):
                    // SV-2: one row for a pinned split, its tabs' names joined as on its sidebar row.
                    out.append(Line(id: x.sourceID, title: x.title ?? x.tabs.map { $0.title ?? $0.pageTitle ?? URLRules.displayHost($0.url) }.joined(separator: " | "),
                                    url: x.tabs.first?.url, depth: depth, isFolder: false))
                }
            }
        }
        walk(space.pinned, depth: 0)
        // More than the window can show; the rest is clipped (a long Arc sidebar is hundreds of rows).
        return Array(out.prefix(Self.maxLines))
    }

    /// Enough rows to fill the window's height with no Favorites.
    static let maxLines = 12

    /// Today's tabs under New Tab, when the pinned rows leave room for them.
    private var todayLines: [Line] {
        Array(space.today.prefix(max(0, Self.maxLines - lines.count))).map {
            Line(id: $0.sourceID, title: $0.title ?? $0.pageTitle ?? URLRules.displayHost($0.url), url: $0.url, depth: 0, isFolder: false)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { i, l in
                row(l).testAnchor("onboarding.preview.line\(i)")
            }
            Rectangle().fill(theme.separator.color).frame(height: 1)
                .padding(.horizontal, AircMetrics.Divider.inset).padding(.vertical, 7)
            HStack(spacing: 0) {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textTertiary.color)
                    .frame(width: AircMetrics.Row.favicon).padding(.leading, AircMetrics.Row.faviconX - AircMetrics.Sidebar.inset)
                Text("New Tab").aircFont(AircFont.row).foregroundStyle(theme.textTertiary.color)
                    .padding(.leading, AircMetrics.Row.titleX - AircMetrics.Row.faviconX - AircMetrics.Row.favicon)
                Spacer()
            }
            .frame(height: AircMetrics.Row.pitch)
            .padding(.horizontal, AircMetrics.Sidebar.inset)
            ForEach(todayLines) { l in row(l) }
        }
        .id(space.sourceID)
        .transition(.opacity)
        .aircAnimation(AircCurve.previewIn, value: space.sourceID)
    }

    /// One sidebar row at the real sidebar's metrics: favicon at x 17 (18 pt), title at x 43 in `row`, 41 pt pitch.
    private func row(_ l: Line) -> some View {
        HStack(spacing: 0) {
            Group {
                if l.isFolder {
                    // Folders in the preview are open, as they come over (the sidebar's filled glyph at 0.9).
                    AircFolderGlyph(isOpen: true)
                } else if let u = l.url {
                    RemoteFavicon(pageURL: u, size: AircMetrics.Row.favicon)
                }
            }
            .frame(width: AircMetrics.Row.favicon, height: AircMetrics.Row.favicon)
            .padding(.leading, AircMetrics.Row.faviconX - AircMetrics.Sidebar.inset + CGFloat(l.depth) * AircMetrics.Row.folderIndent)
            // Titles fade out at the end instead of "…", as in the sidebar (AircFadingLabel there).
            AircFadingText(l.title, style: l.isFolder ? AircFont.row.weight(.semibold) : AircFont.row)
                .foregroundStyle(theme.text.color)
                .padding(.leading, AircMetrics.Row.titleX - AircMetrics.Row.faviconX - AircMetrics.Row.favicon)
                .padding(.trailing, AircMetrics.Row.titleTrailing - AircMetrics.Sidebar.inset)
        }
        .frame(height: AircMetrics.Row.pitch)
        .padding(.horizontal, AircMetrics.Sidebar.inset)
        .transition(.opacity)
    }

    // MARK: Footer: the Space bar fills as the Spaces arrive.

    private var footer: some View {
        let spaces = model.previewSpaces
        let shown = Array(spaces.prefix(max(1, model.revealedSpaces)))
        return HStack(spacing: 0) {
            Image(systemName: "archivebox").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.textSecondary.color)
                .frame(width: AircMetrics.Footer.button, height: AircMetrics.Footer.button)
            Spacer(minLength: 0)
            if spaces.count > 1 {
                HStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.sourceID) { i, s in
                        Group {
                            if case .emoji(let e)? = s.icon {
                                Text(e).font(.system(size: AircMetrics.Footer.spaceEmoji))
                            } else {
                                Circle().fill(theme.text.color).frame(width: AircMetrics.Footer.spaceDot, height: AircMetrics.Footer.spaceDot)
                            }
                        }
                        .frame(width: min(AircMetrics.Footer.spaceCellPitch, 140 / CGFloat(max(1, spaces.count))), height: AircMetrics.Footer.spaceCell.height)
                        .opacity(i == model.focusedSpace ? 1 : 0.45)
                        .saturation(i == model.focusedSpace ? 1 : 0.5)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                    }
                }
                .aircAnimation(AircSpring.row, value: shown.count)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.textSecondary.color)
                .frame(width: AircMetrics.Footer.button, height: AircMetrics.Footer.button)
        }
        .padding(.horizontal, AircMetrics.Footer.buttonInset)
        .frame(height: AircMetrics.Footer.height)
    }
}

/// The background-work pill (ON-1): a label and a progress bar, 26 pt tall, in the sidebar's header row.
struct ProgressPill: View {
    let label: String
    let progress: Double
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Text(label).aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.textSecondary.color).lineLimit(1)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.text.alpha(0.12).color)
                    Capsule().fill(theme.accent.color).frame(width: max(4, g.size.width * min(1, max(0, progress))))
                }
            }
            .frame(height: 4)
            .aircAnimation(AircSpring.settle, value: progress)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(theme.fieldFill.color))
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

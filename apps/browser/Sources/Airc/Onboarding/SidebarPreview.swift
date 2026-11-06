// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import SwiftUI

/// The live sidebar on the left of the onboarding window (design §7): the browser's sidebar at 1:1 (228 pt, Arc's
/// row pitch, tiles and footer), without window buttons, rebuilding as the import is read and as choices change.
/// It draws straight on the window's theme in theme ink.
struct SidebarPreview: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.aircTheme) private var theme

    private var space: ImportBlueprint.Space { model.focused }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            urlField
            favorites
            spaceHeader
            rows
            Spacer(minLength: 0)
            footer
        }
        .frame(width: AircMetrics.Sidebar.defaultWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .allowsHitTesting(false)
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

    private var spaceHeader: some View {
        let showsPill = model.hoveredProfile != nil && model.hoveredProfile == space.profileSourceID
        return HStack(spacing: 0) {
            if case .emoji(let e)? = space.icon {
                Text(e).font(.system(size: 16)).frame(width: AircMetrics.SpaceHeader.iconFrame)
                    .padding(.leading, AircMetrics.SpaceHeader.iconCenterX - AircMetrics.SpaceHeader.iconFrame / 2 - AircMetrics.Sidebar.inset)
                Spacer().frame(width: AircMetrics.SpaceHeader.nameX - AircMetrics.SpaceHeader.iconCenterX - AircMetrics.SpaceHeader.iconFrame / 2)
            } else {
                Spacer().frame(width: AircMetrics.SpaceHeader.nameXWithoutIcon - AircMetrics.Sidebar.inset)
            }
            Text(space.name).aircFont(AircFont.spaceName).foregroundStyle(theme.textSecondary.color).lineLimit(1)
            if showsPill, let p = model.profile(of: space) {
                HStack(spacing: 4) {
                    AircProfileAvatar(emoji: "", name: p.name, color: p.color?.aircColor ?? theme.accent, size: 16)
                    Text(p.name).aircFont(AircFont.caption).foregroundStyle(theme.textSecondary.color)
                }
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(Capsule().fill(theme.tileFill.color))
                .padding(.leading, 8)
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(height: AircMetrics.SpaceHeader.plateHeight)
        .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(showsPill ? theme.hoverFill.color : .clear))
        .padding(.horizontal, AircMetrics.Sidebar.inset)
        .padding(.vertical, (AircMetrics.Row.pitch - AircMetrics.SpaceHeader.plateHeight) / 2)
        .padding(.top, 4)
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
        return Array(out.prefix(9))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { l in
                HStack(spacing: 0) {
                    Group {
                        if l.isFolder {
                            Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(theme.accent.color)
                        } else if let u = l.url {
                            RemoteFavicon(pageURL: u, size: AircMetrics.Row.favicon)
                        }
                    }
                    .frame(width: AircMetrics.Row.favicon, height: AircMetrics.Row.favicon)
                    .padding(.leading, AircMetrics.Row.faviconX - AircMetrics.Sidebar.inset + CGFloat(l.depth) * AircMetrics.Row.folderIndent)
                    Text(l.title)
                        .aircFont(l.isFolder ? AircFont.row.weight(.semibold) : AircFont.row)
                        .foregroundStyle(theme.text.color)
                        .lineLimit(1)
                        .padding(.leading, AircMetrics.Row.titleX - AircMetrics.Row.faviconX - AircMetrics.Row.favicon)
                    Spacer(minLength: AircMetrics.Row.titleTrailing - AircMetrics.Sidebar.inset)
                }
                .frame(height: AircMetrics.Row.pitch)
                .padding(.horizontal, AircMetrics.Sidebar.inset)
                .transition(.opacity)
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
        }
        .id(space.sourceID)
        .transition(.opacity)
        .aircAnimation(AircCurve.previewIn, value: space.sourceID)
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

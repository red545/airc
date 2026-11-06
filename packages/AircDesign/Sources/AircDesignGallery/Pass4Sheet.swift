// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AircDesign
import AppKit
import SwiftUI

// Design pass 4: the components the app adopts in place of its own (docs/qa/visual-review.md), light and dark.
// `pass4-light.png` / `pass4-dark.png` are SwiftUI; `pass4-appkit-*.png` draw the AppKit forms the sidebar and the
// command bar use, captured with AircSnapshot so labels show at their real ink.

private let freelance = AircProfileIdentity(name: "Freelance", emoji: "🪴", color: AircProfileColor.choices[2])

struct Pass4Sheet: View {
    let dark: Bool
    @State private var picked: SpaceTheme
    @State private var colour = 2

    init(dark: Bool) {
        self.dark = dark
        _picked = State(initialValue: SpaceTheme.preset(dark ? "ember" : "lemon")!)
    }

    var body: some View {
        let side = SpaceTheme.preset(dark ? "ocean" : "sky")!.resolved(systemIsDark: dark)
        HStack(alignment: .top, spacing: 24) {
            sidebar(side)
            VStack(alignment: .leading, spacing: 20) {
                label("Empty Space (page card, \(side.isDark ? "dark" : "light"))")
                AircEmptySpaceView(emoji: "🌱", name: "Side project", profile: freelance)
                    .aircPageCard(side)
                    .frame(width: 560, height: 300)
                    .aircTheme(side)
                    .padding(10)
                    .background(SpaceBackground(side))
                label("Command bar rows")
                commandRows(side)
                label("Profile colours")
                HStack(spacing: 14) {
                    AircProfileColorPicker(selection: $colour)
                    ForEach(0..<4) { i in AircProfileAvatar(AircProfileIdentity(name: ["Personal", "Acme", "Zoe", "Lab"][i], emoji: i == 0 ? "🏡" : "", color: AircProfileColor.choices[[1, 0, 4, 7][i]]), size: 22) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(side.surface.color))
                .aircTheme(side)
            }
            .frame(width: 600, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                label("Theme picker (\(dark ? "Ember" : "Lemon"))")
                AircThemePicker(theme: $picked, systemIsDark: dark)
            }
        }
        .padding(24)
        .background(dark ? Color(white: 0.10) : AircColor.Stone.s100.color)
    }

    private func label(_ s: String) -> some View {
        Text(s).aircFont(AircFont.caption).foregroundStyle(dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5))
    }

    private func sidebar(_ r: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            field(r, host: nil)
            field(r, host: "news.ycombinator.com/item?id=4242424242", buttons: true).padding(.top, 8)
            HStack(spacing: 2) {
                Text("🌱").font(.system(size: 15)).frame(width: 26, height: 26)
                Text("Side project").aircFont(AircFont.spaceName).foregroundStyle(r.textSecondary.color)
            }
            .padding(.leading, 13).frame(height: 36).padding(.top, 14)
            row(r, title: "Trips", folder: false)
            row(r, title: "Lisbon", folder: true)
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                Text("New Tab").aircFont(AircFont.row)
            }
            .foregroundStyle(r.textTertiary.color).padding(.leading, 18).frame(height: 41)
            AircSidebarCard.signInToGoogle(isDark: r.isDark, onSignIn: {}, onNotNow: {}, onDismiss: {})
                .frame(width: AircMetrics.Profile.signInCardWidth)
                .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .frame(width: 228, height: 700, alignment: .top)
        .background(SpaceBackground(r))
        .aircTheme(r)
    }

    private func field(_ r: ResolvedTheme, host: String?, buttons: Bool = false) -> some View {
        HStack(spacing: 0) {
            AircAddressFieldText(host: host).padding(.leading, 12)
            if buttons {
                Spacer(minLength: AircMetrics.Row.titleFadeGap)
                ForEach(["link", "slider.horizontal.3"], id: \.self) { s in
                    Image(systemName: s).font(.system(size: 12, weight: .medium)).foregroundStyle(r.textSecondary.color).frame(width: 30, height: 30)
                }
            }
        }
        .padding(.trailing, buttons ? 3 : 12)
        .frame(height: AircMetrics.Sidebar.urlFieldHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(r.fieldFill.color))
        .padding(.horizontal, 8)
    }

    private func row(_ r: ResolvedTheme, title: String, folder open: Bool) -> some View {
        HStack(spacing: 0) {
            AircFolderGlyph(isOpen: open).padding(.leading, 9)
            Text(title).aircFont(AircFont.row.weight(.semibold)).foregroundStyle(r.text.color).padding(.leading, 8)
            Spacer()
        }
        .frame(height: 36).padding(.horizontal, 8).padding(.vertical, 2.5)
    }

    private func commandRows(_ r: ResolvedTheme) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(r.surfaceTextTertiary.color).frame(width: 40)
                (Text("wiki").foregroundStyle(r.surfaceText.color)
                 + Text("pedia.org").foregroundStyle(r.inlineCompletionText.color))
                    .aircFont(AircFont.commandInput)
                    .background(alignment: .trailing) {
                        // The highlight sits under the completion only.
                        r.inlineCompletionHighlight.color.frame(width: 84).offset(x: 2)
                    }
                Spacer()
            }
            .frame(height: 52)
            Rectangle().fill(r.surfaceBorder.color).frame(height: 0.5)
            VStack(spacing: 0) {
                cbRow(r, "wikipedia.org", sub: "Wikipedia, the free encyclopedia", action: "Open", selected: true)
                cbRow(r, "wiki", sub: AircCommandText.searchSubtitle(engine: "Google"), action: "Search", selected: false, symbol: "magnifyingglass")
                HStack {
                    Image(systemName: "star").font(.system(size: 14)).foregroundStyle(r.surfaceTextSecondary.color).frame(width: 20)
                    Text("Add to Favorites").aircFont(AircFont.row).foregroundStyle(r.surfaceText.color)
                    Spacer()
                    AircShortcutKeys(["⌘", "D"])
                }
                .padding(.horizontal, 14).frame(height: 40)
            }
            .padding(6)
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(r.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).inset(by: 0.25).stroke(r.surfaceBorder.color, lineWidth: 0.5))
        .aircTheme(r)
    }

    private func cbRow(_ r: ResolvedTheme, _ title: String, sub: String, action: String, selected: Bool, symbol: String = "globe") -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(r.surfaceTextSecondary.color).frame(width: 20)
            Text(title).aircFont(AircFont.row).foregroundStyle(r.surfaceText.color)
            Text(sub).aircFont(AircFont.urlField).foregroundStyle(r.surfaceTextTertiary.color).lineLimit(1)
            Spacer()
            AircCommandAction(action, isSelected: selected)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill((selected ? r.surfaceSelected : .clear).color))
    }
}

/// The AppKit forms, as the app would place them: a sidebar strip with the address label, folder rows (NSImageView with
/// the tinted folder), the sign-in card host and a drag ghost lifted over the rows; a page card; command bar actions.
@MainActor
func pass4AppKitSheet(dark: Bool) -> NSView {
    let r = SpaceTheme.preset(dark ? "ocean" : "mint")!.resolved(systemIsDark: dark)
    let size = NSSize(width: 860, height: 520)
    let root = NSView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    let bg = SpaceBackgroundView(theme: r)
    bg.frame = root.bounds
    root.addSubview(bg)

    // Sidebar (flipped coordinates are easier to read: y from the top).
    let sidebar = FlippedView(frame: NSRect(x: 0, y: 0, width: 228, height: size.height))
    sidebar.wantsLayer = true
    root.addSubview(sidebar)
    let field = NSView(frame: NSRect(x: 8, y: 16, width: 212, height: 36))
    field.wantsLayer = true
    field.layer?.backgroundColor = r.fieldFill.cgColor
    field.layer?.cornerRadius = 12
    field.layer?.cornerCurve = .continuous
    sidebar.addSubview(field)
    let address = AircAddressFieldLabel(theme: r)
    address.host = "news.ycombinator.com/item?id=4242424242"
    address.frame = AircAddressFieldLabel.frame(inField: field.bounds, trailingControlMinX: 212 - 66)
    field.addSubview(address)
    for (i, s) in ["link", "slider.horizontal.3"].enumerated() {
        let b = NSImageView(image: NSImage(systemSymbolName: s, accessibilityDescription: nil)!)
        b.contentTintColor = r.textSecondary.nsColor
        b.frame = NSRect(x: 212 - 63 + CGFloat(i) * 30, y: 3, width: 30, height: 30)
        field.addSubview(b)
    }
    let rows: [(String, Bool?)] = [("Trips", false), ("Lisbon", true), ("Hacker News", nil), ("swiftlang/swift", nil)]
    for (i, (title, folder)) in rows.enumerated() {
        let y = 70 + CGFloat(i) * AircMetrics.Row.pitch
        let icon = NSImageView(frame: NSRect(x: AircMetrics.Row.faviconX, y: y + 11, width: 18, height: 18))
        if let folder {
            icon.image = AircFolderGlyph.image(isOpen: folder, theme: r)
        } else {
            icon.wantsLayer = true
            icon.layer?.backgroundColor = r.tileHoverFill.cgColor
            icon.layer?.cornerRadius = 4
        }
        sidebar.addSubview(icon)
        let t = AircFadingLabel(style: folder == nil ? AircFont.row : AircFont.row.weight(.semibold))
        t.stringValue = title
        t.textColor = r.text.nsColor
        t.frame = NSRect(x: AircMetrics.Row.titleX, y: y + 11, width: 228 - AircMetrics.Row.titleX - AircMetrics.Row.titleTrailing, height: 18)
        sidebar.addSubview(t)
    }
    let card = AircSignInCardView(theme: r)
    card.onDismiss = {}
    card.frame = NSRect(x: 8, y: 250, width: AircMetrics.Profile.signInCardWidth, height: AircMetrics.Profile.signInCardHeight)
    sidebar.addSubview(card)
    let ghost = AircDragGhostLayer(kind: .row, width: 228, theme: r)
    ghost.configure(title: "Hacker News — a very long title that has to fade", favicon: nil)
    ghost.position = CGPoint(x: 114 + 10, y: 70 + 2.5 * AircMetrics.Row.pitch + 20)
    sidebar.layer?.addSublayer(ghost)
    let tile = AircDragGhostLayer(kind: .tile, width: 102, theme: r)
    tile.configure(title: "", favicon: nil)
    tile.position = CGPoint(x: 80, y: 420)
    sidebar.layer?.addSublayer(tile)

    // Page card with the empty Space inside, and the command bar actions drawn in AppKit.
    let page = AircPageCardView(theme: r, frame: NSRect(x: 238, y: 10, width: size.width - 248, height: size.height - 20))
    page.contentView = NSHostingView(rootView: AircEmptySpaceView(emoji: "🌱", name: "Side project", profile: freelance).aircTheme(r))
    root.addSubview(page)
    let bar = FlippedView(frame: NSRect(x: 46, y: page.bounds.height - 40 - 92, width: 520, height: 92))
    bar.wantsLayer = true
    bar.layer?.backgroundColor = r.surface.cgColor
    bar.layer?.cornerRadius = 12
    bar.layer?.borderWidth = 0.5
    bar.layer?.borderColor = r.surfaceBorder.cgColor
    page.addSubview(bar)
    for (i, (title, keys, selected)) in [("Open", ["↵"], true), ("Add to Favorites", ["⌘", "D"], true)].enumerated() {
        let y = CGFloat(i) * 44 + 4
        let plate = NSView(frame: NSRect(x: 4, y: y, width: 512, height: 40))
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 10
        plate.layer?.backgroundColor = (i == 0 ? r.surfaceSelected : AircColor.clear).cgColor
        bar.addSubview(plate)
        let t = NSTextField(labelWithAttributedString: NSAttributedString(string: i == 0 ? "wikipedia.org" : "Add to Favorites", attributes: r.commandRowTitleAttributes))
        t.frame = NSRect(x: 14, y: 11, width: 200, height: 18)
        plate.addSubview(t)
        let a = AircCommandActionView(title: i == 0 ? title : "", keys: keys, theme: r)
        a.isSelected = selected
        let w = a.intrinsicContentSize.width
        a.frame = NSRect(x: 512 - AircMetrics.CommandBar.actionTrailing - w, y: 11, width: w, height: 18)
        plate.addSubview(a)
    }
    return root
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

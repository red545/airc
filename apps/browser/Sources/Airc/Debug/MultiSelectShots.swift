// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of a sidebar multi-selection (SB-36), the marketing scenario's part "multiselect"
/// (`scripts/marketing-shots.sh --parts multiselect`):
///   - multi-select: Personal on apple.com with three Today tabs selected (Kyoto, Swift.org, Typography), and the
///     selection's context menu open beside them.
/// A context menu is a window of the system's that a capture without screen recording can't take, so the menu is
/// drawn here from the app's own `selectionMenu` (its items, separators and submenus), in macOS 26's menu style.
extension SnapshotRunner {
    func mkMultiSelectShots(_ d: MarketingDemo) {
        mkShow(d, "personal", "apple")
        mkSettleShown()
        var ids: [String] = []
        run { [self] in
            ids = ["kyoto", "swift", "natoday"].compactMap { d.tab[$0] }
            c.pageView(for: c.currentSpaceID)?.setSelection(ids)
            c.root.layoutSubtreeIfNeeded()
        }
        wait(0.3)
        mkWindowShot("multi-select") { [self] frame in
            guard let page = c.pageView(for: c.currentSpaceID), let row = ids.dropFirst().first.flatMap({ page.rows[$0] }) else { return [] }
            let menu = c.selectionMenu(ids: page.selection, spaceID: page.spaceID)
            guard let image = Self.mkMenuImage(menu, highlighted: "New Folder with 3 Tabs", dark: mkIsDark()) else { return [] }
            // Where a right-click on the middle row opens it: its top left at the pointer.
            let r = row.convert(row.bounds, to: nil)
            let at = NSPoint(x: frame.minX + r.minX + 150, y: frame.minY + r.midY + 6)
            return [MarketingStudio.Layer(image: image, frame: NSRect(x: at.x, y: at.y - image.size.height, width: image.size.width,
                                                                      height: image.size.height),
                                          radius: Self.mkMenuRadius, dark: mkIsDark(), shadow: .panel)]
        }
        run { [self] in c.pageView(for: c.currentSpaceID)?.clearSelection() }
    }

    static let mkMenuRadius: CGFloat = 10

    /// `menu` as macOS 26 draws a context menu: a pale (or dark) rounded panel, 13 pt items 22 pt tall, separators,
    /// a chevron for submenus, and `highlighted` in the accent colour as under the pointer.
    static func mkMenuImage(_ menu: NSMenu, highlighted: String?, dark: Bool) -> NSImage? {
        let font = NSFont.menuFont(ofSize: 13)
        let itemHeight: CGFloat = 22, separatorHeight: CGFloat = 11, inset: CGFloat = 5, textX: CGFloat = 26, chevronRoom: CGFloat = 30
        // As the menu shows it: ⌥ alternates and hidden items only appear with their modifier.
        let items = menu.items.filter { !$0.isAlternate && !$0.isHidden }
        let titleWidth = items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 100
        let width = ceil(textX + titleWidth + chevronRoom)
        let height = items.reduce(2 * inset) { $0 + ($1.isSeparatorItem ? separatorHeight : itemHeight) }
        let ink = dark ? NSColor.white : NSColor.black
        return NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.965, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: mkMenuRadius, yRadius: mkMenuRadius).fill()
            var y = inset
            for item in items {
                if item.isSeparatorItem {
                    ink.withAlphaComponent(0.1).setFill()
                    NSRect(x: inset + 9, y: y + separatorHeight / 2 - 0.5, width: width - 2 * inset - 18, height: 1).fill()
                    y += separatorHeight
                    continue
                }
                let row = NSRect(x: inset, y: y, width: width - 2 * inset, height: itemHeight)
                let lit = item.title == highlighted
                if lit {
                    NSColor.controlAccentColor.setFill()
                    NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
                }
                let color: NSColor = lit ? .white : item.isEnabled ? ink.withAlphaComponent(0.88) : ink.withAlphaComponent(0.3)
                let title = NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: color])
                title.draw(at: NSPoint(x: textX, y: y + (itemHeight - title.size().height) / 2))
                // Share's submenu is the system's, filled only when it opens: it still has its chevron.
                if item.hasSubmenu || SelectionShare.of(item) != nil, let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
                    let tinted = NSImage(size: chevron.size, flipped: false) { r in
                        chevron.draw(in: r)
                        (lit ? NSColor.white : ink.withAlphaComponent(item.isEnabled ? 0.6 : 0.25)).set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: width - inset - 14 - chevron.size.width / 2, y: y + (itemHeight - chevron.size.height) / 2,
                                           width: chevron.size.width, height: chevron.size.height))
                }
                y += itemHeight
            }
            return true
        }
    }
}
#endif

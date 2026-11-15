// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

/// A live folder's state at the end of its row (Sidebar/SidebarRows.swift FolderRowView calls `configure` and
/// `place`): a small spinner while it refreshes; when it can't, a warning glyph with a word (Sign In, Rate Limited,
/// Offline, Failed, Not Found) and Arc's message as its tooltip ("Not signed in to GitHub", "GitHub rate limit
/// exceeded", "Failed to update"); otherwise a faint pull-request glyph that says the folder is live. Shown open or
/// closed, so a folder that stopped updating is never silent. Clicking the warning opens the folder's menu.
final class LiveFolderBadgeView: NSView {
    private(set) var folderID: String?
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var palette: Palette?
    private var observer: NSObjectProtocol?
    private(set) var state: LiveFolderCenter.Display?

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.imageScaling = .scaleProportionallyDown
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byClipping
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        [glyph, label, spinner].forEach(addSubview)
        observer = NotificationCenter.default.addObserver(forName: LiveFolderCenter.didChange, object: nil, queue: .main) { [weak self] n in
            guard let self, n.object == nil || (n.object as? String) == self.folderID else { return }
            self.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    // MARK: Hooks for FolderRowView

    /// Shows or hides the badge for this folder row.
    static func configure(in row: NSView, item: Item, palette: Palette, store: SpacesStore?) {
        let existing = row.subviews.first { $0 is LiveFolderBadgeView } as? LiveFolderBadgeView
        guard let store, let book = LiveFolderCenter.shared.attach(store), book.isLive(item.id) else {
            existing?.removeFromSuperview()
            return
        }
        let badge = existing ?? {
            let b = LiveFolderBadgeView()
            row.addSubview(b)
            return b
        }()
        badge.folderID = item.id
        badge.palette = palette
        badge.refresh()
    }

    /// Puts the badge at the row's trailing edge and shortens the title to leave it room.
    static func place(in row: NSView, title: NSView) {
        guard let badge = row.subviews.first(where: { $0 is LiveFolderBadgeView }) as? LiveFolderBadgeView else { return }
        let w = badge.fittingWidth
        let h = row.bounds.height
        let x = row.bounds.width - AircMetrics.Row.titleTrailing - w + 4
        badge.frame = NSRect(x: x, y: (h - 18) / 2, width: w, height: 18)
        var f = title.frame
        f.size.width = max(0, min(f.width, x - 4 - f.minX))
        title.frame = f
    }

    // MARK: Drawing

    var fittingWidth: CGFloat {
        guard let state else { return 0 }
        if state.isRefreshing { return 16 }
        if state.status.isError { return 16 + 4 + ceil(label.intrinsicContentSize.width) }
        return 14
    }

    /// The word shown, for checks.
    var shownText: String { label.isHidden ? "" : label.stringValue }

    func refresh() {
        guard let folderID, let s = LiveFolderCenter.shared.display(folderID), let palette else {
            isHidden = true
            return
        }
        isHidden = false
        let changed = s != state
        state = s
        if s.isRefreshing {
            glyph.isHidden = true
            label.isHidden = true
            spinner.startAnimation(nil)
            toolTip = "Updating…"
        } else {
            spinner.stopAnimation(nil)
            glyph.isHidden = false
            if s.status.isError {
                glyph.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: s.status.message)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
                glyph.contentTintColor = palette.textSecondary
                label.isHidden = false
                label.stringValue = s.status.badge
                label.textColor = palette.textSecondary
                toolTip = Self.tooltip(s)
            } else {
                glyph.image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Live Folder")?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
                glyph.contentTintColor = palette.textMuted
                label.isHidden = true
                toolTip = Self.tooltip(s)
            }
        }
        setAccessibilityLabel(s.isRefreshing ? "Updating" : s.status.isError ? s.status.message : "Live Folder")
        if changed {
            needsLayout = true
            superview?.needsLayout = true
        }
    }

    static func tooltip(_ s: LiveFolderCenter.Display) -> String {
        var lines = [s.status.message]
        if case .rateLimited(let until?) = s.status {
            lines.append("Updates again at " + DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short))
        }
        if let t = s.lastRefreshed {
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .full
            lines.append("Updated " + rel.localizedString(for: t, relativeTo: Date()))
        }
        return lines.joined(separator: "\n")
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        spinner.frame = NSRect(x: bounds.width - 16, y: (h - 16) / 2, width: 16, height: 16)
        glyph.frame = NSRect(x: 0, y: (h - 14) / 2, width: 14, height: 14)
        let lw = ceil(label.intrinsicContentSize.width)
        label.frame = NSRect(x: 18, y: (h - 15) / 2, width: lw, height: 15)
        if !(state?.status.isError ?? false) { glyph.frame.origin.x = bounds.width - 14 }
    }

    override func mouseDown(with event: NSEvent) {
        guard state?.status.isError == true, let row = superview, let menu = row.menu(for: event) else {
            return super.mouseDown(with: event)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: row)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the warning takes clicks; elsewhere the row gets them (press to open or close, drag).
        guard state?.status.isError == true, !isHidden else { return nil }
        return frame.contains(point) ? self : nil
    }
}

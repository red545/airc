// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// SB-34 / design §7 "Folder row": hovering a closed folder for 0.45 s shows a searchable list of its tabs, 240 pt
/// wide, 4 pt right of the sidebar, rows on a 45 pt pitch, `popover` elevation, 90 ms in. Clicking a row opens it.
final class FolderPreviewController {
    static let delay: TimeInterval = 0.45
    static let width: CGFloat = 240
    static let rowPitch: CGFloat = 45
    static let shadowMargin: CGFloat = 20

    private weak var controller: WindowController?
    private var pending: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private(set) var panel: NSView?
    private(set) var folderID: String?
    private var insidePanel = false

    init(controller: WindowController) {
        self.controller = controller
    }

    /// The pointer entered a folder row.
    func hoverBegan(folder item: Item, row: NSView) {
        hideWork?.cancel()
        guard item.isCollapsed else { return hide() }
        if folderID == item.id, panel != nil { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak row] in
            guard let self, let row, row.window != nil else { return }
            self.show(folder: item.id, beside: row)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// The pointer left the folder row: hide unless it moved onto the preview.
    func hoverEnded() {
        pending?.cancel()
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.insidePanel else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func hide() {
        pending?.cancel()
        guard let p = panel else { return }
        panel = nil
        folderID = nil
        insidePanel = false
        p.removeFromSuperview()
    }

    private func show(folder id: String, beside row: NSView) {
        guard let c = controller, let folder = c.store.item(id) else { return }
        hide()
        let tabs = Self.tabs(in: id, store: c.store)
        let theme = c.currentPalette.resolved
        let height = min(CGFloat(tabs.count) * Self.rowPitch + 52, 420)
        let view = FolderPreviewView(title: folder.displayTitle, tabs: tabs, theme: theme,
                                     onOpen: { [weak self] item in
                                         self?.hide()
                                         self?.controller?.activate(entry: .pinned(item, depth: 0, c.store.liveTab(forItem: item.id)))
                                     },
                                     onHover: { [weak self] inside in
                                         self?.insidePanel = inside
                                         if !inside { self?.scheduleHide() } else { self?.hideWork?.cancel() }
                                     })
        let host = NSHostingView(rootView: view)
        let rowInRoot = row.convert(row.bounds, to: c.root)
        // The hosting view is larger than the panel by its shadow's reach, so the shadow isn't clipped.
        let m = Self.shadowMargin
        let x = c.sidebar.frame.maxX + 4 - m
        let y = min(max(8, rowInRoot.minY - 6), c.root.bounds.height - height - 8) - m
        host.frame = NSRect(x: x, y: y, width: Self.width + 2 * m, height: height + 2 * m)
        host.wantsLayer = true
        c.root.addSubview(host)
        host.layer?.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration)
        panel = host
        folderID = id
    }

    /// The folder's tabs, nested folders flattened, in sidebar order.
    static func tabs(in folderID: String, store: SpacesStore) -> [Item] {
        guard let f = store.item(folderID), case .pinned(let sid) = f.container else { return [] }
        var out: [Item] = []
        func walk(_ parent: String) {
            for child in store.children(of: .pinned(spaceID: sid), parent: parent) {
                // SV-2: a pinned split lists its panes (picking one opens the split on it).
                if child.kind == .folder { walk(child.id) } else if child.kind == .split { out += store.panes(ofSplitItem: child.id) } else { out.append(child) }
            }
        }
        walk(folderID)
        return out
    }
}

private struct FolderPreviewView: View {
    let title: String
    let tabs: [Item]
    let theme: ResolvedTheme
    let onOpen: (Item) -> Void
    let onHover: (Bool) -> Void
    @State private var query = ""
    @State private var hovered: String?

    private var shown: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tabs }
        return tabs.filter { CommandSearch.score(q, in: $0.displayTitle) != nil || CommandSearch.score(q, in: URLRules.displayURL($0.savedURL ?? "")) != nil }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AircRadius.popover, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.surfaceTextTertiary.color)
                TextField("", text: $query, prompt: Text("Search \(title)").foregroundStyle(theme.surfaceTextTertiary.color))
                    .textFieldStyle(.plain).aircFont(AircFont.callout).foregroundStyle(theme.surfaceText.color)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: AircRadius.control, style: .continuous).fill(theme.surfaceHover.color))
            .padding(8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(shown) { item in
                        HStack(spacing: 10) {
                            RemoteFavicon(pageURL: item.savedURL ?? "", size: AircMetrics.Row.favicon)
                            Text(item.displayTitle).aircFont(AircFont.row).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: FolderPreviewController.rowPitch - 4)
                        .background(RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous)
                            .fill(hovered == item.id ? theme.surfaceSelected.color : .clear))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                        .onTapGesture { onOpen(item) }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .frame(width: FolderPreviewController.width)
        .background(shape.fill(theme.surface.color))
        .overlay(shape.inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
        .clipShape(shape)
        .aircShadow(.popover)
        .onHover(perform: onHover)
        .padding(FolderPreviewController.shadowMargin)
        .aircTheme(theme)
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// Manage Spaces… (SB-21's Space menu, the Spaces menu, the Library's Spaces tab): every Space in one card, centred over
/// the page like Create Profile, the sidebar live beside it. Drag a row to reorder; click the name to rename it; the
/// icon, theme disc and profile pill open the same pickers as the Space menu; the trash asks first and says what
/// happens to the Space's tabs. Every change goes through the Space menu's own paths (WindowActions.swift,
/// `reorderSpace`), so the sidebar and the footer show it at once.
final class ManageSpacesModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var id: String
        var name: String
        var emoji: String?
        var theme: ResolvedTheme
        var profile: AircProfileIdentity
        var pinned: Int
        var today: Int
        var isCurrent: Bool
    }

    @Published private(set) var rows: [Row] = []
    @Published var ui: ResolvedTheme
    /// The row whose name is being edited.
    @Published var renaming: String?
    /// Where each row's controls are, in the card's coordinates (top-left origin): popovers and menus anchor there.
    var frames: [String: CGRect] = [:]
    weak var controller: WindowController?
    var onClose: (() -> Void)?
    /// The row height and pitch the drag reorders by.
    static let pitch: CGFloat = 52
    #if AIRC_TESTING
    /// What the card's gestures saw, for the scripted check's messages.
    var trace: [String] = []
    #endif
    func note(_ s: String) {
        #if AIRC_TESTING
        trace.append(s)
        #endif
    }

    init(controller: WindowController) {
        self.controller = controller
        ui = controller.currentPalette.resolved
        reload()
    }

    var canDelete: Bool { rows.count > 1 }

    func reload() {
        guard let c = controller else { return }
        let store = c.store
        ui = c.currentPalette.resolved
        let new = store.orderedSpaces.map { s -> Row in
            let p = store.profile(ofSpace: s.id)
            let emoji: String? = if case .emoji(let e)? = s.icon { e } else { nil }
            return Row(id: s.id, name: s.name, emoji: emoji, theme: c.palette(for: s).resolved,
                       profile: AircProfileIdentity(name: p.name, emoji: p.emoji, color: p.color.aircColor),
                       pinned: store.state.items.values.filter { $0.spaceID == s.id && !$0.isFavorite && $0.kind != .folder }.count,
                       today: store.todayTabs(ofSpace: s.id).count, isCurrent: s.id == c.currentSpaceID)
        }
        if new != rows { rows = new }
    }

    func move(_ id: String, to index: Int) {
        guard let from = rows.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(index, rows.count - 1))
        guard to != from else { return }
        controller?.reorderSpace(id, to: to)
        reload()
    }

    func rename(_ id: String, to name: String) {
        renaming = nil
        controller?.renameSpace(id, to: name)
        reload()
    }

    /// The anchor for `control` ("icon", "theme", "profile") of row `id`, in `host`'s coordinates.
    func anchor(_ control: String, _ id: String, in host: NSView) -> (view: NSView, rect: NSRect) {
        (host, frames["\(control):\(id)"] ?? NSRect(x: host.bounds.midX, y: 40, width: 1, height: 1))
    }
}

struct ManageSpacesCard: View {
    @ObservedObject var model: ManageSpacesModel
    var host: () -> NSView?
    @State private var dragging: String?
    @State private var dragOffset: CGFloat = 0
    @State private var hovered: String?

    private var ui: ResolvedTheme { model.ui }
    private static let space = "manage-spaces"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Manage Spaces").aircFont(AircFont.title2).foregroundStyle(ui.surfaceText.color)
                Spacer()
                Text("\(model.rows.count) Space\(model.rows.count == 1 ? "" : "s")")
                    .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color)
            }
            Text("Drag to reorder. Click a name to rename it. Changes show in the sidebar right away.")
                .aircFont(AircFont.body)
                .foregroundStyle(ui.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            list.padding(.top, 14)
            HStack {
                Spacer()
                Button("Done") { model.onClose?() }
                    .buttonStyle(.airc(.primary))
                    .testAnchor("manage.done")
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(width: 600)
        .coordinateSpace(name: Self.space)
        .testAnchorRoot()
        .aircTheme(ui)
        .background {
            // Esc ends a rename without saving it, else closes the card.
            Button("") { if model.renaming != nil { model.renaming = nil } else { model.onClose?() } }
                .keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false)
        }
    }

    /// Up to eight rows as they are; more scroll (a scroll view would also cost the rows their first click in a window
    /// that isn't in front).
    @ViewBuilder private var list: some View {
        let height = CGFloat(model.rows.count) * ManageSpacesModel.pitch
        if model.rows.count <= 8 {
            rowStack.frame(height: height, alignment: .top)
        } else {
            ScrollView(.vertical) { rowStack.frame(height: height, alignment: .top) }
                .frame(height: 8 * ManageSpacesModel.pitch)
        }
    }

    private var rowStack: some View {
        ZStack(alignment: .top) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                rowView(row, index: i)
                    .frame(height: ManageSpacesModel.pitch)
                    .offset(y: CGFloat(i) * ManageSpacesModel.pitch + offset(for: row.id, at: i))
                    .zIndex(dragging == row.id ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Where the drag would drop the dragged row: the rows between move out of its way.
    private func target(from index: Int) -> Int {
        max(0, min(model.rows.count - 1, index + Int((dragOffset / ManageSpacesModel.pitch).rounded())))
    }

    private func offset(for id: String, at i: Int) -> CGFloat {
        guard let d = dragging, let from = model.rows.firstIndex(where: { $0.id == d }) else { return 0 }
        if id == d { return dragOffset }
        let to = target(from: from)
        if from < to, i > from, i <= to { return -ManageSpacesModel.pitch }
        if to < from, i >= to, i < from { return ManageSpacesModel.pitch }
        return 0
    }

    private func drag(_ row: ManageSpacesModel.Row, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if dragging != row.id { dragging = row.id; model.renaming = nil; model.note("drag \(index)") }
                dragOffset = v.translation.height
            }
            .onEnded { _ in
                let to = target(from: index)
                model.note("drop \(index)→\(to)")
                // The rows glide into their new places (Arc's 115 ms drop, SB-35) as the store reorders.
                withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                    dragging = nil
                    dragOffset = 0
                    model.move(row.id, to: to)
                }
            }
    }

    private func record(_ control: String, _ id: String) -> some View {
        Color.clear.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { model.frames["\(control):\(id)"] = $0 }
    }

    @ViewBuilder private func rowView(_ row: ManageSpacesModel.Row, index i: Int) -> some View {
        let isDragged = dragging == row.id
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ui.surfaceTextTertiary.color)
                .frame(width: 18, height: 40)
                .contentShape(Rectangle())
                .testAnchor("manage.handle.\(row.id)")
            Button {
                guard let h = host() else { return }
                model.controller?.changeSpaceIcon(row.id, anchor: model.anchor("icon", row.id, in: h))
            } label: {
                Group {
                    if let e = row.emoji {
                        Text(e).font(.system(size: 18))
                    } else {
                        Circle().fill(ui.surfaceText.alpha(0.55).color).frame(width: 8, height: 8)
                    }
                }
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.fieldFill.color))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change Space Icon…")
            .background(record("icon", row.id))
            .testAnchor("manage.icon.\(row.id)")
            VStack(alignment: .leading, spacing: 1) {
                if model.renaming == row.id {
                    // Saved by ↩ or by clicking away; Esc has already ended the rename, so its focus loss saves nothing.
                    RenameField(name: row.name, ui: ui) { name in
                        model.note("commit \(model.renaming == row.id)")
                        if model.renaming == row.id { model.rename(row.id, to: name) }
                    }
                        cancel: { model.renaming = nil }
                        .testAnchor("manage.renameField")
                } else {
                    Text(row.name.isEmpty ? "Untitled Space" : row.name)
                        .aircFont(row.isCurrent ? AircFont.row.weight(.semibold) : AircFont.row)
                        .foregroundStyle(ui.surfaceText.color)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture { model.renaming = row.id; model.note("rename \(i)") }
                        .testAnchor("manage.name.\(row.id)")
                }
                Text(caption(row)).aircFont(AircFont.caption).foregroundStyle(ui.surfaceTextTertiary.color).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                guard let h = host() else { return }
                model.controller?.editTheme(row.id, anchor: model.anchor("theme", row.id, in: h))
            } label: {
                AircThemeDisc(theme: row.theme, size: 22).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Edit Theme Color…")
            .background(record("theme", row.id))
            .testAnchor("manage.theme.\(row.id)")
            Button {
                guard let h = host(), let c = model.controller, let s = c.store.space(row.id) else { return }
                let r = model.anchor("profile", row.id, in: h).rect
                c.setProfileMenu(spaceID: row.id, current: s.profileID).popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.maxY + 4), in: h)
                model.reload()
            } label: {
                AircProfilePill(row.profile)
            }
            .buttonStyle(.plain)
            .help("Set Profile")
            .background(record("profile", row.id))
            .testAnchor("manage.profile.\(row.id)")
            Button {
                model.controller?.deleteSpace(row.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.airc(.plain, size: .small))
            .foregroundStyle((model.canDelete ? ui.surfaceTextSecondary : ui.surfaceTextTertiary.alpha(0.5)).color)
            .disabled(!model.canDelete)
            .help(model.canDelete ? "Delete Space…" : "The last Space can’t be deleted")
            .testAnchor("manage.delete.\(row.id)")
        }
        .padding(.horizontal, 10)
        .frame(height: ManageSpacesModel.pitch - 6)
        .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous)
            .fill((isDragged ? ui.surfaceSelected : hovered == row.id ? ui.hoverFill : AircColor.clear).color)
            .shadow(color: .black.opacity(isDragged ? 0.18 : 0), radius: 10, y: 4))
        .scaleEffect(isDragged ? 1.015 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
        .gesture(drag(row, index: i))
        // The other rows make way on a spring; the dragged one follows the pointer exactly.
        .animation(dragging == nil || isDragged ? nil : .spring(response: 0.22, dampingFraction: 0.9), value: dragOffset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.name)
        .testAnchor("manage.row.\(row.id)")
    }

    private func caption(_ row: ManageSpacesModel.Row) -> String {
        var parts: [String] = []
        if row.isCurrent { parts.append("Current") }
        parts.append(row.pinned == 1 ? "1 pinned" : "\(row.pinned) pinned")
        parts.append(row.today == 1 ? "1 Today tab" : "\(row.today) Today tabs")
        return parts.joined(separator: " · ")
    }
}

/// The name as a field: ↩ saves, Esc and an empty name keep the old one (Arc's rename, SB-21).
private struct RenameField: View {
    @State var name: String
    let ui: ResolvedTheme
    let commit: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    init(name: String, ui: ResolvedTheme, commit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _name = State(initialValue: name)
        self.ui = ui
        self.commit = commit
        self.cancel = cancel
    }

    var body: some View {
        TextField("Space name", text: $name)
            .textFieldStyle(.plain)
            .aircFont(AircFont.row)
            .foregroundStyle(ui.surfaceText.color)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ui.fieldFill.color))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ui.focusRing.color, lineWidth: 1.5))
            .focused($focused)
            .onSubmit { commit(name) }
            .onExitCommand { cancel() }
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onChange(of: focused) { _, now in if !now { commit(name) } }
    }
}

/// A scrim over the page with the card centred on it; the sidebar stays live beside it (like Create Profile).
final class ManageSpacesPanelHost: NSView {
    let model: ManageSpacesModel
    private let scrim = NSView()
    private let card = NSView()
    private(set) var host: AircFirstClickHostingView<ManageSpacesCard>!
    private weak var controller: WindowController?
    private var token: Int?
    private var frameObserver: NSObjectProtocol?

    init(controller: WindowController) {
        self.controller = controller
        model = ManageSpacesModel(controller: controller)
        super.init(frame: .zero)
        host = AircFirstClickHostingView(rootView: ManageSpacesCard(model: model) { [weak self] in self?.host })
        wantsLayer = true
        scrim.wantsLayer = true
        scrim.layer?.cornerRadius = AircMetrics.Window.cardRadius
        addSubview(scrim)
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 0.5
        card.layer?.applyAircShadow(.panel)
        addSubview(card)
        card.addSubview(host)
        restyle()
        // Any change (here, in the sidebar, a confirm sheet, ⌘Z) redraws the rows.
        token = controller.store.observe { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.reload()
                self.restyle()
                self.needsLayout = true
            }
        }
        // The page card moves with the sidebar (⌘S, a resize): the scrim follows it.
        controller.card.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: controller.card,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let token { controller?.store.removeObserver(token) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var hostingView: NSView { host }
    var cardFrame: NSRect { card.frame }

    private func restyle() {
        let ui = model.ui
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(ui.isDark ? 0.40 : 0.22).cgColor
        card.layer?.backgroundColor = ui.surface.nsColor.cgColor
        card.layer?.borderColor = ui.surfaceBorder.nsColor.cgColor
    }

    /// Covers the page card; the sidebar beside it stays live (its clicks go through).
    override func layout() {
        super.layout()
        guard let page = controller?.card.frame else { return }
        frame = page
        scrim.frame = bounds
        let size = host.fittingSize
        let h = min(size.height, bounds.height - 32)
        card.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: max(16, ((bounds.height - h) / 2 - 20).rounded()),
                            width: size.width, height: h)
        host.frame = card.bounds
    }

    // A click on the scrim closes, like Done.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { model.onClose?() }
    }
}

extension WindowController {
    /// The open Manage Spaces card, if any.
    var manageSpacesPanel: ManageSpacesPanelHost? { root.subviews.lazy.compactMap { $0 as? ManageSpacesPanelHost }.first }

    /// Space menu → Manage Spaces…, Spaces → Manage Spaces…, the Library's Spaces tab.
    func showManageSpaces() {
        if let open = manageSpacesPanel { open.model.reload(); return }
        if library != nil { toggleLibrary() }
        closeCommandBar()
        closeCreateProfile()
        let panel = ManageSpacesPanelHost(controller: self)
        panel.model.onClose = { [weak self] in self?.closeManageSpaces() }
        root.addSubview(panel, positioned: .below, relativeTo: toast)
        panel.frame = card.frame
        panel.layoutSubtreeIfNeeded()
        panel.layer?.fade(from: 0, to: 1, duration: 0.15)
    }

    func closeManageSpaces() {
        guard let p = manageSpacesPanel else { return }
        // A rename in progress is kept (its field commits as it goes).
        p.window?.makeFirstResponder(nil)
        p.layer?.fade(from: 1, to: 0, duration: 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { p.removeFromSuperview() }
        if let id = shownTabID { engineTab(for: id)?.focus() }
    }
}

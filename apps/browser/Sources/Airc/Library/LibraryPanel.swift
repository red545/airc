// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// The Library (SB-62, Arc ref §5): slides in from the left, 417 pt wide, pushing the page card on the `push` spring
/// (0.245 s, ζ 0.92). Archived Tabs (searchable; restore returns a tab to its Space), Downloads, Spaces. It sits on
/// the window's theme like the sidebar it covers.
final class LibraryModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case archive = "Archived Tabs", downloads = "Downloads", spaces = "Spaces"
        var id: String { rawValue }
    }

    @Published var section: Section = .archive
    @Published var query = ""
    @Published var downloadsQuery = ""
    @Published var revision = 0
    weak var controller: WindowController?

    init(controller: WindowController) {
        self.controller = controller
    }

    struct Day: Identifiable {
        var id: String { title }
        var title: String
        var entries: [ArchiveEntry]
    }

    var days: [Day] {
        guard let c = controller else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        let entries = c.store.archivedEntries.filter { e in
            q.isEmpty || CommandSearch.score(q, in: e.title) != nil || CommandSearch.score(q, in: URLRules.displayURL(e.url)) != nil
        }
        let cal = Calendar.current
        var out: [Day] = []
        for e in entries.prefix(400) {
            let title: String
            if cal.isDateInToday(e.archivedAt) { title = "Today" }
            else if cal.isDateInYesterday(e.archivedAt) { title = "Yesterday" }
            else { title = e.archivedAt.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
            if out.last?.title == title { out[out.count - 1].entries.append(e) } else { out.append(Day(title: title, entries: [e])) }
        }
        return out
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    let theme: ResolvedTheme
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Library").aircFont(AircFont.title2).foregroundStyle(theme.text.color)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.airc(.plain, size: .small))
                    .foregroundStyle(theme.textSecondary.color)
                    .keyboardShortcut(.cancelAction)
                    .help("Close (⇧⌘L)")
            }
            .padding(.top, 48)
            .padding(.horizontal, 18)
            HStack(spacing: 6) {
                ForEach(LibraryModel.Section.allCases) { s in
                    Text(s.rawValue)
                        .aircFont(AircFont.callout.weight(.medium))
                        .foregroundStyle((model.section == s ? theme.text : theme.textSecondary).color)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(model.section == s ? theme.selectedFill.color : .clear))
                        .contentShape(Capsule())
                        .onTapGesture { model.section = s }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            switch model.section {
            case .archive: archive
            case .downloads: downloads
            case .spaces: spaces
            }
        }
        // The bottom band is the footer's: the back button sits there (LibraryPanelHost).
        .padding(.bottom, AircMetrics.Footer.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .testAnchorRoot()
        .aircTheme(theme)
    }

    private var archive: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textTertiary.color)
                TextField("", text: $model.query, prompt: Text("Search archived tabs").foregroundStyle(theme.textTertiary.color))
                    .textFieldStyle(.plain).aircFont(AircFont.body).foregroundStyle(theme.text.color)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(theme.fieldFill.color))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            let days = model.days
            if days.isEmpty {
                empty("archivebox", model.query.isEmpty ? "Closed and auto-archived Today tabs show up here." : "Nothing archived matches.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(days) { day in
                            Text(day.title).aircFont(AircFont.caption).foregroundStyle(theme.textTertiary.color)
                                .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 4)
                            ForEach(day.entries) { e in ArchiveRow(entry: e, theme: theme, spaceName: spaceName(e)) { restore(e) } }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
    }

    /// Every profile's downloads (Downloads/DownloadViews.swift).
    @ViewBuilder private var downloads: some View {
        if let center = MediaLibrary.shared.downloads, let store = model.controller?.store {
            LibraryDownloadsView(center: center, query: $model.downloadsQuery, theme: theme) { id in
                store.state.profiles.count > 1 ? store.profile(id)?.name : nil
            }
        } else {
            empty("arrow.down.circle", "This engine has no downloads list yet.")
        }
    }

    private var spaces: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.controller?.store.orderedSpaces ?? []) { s in
                    let store = model.controller!.store
                    HStack(spacing: 10) {
                        AircThemeDisc(theme: s.theme.design.resolved(systemIsDark: theme.isDark), size: 20)
                        Text(s.iconLabel).font(.system(size: 15)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).aircFont(AircFont.row).foregroundStyle(theme.text.color)
                            Text("\(store.profile(ofSpace: s.id).name) · \(store.pinnedRows(ofSpace: s.id).count) pinned · \(store.todayTabs(ofSpace: s.id).count) today")
                                .aircFont(AircFont.caption).foregroundStyle(theme.textTertiary.color)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                    .onTapGesture { model.controller?.switchToSpace(s.id, animated: true); onClose() }
                    .padding(.horizontal, 8)
                }
            }
            .padding(.top, 10)
        }
    }

    private func empty(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(theme.textTertiary.color)
            Text(text).aircFont(AircFont.callout).foregroundStyle(theme.textSecondary.color).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 40)
    }

    private func spaceName(_ e: ArchiveEntry) -> String? { model.controller?.store.space(e.spaceID)?.name }

    private func restore(_ e: ArchiveEntry) {
        guard let c = model.controller, let t = try? c.store.restoreArchived(e.id, fallbackSpaceID: c.currentSpaceID) else { return }
        model.revision += 1
        if let sid = t.spaceID, sid != c.currentSpaceID { c.switchToSpace(sid, animated: true) }
        c.show(t.id)
        onClose()
    }
}

private struct ArchiveRow: View {
    let entry: ArchiveEntry
    let theme: ResolvedTheme
    let spaceName: String?
    let onRestore: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            RemoteFavicon(pageURL: entry.url, size: AircMetrics.Row.favicon)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? URLRules.displayHost(entry.url) : entry.title)
                    .aircFont(AircFont.row).foregroundStyle(theme.text.color).lineLimit(1)
                Text([URLRules.displayHost(entry.url), spaceName].compactMap { $0 }.joined(separator: " · "))
                    .aircFont(AircFont.caption).foregroundStyle(theme.textTertiary.color).lineLimit(1)
            }
            Spacer(minLength: 6)
            if hovered {
                Text("Restore").aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.accent.color)
            } else {
                Text(entry.archivedAt.formatted(date: .omitted, time: .shortened)).aircFont(AircFont.mono).foregroundStyle(theme.textTertiary.color)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(hovered ? theme.hoverFill.color : .clear))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onRestore)
        .help("Restore to its Space")
    }
}

/// The panel's AppKit host: sits over the sidebar column and slides with the window's library fraction. Its back
/// button is where the footer's Library button was (Arc), same size and hover plate: a second click without moving
/// the pointer closes the Library.
final class LibraryPanelHost: NSView {
    let model: LibraryModel
    private var host: NSHostingView<LibraryView>?
    private weak var controller: WindowController?
    let back = GlyphButton(symbol: "chevron.left", size: 15)

    init(controller: WindowController) {
        self.controller = controller
        model = LibraryModel(controller: controller)
        super.init(frame: .zero)
        wantsLayer = true
        setTheme(controller.currentPalette.resolved)
        back.toolTip = "Back ⇧⌘L"
        back.setAccessibilityElement(true)
        back.setAccessibilityRole(.button)
        back.setAccessibilityLabel("Back")
        back.action = { [weak self] in self?.controller?.toggleLibrary() }
        addSubview(back)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        back.frame = SpaceBarView.libraryButtonFrame(columnHeight: bounds.height)
    }

    func setTheme(_ theme: ResolvedTheme) {
        let view = LibraryView(model: model, theme: theme) { [weak self] in self?.controller?.toggleLibrary() }
        if let host {
            host.rootView = view
        } else {
            let h = NSHostingView(rootView: view)
            h.frame = bounds
            h.autoresizingMask = [.width, .height]
            addSubview(h, positioned: .below, relativeTo: back.superview == nil ? nil : back)
            host = h
        }
        if let palette = controller?.currentPalette {
            back.tint = palette.glyph
            back.hoverFill = palette.hover
        }
    }
}

extension WindowController {
    /// ⇧⌘L and the footer's Library button (SB-62).
    func toggleLibrary() {
        let opening = library == nil
        if opening {
            closeCommandBar()
            let panel = LibraryPanelHost(controller: self)
            library = panel
            root.addSubview(panel, positioned: .above, relativeTo: sidebar)
        }
        let from = libraryFraction
        let to: CGFloat = opening ? 1 : 0
        positionTrafficLights()
        animator.spring("library", from: Double(from), to: Double(to), velocity: 0, spring: Spring(AircSpring.push), update: { [weak self] v in
            self?.libraryFraction = CGFloat(v)
            self?.layoutRoot()
        }, completion: { [weak self] in
            guard let self else { return }
            // At rest exactly where it belongs: the back button then sits on the Library button's very pixels.
            guard !opening else {
                self.libraryFraction = 1
                return self.layoutRoot()
            }
            self.library?.removeFromSuperview()
            self.library = nil
            self.libraryFraction = 0
            self.layoutRoot()
            self.positionTrafficLights()
        })
    }
}

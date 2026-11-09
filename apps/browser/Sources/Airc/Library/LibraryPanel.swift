// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import Quartz
import SwiftUI

/// The Library (SB-62, Arc ref §5): slides in from the left, 417 pt wide, pushing the page card on the `push` spring
/// (0.245 s, ζ 0.92). Archived Tabs (searchable, filtered as Arc's by where the tab was and how it closed; restore returns
/// a tab to its Space), Media (LIB-1, with folder sources), Downloads, Notes (every note, P10a), Spaces.
/// It sits on the window's theme like the sidebar it covers.
final class LibraryModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case archive = "Archived Tabs", media = "Media", downloads = "Downloads", notes = "Notes", spaces = "Spaces"
        var id: String { rawValue }
    }

    @Published var section: Section = .archive
    @Published var query = ""
    /// Arc's "Filter Archived Tabs" (P10a): where the tab was, how it closed.
    @Published var archiveFilter = ArchiveFilter()
    @Published var downloadsQuery = ""
    @Published var revision = 0
    weak var controller: WindowController?

    init(controller: WindowController) {
        self.controller = controller
    }

    // The Library is global, just like its Downloads and Spaces sections. Freeze IDs when
    // asking so an entry auto-archived while the question is open is not silently removed.
    var archiveCount: Int { controller?.store.state.archive.count ?? 0 }
    private(set) var archiveConfirmation: NSAlert?
    private(set) var lastArchiveBackup: URL?

    func requestClearArchive(entryID: String? = nil) {
        guard let c = controller, let settings = c.app?.settings,
              c.window.attachedSheet == nil else { return }
        let ids = Set(c.store.archivedEntries.filter { entryID == nil || $0.id == entryID }.map(\.id))
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(ids.count) archived \(ids.count == 1 ? "tab" : "tabs")? This can't be undone."
        alert.informativeText = "\(entryID == nil ? "All Spaces and profiles, including tabs hidden by search." : "Only this archived tab, in its original Space and profile.") A recovery backup will be saved first in your backup folder (\(settings.backupDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))). ⌘Z won't restore these tabs."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: entryID == nil ? "Clear Archive" : "Remove from Archive")
        alert.buttons[1].hasDestructiveAction = true
        archiveConfirmation = alert
        alert.beginSheetModal(for: c.window) { [weak self, weak c] response in
            guard let self, let c else { return }
            self.archiveConfirmation = nil
            guard response == .alertSecondButtonReturn else { return }
            do {
                try c.store.clearArchive(entryIDs: ids) {
                    self.lastArchiveBackup = try settings.backUp(c.store, purpose: .archiveRemoval)
                }
                self.revision += 1
            } catch {
                let failure = NSAlert()
                failure.messageText = "Couldn't remove archived tabs"
                failure.informativeText = "The archive was kept. Check that your backup folder is available and try again. \(error.localizedDescription)"
                failure.beginSheetModal(for: c.window)
            }
        }
    }

    struct Day: Identifiable {
        var id: String { title }
        var title: String
        var entries: [ArchiveEntry]
    }

    var days: [Day] {
        guard let c = controller else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        let filter = archiveFilter
        let entries = c.store.archivedEntries.filter { e in
            filter.matches(e)
                && (q.isEmpty || CommandSearch.score(q, in: e.title) != nil || CommandSearch.score(q, in: URLRules.displayURL(e.url)) != nil)
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
            case .media: LibraryMediaView(files: LibraryFiles.shared, theme: theme, host: model.controller?.library) { model.controller?.showToast($0) }
            case .downloads: downloads
            case .notes: LibraryNotesView(controller: model.controller, theme: theme, revision: model.revision, onOpened: onClose)
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
            HStack {
                archiveFilterMenu
                Spacer()
                Button("Clear Archive…") { model.requestClearArchive() }
                    .buttonStyle(.airc(.secondary, size: .small))
                    .disabled(model.archiveCount == 0)
                    .testAnchor("library.clearArchive")
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 8)
            let days = model.days
            if days.isEmpty {
                empty("archivebox", model.query.isEmpty && !model.archiveFilter.isActive
                      ? "Closed and auto-archived Today tabs show up here." : "Nothing archived matches.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(days) { day in
                            Text(day.title).aircFont(AircFont.caption).foregroundStyle(theme.textTertiary.color)
                                .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 4)
                            ForEach(day.entries) { e in
                                ArchiveRow(entry: e, theme: theme, spaceName: spaceName(e)) { restore(e) }
                                    .contextMenu {
                                        Button("Restore") { restore(e) }
                                        Button("Remove from Archive…", role: .destructive) { model.requestClearArchive(entryID: e.id) }
                                        Divider()
                                        Button("Clear Archive…", role: .destructive) { model.requestClearArchive() }
                                    }
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
    }

    /// Arc's "Filter Archived Tabs": "Where was the tab?" (a Space, or Little Arc) and "How was the tab closed?".
    private var archiveFilterMenu: some View {
        let f = model.archiveFilter
        return Menu {
            Section("Where was the tab?") {
                Toggle("All Spaces", isOn: Binding(get: { f.place == .anywhere }, set: { if $0 { model.archiveFilter.place = .anywhere } }))
                ForEach(model.controller?.store.orderedSpaces ?? []) { s in
                    Toggle("\(s.iconLabel) \(s.name)".trimmingCharacters(in: .whitespaces),
                           isOn: Binding(get: { f.place == .space(s.id) }, set: { if $0 { model.archiveFilter.place = .space(s.id) } }))
                }
                Toggle("Little Airc", isOn: Binding(get: { f.place == .littleArc }, set: { if $0 { model.archiveFilter.place = .littleArc } }))
            }
            Section("How was the tab closed?") {
                Toggle("Any Way", isOn: Binding(get: { f.closing == .any }, set: { if $0 { model.archiveFilter.closing = .any } }))
                Toggle("Auto-Closed", isOn: Binding(get: { f.closing == .automatic }, set: { if $0 { model.archiveFilter.closing = .automatic } }))
                Toggle("Manually Closed", isOn: Binding(get: { f.closing == .manual }, set: { if $0 { model.archiveFilter.closing = .manual } }))
            }
            if f.isActive {
                Divider()
                Button("Clear Filter") { model.archiveFilter = ArchiveFilter() }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: f.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12, weight: .medium))
                Text(filterSummary).aircFont(AircFont.callout.weight(.medium))
            }
            .foregroundStyle((f.isActive ? theme.accent : theme.textSecondary).color)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter Archived Tabs")
        .accessibilityLabel("Filter Archived Tabs")
        .testAnchor("library.archive.filter")
    }

    private var filterSummary: String {
        let f = model.archiveFilter
        var parts: [String] = []
        switch f.place {
        case .anywhere: break
        case .space(let id): parts.append(model.controller?.store.space(id)?.name ?? "Space")
        case .littleArc: parts.append("Little Airc")
        }
        switch f.closing {
        case .any: break
        case .automatic: parts.append("Auto-Closed")
        case .manual: parts.append("Manually Closed")
        }
        return parts.isEmpty ? "Filter" : parts.joined(separator: ", ")
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
        VStack(alignment: .leading, spacing: 0) {
            // Reorder, rename, icon, theme, profile and delete, for every Space in one card (ManageSpacesPanel).
            HStack {
                Spacer()
                Button("Manage Spaces…") { model.controller?.showManageSpaces() }
                    .buttonStyle(.airc(.secondary, size: .small))
                    .testAnchor("library.manageSpaces")
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            spaceList
        }
    }

    private var spaceList: some View {
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
    private var host: AircFirstClickHostingView<LibraryView>?
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

    // Library › Media's Quick Look panel (LibraryQuickLook): the host is first responder while it's up.
    override var acceptsFirstResponder: Bool { true }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { LibraryQuickLook.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { LibraryQuickLook.shared.end(panel) }

    override func layout() {
        super.layout()
        back.frame = SpaceBarView.libraryButtonFrame(columnHeight: bounds.height)
        // With the sidebar on the right the panel ends at the window's right edge (WIN-5): the button moves by as much
        // as the panel is wider than the sidebar, so it still sits on the footer's Library button.
        if let c = controller, c.sidebarOnRight { back.frame.origin.x += max(0, bounds.width - c.sidebarWidth) }
    }

    func setTheme(_ theme: ResolvedTheme) {
        let view = LibraryView(model: model, theme: theme) { [weak self] in self?.controller?.toggleLibrary() }
        if let host {
            host.rootView = view
        } else {
            // The first click works, as on the sidebar it covers (Arc), also while the window isn't in front.
            let h = AircFirstClickHostingView(rootView: view)
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
    /// A swipe past the first Space (SP-25): opens the Library, never closes it.
    func openLibrary() {
        if library == nil { toggleLibrary() }
    }

    /// ⇧⌘L and the footer's Library button (SB-62).
    func toggleLibrary() {
        let opening = library == nil
        recentFiles.hide()
        if !opening { LibraryQuickLook.shared.close() }
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

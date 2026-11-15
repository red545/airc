// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

// MARK: - Library › Media (LIB-1)

/// Arc's Library › Media: the images and videos downloaded in Airc, the Captures saved with ⇧⌘2 and (P10a) the
/// pictures and videos of folders the person let it show, as a grid of thumbnails, newest first by day. "Show media
/// from" switches each source; a folder not allowed yet, declined or no longer readable says so above the grid. A click shows the file in Quick Look (← → move through the grid), a double-click
/// opens it in its app, ⌘-click shows it in Finder, and a tile drags out as the file. Its menu also copies it and moves
/// it to the Trash, with Undo in the bar under the grid while it's offered.
struct LibraryMediaView: View {
    @ObservedObject var files: LibraryFiles
    @ObservedObject var folders = LibraryFolderSources.shared
    let theme: ResolvedTheme
    weak var host: LibraryPanelHost?
    var failed: (String) -> Void

    static let spacing: CGFloat = 8
    #if AIRC_TESTING
    /// The files the grid last drew, in order (the scripted check reads it).
    static var rendered: [String] = []
    /// Drags that started from a tile or a recent-files row.
    static var dragsStarted = 0
    #endif
    static let tileMinimum: CGFloat = 108

    struct Day: Identifiable {
        var id: String { title }
        var title: String
        var files: [LibraryFile]
    }

    /// Arc's buckets ("Today", "Yesterday", "Earlier This Week", then months), after the type filter.
    private var days: [Day] {
        LibraryMedia.buckets(shown).map { Day(title: $0.title, files: $0.files) }
    }

    /// The grid's files with the type filter (L04).
    private var shown: [LibraryFile] { LibraryMedia.filtered(files.media, by: files.filter) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sourcesBar
            ForEach(LibraryFolder.allCases.filter { needsNote($0) }) { f in folderNote(f) }
            if let f = files.filter { filterChip(f) }
            let days = days
            #if AIRC_TESTING
            let _ = { LibraryMediaView.rendered = days.flatMap { $0.files.map(\.name) } }()
            #endif
            if days.isEmpty, let f = files.filter, !files.media.isEmpty {
                VStack(spacing: 10) {
                    Text("No \(f.title)").aircFont(AircFont.body.weight(.semibold)).foregroundStyle(theme.text.color)
                    Button("Remove \(f.title) Filter") { files.filter = nil }
                        .buttonStyle(.airc(.secondary, size: .small))
                        .testAnchor("library.media.removeFilterEmpty")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                Spacer(minLength: 0)
            } else if days.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 22, weight: .light)).foregroundStyle(theme.textTertiary.color)
                    Text(noFolders ? "Your Media in the Library" : "Nothing here yet")
                        .aircFont(AircFont.body.weight(.semibold)).foregroundStyle(theme.text.color)
                    Text(noFolders
                         ? "Images and videos you download, and Captures you save, show up here. Allow your Desktop, Documents, Downloads or Screenshots folder to see their pictures and videos too."
                         : "Save pictures and videos to the folders you allowed, or download some, and they show up here alongside your Captures.")
                        .aircFont(AircFont.callout).foregroundStyle(theme.textSecondary.color).multilineTextAlignment(.center)
                    if noFolders {
                        Button("Allow Desktop…") { folders.requestAccess(.desktop, for: host?.window) }
                            .buttonStyle(.airc(.secondary, size: .small))
                            .testAnchor("library.media.allowDesktop")
                        Text("Media never leaves your computer and is not viewable by anyone but you.")
                            .aircFont(AircFont.caption).foregroundStyle(theme.textTertiary.color).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.horizontal, 36)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days) { day in
                            Text(day.title).aircFont(AircFont.caption).foregroundStyle(theme.textTertiary.color)
                                .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 6)
                                .testAnchor("library.media.day.\(day.title)")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMinimum), spacing: Self.spacing)], spacing: Self.spacing) {
                                ForEach(day.files) { f in
                                    MediaTile(file: f, theme: theme, selected: files.selected?.path == f.path) { count, command in
                                        files.activate(f, in: shown, clickCount: count, command: command, from: host)
                                    }
                                    .contextMenu { menu(f) }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
            }
            if let t = files.trashed {
                undoBar(t)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.top, 8)
        .animation(AircSpring.row.animation, value: files.trashed)
        .onAppear {
            folders.start()
            files.refresh()
        }
        .onDisappear { files.forgetTrash() }
    }

    @ViewBuilder private func menu(_ f: LibraryFile) -> some View {
        Button("Open") { files.open(f) }
        Button("Quick Look") { files.activate(f, in: shown, clickCount: 1, command: false, from: host) }
        Button("Show in Finder") { files.showInFinder(f) }
        Divider()
        Button("Copy") { files.copy(f) }
        Divider()
        // Arc's "Hide from Arc" for a folder's screenshot: the file stays where it is.
        if f.source == .folder { Button("Hide from Library") { folders.hide(f) } }
        Button("Move to Trash", role: .destructive) { files.moveToTrash(f, failed: failed) }
    }

    // MARK: Sources (P10a)

    private var noFolders: Bool { folders.settings.grants.isEmpty }

    /// Arc's "Show media from:": Captures and Downloads (Airc's own), then each folder: a checkmark when shown, "Allow…"
    /// before it's granted, "Choose Again…" when it can't be read.
    private var sourcesBar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Menu {
                Section("Filter Media") {
                    ForEach(LibraryMedia.Filter.allCases) { f in
                        Toggle(f.title, isOn: Binding(get: { files.filter == f }, set: { files.filter = $0 ? f : nil }))
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 12, weight: .medium))
                    .foregroundStyle((files.filter == nil ? theme.textSecondary : theme.text).color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter Media")
            .accessibilityLabel("Filter Media")
            .testAnchor("library.media.filter")
            Menu {
                Section("Show media from") {
                    Toggle("Captures", isOn: Binding(get: { folders.settings.showCaptures },
                                                     set: { v in var s = folders.settings; s.showCaptures = v; folders.settings = s; files.refresh() }))
                    Toggle("Downloads", isOn: Binding(get: { folders.settings.showDownloads },
                                                      set: { v in var s = folders.settings; s.showDownloads = v; folders.settings = s; files.refresh() }))
                }
                Section("Folders") {
                    ForEach(LibraryFolder.allCases) { f in folderMenuItem(f) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.system(size: 11, weight: .medium))
                    Text(sourcesSummary).aircFont(AircFont.callout.weight(.medium))
                }
                .foregroundStyle(theme.textSecondary.color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show media from…")
            .accessibilityLabel("Show media from")
            .testAnchor("library.media.sources")
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
    }

    private var sourcesSummary: String {
        let s = folders.settings
        var parts: [String] = []
        if s.showCaptures { parts.append("Captures") }
        if s.showDownloads { parts.append("Downloads") }
        let shown = LibraryFolder.allCases.filter { s.shows($0) }
        if !shown.isEmpty { parts.append(shown.count == 1 ? shown[0].title : "\(shown.count) folders") }
        return parts.isEmpty ? "No sources" : parts.joined(separator: ", ")
    }

    @ViewBuilder private func folderMenuItem(_ f: LibraryFolder) -> some View {
        switch folders.states[f] ?? .notGranted {
        case .granted:
            Toggle(f.title, isOn: Binding(get: { folders.settings.shows(f) }, set: { folders.setShown(f, $0) }))
        case .revoked:
            Button("\(f.title): Choose Again…") { folders.requestAccess(f, for: host?.window) }
        case .notGranted, .declined:
            Button("\(f.title)…") { folders.requestAccess(f, for: host?.window) }
        }
        if folders.settings.grant(f) != nil {
            Button("Stop Showing \(f.title)") { folders.forget(f) }
        }
    }

    /// A folder the person said no to while Media shows nothing of it, or one that can't be read any more.
    private func needsNote(_ f: LibraryFolder) -> Bool {
        switch folders.states[f] ?? .notGranted {
        case .revoked: return true
        case .declined: return noFolders && f == .desktop
        default: return false
        }
    }

    private func folderNote(_ f: LibraryFolder) -> some View {
        let state = folders.states[f] ?? .notGranted
        let text: String
        if case .revoked(let why) = state {
            text = "\(f.title): \(why)"
        } else {
            text = "Airc doesn’t have permission to show your \(f.title) folder."
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textTertiary.color)
            Text(text).aircFont(AircFont.callout).foregroundStyle(theme.textSecondary.color).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(state == .declined ? "Allow…" : "Choose Again…") { folders.requestAccess(f, for: host?.window) }
                .buttonStyle(.airc(.secondary, size: .small))
                .testAnchor("library.media.note.\(f.rawValue)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(theme.fieldFill.color))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// Arc's active filter, with its "Remove Images Filter" button.
    private func filterChip(_ f: LibraryMedia.Filter) -> some View {
        HStack(spacing: 6) {
            Text(f.title).aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.text.color)
            Button { files.filter = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary.color)
                .help("Remove \(f.title) Filter")
                .accessibilityLabel("Remove \(f.title) Filter")
                .testAnchor("library.media.removeFilter")
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .frame(height: 24)
        .background(Capsule().fill(theme.selectedFill.color))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private func undoBar(_ t: LibraryFiles.Trashed) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textTertiary.color)
            Text("Moved “\(t.file.name)” to the Trash")
                .aircFont(AircFont.callout).foregroundStyle(theme.textSecondary.color)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button("Undo") { if !files.undoTrash() { failed("Couldn’t put “\(t.file.name)” back") } }
                .buttonStyle(.airc(.secondary, size: .small))
                .testAnchor("library.media.undo")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(theme.fieldFill.color))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// One file in the grid: its Quick Look picture filling a rounded square (the file's icon until it comes), a play badge
/// on videos, and the name on hover.
private struct MediaTile: View {
    let file: LibraryFile
    let theme: ResolvedTheme
    var selected = false
    let onClick: (_ clickCount: Int, _ command: Bool) -> Void
    @State private var image: NSImage?
    @State private var hovered = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: AircRadius.tile, style: .continuous).fill(theme.tileFill.color)
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side).clipped()
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().interpolation(.high)
                        .frame(width: side * 0.42, height: side * 0.42)
                        .frame(width: side, height: side)
                        .opacity(0.8)
                }
                if file.kind == .video {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .padding(6)
                        .frame(width: side, height: side, alignment: .topTrailing)
                }
                if hovered {
                    Text(file.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8).padding(.bottom, 6).padding(.top, 14)
                        .frame(width: side, alignment: .leading)
                        .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .transition(.opacity)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: AircRadius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AircRadius.tile, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : theme.separator.color, lineWidth: selected ? 2 : 0.5))
            .task(id: "\(file.id)|\(file.date.timeIntervalSince1970)|\(Int(side))") {
                guard side > 0 else { return }
                if let hit = LibraryThumbnails.shared.cached(file, side: side, scale: scale) { image = hit; return }
                LibraryThumbnails.shared.thumbnail(file, side: side, scale: scale) { got in if let got { image = got } }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
        .onTapGesture {
            let e = NSApp.currentEvent
            onClick(e?.clickCount ?? 1, e?.modifierFlags.contains(.command) == true)
        }
        .onDrag {
            #if AIRC_TESTING
            LibraryMediaView.dragsStarted += 1
            #endif
            return NSItemProvider(contentsOf: file.url) ?? NSItemProvider()
        }
        .help(file.name)
        .testAnchor("library.media.\(file.name)")
    }
}

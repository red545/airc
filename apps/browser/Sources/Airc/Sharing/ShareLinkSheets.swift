// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import SwiftUI

/// H01, H02: Share Space… and Share Folder… show exactly what the link will hold, then publish it to aircbrowser.com
/// (SharingCenter) only when the person clicks Create Link. Arc asked first too: "Anyone with this link can view your …".
/// Unlike Arc's permalinks, a link can be taken back: this Mac keeps its key, and the sheet lists the links made of the
/// same Space or folder with Take Back.
final class ShareLinkSheet: ObservableObject {
    static var active: [ObjectIdentifier: ShareLinkSheet] = [:]
    enum Phase: Equatable {
        case preview
        case publishing
        case published(SharedLinkRecord)
    }
    let draft: ShareDraft
    let sourceID: String
    /// Why the snapshot can't be published (too large), found before anything is sent.
    let problem: String?
    let rows: [ShareRow]
    let sheet: NSWindow
    weak var parent: NSWindow?
    weak var controller: WindowController?
    @Published private(set) var phase = Phase.preview
    @Published private(set) var message: String?
    @Published private(set) var earlier: [SharedLinkRecord]
    @Published private(set) var revoking: Set<String> = []

    init(draft: ShareDraft, sourceID: String, controller: WindowController) {
        self.draft = draft
        self.sourceID = sourceID
        self.controller = controller
        parent = controller.window
        do {
            try SharingService.check(draft.snapshot)
            problem = nil
        } catch {
            problem = error.localizedDescription + (draft.snapshot.counts.folders > 0 ? " Share one of its folders instead." : "")
        }
        rows = ShareRow.rows(draft.snapshot.items)
        earlier = SharingCenter.shared.links(of: sourceID)
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Share"
        sheet.isReleasedWhenClosed = false
        sheet.contentView = NSHostingView(rootView: ShareLinkView(share: self))
    }

    var isSpace: Bool { if case .space = draft.snapshot.kind { true } else { false } }
    var published: SharedLinkRecord? { if case .published(let r) = phase { r } else { nil } }

    func present() {
        guard let parent, parent.attachedSheet == nil else { NSSound.beep(); return }
        Self.active[ObjectIdentifier(parent)] = self
        parent.beginSheet(sheet)
    }

    func close() {
        guard let parent else { return }
        parent.endSheet(sheet)
        sheet.orderOut(nil)
        Self.active[ObjectIdentifier(parent)] = nil
    }

    /// Create Link: the snapshot goes to aircbrowser.com; the link comes back with its key.
    func create() {
        guard phase == .preview, problem == nil else { return NSSound.beep() }
        phase = .publishing
        message = nil
        Task { @MainActor in
            do {
                let r = try await SharingCenter.shared.publish(draft, sourceID: sourceID)
                phase = .published(r)
            } catch {
                phase = .preview
                message = error.localizedDescription
            }
        }
    }

    /// Copy Link: the new link on the clipboard (the link pasteboard, as Copy Link's), with a toast.
    func copyLink() {
        guard let r = published else { return NSSound.beep() }
        close()
        controller?.writeLinks(r.url.absoluteString, toast: "Copied Link")
    }

    func copy(_ r: SharedLinkRecord) {
        controller?.writeLinks(r.url.absoluteString, toast: "Copied Link")
    }

    /// Share…: the system's picker for the link (Messages, Mail, AirDrop…), beside the button.
    func shareWithPicker() {
        guard let r = published, let view = sheet.contentView, let share = SelectionShare([r.url.absoluteString]) else { return NSSound.beep() }
        share.show(relativeTo: NSRect(x: view.bounds.maxX - 200, y: 20, width: 80, height: 24), of: view, edge: .minY)
    }

    /// Take Back: asks first, then the link stops working everywhere (it 404s).
    func takeBack(_ r: SharedLinkRecord, confirmed: Bool = false) {
        guard confirmed else {
            let alert = NSAlert()
            alert.messageText = "Take back this link?"
            alert.informativeText = "Anyone who opens it will see that it was taken back. What they already added to Airc stays with them."
            alert.addButton(withTitle: "Take Back")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: sheet) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.takeBack(r, confirmed: true) }
            }
            return
        }
        revoking.insert(r.id)
        Task { @MainActor in
            defer { revoking.remove(r.id) }
            do {
                try await SharingCenter.shared.revoke(r)
                earlier = SharingCenter.shared.links(of: sourceID)
                if published?.id == r.id { phase = .preview }
                message = "Link taken back."
            } catch SharingCenter.RevokeFailure.noToken {
                SharingCenter.shared.forget(r)
                earlier = SharingCenter.shared.links(of: sourceID)
                message = SharingCenter.RevokeFailure.noToken.localizedDescription
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// What the preview says about what isn't in the link.
    var leftOutText: String {
        var parts: [String] = []
        if draft.todayTabs > 0 { parts.append(draft.todayTabs == 1 ? "1 Today tab" : "\(draft.todayTabs) Today tabs") }
        if draft.leftOut > 0 { parts.append(draft.leftOut == 1 ? "1 note or local file" : "\(draft.leftOut) notes or local files") }
        let never = "Favorites, history, cookies and what's on the pages are never in a link."
        return parts.isEmpty ? never : "Not included: " + parts.joined(separator: " and ") + ". " + never
    }
}

/// An opened link's preview, then Add, into the destination the person picks: a new Space in one of their profiles,
/// or a folder at the end of one of their Spaces' pinned tabs. Nothing is added before Add.
final class ShareImportSheet: ObservableObject {
    static var active: [ObjectIdentifier: ShareImportSheet] = [:]
    let snapshot: ShareSnapshot
    let rows: [ShareRow]
    let sheet: NSWindow
    weak var parent: NSWindow?
    weak var controller: WindowController?
    @Published private(set) var message: String?
    /// Where it goes: a profile (for a Space) or a Space (for a folder).
    struct Destination: Identifiable, Hashable { let id: String; let title: String }
    @Published var destination: String
    let destinations: [Destination]

    init(snapshot: ShareSnapshot, controller: WindowController) {
        self.snapshot = snapshot
        self.controller = controller
        parent = controller.window
        rows = ShareRow.rows(snapshot.items)
        let store = controller.store
        if case .space = snapshot.kind {
            destinations = store.orderedProfiles.map { Destination(id: $0.id, title: $0.name) }
            destination = store.profile(ofSpace: controller.currentSpaceID).id
        } else {
            destinations = store.orderedSpaces.map { Destination(id: $0.id, title: $0.name.isEmpty ? "Space" : $0.name) }
            destination = controller.currentSpaceID
        }
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Shared Link"
        sheet.isReleasedWhenClosed = false
        sheet.contentView = NSHostingView(rootView: ShareImportView(sheet: self))
    }

    var isSpace: Bool { if case .space = snapshot.kind { true } else { false } }
    var destinationName: String { destinations.first { $0.id == destination }?.title ?? "This Space" }

    func present() {
        guard let parent, parent.attachedSheet == nil else { NSSound.beep(); return }
        Self.active[ObjectIdentifier(parent)] = self
        parent.beginSheet(sheet)
    }

    func close() {
        guard let parent else { return }
        parent.endSheet(sheet)
        sheet.orderOut(nil)
        Self.active[ObjectIdentifier(parent)] = nil
    }

    /// Adds it in one undoable step: a Space (in the chosen profile, after this window's Space, shown) or a folder at
    /// the end of the chosen Space's pinned tabs. Its tabs aren't opened.
    func add() {
        guard let c = controller else { return }
        do {
            if isSpace {
                let s = try c.store.addSharedSpace(snapshot, profileID: destination, after: c.currentSpaceID)
                close()
                c.switchToSpace(s.id, animated: true)
                c.showToast("Added “\(s.name)” as a new Space")
            } else {
                let f = try c.store.addSharedFolder(snapshot, toSpace: destination)
                close()
                if destination != c.currentSpaceID { c.switchToSpace(destination, animated: true) }
                c.showToast("Added “\(f.displayTitle)” to \(destination == c.currentSpaceID ? "this Space" : "“\(destinationName)”")")
            }
        } catch {
            message = "Airc couldn’t add it: \(error.localizedDescription)"
        }
    }
}

/// One row of a preview: a tab, a folder or a split, indented by its depth.
struct ShareRow: Identifiable {
    enum Kind { case tab, folder, split }
    let id: Int
    let depth: Int
    let kind: Kind
    let title: String
    let detail: String

    static func rows(_ nodes: [ShareNode]) -> [ShareRow] {
        var out: [ShareRow] = []
        func tab(_ t: ShareTab, depth: Int) {
            let host = URL(string: t.url)?.host ?? t.url
            out.append(ShareRow(id: out.count, depth: depth, kind: .tab, title: t.title ?? host, detail: t.title == nil ? "" : host))
        }
        func walk(_ nodes: [ShareNode], depth: Int) {
            for n in nodes {
                switch n {
                case .tab(let t): tab(t, depth: depth)
                case .folder(let name, let items):
                    out.append(ShareRow(id: out.count, depth: depth, kind: .folder, title: name, detail: ""))
                    walk(items, depth: depth + 1)
                case .split(_, let tabs):
                    out.append(ShareRow(id: out.count, depth: depth, kind: .split, title: "Split View", detail: "\(tabs.count) tabs"))
                    tabs.forEach { tab($0, depth: depth + 1) }
                }
            }
        }
        walk(nodes, depth: 0)
        return out
    }

    /// "12 tabs in 3 folders", "1 tab".
    static func summary(_ s: ShareSnapshot) -> String {
        let c = s.counts
        let tabs = c.tabs == 1 ? "1 tab" : "\(c.tabs) tabs"
        guard c.folders > 0 else { return tabs }
        return tabs + (c.folders == 1 ? " in 1 folder" : " in \(c.folders) folders")
    }
}

private struct ShareTree: View {
    let rows: [ShareRow]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in
                    HStack(spacing: 8) {
                        Image(systemName: r.kind == .folder ? "folder" : r.kind == .split ? "rectangle.split.2x1" : "globe")
                            .foregroundStyle(.secondary).frame(width: 16)
                        Text(r.title).lineLimit(1).truncationMode(.tail)
                        if !r.detail.isEmpty { Text(r.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13))
                    .padding(.leading, CGFloat(r.depth) * 18 + 10).padding(.trailing, 10).frame(height: 26)
                }
            }.padding(.vertical, 6)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

private struct ShareHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }
}

/// A link's address without its scheme, as the sheet shows it.
private func shortLink(_ url: URL) -> String {
    (url.host ?? "") + (url.port.map { ":\($0)" } ?? "") + url.path
}

struct ShareLinkView: View {
    @ObservedObject var share: ShareLinkSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShareHeader(symbol: "link", title: (share.isSpace ? "Share Space “" : "Share Folder “") + share.draft.snapshot.name + "”",
                        subtitle: ShareRow.summary(share.draft.snapshot)).testAnchor("share.title")
            ShareTree(rows: share.rows).testAnchor("share.tree")
            if let r = share.published {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(r.url.absoluteString).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                        .truncationMode(.middle).testAnchor("share.link")
                }
                Text("Anyone with this link can see these titles and addresses, in any browser. Later changes don’t reach it. Take it back here whenever you like.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Create Link puts these titles and addresses on aircbrowser.com, where anyone with the link can see them. It’s a snapshot: later changes don’t reach it. You can take it back.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(share.leftOutText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .testAnchor("share.leftOut")
            }
            let others = share.earlier.filter { $0.id != share.published?.id }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(others.count == 1 ? "A link you made earlier" : "Links you made earlier").font(.callout.weight(.semibold))
                    ForEach(others) { r in
                        HStack(spacing: 8) {
                            Text(shortLink(r.url)).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Text(r.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Copy") { share.copy(r) }.controlSize(.small)
                            Button("Take Back") { share.takeBack(r) }.controlSize(.small).disabled(share.revoking.contains(r.id))
                                .testAnchor("share.takeBack.\(r.id)")
                        }
                    }
                }
            }
            if let p = share.problem { Text(p).foregroundStyle(.red).testAnchor("share.error") }
            if let m = share.message { Text(m).font(.callout).foregroundStyle(.secondary).testAnchor("share.message") }
            HStack {
                if let r = share.published {
                    Button("Take Back") { share.takeBack(r) }.disabled(share.revoking.contains(r.id)).testAnchor("share.takeBack")
                }
                Spacer()
                switch share.phase {
                case .published:
                    Button("Done", action: share.close).keyboardShortcut(.cancelAction).testAnchor("share.done")
                    Button("Share…", action: share.shareWithPicker).testAnchor("share.picker")
                    Button("Copy Link", action: share.copyLink).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .testAnchor("share.copy")
                case .preview, .publishing:
                    Button("Cancel", action: share.close).keyboardShortcut(.cancelAction).testAnchor("share.cancel")
                    if share.phase == .publishing { ProgressView().controlSize(.small) }
                    Button("Create Link", action: share.create).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(share.problem != nil || share.phase == .publishing).testAnchor("share.create")
                }
            }
        }.padding(24).frame(width: 520, height: 600).background(.background)
    }
}

struct ShareImportView: View {
    @ObservedObject var sheet: ShareImportSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShareHeader(symbol: sheet.isSpace ? "square.stack" : "folder", title: sheet.snapshot.name,
                        subtitle: (sheet.isSpace ? "A shared Space · " : "A shared folder · ") + ShareRow.summary(sheet.snapshot))
                .testAnchor("share.import.title")
            ShareTree(rows: sheet.rows).testAnchor("share.import.tree")
            if sheet.destinations.count > 1 {
                Picker(sheet.isSpace ? "Add to profile" : "Add to Space", selection: $sheet.destination) {
                    ForEach(sheet.destinations) { d in Text(d.title).tag(d.id) }
                }
                .testAnchor("share.import.destination")
            }
            Text(sheet.isSpace ? "It’s added as a new Space with these pinned tabs and folders. Nothing opens until you click a tab."
                               : "It’s added to the end of “\(sheet.destinationName)”’s pinned tabs. Nothing opens until you click a tab.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let m = sheet.message { Text(m).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: sheet.close).keyboardShortcut(.cancelAction).testAnchor("share.import.cancel")
                Button(sheet.isSpace ? "Add as New Space" : "Add Folder", action: sheet.add).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).testAnchor("share.import.add")
            }
        }.padding(24).frame(width: 520, height: 600).background(.background)
    }
}

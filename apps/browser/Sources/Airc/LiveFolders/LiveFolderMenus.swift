// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// Live Folders in the window's menus (Browser/WindowActions.swift calls these): New Live Folder… in the Space menu and
/// the + menu (Arc's Space menu has "Live Folder ›" right after New Folder), the folder's own items at the top of its
/// menu, Keep in Folder on a pull request's row, and the Command Bar's entries.
extension WindowController {
    private var liveCenter: LiveFolderCenter { LiveFolderCenter.shared }

    /// New Live Folder… (Space menu, + menu).
    func addNewLiveFolderItem(to m: NSMenu, spaceID: String) {
        guard !isPrivateLiveStore else { return }
        let item = m.add("New Live Folder…") { [weak self] in self?.newLiveFolder(inSpace: spaceID) }
        item.image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)
    }

    /// A private window's store never has live folders (it'd sign requests with nothing and keep nothing).
    private var isPrivateLiveStore: Bool {
        guard let main = (NSApp.delegate as? AppDelegate)?.store else { return true }
        return main !== store
    }

    func newLiveFolder(inSpace spaceID: String? = nil) {
        guard !isPrivateLiveStore else { return NSSound.beep() }
        LiveFolderSheet(controller: self, spaceID: spaceID ?? currentSpaceID).present()
    }

    func editLiveFolder(_ folderID: String) {
        guard let space = store.item(folderID)?.spaceID else { return }
        LiveFolderSheet(controller: self, spaceID: space, editing: folderID).present()
    }

    /// The folder menu's live part: its state, Refresh, the filters, the account, Stop Updating. Nothing for a plain
    /// folder.
    func addLiveFolderItems(to m: NSMenu, folder: Item) {
        guard !isPrivateLiveStore, liveCenter.attach(store) != nil, let s = liveCenter.display(folder.id) else { return }
        let status = NSMenuItem(title: s.isRefreshing ? "Updating…" : s.status == .ok ? Self.updatedLine(s) : s.status.message,
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        m.addItem(status)
        m.add("Refresh") { [weak self] in self?.liveCenter.refresh(folder.id) }.isEnabled = !s.isRefreshing && {
            if case .rateLimited(let until?) = s.status { return until <= Date() }
            return true
        }()
        if s.status == .signedOut || (s.account == nil && s.query.needsSignIn) {
            m.add("Sign In to GitHub…") { [weak self] in self?.editLiveFolder(folder.id) }
        }
        // Arc's filters, in its words; each change lists again.
        let q = s.query
        if q.repository == nil || q.createdByMe || q.reviewRequested {
            m.add("Created by Me") { [weak self] in
                var n = q
                n.createdByMe.toggle()
                if !n.createdByMe && !n.reviewRequested { n.reviewRequested = true }
                self?.liveCenter.setQuery(n, ofFolder: folder.id)
            }.state = q.createdByMe ? .on : .off
            m.add("Review Requests") { [weak self] in
                var n = q
                n.reviewRequested.toggle()
                if !n.createdByMe && !n.reviewRequested { n.createdByMe = true }
                self?.liveCenter.setQuery(n, ofFolder: folder.id)
            }.state = q.reviewRequested ? .on : .off
        }
        m.add("Drafts") { [weak self] in
            var n = q
            n.includeDrafts.toggle()
            self?.liveCenter.setQuery(n, ofFolder: folder.id)
        }.state = q.includeDrafts ? .on : .off
        // Arc lists the repositories of the pull requests it shows, to narrow the folder to one.
        let repos = Array(Set((liveCenter.book?.definition(folder.id)?.cache ?? []).map(\.repository))).sorted()
        if q.createdByMe || q.reviewRequested, repos.count > 1 || q.repository != nil {
            let sub = NSMenu()
            sub.add("All Repositories") { [weak self] in
                var n = q
                n.repository = nil
                self?.liveCenter.setQuery(n, ofFolder: folder.id)
            }.state = q.repository == nil ? .on : .off
            sub.addItem(.separator())
            for r in Set(repos + [q.repository].compactMap { $0 }).sorted() {
                sub.add(r) { [weak self] in
                    var n = q
                    n.repository = r
                    self?.liveCenter.setQuery(n, ofFolder: folder.id)
                }.state = q.repository == r ? .on : .off
            }
            let note = NSMenuItem(title: "This list is generated based on your currently active pull requests.", action: nil, keyEquivalent: "")
            note.isEnabled = false
            sub.addItem(.separator())
            sub.addItem(note)
            let item = NSMenuItem(title: "Repositories", action: nil, keyEquivalent: "")
            item.submenu = sub
            m.addItem(item)
        }
        m.add("Edit Live Folder…") { [weak self] in self?.editLiveFolder(folder.id) }
        m.add("Stop Updating") { [weak self] in self?.liveCenter.stopUpdating(folder.id) }
        m.addItem(.separator())
    }

    static func updatedLine(_ s: LiveFolderCenter.Display) -> String {
        guard let t = s.lastRefreshed else { return "Not updated yet" }
        if Date().timeIntervalSince(t) < 60 { return "Updated just now" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        return "Updated " + rel.localizedString(for: t, relativeTo: Date())
    }

    /// Keep in Folder on a pull request's row: it becomes the person's own tab and stays after the pull request ends.
    func addLiveRowItems(to m: NSMenu, item: Item) {
        guard !isPrivateLiveStore, liveCenter.attach(store)?.liveKey(ofItem: item.id) != nil else { return }
        m.addItem(.separator())
        m.add("Keep in Folder") { [weak self] in self?.liveCenter.keep(item.id) }
            .toolTip = "Keeps this tab here after its pull request is merged or closed"
    }

    /// The Command Bar's Live Folder commands (WindowActions.swift `contextCommandActions`).
    func liveFolderCommandActions() -> [CommandAction] {
        guard !isPrivateLiveStore else { return [] }
        var a: [CommandAction] = [
            .init(title: "New Live Folder…", symbol: "arrow.triangle.pull", hint: "",
                  keywords: ["live folder", "github", "pull requests", "prs", "review requests", "automatic"]) { [weak self] in
                self?.newLiveFolder()
            },
        ]
        guard let book = liveCenter.attach(store) else { return a }
        for id in book.activeFolderIDs where store.item(id)?.spaceID == currentSpaceID {
            let name = store.item(id)?.displayTitle ?? "Live Folder"
            a.append(.init(title: "Refresh \(name) Live Folder", symbol: "arrow.clockwise", hint: "",
                           keywords: ["live folder", "github", "refresh", "update", "pull requests"]) { [weak self] in
                self?.liveCenter.refresh(id)
            })
        }
        return a
    }
}

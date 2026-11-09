// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// P04 (S14): files, folders, links and text into the sidebar, by a drop or by Add Files (Arc 2021's "Add Files" in the
/// "+" menu, and its Finder drops). What each becomes is AircKit's `SidebarFilePlanner`: a file opens as a tab, a folder
/// becomes a sidebar folder with its files as pinned tabs (nested folders kept), a link a tab, a phrase a search, longer
/// text a note. Reading folders happens off the main thread; a slow read shows a sheet with Cancel; more than
/// `confirmAbove` tabs asks first. Nothing is made until the end, and then all of it in one step that one ⌘Z undoes:
/// a cancel, at any point, makes no rows.
///
/// The hooks: `addFiles()` (the "+" menu), `canImportIntoSidebar(_:)` and `importIntoSidebar(_:destination:)` (the
/// sidebar's drop target, with the drop line's section, folder and place).
enum SidebarFileImport {
    /// What a sidebar drop target registers for.
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]
    static let urlNameType = NSPasteboard.PasteboardType("public.url-name")
    /// More tabs than this ask before they're made.
    static var confirmAbove = 25
    /// A read that takes longer shows the Cancel sheet.
    static var sheetAfter: TimeInterval = 0.4
    /// Checks answer the "Add N tabs?" question here instead of a sheet (true: add).
    static var confirmOverride: ((SidebarFilePlan) -> Bool)?
    /// The import under way, or the last one (checks read it).
    static private(set) weak var latest: SidebarFileImportOperation?

    /// A drag's or the pasteboard's files, links (with their titles) and text, in order.
    static func items(from pb: NSPasteboard) -> [SidebarDropItem] {
        var files: [URL] = [], links: [String] = [], titles: [String] = []
        for item in pb.pasteboardItems ?? [] {
            if let s = item.string(forType: .fileURL), let u = URL(string: s), u.isFileURL {
                files.append(u)
            } else if let s = item.string(forType: .URL), !s.isEmpty {
                links.append(s)
                titles.append(item.string(forType: urlNameType) ?? "")
            }
        }
        return SidebarFilePlanner.items(files: files, links: links, titles: titles, text: pb.string(forType: .string))
    }

    /// Imports under way, held until they end.
    private static var running: [SidebarFileImportOperation] = []
    fileprivate static func began(_ op: SidebarFileImportOperation) {
        latest = op
        running.append(op)
    }
    fileprivate static func ended(_ op: SidebarFileImportOperation) { running.removeAll { $0 === op } }
}

/// One import: the plan read off the main thread, the question for a big one, then the rows.
final class SidebarFileImportOperation {
    enum State: Equatable {
        case reading, asking, done(SidebarFileResult), cancelled
    }

    private(set) var state = State.reading
    private(set) var plan: SidebarFilePlan?
    let destination: SidebarFileDestination
    private weak var controller: WindowController?
    private let flag = CancelFlag()
    private weak var sheet: NSWindow?
    /// The rows were made or the import was cancelled.
    var onFinish: ((SidebarFileImportOperation) -> Void)?

    var isFinished: Bool { if case .done = state { true } else { state == .cancelled } }

    fileprivate init(destination: SidebarFileDestination, controller: WindowController) {
        self.destination = destination
        self.controller = controller
    }

    fileprivate func start(_ items: [SidebarDropItem]) {
        let flag = flag
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = SidebarFilePlanner.plan(items) { flag.isSet }
            DispatchQueue.main.async { self?.planned(plan) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarFileImport.sheetAfter) { [weak self] in
            guard let self, self.state == .reading else { return }
            self.ask("Reading files…", "Nothing is added until it's done.", buttons: ["Cancel"], required: false) { [weak self] _ in self?.cancel() }
        }
    }

    /// Before the rows are made, at any point: nothing is made.
    func cancel() {
        guard !isFinished else { return }
        flag.set()
        endSheet()
        state = .cancelled
        onFinish?(self)
        SidebarFileImport.ended(self)
    }

    private func planned(_ p: SidebarFilePlan) {
        guard state == .reading else { return }
        endSheet()
        plan = p
        guard !p.cancelled else { return cancel() }
        guard let c = controller, let space = c.store.space(destination.spaceID) else { return cancel() }
        guard !p.isEmpty else {
            c.showToast(p.skipped.total > 0 ? "Nothing to add: only hidden or unreadable files" : "Nothing to add")
            return finish(SidebarFileResult())
        }
        guard p.tabCount > SidebarFileImport.confirmAbove || p.truncated else { return apply() }
        state = .asking
        if let answer = SidebarFileImport.confirmOverride { return answer(p) ? apply() : cancel() }
        let folders = p.folderCount == 0 ? "" : p.folderCount == 1 ? " in a folder" : " in \(p.folderCount) folders"
        var detail = "They're added as tabs\(folders). One ⌘Z takes them all back."
        if p.truncated { detail = "Only the first \(p.tabCount) files are added. " + detail }
        ask("Add \(p.tabCount) tabs to “\(space.name)”?", detail, buttons: ["Add", "Cancel"]) { [weak self] r in
            r == .alertFirstButtonReturn ? self?.apply() : self?.cancel()
        }
    }

    private func apply() {
        guard let c = controller, let p = plan, !flag.isSet else { return cancel() }
        let engine = c.store.profile(ofSpace: destination.spaceID).searchEngine
        do {
            let r = try c.store.applySidebarFilePlan(p, to: destination, engine: engine)
            if let first = r.todayTabIDs.first {
                if destination.spaceID != c.currentSpaceID { c.switchToSpace(destination.spaceID, animated: false) }
                c.show(first)
            }
            let tabs = r.tabs == 1 ? "a tab" : "\(r.tabs) tabs"
            let folders = r.folders == 0 ? "" : r.folders == 1 ? " and a folder" : " and \(r.folders) folders"
            c.showToast("Added \(tabs)\(folders) to \(c.store.space(destination.spaceID)?.name ?? "the Space")")
            finish(r)
        } catch {
            c.showToast("Couldn't add the files")
            cancel()
        }
    }

    private func finish(_ r: SidebarFileResult) {
        state = .done(r)
        onFinish?(self)
        SidebarFileImport.ended(self)
    }

    /// A sheet on the window. With another sheet up already, a question that must be answered (`required`) is asked in
    /// a window of its own instead; the reading sheet is left out.
    private func ask(_ message: String, _ detail: String, buttons: [String], required: Bool = true,
                     _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        buttons.forEach { a.addButton(withTitle: $0) }
        guard let window = controller?.window, window.attachedSheet == nil else {
            if required { done(a.runModal()) }
            return
        }
        sheet = a.window
        a.beginSheetModal(for: window) { [weak self] r in
            self?.sheet = nil
            // Ended in code (the read finished, or a cancel): not an answer.
            if r != .abort { done(r) }
        }
    }

    private func endSheet() {
        guard let s = sheet else { return }
        sheet = nil
        s.sheetParent?.endSheet(s, returnCode: .abort)
    }
}

/// A flag the reading thread checks.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

extension WindowController {
    /// What a drop on the sidebar would hold that it can take (files, folders, links, text).
    func canImportIntoSidebar(_ pb: NSPasteboard) -> Bool { !SidebarFileImport.items(from: pb).isEmpty }

    /// A drop on the sidebar: `destination` is where the drop line is (nil: the current Space's Today, folders at the
    /// end of its pinned section). False when there was nothing to take.
    @discardableResult
    func importIntoSidebar(_ pb: NSPasteboard, destination: SidebarFileDestination? = nil) -> Bool {
        importIntoSidebar(SidebarFileImport.items(from: pb), destination: destination) != nil
    }

    @discardableResult
    func importIntoSidebar(_ items: [SidebarDropItem], destination: SidebarFileDestination? = nil) -> SidebarFileImportOperation? {
        guard !items.isEmpty else { return nil }
        SidebarFileImport.latest?.cancel()
        let op = SidebarFileImportOperation(destination: destination ?? SidebarFileDestination(spaceID: currentSpaceID), controller: self)
        SidebarFileImport.began(op)
        op.start(items)
        return op
    }

    /// Add Files… (Arc's "+" menu, 2021): files and folders from an open panel, into the current Space. Cancel adds
    /// nothing.
    func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Files open as tabs; a folder comes in as a folder with its files."
        let space = currentSpaceID
        let done: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] r in
            guard r == .OK, let self, let urls = panel?.urls, !urls.isEmpty, self.store.space(space) != nil else { return }
            self.importIntoSidebar(urls.map(SidebarDropItem.file), destination: SidebarFileDestination(spaceID: space))
        }
        if window.attachedSheet == nil { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}

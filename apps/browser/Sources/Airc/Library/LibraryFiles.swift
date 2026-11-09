// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import Combine
import Quartz
import QuickLookThumbnailing

/// The files the Library knows (LIB-1): the engine's own downloads list (DownloadCenter, every Space profile; a private
/// window's downloads live in their session's own list and never reach it), the Captures saved with ⇧⌘2 outside
/// private windows (CaptureRecords, a small JSON file in the data folder), and (P10a) the pictures and videos of folders
/// the person let it show (LibraryFolderSources), each source switchable in Media's "Show media from" menu. Paths a
/// private window wrote (its downloads, its Captures) are kept in memory only and never listed, also when they land in a
/// shown folder.
///
/// Library › Media and the Library button's recent files read `media` and `recent`. Working out which files still exist
/// happens off the main thread; it runs when a view asks (the section shows, the pointer rests on the button), when a
/// download finishes or goes, when a Capture is saved, and when Airc comes to the front (a file deleted in Finder).
final class LibraryFiles: ObservableObject {
    static let shared = LibraryFiles()

    /// Images and videos, newest first.
    @Published private(set) var media: [LibraryFile] = []
    /// The newest downloads and Captures of any type (LibraryMedia.recentLimit).
    @Published private(set) var recent: [LibraryFile] = []
    /// The file last moved to the Trash while Undo can still put it back.
    @Published private(set) var trashed: Trashed?
    /// Bumped when a refresh lands (the scripted check waits for it).
    @Published private(set) var revision = 0

    struct Trashed: Equatable {
        let file: LibraryFile
        let trashURL: URL
    }

    // MARK: Hooks (scripted runs record these instead of opening apps, Finder or the owner's Trash)

    static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    static var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    /// nil: the real Quick Look panel.
    static var quickLook: ((_ urls: [URL], _ index: Int) -> Void)?
    /// Moves a file to the Trash and answers with where it went (nil: it couldn't).
    static var trash: (URL, @escaping (URL?) -> Void) -> Void = { url, done in
        NSWorkspace.shared.recycle([url]) { moved, error in done(error == nil ? moved[url] : nil) }
    }
    static var recordsURL: URL { AppPaths.dataDirectory.appendingPathComponent("Captures.json") }

    /// Files a private window wrote this run: never listed, never written down.
    private(set) var privatePaths: Set<String> = []

    private var captures = CaptureRecords()
    private var capturesLoaded = false
    private var downloadsWatch: AnyCancellable?
    private var foldersWatch: AnyCancellable?
    private var downloadFiles: [LibraryFile] = []
    private var activeObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "airc.library.files", qos: .userInitiated)
    private var generation = 0
    private var trashExpiry: DispatchWorkItem?

    private init() {}

    // MARK: Sources

    /// Starts listening (once): the downloads list and Airc coming to the front.
    private func connect() {
        loadCaptures()
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                    queue: .main) { [weak self] _ in self?.refresh() }
        }
        if foldersWatch == nil {
            // @Published sends before the property changes: read it a turn later, when it has.
            foldersWatch = LibraryFolderSources.shared.$files.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
        }
        guard downloadsWatch == nil, let center = MediaLibrary.shared.downloads else { return }
        // Running downloads tick ten times a second; only finished files matter here.
        downloadFiles = Self.finished(center.items)
        downloadsWatch = center.$items.dropFirst()
            .map(Self.finished)
            .removeDuplicates()
            .sink { [weak self] files in
                self?.downloadFiles = files
                self?.refresh()
            }
    }

    private static func finished(_ items: [DownloadCenter.Item]) -> [LibraryFile] { items.map(file(of:)).filter(\.isComplete) }

    static func file(of item: DownloadCenter.Item) -> LibraryFile {
        let d = item.download
        return LibraryFile(id: item.id, path: d.path ?? "", name: d.fileName, date: d.endTime ?? d.startTime ?? .distantPast,
                           source: .download, mimeType: d.mimeType, isComplete: d.state == .complete && !d.dangerous)
    }

    private func loadCaptures() {
        guard !capturesLoaded else { return }
        capturesLoaded = true
        if let data = try? Data(contentsOf: Self.recordsURL), let r = try? JSONDecoder().decode(CaptureRecords.self, from: data) {
            captures = r
        }
        // Files deleted since the last run are forgotten (one stat each, off the main thread).
        let paths = captures.entries.map(\.path)
        queue.async { [weak self] in
            let missing = Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            guard !missing.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.captures.prune(exists: { !missing.contains($0) }) else { return }
                self.saveCaptures()
            }
        }
    }

    private func saveCaptures() {
        let data = try? JSONEncoder().encode(captures)
        let url = Self.recordsURL
        queue.async { try? data?.write(to: url, options: .atomic) }
    }

    /// A Capture was saved (CaptureSession.write). A private window's never is (and never shows from a folder either).
    func recordCapture(_ url: URL, isPrivate: Bool) {
        guard !isPrivate else { return notePrivatePath(url.path) }
        loadCaptures()
        captures.add(path: url.path, date: Date())
        saveCaptures()
        refresh()
    }

    /// A file a private window wrote (its download, its Capture): kept out of every list for the rest of this run.
    func notePrivatePath(_ path: String) {
        let p = (path as NSString).standardizingPath
        guard !p.isEmpty, privatePaths.insert(p).inserted else { return }
        LibraryFolderSources.shared.reloadAll()
        refresh()
    }

    /// The private sessions' downloads that are files now.
    private func collectPrivateDownloads() {
        for w in PrivateBrowsing.shared.windows {
            for item in PrivateBrowsing.shared.downloads(of: w.profileID)?.items ?? [] {
                if let p = item.download.path, !p.isEmpty { privatePaths.insert((p as NSString).standardizingPath) }
            }
        }
    }

    // MARK: Lists

    /// Works out the lists again, off the main thread; `done` runs on the main thread once they're published.
    func refresh(_ done: (() -> Void)? = nil) {
        connect()
        collectPrivateDownloads()
        let sources = LibraryFolderSources.shared.settings
        let own = (sources.showDownloads ? downloadFiles : []) + (sources.showCaptures ? captures.files : [])
        let excluded = privatePaths.union(sources.hidden)
        let own_ = own.filter { !excluded.contains(($0.path as NSString).standardizingPath) }
        let all = own_ + LibraryFolderSources.shared.files.filter { !excluded.contains($0.path) }
        generation += 1
        let gen = generation
        queue.async { [weak self] in
            var known: [String: Bool] = [:]
            let exists = { (p: String) -> Bool in
                if let k = known[p] { return k }
                let e = FileManager.default.fileExists(atPath: p)
                known[p] = e
                return e
            }
            let media = LibraryMedia.media(all, exists: exists)
            // The hover list stays Airc's own: the newest downloads and Captures.
            let recent = LibraryMedia.recent(own_, exists: exists)
            DispatchQueue.main.async {
                guard let self else { return }
                if gen == self.generation {
                    if media != self.media { self.media = media }
                    if recent != self.recent { self.recent = recent }
                    self.revision += 1
                }
                done?()
            }
        }
    }

    // MARK: Actions

    /// A click on a tile: Quick Look, ⌘-click Show in Finder, a double-click opens it in its app.
    func activate(_ file: LibraryFile, in list: [LibraryFile], clickCount: Int, command: Bool, from host: LibraryPanelHost?) {
        if command { return Self.reveal([file.url]) }
        if clickCount >= 2 {
            LibraryQuickLook.shared.close()
            return open(file)
        }
        let urls = list.map(\.url)
        quickLook(urls, index: list.firstIndex(of: file) ?? 0, from: host)
    }

    func quickLook(_ urls: [URL], index: Int, from host: LibraryPanelHost?) {
        if let hook = Self.quickLook { return hook(urls, index) }
        LibraryQuickLook.shared.show(urls, index: index, from: host)
    }

    func open(_ file: LibraryFile) { Self.open(file.url) }

    func showInFinder(_ file: LibraryFile) { Self.reveal([file.url]) }

    func copy(_ file: LibraryFile) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([file.url as NSURL])
    }

    /// Delete: to the Trash, with Undo while it's offered (the Library's bar, about 15 s). A file someone puts back
    /// later from the Trash comes back to the list too: it's the same path.
    func moveToTrash(_ file: LibraryFile, failed: @escaping (String) -> Void) {
        if LibraryQuickLook.shared.isShowing(file.url) { LibraryQuickLook.shared.close() }
        Self.trash(file.url) { [weak self] moved in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let moved else { return failed("Couldn’t move “\(file.name)” to the Trash") }
                self.trashed = Trashed(file: file, trashURL: moved)
                self.trashExpiry?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.trashed = nil }
                self.trashExpiry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
                self.refresh()
            }
        }
    }

    /// Puts the file last moved to the Trash back where it was. False when it can't (the Trash was emptied, or a file
    /// of that name is there again).
    @discardableResult
    func undoTrash() -> Bool {
        guard let t = trashed else { return false }
        trashed = nil
        trashExpiry?.cancel()
        do {
            try FileManager.default.moveItem(at: t.trashURL, to: t.file.url)
        } catch {
            return false
        }
        refresh()
        return true
    }

    func forgetTrash() {
        trashExpiry?.cancel()
        trashed = nil
    }
}

// MARK: - Thumbnails

/// QuickLookThumbnailing pictures for the grid and the hover list: made off the main thread, kept in memory (an
/// NSCache, at most a few hundred), keyed by file, date and pixel size, so scrolling back never asks twice.
final class LibraryThumbnails {
    static let shared = LibraryThumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private var waiting: [String: [(NSImage?) -> Void]] = [:]

    private init() {
        cache.countLimit = 400
    }

    #if AIRC_TESTING
    /// Files Quick Look made a picture of (the scripted check reads it).
    private(set) var pictured: Set<String> = []
    #endif

    private func key(_ f: LibraryFile, _ px: Int) -> String { "\(f.path)|\(f.date.timeIntervalSince1970)|\(px)" }

    func cached(_ f: LibraryFile, side: CGFloat, scale: CGFloat) -> NSImage? {
        cache.object(forKey: key(f, Int(side * scale)) as NSString)
    }

    /// The picture, on the main thread (nil: Quick Look has none for it; the caller keeps the file's icon).
    func thumbnail(_ f: LibraryFile, side: CGFloat, scale: CGFloat, _ done: @escaping (NSImage?) -> Void) {
        let k = key(f, Int(side * scale))
        if let hit = cache.object(forKey: k as NSString) { return done(hit) }
        if waiting[k] != nil { waiting[k]?.append(done); return }
        waiting[k] = [done]
        let request = QLThumbnailGenerator.Request(fileAt: f.url, size: CGSize(width: side, height: side), scale: scale,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let image = rep?.nsImage
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.cache.setObject(image, forKey: k as NSString) }
                #if AIRC_TESTING
                if image != nil { self.pictured.insert(f.path) }
                #endif
                let calls = self.waiting.removeValue(forKey: k) ?? []
                calls.forEach { $0(image) }
            }
        }
    }
}

// MARK: - Quick Look

/// The Quick Look panel for Library › Media: the Library's host takes the panel (the responder chain's way), the grid's
/// files are its items, so ← → move through them.
final class LibraryQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = LibraryQuickLook()
    private(set) var urls: [URL] = []
    private var index = 0

    func show(_ urls: [URL], index: Int, from host: LibraryPanelHost?) {
        self.urls = urls
        self.index = index
        guard let panel = QLPreviewPanel.shared() else { return }
        if let host, let w = host.window, w.firstResponder !== host { w.makeFirstResponder(host) }
        if panel.isVisible, panel.dataSource === self {
            panel.reloadData()
            panel.currentPreviewItemIndex = index
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func isShowing(_ url: URL) -> Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible && urls.contains(url)
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
              panel.dataSource === self else { return }
        panel.orderOut(nil)
    }

    /// LibraryPanelHost took the panel.
    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = index
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

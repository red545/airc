// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// P10a (L04, Arc's "Show media from:"): folders the person lets Library › Media show, beside Airc's own Captures and
/// downloads. A folder is only ever one they picked in an open panel ("Allow…"); Airc keeps a security-scoped bookmark of
/// it (settings.json `librarySources`) and never reads a folder on its own, nor the folders inside a granted one (not a
/// crawler: its pictures and videos at the top only, AircKit's LibraryFolderListing).
///
/// Each granted folder is watched (a file-system event source on the folder): a file added, renamed or deleted in
/// Finder updates the grid. Reading the folder happens on a background queue, never the main thread. A folder that's
/// gone or can't be read any more is "revoked" in the menu, with Choose Again. A private window's downloads and Captures,
/// and files hidden from the Library, never show.
final class LibraryFolderSources: ObservableObject {
    static let shared = LibraryFolderSources()

    /// Each folder's state, as the menu shows it.
    @Published private(set) var states: [LibraryFolder: LibraryFolderState] = [:]
    /// The shown folders' pictures and videos, newest first.
    @Published private(set) var files: [LibraryFile] = []
    /// Bumped when a folder's listing lands (the scripted check waits for it).
    @Published private(set) var revision = 0

    // MARK: Hooks (scripted runs answer the panel and use scratch folders, never the owner's)

    /// Answers "Allow…" instead of the open panel: the folder picked, or nil for Cancel.
    static var testPanel: ((LibraryFolder, URL) -> URL?)?
    /// Where each folder is, instead of the person's own.
    static var testDefaultURL: ((LibraryFolder) -> URL)?
    #if AIRC_TESTING
    /// Folder reads that ran on the main thread (there must be none).
    private(set) var mainThreadReads = 0
    #endif

    private struct Watch {
        let url: URL
        let source: DispatchSourceFileSystemObject
        let scoped: Bool
    }
    private var watches: [LibraryFolder: Watch] = [:]
    private var listed: [LibraryFolder: [LibraryFile]] = [:]
    private var pending: [LibraryFolder: DispatchWorkItem] = [:]
    private var started = false
    private let queue = DispatchQueue(label: "airc.library.folders", qos: .utility)

    private init() {}

    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    var settings: LibrarySourceSettings {
        get { app?.settings.values.librarySources ?? LibrarySourceSettings() }
        set { app?.settings.values.librarySources = newValue }
    }

    /// Where a folder normally is: the person's Desktop, Documents and Downloads, and where macOS saves screenshots
    /// (Screenshot's Options › Save to; the Desktop unless changed).
    static func defaultURL(_ f: LibraryFolder) -> URL {
        if let t = testDefaultURL { return t(f) }
        let fm = FileManager.default
        switch f {
        case .desktop: return fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        case .documents: return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        case .downloads: return fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .screenshots:
            if let p = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !p.isEmpty {
                return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
            }
            return fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
    }

    // MARK: Start

    /// Once, when Media first shows: resolves the grants (off the main thread) and starts watching them.
    func start() {
        guard !started else { return }
        started = true
        updateStates()
        for f in LibraryFolder.allCases where settings.shows(f) { open(f) }
    }

    private func updateStates() {
        let s = settings
        var out: [LibraryFolder: LibraryFolderState] = [:]
        for f in LibraryFolder.allCases {
            if let g = s.grant(f) {
                if case .revoked(let why)? = states[f] { out[f] = .revoked(reason: why) } else { out[f] = .granted(path: g.path) }
            } else {
                out[f] = s.declined.contains(f.rawValue) ? .declined : .notGranted
            }
        }
        if out != states { states = out }
    }

    // MARK: Asking

    /// "Allow…" / "Choose Again…": an open panel at the folder, with Arc's explanation. Cancel is a no, remembered so
    /// nothing asks again by itself.
    func requestAccess(_ f: LibraryFolder, for window: NSWindow?) {
        let suggested = Self.defaultURL(f)
        if let answer = Self.testPanel {
            return finishRequest(f, picked: answer(f, suggested))
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = suggested
        panel.prompt = "Allow"
        panel.message = "Allow Airc to show your \(f == .downloads ? "Downloads folder" : f == .screenshots ? "Screenshots folder" : "\(f.title) folder") "
            + "to see its pictures and videos here alongside your Captures. Media never leaves your computer and is not viewable by anyone but you."
        let done: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] r in
            self?.finishRequest(f, picked: r == .OK ? panel?.url : nil)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    private func finishRequest(_ f: LibraryFolder, picked: URL?) {
        var s = settings
        guard let url = picked else {
            s.declined(f)
            settings = s
            updateStates()
            return
        }
        // A security-scoped bookmark, so the person's choice holds after a relaunch; a plain one where the system
        // won't make that (a build without the bookmarks entitlement).
        let data = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        guard let data else {
            states[f] = .revoked(reason: "Airc couldn’t keep access to “\(url.lastPathComponent)”.")
            return
        }
        s.granted(f, LibrarySourceSettings.Grant(bookmark: data, path: url.path, grantedAt: Date()))
        settings = s
        close(f)
        states[f] = .granted(path: url.path)
        open(f)
    }

    /// The menu's checkmark: a granted folder on or off (kept granted).
    func setShown(_ f: LibraryFolder, _ on: Bool) {
        var s = settings
        s.setShown(f, on)
        settings = s
        if on { open(f) } else { close(f); listed[f] = nil; publish() }
        updateStates()
    }

    /// "Stop Showing": the grant and its bookmark go.
    func forget(_ f: LibraryFolder) {
        close(f)
        listed[f] = nil
        var s = settings
        s.forget(f)
        settings = s
        states[f] = nil
        updateStates()
        publish()
    }

    /// "Hide from Library": the file stays where it is.
    func hide(_ file: LibraryFile) {
        var s = settings
        s.hidden.insert(file.path)
        settings = s
        for (f, list) in listed { listed[f] = list.filter { $0.path != file.path } }
        publish()
        LibraryFiles.shared.refresh()
    }

    // MARK: Watching and reading

    private func open(_ f: LibraryFolder) {
        guard watches[f] == nil, let grant = settings.grant(f) else { return }
        let bookmark = grant.bookmark
        queue.async { [weak self] in
            var stale = false
            let url = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
            DispatchQueue.main.async {
                guard let self else { return }
                guard let url, FileManager.default.fileExists(atPath: url.path) else {
                    return self.revoke(f, "The folder can’t be found any more.")
                }
                let scoped = url.startAccessingSecurityScopedResource()
                let fd = Darwin.open(url.path, O_EVTONLY)
                guard fd >= 0 else {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    return self.revoke(f, "Airc can’t read this folder any more.")
                }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke],
                                                                       queue: .main)
                source.setEventHandler { [weak self, weak source] in
                    guard let self, let source else { return }
                    let ev = source.data
                    if ev.contains(.delete) || ev.contains(.revoke) || ev.contains(.rename) {
                        // Gone, unmounted, or moved: look again from the bookmark (it follows a move).
                        self.close(f)
                        self.open(f)
                    } else {
                        self.scheduleRead(f)
                    }
                }
                source.setCancelHandler { Darwin.close(fd) }
                source.resume()
                self.watches[f] = Watch(url: url, source: source, scoped: scoped)
                if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    var s = self.settings
                    s.grants[f.rawValue]?.bookmark = fresh
                    s.grants[f.rawValue]?.path = url.path
                    self.settings = s
                }
                self.states[f] = .granted(path: url.path)
                self.read(f)
            }
        }
    }

    private func close(_ f: LibraryFolder) {
        pending[f]?.cancel()
        pending[f] = nil
        guard let w = watches.removeValue(forKey: f) else { return }
        w.source.cancel()
        if w.scoped { w.url.stopAccessingSecurityScopedResource() }
    }

    private func revoke(_ f: LibraryFolder, _ reason: String) {
        close(f)
        listed[f] = nil
        if settings.grant(f) != nil { states[f] = .revoked(reason: reason) }
        publish()
    }

    /// Changes come in bursts (a download writes, renames, sets attributes): one read a quarter second after the last.
    private func scheduleRead(_ f: LibraryFolder) {
        pending[f]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.read(f) }
        pending[f] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Reads the folder's top level on the background queue and publishes its pictures and videos.
    func read(_ f: LibraryFolder) {
        guard let w = watches[f] else { return }
        let url = w.url
        let excluded = settings.hidden.union(LibraryFiles.shared.privatePaths)
        queue.async { [weak self] in
            #if AIRC_TESTING
            if Thread.isMainThread { DispatchQueue.main.async { self?.mainThreadReads += 1 } }
            #endif
            let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]
            let result: Result<[LibraryFile], Error> = Result {
                let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                let entries: [LibraryFolderListing.Entry] = urls.compactMap { u in
                    guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
                    return LibraryFolderListing.Entry(name: u.lastPathComponent, isDirectory: v.isDirectory ?? false,
                                                      isHidden: v.isHidden ?? false, isPackage: v.isPackage ?? false,
                                                      modified: v.contentModificationDate ?? .distantPast, size: Int64(v.fileSize ?? 0))
                }
                return LibraryFolderListing.files(f, at: url.path, entries: entries, excluded: excluded)
            }
            DispatchQueue.main.async {
                guard let self, self.watches[f] != nil else { return }
                switch result {
                case .success(let files):
                    self.listed[f] = files
                    if !(self.states[f]?.isGranted ?? false) { self.states[f] = .granted(path: url.path) }
                case .failure:
                    return self.revoke(f, "Airc can’t read this folder any more. Allow it again, or check System Settings › Privacy & Security › Files and Folders.")
                }
                self.publish()
            }
        }
    }

    private func publish() {
        let s = settings
        let all = LibraryFolder.allCases.filter { s.shows($0) }.flatMap { listed[$0] ?? [] }
        let private_ = LibraryFiles.shared.privatePaths
        let merged = all.filter { !s.hidden.contains($0.path) && !private_.contains($0.path) }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
        if merged != files { files = merged }
        revision += 1
    }

    /// Reads every shown folder again (a private download finished: its path is excluded now).
    func reloadAll() {
        for f in watches.keys { read(f) }
    }

    #if AIRC_TESTING
    /// The check starts from nothing: no watches, no lists.
    func resetForTesting() {
        for f in LibraryFolder.allCases { close(f) }
        listed = [:]
        states = [:]
        files = []
        started = false
    }
    #endif
}

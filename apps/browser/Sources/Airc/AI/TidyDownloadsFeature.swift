// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import Combine
import PDFKit

/// Tidy Downloads (Arc Max's auto-renamed downloads, docs/user/ai.md): when a download with a meaningless name
/// ("IMG_2041 (1).pdf") finishes, Apple's on-device model suggests a clean one ("Lisbon itinerary.pdf") from the page it
/// came from (its title, from the open tab or Airc's history, and its address) and the start of the file's text (a
/// PDF's first pages through PDFKit, or a text file's first lines; read on this Mac only). Library › Downloads shows
/// the suggestion with a Rename button; nothing is renamed until it's clicked. The file keeps its extension and its
/// folder, and gets a number if the name is taken. The engine still knows the old path, so renames are kept in
/// TidyDownloads.json in the data folder (never synced or sent) and the downloads list, Open, Show in Finder and
/// dragging use the new one. Private windows' downloads are their own list (PrivateWindowExtras.swift) and never
/// come here.
///
/// Rename automatically (tidydl, Arc's Tidy Downloads, off by default): with it on, a suggestion is applied as soon as
/// it arrives and the window shows "Renamed to “…”" with Undo, which puts the original name back. Disk images,
/// installers, apps and archives are left alone (`TidyDownloadRules.autoRenameSkips`), and so is a file another app has
/// open or that changed in the last second (it's tried again a few times, then the suggestion stays for a click). The
/// Downloads list shows the name a renamed file had.
enum TidyDownloadsFeature {
    /// The data folder's record of renamed files (download key → its new path and name).
    static var fileURL: URL { AppPaths.dataDirectory.appendingPathComponent("TidyDownloads.json") }
    private static var renames: TidyDownloadRenames = load()
    /// Files bigger than this aren't opened for their text.
    static let maxFileBytes = 50 * 1024 * 1024
    /// Where a failed rename is logged: a fixed line with the error's domain and number only (never its description,
    /// which names the files). The scripted check reads it.
    static var log: (String) -> Void = { NSLog("%@", $0) }

    /// The suggestions the Library's rows show (they observe it).
    final class Model: ObservableObject {
        static let shared = Model()
        @Published fileprivate(set) var suggestions: [String: String] = [:]
    }

    // MARK: DownloadCenter's hooks

    /// A download just finished (DownloadCenter.update): with Tidy Downloads on, its name needs one, and the model can
    /// run, a suggestion is made in the background.
    static func finished(_ item: DownloadCenter.Item) {
        guard let app = NSApp.delegate as? AppDelegate, app.settings.values.tidyDownloads else { return }
        let d = item.download
        guard TidyDownloadRules.needsTidy(d.fileName), let path = d.path else { return }
        let source = d.referrer ?? ""
        let title = pageTitle(source, profileID: item.profileID, app: app)
        let key = item.id, name = d.fileName, mime = d.mimeType
        // The profile's data cleared while the file is read: it isn't offered after.
        let generation = MainActor.assumeIsolated { AIFeatures.shared.downloads.generation(ofProfile: item.profileID) }
        DispatchQueue.global(qos: .utility).async {
            // The file's text and the request (its text cut and tidied) off the main thread.
            let text = fileText(URL(fileURLWithPath: path), mime: mime)
            let r = TidyDownloadPrompt.request(fileName: name, pageTitle: title, pageURL: source, fileText: text)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = AIFeatures.shared.downloads.offer(key: key, request: r, profileGeneration: generation) }
            }
        }
    }

    /// DownloadCenter.update: a renamed file's row shows its new name and path (while the file is there).
    static func applyRename(_ d: inout EngineDownload, key: String) {
        guard let r = renames.entries[key], d.state == .complete, FileManager.default.fileExists(atPath: r.path) else { return }
        d.path = r.path
        d.fileName = r.name
    }

    /// The renamed file of a finished download, if it was renamed here and is still there.
    static func renamedFile(_ item: DownloadCenter.Item) -> URL? {
        guard let r = renames.entries[item.id], item.download.state == .complete,
              FileManager.default.fileExists(atPath: r.path) else { return nil }
        return URL(fileURLWithPath: r.path)
    }

    // MARK: The Library's row

    static func suggestion(for item: DownloadCenter.Item) -> String? {
        guard item.download.state == .complete, !item.download.dangerous, renames.entries[item.id] == nil else { return nil }
        return Model.shared.suggestions[item.id]
    }

    /// AIFeatures' queue made (or dropped) a suggestion.
    @MainActor static func suggestionChanged(_ key: String) {
        Model.shared.suggestions = AIFeatures.shared.downloads.suggestions
        if AIFeatures.shared.downloads.suggestions[key] != nil { autoRename(key) }
    }

    // MARK: Rename automatically (tidydl)

    /// How often a busy file is tried again, and how long apart.
    static var autoAttempts = 8
    static var autoRetryDelay: TimeInterval = 1
    /// A file written to this recently counts as still being written.
    static var quietPeriod: TimeInterval = 1
    /// What the scripted check reads: each automatic rename's outcome ("renamed", "skipped type", "busy"…), by key.
    static var autoLog: (String, String) -> Void = { _, _ in }

    static var autoEnabled: Bool {
        guard let v = (NSApp.delegate as? AppDelegate)?.settings.values else { return false }
        return v.tidyDownloads && v.tidyDownloadsAuto
    }

    /// A suggestion arrived for a finished download: with Rename automatically on, it's applied when the file is free.
    @MainActor static func autoRename(_ key: String, attempt: Int = 1) {
        guard autoEnabled, let center = MediaLibrary.shared.downloads, let item = center.item(key),
              let name = suggestion(for: item), let file = center.file(item) else { return }
        if TidyDownloadRules.autoRenameSkips(item.download.fileName) { return autoLog(key, "skipped type") }
        let quiet = quietPeriod
        DispatchQueue.global(qos: .utility).async {
            let busy = fileBusy(file, quietPeriod: quiet)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard autoEnabled, let item = center.item(key), suggestion(for: item) == name else { return }
                    if let busy {
                        autoLog(key, "busy: \(busy)")
                        if attempt < autoAttempts {
                            DispatchQueue.main.asyncAfter(deadline: .now() + autoRetryDelay) {
                                MainActor.assumeIsolated { autoRename(key, attempt: attempt + 1) }
                            }
                        }
                        return
                    }
                    guard rename(item, center: center), let r = renames.entries[key] else { return autoLog(key, "failed") }
                    autoLog(key, "renamed")
                    toastController(center)?.showActionToast("Renamed to “\(r.name)”", action: (title: "Undo", run: {
                        guard let item = center.item(key), undo(item, center: center) else { return }
                        toastController(center)?.showToast("Download name reverted")
                    }))
                }
            }
        }
    }

    /// The window a rename's toast shows in: the key one, else the Library's.
    @MainActor static func toastController(_ center: DownloadCenter) -> WindowController? {
        let app = NSApp.delegate as? AppDelegate
        return app?.controllers.first { $0.window.isKeyWindow } ?? center.library?.controller ?? app?.controllers.first
    }

    /// Why a file can't be renamed now (nil: it can): another process has it open (libproc, the same list `lsof` reads;
    /// Airc itself doesn't count), or it changed in the last `quietPeriod` seconds or while it was looked at. Off the
    /// main thread.
    static func fileBusy(_ url: URL, quietPeriod: TimeInterval) -> String? {
        let fm = FileManager.default
        func stamp() -> (Int, Date)? {
            guard let a = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            return ((a[.size] as? NSNumber)?.intValue ?? -1, (a[.modificationDate] as? Date) ?? .distantPast)
        }
        guard let first = stamp() else { return "gone" }
        if Date().timeIntervalSince(first.1) < quietPeriod { return "being written" }
        if !openingProcesses(url).isEmpty { return "open in another app" }
        usleep(200_000)
        guard let second = stamp(), second == first else { return "being written" }
        return nil
    }

    /// Other processes with the file open (event-only watchers such as Finder's left out).
    static func openingProcesses(_ url: URL) -> [pid_t] {
        let own = getpid()
        var pids = [pid_t](repeating: 0, count: 512)
        let bytes = url.path.withCString { path in
            pids.withUnsafeMutableBytes { proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY),
                                                            $0.baseAddress, Int32($0.count)) }
        }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 && $0 != own }
    }

    /// Undo (the toast's, or the Library's Revert to Original Name): the file takes its original name again in its
    /// folder ("Name 2.pdf" if that's taken now) and stays in the list. False when it's gone or can't be moved.
    @discardableResult
    static func undo(_ item: DownloadCenter.Item, center: DownloadCenter) -> Bool {
        guard let r = renames.entries[item.id], FileManager.default.fileExists(atPath: r.path) else { return false }
        let folder = (r.path as NSString).deletingLastPathComponent
        guard let back = renames.undo(item.id, exists: { FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) })
        else { return false }
        do {
            try FileManager.default.moveItem(atPath: r.path, toPath: back.path)
        } catch {
            log(TidyDownloadRules.renameFailureLog(error))
            return false
        }
        if back.name == r.from {
            renames.remove(item.id)
        } else {
            // The original name was taken meanwhile: the record keeps where the file is now (and no "renamed from").
            renames.set(item.id, path: back.path, name: back.name, from: back.name)
        }
        save()
        center.restored(item.id, path: back.path, name: back.name)
        return true
    }

    /// The name a renamed download had (the Downloads list shows it), while the file is there.
    static func originalName(_ item: DownloadCenter.Item) -> String? {
        guard let r = renames.entries[item.id], r.from != r.name, item.download.state == .complete,
              FileManager.default.fileExists(atPath: r.path) else { return nil }
        return r.from
    }

    /// The row's Rename: the file gets the suggested name in its folder ("Name 2.pdf" if that's taken). False when the
    /// file is gone or can't be moved (the suggestion stays).
    @discardableResult
    static func rename(_ item: DownloadCenter.Item, center: DownloadCenter) -> Bool {
        guard let name = suggestion(for: item), let file = center.file(item) else { return false }
        let folder = file.deletingLastPathComponent()
        let fm = FileManager.default
        let target = TidyDownloadRules.unique(name) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let destination = folder.appendingPathComponent(target)
        guard destination.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return false }
        do {
            try fm.moveItem(at: file, to: destination)
        } catch {
            log(TidyDownloadRules.renameFailureLog(error))
            return false
        }
        renames.set(item.id, path: destination.path, name: target, from: item.download.fileName)
        save()
        MainActor.assumeIsolated {
            AIFeatures.shared.downloads.dismiss(item.id)
            AIFeatures.shared.recordUse(.aiTidyDownloads(.used))
        }
        center.renamed(item.id)
        return true
    }

    /// The row's "Keep Name".
    static func dismiss(_ item: DownloadCenter.Item) {
        MainActor.assumeIsolated { AIFeatures.shared.downloads.dismiss(item.id) }
    }

    // MARK: Sources

    /// The title of the page a download came from: a tab of the download's own profile showing it, else Airc's history
    /// of that profile (AircKit's TidyDownloadSources: never another profile's page at the same address).
    static func pageTitle(_ url: String, profileID: String, app: AppDelegate) -> String {
        guard !url.isEmpty else { return "" }
        let pages = app.controllers.flatMap { $0.pages.values }.map {
            TidyDownloadSources.OpenPage(profileID: app.profiles.profileID(for: $0.profile), url: $0.url, title: $0.title)
        }
        return TidyDownloadSources.pageTitle(for: url, profileID: profileID, openPages: pages) {
            app.history?.entry(profileID: profileID, url: $0)?.title
        }
    }

    /// The start of a file's text: a PDF's first two pages (PDFKit), or a text file's first 8 KB. Nil for other files,
    /// files over `maxFileBytes`, or a PDF that doesn't open. Off the main thread.
    static func fileText(_ url: URL, mime: String?) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= maxFileBytes else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" || mime == "application/pdf" {
            guard let doc = PDFDocument(url: url) else { return nil }
            var s = ""
            for i in 0..<min(2, doc.pageCount) {
                // Only the start of each page is kept (a page can hold far more text than the prompt takes).
                s += String((doc.page(at: i)?.string ?? "").prefix(TidyDownloadPrompt.fileTextLength * 4)) + "\n"
                if s.count >= TidyDownloadPrompt.fileTextLength { break }
            }
            return s
        }
        let texts: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "xml", "ics", "vcf", "log", "srt", "vtt"]
        guard texts.contains(ext) || mime?.hasPrefix("text/") == true,
              let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 8192)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: The record

    private static func load() -> TidyDownloadRenames {
        guard let data = try? Data(contentsOf: fileURL), let r = try? JSONDecoder().decode(TidyDownloadRenames.self, from: data) else {
            return TidyDownloadRenames()
        }
        return r
    }

    private static func save() {
        if renames.entries.isEmpty { try? FileManager.default.removeItem(at: fileURL); return }
        if let data = try? JSONEncoder().encode(renames) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Clear Data (the engine's download list goes with it) and Delete Profile: that profile's renames are forgotten
    /// (the files keep their new names). Settings → AI's switch off keeps them; only suggestions go (AIFeatures).
    static func forget(profileID: String) {
        renames.remove(profileID: profileID)
        save()
    }

    #if AIRC_TESTING
    /// Scripted checks: the record as it is.
    static var record: TidyDownloadRenames { renames }
    #endif
}

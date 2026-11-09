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

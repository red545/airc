// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircImport
import AircKit
import AppKit

// Other browsers (IM-4): bookmarks and history from the Chromium family, Firefox and Zen; Safari's bookmarks from a
// file the user exports; saved passwords only from a CSV file the user exported and chose. Airc never reads another
// browser's password store, cookies or Keychain item. Nothing here logs a URL, a title, a name or a password.

enum BrowserImportLocator {
    #if AIRC_TESTING
    /// A synthetic home folder for automated runs: set by ImportBrowsersCheck and the marketing shots, or
    /// `--import-home=<dir>` at launch. Never the owner's.
    static var testHome: URL? = {
        CommandLine.arguments.first { $0.hasPrefix("--import-home=") }.map { URL(fileURLWithPath: String($0.dropFirst("--import-home=".count))) }
    }()
    #endif

    /// Where other browsers' folders are looked for: the home folder; in automated runs only a synthetic one, so a test
    /// never reads the owner's real browsers.
    static var home: URL? {
        #if AIRC_TESTING
        if LaunchOptions.current.isAutomated { return testHome }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Every browser with bookmarks or history, off the main thread.
    static func detect() async -> [BrowserInstall] {
        guard let home else { return [] }
        return await Task.detached(priority: .userInitiated) { BrowserImporter.detect(home: home) }.value
    }

    /// The browser's app icon, if it's installed (never in automated runs, which show a stand-in).
    static func icon(bundleIDs: [String]) -> NSImage? {
        guard !LaunchOptions.current.isAutomated else { return nil }
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return NSWorkspace.shared.icon(forFile: url.path) }
        }
        return nil
    }
}

enum BrowserImportAdapter {
    /// The browser's plan as AircKit's blueprint. Its IDs are full source keys already ("chrome-space:Default"); each
    /// browser profile's default one may take over Airc's untouched default profile, as Arc's does.
    static func blueprint(from r: BrowserImport) -> ImportBlueprint {
        let profiles = r.plan.profiles.map { p in
            let s = r.profiles.first { $0.sourceKey == p.id }
            let color = ArcTheme.chromiumColor(p.color?.foundation) ?? s?.color.flatMap(RGBA.init(hex:))
                ?? RGBA(hex: r.kind?.color ?? BrowserKind.safari.color)
            return ImportBlueprint.Profile(sourceID: p.id, name: p.name, emoji: "", color: color, isSourceDefault: s?.isDefault ?? false)
        }
        let spaces = r.plan.spaces.map { s in
            ImportBlueprint.Space(sourceID: s.id, name: s.name, icon: nil, theme: ImportAdapter.theme(s.theme), profileSourceID: s.profileID,
                                  pinned: s.pinned.map { ImportAdapter.node($0, prefix: "") }, today: [])
        }
        return ImportBlueprint(profiles: profiles, spaces: spaces)
    }

    /// The history of the profiles that came over, keyed to their Airc profiles.
    static func visits(_ r: BrowserImport, profileIDs: [String: String]) -> [HistoryEntry] {
        r.history.flatMap { key, visits -> [HistoryEntry] in
            guard let pid = profileIDs[key] else { return [] }
            return visits.map {
                HistoryEntry(profileID: pid, url: $0.url, title: $0.title, visitCount: $0.visitCount, typedCount: $0.typedCount, lastVisit: $0.lastVisit)
            }
        }
    }

    /// "312 bookmarks · 4 folders · 2,140 history entries".
    static func counts(bookmarks: Int, folders: Int, history: Int?) -> String {
        var parts = [plural(bookmarks, "bookmark"), plural(folders, "folder")]
        if let history { parts.append(plural(history, "history entry", "history entries")) }
        return parts.joined(separator: " · ")
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n.formatted()) " + (n == 1 ? one : many ?? one + "s")
    }

    /// The source for telemetry.
    static func telemetrySource(_ r: BrowserImport) -> TelemetryEvent.ImportBrowser.Source {
        guard let kind = r.kind else { return .bookmarksFile }
        return TelemetryEvent.ImportBrowser.Source(rawValue: kind.rawValue) ?? .bookmarksFile
    }

    /// What a browser import changes on the way, said plainly (the import step's Details). Warnings never carry a
    /// title or an address, so neither do these.
    static func changes(for warnings: [ImportWarning]) -> [ImportAdapter.Change] {
        var counts: [ImportWarning.Code: Int] = [:]
        for w in warnings { counts[w.code, default: 0] += 1 }
        var out: [ImportAdapter.Change] = []
        func add(_ code: ImportWarning.Code, _ one: String, _ many: String, _ detail: String) {
            guard let n = counts[code], n > 0 else { return }
            out.append(.init(count: n, summary: "\(n.formatted()) " + (n == 1 ? one : many), detail: detail))
        }
        add(.unreadableBookmarks, "profile's bookmarks couldn't be read", "profiles' bookmarks couldn't be read",
            "Their Spaces and history still come over. Quitting the browser and importing again may help.")
        add(.unreadableHistory, "profile's history couldn't be read", "profiles' history couldn't be read",
            "Their bookmarks still come over. Quitting the browser and importing again may help.")
        if counts[.tooManyBookmarks] != nil {
            out.append(.init(count: 1, summary: "Only the first \(BrowserImporter.maxBookmarks.formatted()) bookmarks of a profile came over",
                             detail: "A sidebar works best with fewer. The rest stay in the browser you're coming from."))
        }
        add(.bookmarklet, "bookmarklet was left out", "bookmarklets were left out",
            "Bookmarklets are javascript: links; Airc doesn't run them from the sidebar.")
        add(.smartBookmark, "smart folder was left out", "smart folders were left out",
            "Firefox's Most Visited and Recent Tags are searches, not bookmarks.")
        add(.invalidTab, "bookmark without an address was left out", "bookmarks without an address were left out",
            "The browser had saved these with no page address, so there was nothing to open.")
        add(.depthLimit, "folder nested too deep was cut short", "folders nested too deep were cut short",
            "Folders more than 64 levels down stop there.")
        return out
    }
}

/// Passwords from a CSV file the user exported and chose (IM-4). The rows go into the chosen Airc profile's password
/// store through the engine's own import (the path Arc's logins take after decryption), then nothing holds them.
enum PasswordImport {
    struct Outcome: Equatable {
        var imported = 0
        /// The same site and username twice in the file, or already saved in the profile.
        var duplicates = 0
        /// Rows without a password or an address.
        var incomplete = 0
        /// App logins and other entries that aren't for a website.
        var notWebsite = 0
        /// Rows that couldn't be read, or that the password store didn't keep.
        var failed = 0
        var profileID = ""
        var format: PasswordFile.Format = .other

        /// "24 passwords imported · 3 duplicates skipped".
        var summary: String {
            var parts = [BrowserImportAdapter.plural(imported, "password") + " imported"]
            if duplicates > 0 { parts.append(BrowserImportAdapter.plural(duplicates, "duplicate") + " skipped") }
            return parts.joined(separator: " · ")
        }

        /// The rest, if any: "1 row without a password · 1 app login".
        var details: String? {
            var parts: [String] = []
            if incomplete > 0 { parts.append(BrowserImportAdapter.plural(incomplete, "row without a password", "rows without a password")) }
            if notWebsite > 0 { parts.append(BrowserImportAdapter.plural(notWebsite, "app login", "app logins") + " (not a website)") }
            if failed > 0 { parts.append(BrowserImportAdapter.plural(failed, "row", "rows") + " couldn't be imported") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        var isFailure: Bool { imported == 0 && duplicates == 0 && failed > 0 }
    }

    /// Reads `file` off the main thread and hands its rows to `sink` for `profileID`. On an engine that can't take
    /// Chromium logins (WebKit), the file isn't read at all.
    static func run(file: URL, profileID: String, sink: CredentialSink, completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard sink.acceptsCredentials else { return completion(.failure(Unsupported())) }
        Task { @MainActor in
            let parsed: PasswordFile
            do { parsed = try await PasswordCSV.read(file) }
            catch {
                Telemetry.shared.record(.importBrowser(.init(source: .passwordsFile, result: .failed)))
                return completion(.failure(error))
            }
            var o = Outcome(duplicates: parsed.duplicates, incomplete: parsed.incomplete, notWebsite: parsed.notWebsite,
                            failed: parsed.unreadable, profileID: profileID, format: parsed.format)
            guard !parsed.logins.isEmpty else { return completion(.success(o)) }
            sink.receive(ImportedCredentials(logins: parsed.logins), forProfile: profileID) { r in
                o.imported = r.loginsImported
                o.duplicates += r.loginsSkipped
                o.failed += r.loginsRejected + r.loginsFailed
                Telemetry.shared.record(.importBrowser(.init(source: .passwordsFile, result: o.isFailure ? .failed : .success, passwords: o.imported)))
                completion(.success(o))
            }
        }
    }

    struct Unsupported: LocalizedError {
        var errorDescription: String? { "Passwords come over with the Chromium engine. This build runs on WebKit, so the file wasn't read." }
    }

    /// The CSV is plain text: once its passwords are in, offer to move it to the Trash. Automated runs delete their
    /// synthetic file instead, so the owner's Trash never fills with test files.
    static func discard(_ file: URL, completion: @escaping (Bool) -> Void) {
        if LaunchOptions.current.isAutomated {
            completion((try? FileManager.default.removeItem(at: file)) != nil)
            return
        }
        NSWorkspace.shared.recycle([file]) { moved, error in
            DispatchQueue.main.async { completion(error == nil && !moved.isEmpty) }
        }
    }

    /// Where to export passwords from, per browser (the logins step and the Passwords source).
    static func exportHint(_ kind: BrowserKind?) -> String {
        switch kind {
        case .firefox?, .zen?: "In \(kind!.name): Passwords → ••• → Export Passwords…"
        case .safari?: "In the Passwords app: File → Export All Passwords…"
        case .some(let k): "In \(k.name): Password Manager → Settings → Export passwords"
        case nil: "Chrome, Edge, Brave, Firefox or the Passwords app."
        }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

public struct ImportedExtension: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// Where Arc had it from (P22); nil in checklists saved before, which were all treated as Web Store extensions.
    public var install: Install? = nil
    public var storeURL: URL { URL(string: "https://chromewebstore.google.com/detail/" + id)! }
    /// The Chrome Web Store has it under this ID (a Web Store or a managed extension).
    public var reinstallsFromWebStore: Bool { install == nil || install == .webStore || install == .managed }

    public enum Install: String, Codable, Sendable {
        /// From the Chrome Web Store (or nothing says otherwise).
        case webStore
        /// Loaded unpacked from a folder (developer mode) or from the command line: the Web Store doesn't have it.
        case unpacked
        /// Installed by an organization's policy in Arc; the Web Store has it, the policy doesn't come along.
        case managed
        /// Updates from somewhere other than the Chrome Web Store.
        case otherSource
    }

    /// Chromium's `ManifestLocation` and update URL in Arc's Preferences say where an extension came from.
    static func provenance(location: Int, updateURL: String, fromWebStore: Bool) -> Install {
        if [4, 8].contains(location) { return .unpacked }
        let google = updateURL.isEmpty || updateURL.contains("clients2.google.com") || updateURL.contains("chromewebstore.google")
            || updateURL.contains("chrome.google.com")
        if !google && !fromWebStore { return .otherSource }
        if [7, 9].contains(location) { return .managed }
        return .webStore
    }
}

extension ArcImporter {
    /// History and preference metadata only, plus the bounded manifest/locale name reads below.
    /// No cookie/login stores, executable extension payloads or Keychain.
    /// WAL-only visits cannot be recovered under this contract: ask the user to quit Arc and reimport.
    static func readProfileData(into plan: inout ImportPlan, at root: URL, tempRoot: URL, now: Date,
                                progress: ProgressHandler?) throws {
        plan.history = [:]; plan.extensions = [:]
        let fm = FileManager.default
        let userData = root.appendingPathComponent("User Data").resolvingSymlinksInPath()
        for (index, p) in plan.profiles.enumerated() where p.isAvailable {
            try Task.checkCancellation()
            try validateDirectory(p.directory)
            let folder = userData.appendingPathComponent(p.directory)
            // A crafted profile must not redirect reads outside User Data.
            guard folder.resolvingSymlinksInPath().deletingLastPathComponent() == userData else {
                plan.warnings.append(.init(code: .profileOutsideArc,
                                           message: "A profile folder links to somewhere outside Arc's folder; its history and extensions weren't read."))
                continue
            }
            func regular(_ name: String) -> URL? {
                let url = folder.appendingPathComponent(name)
                guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      v.isRegularFile == true, v.isSymbolicLink != true else { return nil }
                return url
            }
            progress?(.init(stage: .history, completed: index, total: plan.profiles.count))
            // SQLite's write-ahead log past its 32-byte header holds pages the main file doesn't have yet: Arc is open
            // (or didn't quit cleanly). Only the main file is read, so those visits wait for Arc to quit.
            let walSize = (try? folder.appendingPathComponent("History-wal").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let checkpoint = ImportWarning(code: .historyNeedsCheckpoint, message: "Recent history may still be in Arc. Quit Arc and import again to include it.")
            if let history = regular("History") {
                do {
                    plan.history?[p.id] = try ChromiumHistory.read(DatabaseCopy(history, tempRoot: tempRoot, immutableOnly: true),
                        limit: BrowserImporter.defaultHistoryLimit, since: now.addingTimeInterval(-90 * 86400))
                    if walSize > 32 { plan.warnings.append(checkpoint) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A database that so far lives only in its log (an empty or tableless main file) isn't damaged.
                    plan.warnings.append(walSize > 32 ? checkpoint
                        : .init(code: .unreadableHistory, message: "A profile's history couldn't be read. Quit Arc and import again."))
                }
            } else if walSize > 32 {
                plan.warnings.append(checkpoint)
            }
            progress?(.init(stage: .extensions, completed: index, total: plan.profiles.count))
            var settings: [String: Any] = [:]
            for name in ["Preferences", "Secure Preferences"] {
                guard let source = regular(name) else { continue }
                let scratch = tempRoot.appendingPathComponent("AircImport-" + UUID().uuidString)
                do {
                    try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    defer { try? fm.removeItem(at: scratch) }
                    let copy = scratch.appendingPathComponent(name)
                    try fm.copyItem(at: source, to: copy)
                    guard (try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= BrowserImporter.maxFileSize,
                          let json = try JSONSerialization.jsonObject(with: Data(contentsOf: copy)) as? [String: Any] else {
                        throw ImportError.fileTooLarge
                    }
                    let extensions = json["extensions"] as? [String: Any]
                    settings.merge(extensions?["settings"] as? [String: Any] ?? [:]) { _, secure in secure }
                } catch {
                    try? fm.removeItem(at: scratch)
                    plan.warnings.append(.init(code: .unreadableExtensions, message: "A profile's extension list couldn't be fully read."))
                }
            }
            plan.extensions?[p.id] = settings.compactMap { id, value in
                guard id.count == 32, id.allSatisfy({ ("a"..."p").contains(String($0)) }),
                      let entry = value as? [String: Any], let manifest = entry["manifest"] as? [String: Any] else { return nil }
                // Chromium component/external-component locations; Arc's bundled helpers and Boosts.
                let location = entry["location"] as? Int ?? 0
                let path = (entry["path"] as? String ?? "").lowercased()
                let update = (manifest["update_url"] as? String ?? "").lowercased()
                let rawName = manifest["name"] as? String ?? id
                guard ![5, 10].contains(location), !path.contains("arc.app/"), !path.contains("boosts/"),
                      !update.contains("arc.net"), !update.contains("thebrowser.company"),
                      !rawName.lowercased().hasPrefix("arc internal") else { return nil }
                let fallback = (entry["name"] as? String).flatMap { $0.hasPrefix("__MSG_") || $0.isEmpty ? nil : $0 } ?? id
                let name = rawName.hasPrefix("__MSG_")
                    ? (ExtensionNames.resolve(id: id, entry: entry, profile: folder, tempRoot: tempRoot) ?? fallback)
                    : rawName
                let fromStore = entry["from_webstore"] as? Bool == true || ((entry["creation_flags"] as? Int ?? 0) & 2) != 0
                return ImportedExtension(id: id, name: name, enabled: (entry["state"] as? Int ?? 0) == 1,
                                         install: ImportedExtension.provenance(location: location, updateURL: update, fromWebStore: fromStore))
            }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        }
    }
}

extension ImportPlan {
    /// Same directory-based source keys as the Spaces blueprint. Missing/unselected destinations are never guessed.
    public func mappedHistory(profileIDs: [String: String]) -> [String: [ImportedVisit]] {
        var mapped: [String: [ImportedVisit]] = [:]
        for p in profiles {
            guard let destination = profileIDs["arc-profile:" + p.directory] else { continue }
            mapped[destination, default: []] += history?[p.id] ?? []
        }
        return mapped
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

extension SpacesStore {
    public enum BackupPurpose: String {
        case manual, archiveRemoval = "archive-removal", beforeRestore = "before-restore"
        /// The first iCloud sync on this Mac, before it merges or replaces the sidebar (SyncEngine.choose).
        case beforeICloud = "before-icloud"
    }

    /// An explicit backup always captures the current state, even after today's daily backup.
    /// UUIDs prevent rapid successive removals from overwriting their recovery points. Archive
    /// recovery files have their own prefix so daily retention never silently removes them.
    @discardableResult
    public func writeBackup(to directory: URL, purpose: BackupPurpose) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = purpose == .manual ? "airc-backup-manual" : "airc-\(purpose.rawValue)"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = directory.appendingPathComponent("\(prefix)-\(formatter.string(from: now()))-\(UUID().uuidString).json")
        try exportJSON().write(to: url, options: .atomic)
        return url
    }
}

// A catalog reads each file's exportedAt and state, never its filename or filesystem date.
extension SpacesStore {
    public struct BackupInfo: Identifiable, Sendable {
        public var id: URL { url }
        public let url: URL
        public let date: Date?
        public let size: Int
        public let spaces: Int
        public let tabs: Int
        public let archived: Int
        public let problem: String?
    }

    public enum BackupError: LocalizedError {
        case unsupportedVersion, invalidState, restoreInProgress
        public var errorDescription: String? {
            switch self {
            case .restoreInProgress: "A backup is being restored. Please try again when it finishes."
            case .unsupportedVersion: "This backup uses an unsupported version of Airc."
            case .invalidState: "This backup is damaged or incomplete."
            }
        }
    }

    public static func readBackup(_ data: Data) throws -> Backup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: data)
        guard (1...schemaVersion).contains(backup.version) else { throw BackupError.unsupportedVersion }
        let s = backup.state
        func valid<E: StoreEntity>(_ rows: [String: E]) -> Bool {
            rows.allSatisfy { !$0.key.isEmpty && $0.key == $0.value.id }
        }
        guard !s.profiles.isEmpty, s.spaces.values.contains(where: { !$0.isBlankWindow }),
              valid(s.profiles), valid(s.spaces), valid(s.items), valid(s.tabs), valid(s.archive), valid(s.splits),
              valid(s.notes)
        else { throw BackupError.invalidState }
        return backup
    }

    public static func listBackups(in directory: URL) throws -> [BackupInfo] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension.lowercased() == "json" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { url in
                do {
                    let data = try Data(contentsOf: url)
                    let b = try readBackup(data)
                    return BackupInfo(url: url, date: b.exportedAt, size: data.count, spaces: b.state.spaces.count,
                                      tabs: b.state.items.values.filter { $0.kind == .tab }.count
                                        + b.state.tabs.values.filter { $0.itemID == nil }.count, archived: b.state.archive.count, problem: nil)
                } catch {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return BackupInfo(url: url, date: nil, size: size, spaces: 0, tabs: 0, archived: 0,
                                      problem: error.localizedDescription)
                }
            }.sorted { ($0.date ?? .distantPast, $0.url.lastPathComponent) > ($1.date ?? .distantPast, $1.url.lastPathComponent) }
    }

    /// Validate before writing, then save a fresh recovery point before any state change.
    /// These recovery points are deliberately outside daily retention.
    @discardableResult
    public func restore(fromBackup data: Data, savingCurrentTo directory: URL) throws -> URL {
        _ = try Self.readBackup(data)
        let recovery = try writeBackup(to: directory, purpose: .beforeRestore)
        try restore(fromBackup: data)
        return recovery
    }
}

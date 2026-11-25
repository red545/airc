// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import AircKit

extension AppSettings {
    var backupDirectory: URL { values.backupFolder.map { URL(fileURLWithPath: $0) } ?? AppPaths.backups }

    /// All automatic and explicit recovery backups resolve the current setting here (launch, auto-archive, Back Up,
    /// Clear Archive). Export… is different: its save panel supplies a one-off destination.
    /// SET-3: a chosen folder that can't be written (gone: a drive not plugged in; read-only) doesn't cost the backup:
    /// it goes to the default folder instead, and the chosen folder stays chosen for next time.
    @discardableResult
    func backUp(_ store: SpacesStore, purpose: SpacesStore.BackupPurpose? = nil) throws -> URL? {
        func write(_ folder: URL) throws -> URL? {
            if let purpose { return try store.writeBackup(to: folder, purpose: purpose) }
            return try store.backupIfNeeded(to: folder)
        }
        let folder = backupDirectory
        do { return try write(folder) } catch {
            guard folder.standardizedFileURL.path != AppPaths.backups.standardizedFileURL.path else { throw error }
            NSLog("Airc backup: the chosen folder can't be written (%@); backing up to the default folder", error.localizedDescription)
            return try write(AppPaths.backups)
        }
    }

    /// Whether `url` (a backup backUp wrote) is in the default folder although another one is chosen: the fallback.
    func isFallbackBackup(_ url: URL) -> Bool {
        backupDirectory.standardizedFileURL.path != AppPaths.backups.standardizedFileURL.path
            && url.deletingLastPathComponent().standardizedFileURL.path == AppPaths.backups.standardizedFileURL.path
    }

    /// Every folder that can hold this Mac's backups: the chosen one and the default (older backups stay there after
    /// a change). A note picture any of them names is kept (NoteImages.collectGarbage). The default is left out while
    /// it doesn't exist; a chosen folder never is, so one that's gone (a drive not plugged in) stops the sweep.
    var backupFolders: [URL] {
        var folders: [URL] = []
        if FileManager.default.fileExists(atPath: AppPaths.backups.path) { folders.append(AppPaths.backups) }
        if let chosen = values.backupFolder.map({ URL(fileURLWithPath: $0) }),
           chosen.standardizedFileURL.path != AppPaths.backups.standardizedFileURL.path {
            folders.append(chosen)
        }
        return folders
    }
}

extension AppDelegate {
    @MainActor
    @discardableResult
    func restoreBackup(_ data: Data) async throws -> URL {
        let storePhase = RestoreTrace.begin("restore.store")
        let recovery: URL
        do { recovery = try await store.restoreBackup(data, savingCurrentTo: settings.backupDirectory) }
        catch { RestoreTrace.end(storePhase); throw error }
        RestoreTrace.end(storePhase)
        reloadAfterRestore()
        return recovery
    }

    private func reloadAfterRestore() {
        let phase = RestoreTrace.begin("restore.reload")
        defer { RestoreTrace.end(phase) }
        // Even a surviving tab ID may now name a different URL/profile. Drop its old page.
        for c in controllers {
            for id in Array(c.pages.keys) { c.dropPage(id) }
            c.showEmpty(updatesRows: false)
        }
        profiles.loadAll { [weak self] in
            self?.controllers.forEach { $0.reloadAll(animated: false) }
        }
    }
}

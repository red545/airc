// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import AircKit

extension AppSettings {
    var backupDirectory: URL { values.backupFolder.map { URL(fileURLWithPath: $0) } ?? AppPaths.backups }

    /// All automatic and explicit recovery backups resolve the current setting here.
    /// Export… is different: its save panel supplies a one-off destination.
    @discardableResult
    func backUp(_ store: SpacesStore, purpose: SpacesStore.BackupPurpose? = nil) throws -> URL? {
        if let purpose { return try store.writeBackup(to: backupDirectory, purpose: purpose) }
        return try store.backupIfNeeded(to: backupDirectory)
    }
}

extension AppDelegate {
    @MainActor
    @discardableResult
    func restoreBackup(_ data: Data) async throws -> URL {
        let recovery = try await store.restoreBackup(data, savingCurrentTo: settings.backupDirectory)
        reloadAfterRestore()
        return recovery
    }

    private func reloadAfterRestore() {
        // Even a surviving tab ID may now name a different URL/profile. Drop its old page.
        for c in controllers {
            for id in Array(c.pages.keys) { c.dropPage(id) }
            c.showEmpty(updatesRows: false)
        }
        profiles.loadAll { [weak self] in
            self?.controllers.forEach { $0.reloadAll(animated: false) }
        }
        controllers.forEach { $0.reloadAll(animated: false) }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Library › Easels › Delete Easel… (L05). Arc asked "Are you sure you want to delete this Easel?" and deleted it for
// good; Airc puts it in the Trash instead, so it can come back: the Easel's rows (open tabs, pinned rows, archive
// entries) go in one store step that ⌘Z undoes, and its folder goes to the Trash. When ⌘Z brings a row back, the app
// moves the folder back from the Trash (`EaselFiles.putBack`); the Trash keeps it for Finder's Put Back otherwise.

extension SpacesStore {
    /// Removes every row that shows Easel `id` (tabs, pinned and Favorite items, archive entries) as one undoable step
    /// named "Delete Easel". Returns the removed tabs' IDs (the app lets go of them in its windows).
    @discardableResult
    public func deleteEaselRows(_ id: String) throws -> [String] {
        let url = EaselURL.make(id)
        let tabs = state.tabs.values.filter { $0.url == url }.map(\.id)
        let items = state.items.values.filter { $0.savedURL == url }.map(\.id)
        let pinnedTabs = state.tabs.values.filter { t in t.itemID.map(items.contains) ?? false }.map(\.id)
        let archived = state.archive.values.filter { $0.tab.url == url }.map(\.id)
        let gone = Array(Set(tabs + pinnedTabs)).sorted()
        guard !gone.isEmpty || !items.isEmpty || !archived.isEmpty else { return [] }
        try perform("Delete Easel", undoable: true) {
            for t in gone { remove(LiveTab.self, t) }
            for i in items { remove(Item.self, i) }
            for a in archived { remove(ArchiveEntry.self, a) }
        }
        return gone
    }
}

extension EaselFiles {
    /// Moves Easel `id`'s folder to the Trash and returns where it went there (nil when it had no folder).
    @discardableResult
    public func moveToTrash(_ id: String) throws -> URL? {
        guard Self.isValidID(id), FileManager.default.fileExists(atPath: folder(id).path) else { return nil }
        #if os(macOS)
        var out: NSURL?
        try FileManager.default.trashItem(at: folder(id), resultingItemURL: &out)
        return out as URL?
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    /// Puts a trashed Easel's folder back (⌘Z after Delete Easel…). False when it's no longer in the Trash, or a
    /// folder of that Easel is back already.
    @discardableResult
    public func putBack(_ id: String, from trashed: URL) -> Bool {
        guard Self.isValidID(id), !FileManager.default.fileExists(atPath: folder(id).path),
              FileManager.default.fileExists(atPath: trashed.path) else { return false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: trashed, to: folder(id))
            return true
        } catch {
            return false
        }
    }
}

// MARK: - The PNG's edges

/// Export as Image… (N08): the Easel drawn on a transparent background, cut to the pixels that show something.
public enum EaselTrim {
    /// The smallest rectangle (in pixels, rows from the first one in memory) holding every pixel whose alpha is above
    /// `threshold`, in an RGBA-like buffer of 4 bytes per pixel with alpha at `alphaOffset`. nil when nothing shows.
    public static func opaqueBounds(_ bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                                    alphaOffset: Int = 3, threshold: UInt8 = 0) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard width > 0, height > 0, bytesPerRow >= width * 4, bytes.count >= bytesPerRow * (height - 1) + width * 4 else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * bytesPerRow + alphaOffset
            var first = -1, last = -1
            for x in 0..<width where bytes[row + x * 4] > threshold {
                if first < 0 { first = x }
                last = x
            }
            guard first >= 0 else { continue }
            minX = min(minX, first); maxX = max(maxX, last)
            if minY == height { minY = y }
            maxY = y
        }
        guard maxX >= 0 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }
}

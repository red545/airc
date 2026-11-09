// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// Session-only hiding. Weak references never keep a closed tab, window or profile alive.
enum HiddenMiniPlayers {
    private final class Entry {
        weak var page: EngineTab?
        weak var presentation: MiniPlayerPresentation?
        init(_ page: EngineTab, _ presentation: MiniPlayerPresentation) { self.page = page; self.presentation = presentation }
    }
    private static var entries: [ObjectIdentifier: Entry] = [:]
    static func remember(_ page: EngineTab, _ presentation: MiniPlayerPresentation) {
        entries = entries.filter { $0.value.page?.isClosed == false && $0.value.presentation != nil }
        entries[ObjectIdentifier(page)] = Entry(page, presentation)
        MediaLibrary.shared.media?.miniPlayerVisibilityChanged()
        MediaLibrary.shared.trayContentChanged()
    }
    @discardableResult static func show(_ page: EngineTab) -> Bool {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(page)), !page.isClosed,
              let presentation = entry.presentation, presentation.controls?.window != nil else { return false }
        presentation.restoreWindow()
        MediaLibrary.shared.media?.miniPlayerVisibilityChanged()
        MediaLibrary.shared.trayContentChanged()
        return true
    }
    static func forget(_ page: EngineTab) {
        entries.removeValue(forKey: ObjectIdentifier(page))?.presentation?.clearHiddenWindow()
    }
    static func isHidden(_ page: EngineTab) -> Bool { entries[ObjectIdentifier(page)]?.presentation?.isWindowHidden == true }
}

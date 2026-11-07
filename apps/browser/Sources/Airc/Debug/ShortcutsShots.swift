// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of Settings → Shortcuts (CB-4), the marketing scenario's part "shortcuts"
/// (`scripts/marketing-shots.sh --parts shortcuts`):
///   - settings-shortcuts: Open Location on ⌘L at Airc first (pages never get ⌘L; its row with the reset arrow), and ⌘N
///     just typed for New Private Window, which asks whether to swap with New Window or take the key from it.
/// The map goes back to today's table afterwards.
extension SnapshotRunner {
    func mkShortcutsShots(_ d: MarketingDemo) {
        let center = ShortcutCenter.shared, editor = ShortcutsEditor.shared
        mkShow(d, "personal", "apple")
        run { [self] in
            NSApp.appearance = NSAppearance(named: .aqua)
            center.update { $0.setPriority(.airc, for: "file.openLocation") }
            c.app?.showSettings(page: .shortcuts)
            if let w = c.app?.settingsWindow?.window { w.setFrameOrigin(NSPoint(x: -6000, y: 200)) }
            // ⌘N typed into New Private Window's recorder: it's New Window's, so the row asks.
            editor.start("file.newPrivateWindow")
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                        characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45) {
                editor.record(e)
            }
        }
        wait(0.9)
        step { [self] done in
            defer { done() }
            guard editor.conflict?.other == "file.newWindow" else { return note("marketing: MISSING settings-shortcuts: no conflict row") }
            guard let w = c.app?.settingsWindow?.window, let view = w.contentView, let img = mkContentImage(w) else {
                return note("marketing: MISSING settings-shortcuts: no Settings window")
            }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite("settings-shortcuts", canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(w)),
            ])
        }
        run { [self] in
            editor.resolve(.refuse)
            editor.resetAll()
            c.app?.settingsWindow?.window.orderOut(nil)
        }
    }
}
#endif

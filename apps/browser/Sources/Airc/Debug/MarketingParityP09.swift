// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
#if canImport(AircCore)
import AircCore
#endif

/// The marketing shot of pinned extensions in the toolbar (P09), the marketing scenario's part "parityp09"
/// (`scripts/marketing-shots.sh --parts parityp09`, which opens the engine's test gate for this part):
///   - toolbar-extensions: Work on linear.app with Show Toolbar on; two made-up extensions (synthetic, unpacked into the
///     run's folder) pinned at its top right, ⌘E's list open under the puzzle.
extension SnapshotRunner {
    func mkParityP09Shots(_ d: MarketingDemo) {
        var ids: [String] = []
        mkShow(d, "work", "linear")
        mkSettleShown()
        #if canImport(AircCore)
        for (n, (title, symbol)) in [("Reading List", "book"), ("Focus Timer", "timer")].enumerated() {
            step { [self] done in
                guard Self.engineTestGateOpens, let profile = c.engineTab(for: c.shownTabID ?? "")?.profile as? ChromiumProfile else { return done() }
                let folder = dir.appendingPathComponent("marketing-extension-\(n)", isDirectory: true)
                Self.writeP09Extension(folder, title: title, symbol: symbol)
                profile.core.loadUnpackedExtension(forTesting: folder.path) { id, error in
                    DispatchQueue.main.async {
                        if let error { self.note("marketing: \(title): \(error)") }
                        if let id { ids.append(id); self.c.setExtension(id, pinned: true) }
                        done()
                    }
                }
            }
        }
        #endif
        run { [self] in
            guard ids.count == 2 else { return note("marketing: MISSING toolbar-extensions: no synthetic extensions (the engine's test gate)") }
            if c.pageToolbar == nil { c.togglePageToolbar() }
        }
        wait(1.2)
        run { [self] in c.refreshExtensionButtons() }
        wait(0.4)
        mkWindowShot("toolbar-extensions") { [self] frame in
            // ⌘E's list under the toolbar's puzzle, drawn from its own view (a popover is a window of its own).
            guard ids.count == 2, let t = c.pageToolbar else { return [] }
            c.showExtensions()
            guard let p = c.extensionsPopover, let view = p.contentViewController?.view else { return [] }
            view.layoutSubtreeIfNeeded()
            let image = render(view)
            p.close()
            guard let image else { return [] }
            let r = t.puzzle.convert(t.puzzle.bounds, to: nil)
            let size = view.bounds.size
            return [MarketingStudio.Layer(image: image, frame: NSRect(x: frame.minX + r.maxX + 6 - size.width, y: frame.minY + r.minY - 8 - size.height,
                                                                      width: size.width, height: size.height),
                                          radius: 12, dark: mkIsDark(), shadow: .panel)]
        }
        run { [self] in
            note("marketing: toolbar extensions: \(c.pageToolbar?.extensionButtons.map(\.toolTip) ?? [])")
            if c.pageToolbar != nil { c.togglePageToolbar() }
        }
    }
}
#endif

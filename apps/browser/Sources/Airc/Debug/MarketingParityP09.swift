// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import SwiftUI
import AircDesign
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
        mkWindowShot("extension-profile-results") { [self] frame in
            let view = NSHostingView(rootView: ExtensionProfileResults(name: "Reading List", results: [
                .init(profileID: "personal", profileName: "Personal", message: "Already installed — skipped", tabID: nil),
                .init(profileID: "work", profileName: "Work", message: "Installed", tabID: nil),
                .init(profileID: "research", profileName: "Research", message: "Denied — not installed", tabID: nil)
            ], done: {}).aircTheme(DesignTheme.default.resolved(systemIsDark: false)))
            view.setFrameSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            guard let image = render(view) else { return [] }
            return [MarketingStudio.Layer(image: image, frame: NSRect(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2,
                width: image.size.width, height: image.size.height), radius: 12, dark: false, shadow: .panel)]
        }
        mkWindowShot("capture-page-menu") { [self] frame in
            guard let tab = c.engineTab(for: c.shownTabID ?? "") else { return [] }
            let menu = NSMenu()
            for item in c.tab(tab, pageMenu: [:]) {
                menu.addItem(withTitle: item["title"] ?? "", action: nil, keyEquivalent: "")
            }
            guard let image = Self.mkMenuImage(menu, highlighted: "Capture in Portrait Mode", dark: false) else { return [] }
            return [MarketingStudio.Layer(image: image, frame: NSRect(x: frame.midX, y: frame.midY,
                width: image.size.width, height: image.size.height), radius: Self.mkMenuRadius, dark: false, shadow: .panel)]
        }
        run { [self] in
            note("marketing: toolbar extensions: \(c.pageToolbar?.extensionButtons.map(\.toolTip) ?? [])")
            if c.pageToolbar != nil { c.togglePageToolbar() }
        }
    }
}
#endif

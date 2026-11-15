// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
import ObjectiveC

/// The dark-mode readability audit (artifacts/darkmode): every main surface in one forced appearance, as plain window
/// images (no desktop canvas), so their text contrast can be measured.
///
/// - `AIRC_DARKAUDIT_APPEARANCE=dark|light` pins `NSApp.appearance` for the whole launch: every later assignment (the
///   marketing parts set `.aqua` and `.darkAqua` themselves) is redirected to it. So any marketing part also runs in the
///   pinned appearance, with the system's own setting untouched.
/// - `AIRC_DARKAUDIT_INCREASE_CONTRAST=1` / `AIRC_DARKAUDIT_REDUCE_TRANSPARENCY=1` turn on the scripted overrides of
///   those accessibility settings (`AircTranslucency.increaseContrastOverride`, `reduceTransparencyOverride`).
/// - Parts: `darkaudit-sidebar` (the sidebar in each of the twelve presets and the nine swatches), `darkaudit-overlays`
///   (Command Bar, toast, find bar, Site Controls, Library sections, Boost editor, Manage Spaces, Peek) and
///   `darkaudit-settings` (every Settings pane, top and end).
/// Shots are `da-<part>-<name>.png`.
extension SnapshotRunner {
    /// The pinned appearance, or nil when the run doesn't pin one.
    static var darkAuditAppearance: NSAppearance? {
        switch ProcessInfo.processInfo.environment["AIRC_DARKAUDIT_APPEARANCE"] {
        case "dark": NSAppearance(named: .darkAqua)
        case "light": NSAppearance(named: .aqua)
        default: nil
        }
    }

    /// Installs the appearance pin and the accessibility overrides (once; a no-op without the variables).
    func darkAuditInstall() {
        let env = ProcessInfo.processInfo.environment
        MainActor.assumeIsolated {
            if env["AIRC_DARKAUDIT_INCREASE_CONTRAST"] == "1" { AircTranslucency.increaseContrastOverride = true }
            if env["AIRC_DARKAUDIT_REDUCE_TRANSPARENCY"] == "1" { AircTranslucency.reduceTransparencyOverride = true }
            if env["AIRC_DARKAUDIT_INCREASE_CONTRAST"] == "1" || env["AIRC_DARKAUDIT_REDUCE_TRANSPARENCY"] == "1" {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            }
        }
        guard let pinned = Self.darkAuditAppearance, !DarkAuditPin.installed else { return }
        DarkAuditPin.installed = true
        DarkAuditPin.pinned = pinned
        let cls: AnyClass = NSApplication.self
        let sel = NSSelectorFromString("setAppearance:")
        guard let m = class_getInstanceMethod(cls, sel) else { return note("darkaudit: no setAppearance: to pin") }
        typealias Setter = @convention(c) (AnyObject, Selector, NSAppearance?) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: Setter.self)
        let block: @convention(block) (AnyObject, NSAppearance?) -> Void = { app, _ in original(app, sel, DarkAuditPin.pinned) }
        method_setImplementation(m, imp_implementationWithBlock(block))
        NSApp.appearance = pinned
        note("darkaudit: appearance pinned to \(pinned.name.rawValue)")
    }

    func darkAudit(_ d: MarketingDemo, part: String) {
        switch part {
        case "darkaudit-sidebar": daSidebar(d)
        case "darkaudit-overlays": daOverlays(d)
        case "darkaudit-settings": daSettings(d)
        default: note("darkaudit: unknown part \(part)")
        }
    }

    // MARK: Parts

    /// The Personal Space re-themed with each preset and swatch: header, Favorites, pinned folders, Today rows, the
    /// selected row and the footer, plus a hovered row (the pointer is parked in the sidebar by `hoverRow`).
    private func daSidebar(_ d: MarketingDemo) {
        mkShow(d, "personal", "apple")
        mkSettleShown(timeout: 8, extra: 0.4)
        var themes: [(String, DesignTheme)] = DesignTheme.presets.map { ($0.id, $0.theme) }
        themes += DesignTheme.swatches.map { ("swatch-" + String($0.hexString.dropFirst()), DesignTheme(colors: [$0])) }
        for (name, theme) in themes {
            run { [self] in
                guard let sid = d.space["personal"] else { return }
                try? c.store.updateSpace(sid) { $0.theme = theme.model }
                c.switchToSpace(sid, animated: false)
            }
            wait(0.35)
            daWindowShot("sidebar-\(name)", sidebarOnly: true)
        }
        // The other demo Spaces as they are (Grape's three colours, Sky's two).
        for space in ["travel", "studio", "work"] {
            mkShow(d, space, nil)
            wait(0.4)
            daWindowShot("sidebar-demo-\(space)", sidebarOnly: true)
        }
    }

    /// The overlays on the default theme (Paper follows the system) and on Work (Grape, always dark).
    private func daOverlays(_ d: MarketingDemo) {
        run { [self] in
            if let sid = d.space["personal"] { try? c.store.updateSpace(sid) { $0.theme = DesignTheme.preset("paper")!.model } }
        }
        for space in ["personal", "work"] {
            let tab = space == "personal" ? "apple" : "linear"
            mkShow(d, space, tab)
            mkSettleShown(timeout: 10, extra: 0.5)
            run { [self] in
                c.openCommandBar(mode: .newTab)
                c.commandBar?.type("lis")
            }
            wait(1.0)
            daWindowShot("\(space)-commandbar")
            run { [self] in c.closeCommandBar() }
            wait(0.3)
            run { [self] in c.showToast("Copied link to Lisbon – Wikipedia") }
            wait(0.4)
            daWindowShot("\(space)-toast")
            run { [self] in
                c.showFind()
                c.findBar?.field.stringValue = "the"
                c.findBar?.find(forward: true)
                c.window.makeFirstResponder(nil)
            }
            wait(1.0)
            daWindowShot("\(space)-findbar")
            run { [self] in c.closeFind(refocusPage: false) }
            run { [self] in c.showSiteControls() }
            wait(0.8)
            daWindowShot("\(space)-sitecontrols")
            run { [self] in _ = c.closeSiteControls(animated: false) }
            wait(0.3)
            for section in [LibraryModel.Section.archive, .downloads, .easels, .spaces] {
                run { [self] in c.showLibrary(section) }
                wait(section == .archive ? 2.2 : 0.8)
                daWindowShot("\(space)-library-\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))")
            }
            run { [self] in c.toggleLibrary() }
            wait(0.8)
            run { [self] in c.showBoostEditor(section: .colors) }
            wait(1.2)
            daWindowShot("\(space)-boosteditor")
            run { [self] in _ = c.closeBoostEditor(animated: false) }
            wait(0.4)
            run { [self] in c.showManageSpaces() }
            wait(1.0)
            daWindowShot("\(space)-managespaces")
            run { [self] in c.closeManageSpaces() }
            wait(0.4)
        }
    }

    /// Every Settings pane, at the top and scrolled to the end.
    private func daSettings(_ d: MarketingDemo) {
        mkShow(d, "personal", "apple")
        wait(0.3)
        for page in SettingsPage.allCases {
            run { [self] in
                c.app?.showSettings(page: page)
                if let w = c.app?.settingsWindow?.window {
                    w.setContentSize(NSSize(width: w.contentRect(forFrameRect: w.frame).width, height: 900))
                    w.setFrameOrigin(NSPoint(x: -6000, y: 100))
                }
            }
            wait(0.8)
            daContentShot("settings-\(page.rawValue)")
            run { [self] in mkScrollSettings(.end) }
            wait(0.4)
            daContentShot("settings-\(page.rawValue)-end")
        }
        run { [self] in c.app?.settingsWindow?.window.orderOut(nil) }
    }

    // MARK: Capturing

    private var daPrefix: String {
        let a = ProcessInfo.processInfo.environment["AIRC_DARKAUDIT_APPEARANCE"] ?? "system"
        return "da-\(a)-"
    }

    /// The browser window (or only its sidebar and margin), as captureNow draws it.
    func daWindowShot(_ name: String, sidebarOnly: Bool = false) {
        step { [self] done in
            mkWindowImage { img in
                defer { done() }
                guard let img else { return self.note("darkaudit: MISSING \(name): no capture") }
                var out = img
                if sidebarOnly, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let scale = CGFloat(cg.width) / max(1, img.size.width)
                    let w = (self.c.card.frame.minX + 4) * scale
                    if let cut = cg.cropping(to: CGRect(x: 0, y: 0, width: min(CGFloat(cg.width), w), height: CGFloat(cg.height))) {
                        out = NSImage(cgImage: cut, size: NSSize(width: CGFloat(cut.width) / scale, height: img.size.height))
                    }
                }
                self.daWrite(out, name)
            }
        }
    }

    func daContentShot(_ name: String) {
        step { [self] done in
            defer { done() }
            guard let w = c.app?.settingsWindow?.window, let img = mkContentImage(w) else { return note("darkaudit: MISSING \(name): no window") }
            daWrite(img, name)
        }
    }

    func daWrite(_ img: NSImage, _ name: String) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return note("darkaudit: MISSING \(name): no PNG") }
        let file = daPrefix + name
        do {
            try png.write(to: dir.appendingPathComponent(file + ".png"))
            note("darkaudit: shot \(file)")
        } catch {
            note("darkaudit: MISSING \(file): \(error)")
        }
    }
}

/// The appearance the audit pins (`SnapshotRunner.darkAuditInstall`).
enum DarkAuditPin {
    nonisolated(unsafe) static var installed = false
    nonisolated(unsafe) static var pinned: NSAppearance?
}
#endif

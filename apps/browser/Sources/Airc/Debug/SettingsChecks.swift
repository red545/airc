// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// Part of `--script events`: Settings that drive the engine.
extension SnapshotRunner {
    /// SB-55 (Chromium): the off switch, a site exception and the position reset reach every loaded profile; the
    /// General page is rendered with them.
    func pictureInPictureSettingsCheck() {
        #if canImport(AircCore)
        step { [self] done in
            guard let app = c.app, let chromium = app.engine as? ChromiumEngine else {
                note("picture in picture settings: Chromium only")
                return done()
            }
            let profiles = c.profiles.loadedProfiles
            let before = app.settings.values
            app.settings.values.pipAutomatic = false
            app.settings.values.pipSites = ["https://meet.example": true]
            c.applyPictureInPictureSettings()
            let off = profiles.allSatisfy { !chromium.autoPictureInPictureEnabled($0) }
            let origin = WindowController.pictureInPictureOrigin(" Meet.Example/call?x=1 ")
            // A moved window, then Reset Position.
            profiles.forEach { chromium.setPictureInPictureFrame($0, frame: NSRect(x: 40, y: 40, width: 320, height: 180)) }
            c.resetPictureInPicturePosition()
            let reset = profiles.allSatisfy { chromium.pictureInPictureFrame($0) == .zero }
            app.showSettings(page: .general)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                if let w = app.settingsWindow?.window, let v = w.contentView {
                    v.layoutSubtreeIfNeeded()
                    if let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: dir.appendingPathComponent("settings-pip.png"))
                        note("wrote settings-pip.png")
                    }
                    w.orderOut(nil)
                }
                app.settings.values = before
                c.applyPictureInPictureSettings(cleared: ["https://meet.example"])
                let on = profiles.allSatisfy { chromium.autoPictureInPictureEnabled($0) == before.pipAutomatic }
                check(!profiles.isEmpty && off && on && reset && origin == "https://meet.example",
                      "picture in picture settings: off reaches \(profiles.count) profile(s) (\(off)) and back on (\(on)), "
                      + "Reset Position (\(reset)), a typed site becomes \(origin ?? "nil")")
                done()
            }
        }
        #endif
    }
}
#endif

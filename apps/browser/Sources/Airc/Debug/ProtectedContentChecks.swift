// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
#if canImport(AircCore)
import AircCore
#endif

extension SnapshotRunner {
    /// Dedicated settings integration check: no rendering, capture or devices.
    func protectedContentSettingsScenario() {
        run { [self] in
            guard let app else { check(false, "protected content: app missing"); return }
            let model = SettingsModel(app: app)
            let before = app.engine.protectedContentEnabled
            defer { app.engine.protectedContentEnabled = before }
            #if canImport(AircCore)
            if let chromium = app.engine as? ChromiumEngine {
                check(model.protectedContentAvailable, "protected content: toggle available on Chromium")
                check(model.protectedContentEnabled, "protected content: fresh profile defaults on")
                model.protectedContentEnabled = false
                check(!chromium.core.protectedContentEnabled, "protected content: Privacy binding disables engine")
                check(!SettingsModel(app: app).protectedContentEnabled, "protected content: reopened Settings reads engine state")
                model.protectedContentEnabled = true
                check(chromium.core.protectedContentEnabled, "protected content: Privacy binding re-enables engine")
                return
            }
            #endif
            check(!model.protectedContentAvailable, "protected content: toggle hidden on WebKit")
            model.protectedContentEnabled = !before
            check(app.engine.protectedContentEnabled == before, "protected content: unsupported engine is unchanged")
        }
    }
}
#endif

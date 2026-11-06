// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircCore

@MainActor
func checkHostAPI(engine: AircEngine, window: AircWindow, profile: AircProfile, view: NSView) {
    engine.loadProfile(directory: "Profile One") { _ in }
    engine.createProfile { _ in }
    engine.loadInternalProfile { _ in }
    let _: [String] = engine.profileDirectoryNames
    let _ = profile.extensions
    window.prepareProfile(profile)
    window.uiAnchorView = view
    if let tab = window.openTab(url: "about:blank", profile: profile, foreground: true) {
        tab.attach(to: view)
        tab.loadURL("https://example.com", userInitiated: true)
        tab.goBack()
        tab.goForward()
        tab.reload()
        tab.detach()
        let _ = tab.discard()
        let _ = window.openActionPopup(extensionID: "test", tab: tab)
        tab.close()
    }
}

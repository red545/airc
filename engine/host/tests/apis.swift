// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircCore
func checkExports(_ tab: AircTab, path: String) {
    let formats: [AircSavePageFormat] = [.html, .complete, .mhtml]
    for (value, format) in formats.enumerated() {
        precondition(format.rawValue == value)
    }
    if tab.canSavePage {
        tab.savePage(to: path, format: .complete) { (error: String?) in _ = error }
    }
    tab.snapshot(withMaxSize: CGSize(width: 640, height: 400)) { (image: NSImage?) in _ = image }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import WebKit

/// Which view has the keyboard: DevTools docked in a window (Chromium's frontend, ChromiumDevToolsDock) or WebKit's
/// Web Inspector attached to it. While one has it, its shortcuts are its own first (KeyMonitor), as in Chrome and Safari.
enum DevToolsKeyboard {
    static func hasKeyboard(_ window: NSWindow?) -> Bool {
        #if canImport(AircCore)
        if ChromiumDevToolsDock.hasKeyboard(window) { return true }
        #endif
        guard var v = window?.firstResponder as? NSView else { return false }
        // WebKit's inspector page is its own WKWebView subclass (WKInspectorWKWebView), next to the inspected page.
        while true {
            if v is WKWebView, NSStringFromClass(type(of: v)).contains("Inspector") { return true }
            guard let up = v.superview else { return false }
            v = up
        }
    }
}

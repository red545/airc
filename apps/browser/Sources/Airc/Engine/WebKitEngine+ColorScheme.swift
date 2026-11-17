// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import WebKit

// PageColorScheme on WebKit: a WKWebView's pages prefer the scheme of the view's effective appearance, and WebKit
// updates their media queries and matchMedia listeners when it changes. Pinning the web view's own appearance makes
// the page follow its Space rather than whatever the window or NSApp has; `.engine` gives it back to them.
extension WebKitTab: EngineColorSchemeTab {
    var pageColorScheme: PageColorScheme.Scheme {
        get {
            switch webView.appearance?.name {
            case NSAppearance.Name.darkAqua?: .dark
            case NSAppearance.Name.aqua?: .light
            default: .engine
            }
        }
        set {
            switch newValue {
            case .dark: webView.appearance = NSAppearance(named: .darkAqua)
            case .light: webView.appearance = NSAppearance(named: .aqua)
            case .engine: webView.appearance = nil
            }
        }
    }
}

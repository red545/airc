// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import WebKit

// MEM-3 for WebKit pages (the dev engine's, and the Chromium build's DRM pages): a tab not seen for the inactive-tab
// timeout closes its web view (Browser/TabUnloading.swift) and keeps WebKit's session state, so it comes back with its
// history and scroll position, as Chromium's discarded tabs do.
extension WebKitTab {
    /// The page's back-forward list and scroll positions (WKWebView.interactionState), to open it again with.
    var unloadState: Any? { webView.interactionState }

    /// Whether WebKit itself says the page plays sound: `-[WKWebView _isPlayingAudio]`, the page's media state, which
    /// counts media elements outside the document (`new Audio()`) and Web Audio, unlike the page script's report
    /// (`aircAudio` listens on the document). Nil where the web view doesn't answer.
    var engineReportsAudio: Bool? {
        let sel = NSSelectorFromString("_isPlayingAudio")
        guard webView.responds(to: sel) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(webView.method(for: sel), to: Getter.self)(webView, sel)
    }

    /// Playing: by WebKit's media state, or by the page's media session (a player that says it plays).
    var playsMedia: Bool {
        engineReportsAudio == true || webKitProfile.library.session(of: self).playback == .playing
    }
}

extension WebKitWindow {
    /// A page opened again from `state`: it loads its last entry, with the entries before and after it.
    func openTab(restoring state: Any, profile: WebKitProfile, hostProfile: EngineProfile?) -> WebKitTab {
        let tab = openTab(url: nil, profile: profile, hostProfile: hostProfile, foreground: false)
        tab.webView.interactionState = state
        return tab
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

#if canImport(AircCore)
import AircCore

// The page script on Chromium (engine/core/airc_page_script.cc, renderer/airc_content_renderer_client.cc): the engine
// sends AircEngine.pageScript to every renderer, and each frame runs it in its main world as its script context is
// created or at document start, whichever comes first, before the page's own scripts. Posts arrive through the tab's
// delegate (ChromiumTab, ChromiumEngine.swift) with the frame and the origin the browser process committed.
extension ChromiumEngine: EnginePageScripts {
    var existingPageScript: String? { ChromiumPageScripts.ownScript == nil ? core.pageScript : nil }

    func setPageScript(_ source: String?) {
        ChromiumPageScripts.ownScript = source
        core.pageScript = source
    }

    var pageMessageHandler: ((EngineTab, EnginePageMessage) -> Void)? {
        get { ChromiumPageScripts.handler }
        set { ChromiumPageScripts.handler = newValue }
    }

    func callPage(_ tab: EngineTab, kind: String, json: String) { core(of: tab)?.callPage(kind, json: json) }

    func executeScript(_ code: String, in tab: EngineTab, frame: String?) { core(of: tab)?.executeJavaScript(code, frame: frame) }
}

enum ChromiumPageScripts {
    static var handler: ((EngineTab, EnginePageMessage) -> Void)?
    /// What the app set last (so its own script is never taken for the engine's).
    static var ownScript: String?

    /// On the next turn: the engine is inside its own delivery when it calls the delegate.
    static func received(_ tab: EngineTab, kind: String, json: String, frame: String, main: Bool, origin: String) {
        let message = EnginePageMessage(kind: kind, json: json, frame: frame, isMainFrame: main, origin: origin)
        DispatchQueue.main.async { [weak tab] in
            guard let tab, !tab.isClosed else { return }
            handler?(tab, message)
        }
    }
}
#endif

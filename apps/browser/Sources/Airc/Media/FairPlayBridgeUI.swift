// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

// What the person sees of the FairPlay bridge (docs/design/fairplay-bridge.md): nothing while it plays; when it can't
// (no licence, the player failed), the page gets a media error and its window a toast offering Safari's engine.
extension FairPlayBridge {
    private static var offerInstalled = false

    /// Once, with the first window (Chromium builds): the bridge follows its setting, and a failure offers WebKit.
    static func installOffer() {
        install()
        guard !offerInstalled else { return }
        offerInstalled = true
        NotificationCenter.default.addObserver(forName: failed, object: nil, queue: .main) { note in
            guard let page = note.object as? EngineTab, !page.isClosed,
                  let c = (NSApp.delegate as? AppDelegate)?.controller(owning: page) else { return }
            c.offerSafariEngineAfterFairPlayFailure(page)
        }
    }
}

extension WindowController {
    /// "Spotify couldn't play here"  [Open in Safari's engine]: the choice is kept (protected-media.json), and the page
    /// opens again in WebKit at once.
    func offerSafariEngineAfterFairPlayFailure(_ page: EngineTab) {
        guard let url = page.url else { return }
        let name = ProtectedMediaSites.serviceNames[url.host?.lowercased() ?? ""] ?? URLRules.displayHost(url.absoluteString)
        toast.show("\(name) couldn't play here", palette: currentPalette, in: card.frame, duration: 10,
                   action: ("Open in Safari's engine", { [weak self, weak page] in
                       guard let self, let page, !page.isClosed else { return }
                       self.setProtectedMediaEngine(.webKit, for: page)
                   }))
        #if AIRC_TESTING
        FairPlayBridge.lastOffer = (name, Date())
        #endif
    }
}

#if AIRC_TESTING
extension FairPlayBridge {
    /// The last failure offer (`--script fairplaybridge`).
    static var lastOffer: (service: String, at: Date)?
}
#endif

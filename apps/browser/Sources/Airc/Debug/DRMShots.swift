// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// Protected media's marketing shots (docs/user/protected-media.md), the marketing scenario's part "drm"
/// (`scripts/marketing-shots.sh --parts drm`): Spotify's web player, logged out (nothing signs in), in a WebKit page of
/// the Chromium build with its "plays with Safari's engine" note, then Site Controls with the Safari's engine switch.
/// Logged out nothing plays by itself; the page's media are muted and paused anyway.
extension SnapshotRunner {
    func mkDRMShots(_ d: MarketingDemo) {
        var spotify = ""
        mkShow(d, "personal", nil)
        run { [self] in
            guard let t = try? c.store.openTab(url: "https://open.spotify.com/", inSpace: c.currentSpaceID) else { return }
            spotify = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        mkSettleShown(timeout: 20, extra: 2)
        run { [self] in
            c.engineTab(for: spotify)?.evaluate("document.querySelectorAll('video,audio').forEach(function(m){ m.muted = true; m.pause(); }); true",
                                                completion: nil)
            if !ProtectedMedia.isWebKitPage(c.engineTab(for: spotify)) { note("marketing: MISSING drm-spotify: the page isn't WebKit's") }
            if c.protectedMediaToast == nil { c.protectedMediaPageShown(spotify) }
        }
        wait(0.8)
        mkWindowShot("drm-spotify")
        run { [self] in c.showSiteControls() }
        wait(1)
        mkWindowShot("drm-site-controls")
        run { [self] in
            _ = c.closeSiteControls(animated: false)
            c.closeTab(spotify)
        }
    }
}
#endif

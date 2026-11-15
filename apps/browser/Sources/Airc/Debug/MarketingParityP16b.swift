// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    func mkParityP16bShots(_ d: MarketingDemo) {
        var server: LocalPageServer?
        var id = ""
        let calls = MediaLibrary.shared.calls
        step { [self] done in
            server = LocalPageServer(pages: ["/call": P16bFixture.html + "<style>video{display:none}body{padding:36px}button{margin-right:6px}</style>"])
            server?.start { port in
                guard let port else { self.note("marketing: MISSING call-chat: fixture unavailable"); return done() }
                id = (try? self.c.store.openTab(url: "http://127.0.0.1:\(port)/call", inSpace: self.c.currentSpaceID, title: "Design review"))?.id ?? ""
                self.c.reloadAll(animated: false); self.c.show(id, focus: false); done()
            }
        }
        wait(2)
        run { [self] in
            CallTools.shared.update(id, page: c.engineTab(for: id), active: true)
            CallWindowController.followsWindowVisibility = false
            calls.open(id, .left)
        }
        // The call bar stays dark in both appearances. Capture both to catch
        // inherited black text in a light-mode hosting view, on either engine.
        for dark in [false, true] {
            run {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                calls.window?.appearance = NSApp.appearance
            }
            wait(1)
            step { [self] done in
                let name = dark ? "call-chat-dark" : "call-chat"
                guard let w = calls.window, let shot = mkServerImage(w) else {
                    note("marketing: MISSING \(name): no call window image"); return done()
                }
                let view = w.contentView as? CallWindowView
                check(view != nil && view?.showsCallTools == false,
                      "callcontrols: marketing call chat has only the provider row")
                let (canvas, origin) = MarketingStudio.canvas(around: w.frame.size)
                mkWrite(name, canvas: canvas, dark: dark, [
                    MarketingStudio.Layer(image: shot, frame: NSRect(origin: origin, size: w.frame.size), radius: 14, shadow: .panel)
                ])
                done()
            }
        }
        run { [self] in
            calls.returnPage(showing: false)
            CallTools.shared.update(id, page: nil, active: false)
            c.closeTab(id); server?.stop()
            CallWindowController.followsWindowVisibility = true
        }
    }
}
#endif

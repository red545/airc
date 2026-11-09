// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    func mkDeveloperModeShots() {
        var server: LocalPageServer?, port: UInt16 = 0
        // The demo app's own icon, which its row keeps in Developer Mode.
        let mark = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' rx='8' fill='#2f5d48'/>"
            + "<path d='M11 23V9h11v3.2h-7.4v2.6h6.4V18h-6.4v5z' fill='#f5f3ed'/></svg>"
        let icon = "<link rel=icon href='data:image/svg+xml;base64,\(Data(mark.utf8).base64EncodedString())'>"
        step { done in
            server = LocalPageServer(pages: ["/": """
            <!doctype html><title>Fieldwork · Local preview</title>\(icon)
            <style>
            *{box-sizing:border-box}body{margin:0;background:#f5f3ed;color:#243d32;font:17px -apple-system}
            nav{padding:34px 52px;border-bottom:1px solid #dce1d8;display:flex;justify-content:space-between}
            .tag{font:12px ui-monospace;color:#627567}main{padding:80px 70px}h1{font:64px Georgia;letter-spacing:-2px;margin:22px 0}
            p{max-width:560px;line-height:1.7;color:#69766c}.cards{display:flex;gap:22px;margin-top:60px}.card{padding:30px;background:#fff;border-radius:18px;flex:1;min-height:165px}.n{font:42px Georgia;margin:20px 0}.dot{color:#709477}
            </style><nav><b>Fieldwork</b><span class=tag>WORKSPACE / LOCAL PREVIEW</span></nav>
            <main><span class=tag>YOUR NEXT CHAPTER</span><h1>A little room to grow.</h1><p>A calm place for the projects taking shape.<br>Built here, one thoughtful detail at a time.</p>
            <div class=cards><div class=card><span class=tag>IN PROGRESS</span><div class=n>04</div><span class=dot>●</span> Making steady progress</div><div class=card><span class=tag>THIS WEEK</span><div class=n>12</div>Small things, shipped</div><div class=card><span class=tag>UP NEXT</span><div class=n>Friday</div>A fresh perspective</div></div></main>
            <script src="/app.js"></script>
            """])
            // The app's own bundle logs its errors, as a dev server's would (an inline script at parse time runs before
            // Airc has answered the document, and isn't counted: docs/user/devmode.md).
            server?.handler = { path in
                guard path == "/app.js" else { return nil }
                return .init(headers: ["Content-Type": "text/javascript"],
                             body: "console.error('Synthetic demo: preview API is offline'); console.error('Synthetic demo: missing preview image');",
                             delay: 0.2)
            }
            server?.start { port = $0 ?? 0; done() }
            if server == nil { done() }
        }
        run { [self] in
            // Arc: localhost is in Developer Mode by itself.
            if let app { DeveloperMode.shared.setAutomatic(true, app: app) }
            c.setSidebarWidth(300)
            if let t = try? c.store.openTab(url: "http://localhost:\(port)/", inSpace: c.currentSpaceID) {
                c.reloadAll(animated: false); c.show(t.id, focus: false)
            }
        }
        mkSettleShown()
        wait(0.5)
        mkWindowShot("developer-mode")
        // Site Controls' Developer Mode row: on by itself for localhost (Arc), a switch for any site.
        run { [self] in if c.siteControls == nil { c.toggleSiteControls() } }
        wait(0.8)
        mkWindowShot("developer-mode-site-controls")
        run { [self] in if c.siteControls != nil { c.toggleSiteControls() } }
        wait(0.4)
        run { [self] in
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try? c.store.updateSpace(c.currentSpaceID) { $0.theme.appearance = .dark }
            c.reloadAll(animated: false)
        }
        wait(0.5)
        mkWindowShot("developer-mode-dark", dark: true)
        run { [self] in c.setSidebarWidth(164) }
        wait(0.5)
        mkWindowShot("developer-mode-narrow", dark: true)
        run { server?.stop() }
    }
}
#endif

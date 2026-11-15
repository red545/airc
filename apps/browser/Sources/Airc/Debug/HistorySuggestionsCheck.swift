// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    /// Real engine visits, then real layout-aware keys through the stable UI driver.
    func historySuggestionsCheck() {
        guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
            run { [self] in check(false, "history check requires real keys in a dedicated UI session") }
            return
        }
        var server: LocalPageServer?
        var port: UInt16 = 0
        var profile = ""
        var urls: [String] = []
        step { done in
            server = LocalPageServer(pages: [:])
            server?.handler = { path in .init(body: "<title>Histsugg orchid \(path)</title><p>History fixture</p>") }
            server?.start { port = $0 ?? 0; done() }
        }
        run { [self] in
            check(port != 0, "histsugg: loopback listens")
            app?.settings.values.suggestionsEnabled = false
            profile = c.store.profile(ofSpace: c.currentSpaceID).id
            urls = (1...2).map { "http://127.0.0.1:\(port)/orchid\($0)" }
        }
        for i in 0..<2 {
            run { [self] in c.navigate(to: URL(string: urls[i])!, newTab: false) }
            step { [self] done in
                waitUntil({ self.app?.history.entry(profileID: profile, url: urls[i])?.title.contains("Histsugg") == true }, timeout: 10, then: done)
            }
            run { [self] in check(app?.history.entry(profileID: profile, url: urls[i]) != nil, "histsugg: engine visit \(i + 1) recorded") }
        }
        // Navigate away: the matches must be history, not the current tab.
        run { [self] in c.navigate(to: URL(string: "about:blank")!, newTab: false); c.closeCommandBar() }
        wait(0.5)
        step { [self] done in
            guard UIDriverClient.available, let keys = UIDriverClient.keys(typing: "histsugg") else {
                check(false, "histsugg: real driver available"); return done()
            }
            UIDriverClient.press(["cmd+t"] + keys, pid: getpid()) { ok, output in
                self.check(ok, "histsugg: real cmd+t and prefix keys (\(UIDriverClient.layoutName)): \(output)")
                done()
            }
        }
        wait(1)
        run { [self] in
            let rows = c.commandBar?.results.compactMap(\.historyURL) ?? []
            check(urls.allSatisfy { rows.contains($0) }, "histsugg: both visited pages appear as history rows (\(rows))")
            note("histsugg: query \(c.commandBar?.query ?? "nil"), stored \(app?.history.entries(ofProfile: profile).count ?? -1)")
            c.closeCommandBar()
            server?.stop()
        }
    }
}
#endif

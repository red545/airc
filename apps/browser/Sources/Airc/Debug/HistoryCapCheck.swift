// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    /// Import a large synthetic history, then visit a real loopback page and search with real keys.
    /// Bounded at 120 seconds: an old index queue may remain busy long after the app is usable again.
    func historyCapCheck(keepBrowsing: Bool = false) {
        guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
            run { [self] in check(false, "history check requires real keys in a dedicated UI session") }
            return
        }
        var server: LocalPageServer?
        var port: UInt16 = 0
        var profile = ""
        var started = 0.0
        var firstRows: Double?
        step { done in
            server = LocalPageServer(pages: [:])
            server?.handler = { _ in .init(body: "<title>Orchid visited page</title><p>History cap fixture</p>") }
            server?.start { port = $0 ?? 0; done() }
        }
        run { [self] in
            profile = c.store.profile(ofSpace: c.currentSpaceID).id
            app?.settings.values.suggestionsEnabled = false
            app?.history.clear(profileID: profile)
        }
        if keepBrowsing {
            run { [self] in c.navigate(to: URL(string: "http://127.0.0.1:\(port)/orchid-before")!, newTab: true) }
            step { [self] done in
                waitUntil({ self.app?.history.entry(profileID: profile, url: "http://127.0.0.1:\(port)/orchid-before")?.title.contains("Orchid") == true }, timeout: 10, then: done)
            }
            run { [self] in
                check(app?.history.entry(profileID: profile, url: "http://127.0.0.1:\(port)/orchid-before")?.title.contains("Orchid") == true,
                      "histcap: pre-import real page recorded")
            }
        }
        run { [self] in
            // Model a profile already searched by its user before the import crosses the cap.
            c.openCommandBar(mode: .newTab)
            app?.history.prepareIndex(profileID: profile)
        }
        step { [self] done in
            waitUntil({ self.app?.history.indexSnapshot(profileID: profile) != nil }, timeout: 10, then: done)
        }
        run { [self] in
            check(app?.history.indexSnapshot(profileID: profile) != nil, "histcap: pre-import index prepared")
            c.closeCommandBar()
            let old = Date().addingTimeInterval(-4 * 86400)
            let visits = (0..<25_000).map {
                HistoryEntry(profileID: profile, url: "https://history.example/orchid/\($0)", title: "Orchid imported page \($0)", lastVisit: old)
            }
            started = CACurrentMediaTime()
            app?.history.importVisits(visits)
            note(String(format: "histcap: imported 25000, retained %d; main-thread import/prune %.2f ms",
                        app?.history.entries(ofProfile: profile).count ?? -1, (CACurrentMediaTime() - started) * 1000))
            if keepBrowsing {
                let t = CACurrentMediaTime()
                let local = app?.history.localMatches("orchid", profileID: profile) ?? []
                note(String(format: "histcap: immediately after prune, local rows %d in %.3f ms", local.count, (CACurrentMediaTime() - t) * 1000))
                check(!local.isEmpty && local.allSatisfy { app?.history.entry(profileID: profile, url: $0.entry.url) != nil },
                      "histcap: retained local suggestions remain available immediately after prune")
            }
            c.navigate(to: URL(string: "http://127.0.0.1:\(port)/orchid-visit")!, newTab: true)
        }
        step { [self] done in
            waitUntil({ self.app?.history.entry(profileID: profile, url: "http://127.0.0.1:\(port)/orchid-visit") != nil }, timeout: 10, then: done)
        }
        run { [self] in
            check(app?.history.entry(profileID: profile, url: "http://127.0.0.1:\(port)/orchid-visit") != nil, "histcap: real navigation recorded after import")
            c.closeCommandBar()
        }
        step { [self] done in
            UIDriverClient.press(["cmd+t"], pid: getpid()) { ok, output in
                self.check(ok, "histcap: real Cmd+T (\(output))")
                done()
            }
        }
        step { [self] done in
            c.commandBar?.onHistoryApplied = { n in
                if n > 0, firstRows == nil { firstRows = CACurrentMediaTime() }
            }
            guard let keys = UIDriverClient.keys(typing: "orchid") else { check(false, "histcap: layout keys available"); return done() }
            UIDriverClient.press(keys, pid: getpid()) { ok, output in
                self.check(ok, "histcap: real prefix keys (\(output))")
                done()
            }
        }
        step { [self] done in
            waitUntil({ firstRows != nil }, timeout: 120, then: done)
        }
        run { [self] in
            let elapsed = ((firstRows ?? CACurrentMediaTime()) - started) * 1000
            let rows = c.commandBar?.results.compactMap(\.historyURL) ?? []
            note(String(format: "histcap: first history rows after import %@%.2f ms; visible rows %d; query %@",
                        firstRows == nil ? ">" : "", elapsed, rows.count, c.commandBar?.query ?? "nil"))
            check(firstRows != nil && !rows.isEmpty, "histcap: history suggestions recover within 120 seconds after a 25000-entry import")
            c.commandBar?.onHistoryApplied = nil
            c.closeCommandBar()
            if !keepBrowsing { server?.stop() }
        }
        if keepBrowsing {
            var browseStarted = 0.0
            for visit in 1...5 {
                run { [self] in
                    browseStarted = CACurrentMediaTime()
                    c.navigate(to: URL(string: "http://127.0.0.1:\(port)/orchid-browse-\(visit)")!, newTab: false)
                }
                step { [self] done in
                    waitUntil({ self.app?.history.entry(profileID: profile, url: "http://127.0.0.1:\(port)/orchid-browse-\(visit)")?.title.contains("Orchid") == true }, timeout: 10, then: done)
                }
                run { [self] in
                    check(app?.history.entry(profileID: profile, url: "http://127.0.0.1:\(port)/orchid-browse-\(visit)")?.title.contains("Orchid") == true &&
                          !(app?.history.localMatches("orchid", profileID: profile).isEmpty ?? true),
                          "histcap browsing \(visit): real visit recorded and local suggestions remain available")
                }
                step { [self] done in
                    guard let keys = UIDriverClient.keys(typing: "orchid") else { check(false, "histcap: layout keys available"); return done() }
                    UIDriverClient.press(["cmd+t"] + keys, pid: getpid()) { ok, output in
                        self.check(ok, "histcap browsing \(visit): real driver events, PID-targeted, foreground-verified (\(output))")
                        done()
                    }
                }
                run { [self] in
                    let rows = c.commandBar?.results.compactMap(\.historyURL) ?? []
                    check(c.commandBar?.query == "orchid" && !rows.isEmpty && rows.allSatisfy { app?.history.entry(profileID: profile, url: $0) != nil },
                          "histcap browsing \(visit): real Cmd+T shows retained history rows")
                    note(String(format: "histcap browsing %d: navigation plus real input to rows %.2f ms, rows %d", visit, (CACurrentMediaTime() - browseStarted) * 1000, rows.count))
                }
                if visit == 1 { capture("histsuggbrowse") }
                run { [self] in c.closeCommandBar() }
            }
            step { [self] done in
                waitUntil({ self.app?.history.indexSnapshot(profileID: profile)?.count == 18_006 }, timeout: 10, then: done)
            }
            run { [self] in
                check(app?.history.entries(ofProfile: profile).count == 18_006,
                      "histcap: hysteresis keeps subsequent visits without another prune")
                let latest = app?.history.localMatches("orchid", profileID: profile).contains(where: {
                    $0.entry.url == "http://127.0.0.1:\(port)/orchid-browse-5"
                }) == true
                check(app?.history.indexSnapshot(profileID: profile)?.count == 18_006 && latest,
                      "histcap: full index catches up and the newest browsing visit is searchable")
                server?.stop()
            }
        }
    }
}
#endif

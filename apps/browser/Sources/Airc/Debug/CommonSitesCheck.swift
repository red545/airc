// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// Part of `--script events` (`AIRC_EVENTS_ONLY=sites`): the Command Bar's built-in sites (CommonSites, CB-1).
/// 1. With nothing of this profile on Spotify, "spot" completes to "spotify.com" and Spotify is the first row.
/// 2. A site you visited ("spotlight.example.org") ranks first: it completes inline, Spotify comes after it.
/// 3. Spotify in your history shows once, as your page, not again as the built-in row.
/// Typing goes through the bar's field editor (`CommandBarView.type`), so it needs no key window.
extension SnapshotRunner {
    func commonSitesCheck() {
        var pid = ""
        let bar = { self.c.commandBar }
        func rows() -> [CommandResult] { bar()?.results ?? [] }
        func describe() -> String {
            "inline \"\(bar()?.inlineText ?? "-")\"; rows: " + rows().map { r -> String in
                if case .site = r.icon { return "[site] " + r.title }
                return r.title
            }.joined(separator: " | ")
        }
        func isSite(_ r: CommandResult, _ name: String) -> Bool {
            if case .site = r.icon { return r.title == name }
            return false
        }
        /// Opens the bar (after the history index caught up) and types `q`, then waits for the history answer.
        func open(typing q: String, after first: String? = nil) {
            step { [self] done in
                c.closeCommandBar()
                c.app?.history.prepareIndex(profileID: pid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done() }
            }
            step { [self] done in
                c.openCommandBar(mode: .newTab)
                // "sp" first: its rows (Spiegel, Splitwise…) start loading favicons that must not land on "spot"'s rows.
                if let first { bar()?.type(first) }
                DispatchQueue.main.asyncAfter(deadline: .now() + (first == nil ? 0 : 0.5)) {
                    bar()?.type(q)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { done() }
                }
            }
        }
        step { [self] done in
            pid = c.store.profile(ofSpace: c.currentSpaceID).id
            CommonSitesIndex.shared.prepare()
            waitUntil({ CommonSitesIndex.shared.snapshot != nil }, timeout: 5) {
                let s = CommonSitesIndex.shared.snapshot
                self.note("built-in sites: \(s?.count ?? 0) sites, index built in "
                          + String(format: "%.1f ms", CommonSitesIndex.shared.buildMilliseconds) + " off the main thread")
                done()
            }
        }
        // 1. No history of it.
        run { [self] in
            let mine = (c.app?.history.entries(ofProfile: pid) ?? []).filter {
                CommandSearch.score("spot", in: $0.title) != nil || URLRules.displayHost($0.url).contains("spot")
            }
            if !mine.isEmpty { note("built-in sites: this profile already has \(mine.count) \"spot\" pages") }
        }
        open(typing: "spot", after: "sp")
        run { [self] in
            let first = rows().first
            check(bar()?.inlineText == "spotify.com" && first.map { isSite($0, "Spotify") } == true
                  && rows().filter { $0.title == "Spotify" }.count == 1,
                  "built-in sites: with no history \"spot\" offers Spotify inline and first (\(describe()))")
            if case .open(let url)? = first?.action {
                check(url.absoluteString == "https://open.spotify.com", "built-in sites: Spotify opens \(url.absoluteString)")
            }
        }
        capture("command-bar-site")
        // 2. A visited site ranks first.
        run { [self] in
            for _ in 0..<3 {
                c.app?.history.recordVisit(profileID: pid, url: "https://spotlight.example.org/", title: "Spotlight — weekend picks",
                                           typed: true)
            }
        }
        open(typing: "spot")
        run { [self] in
            let r = rows()
            let spotify = r.firstIndex { isSite($0, "Spotify") }
            check(bar()?.inlineText == "spotlight.example.org" && r.first?.title == "spotlight.example.org"
                  && spotify.map { $0 > 0 } ?? true,
                  "built-in sites: a visited site ranks first, the built-in one after it (\(describe()))")
        }
        // 3. Spotify in your history: once, as yours.
        run { [self] in
            for _ in 0..<2 {
                c.app?.history.recordVisit(profileID: pid, url: "https://open.spotify.com/playlist/37i9dQZEVXcQ9COmYvdajy",
                                           title: "Discover Weekly – playlist by Spotify")
            }
        }
        open(typing: "spot")
        run { [self] in
            let r = rows()
            let builtIn = r.filter { isSite($0, "Spotify") }.count
            let mine = r.filter { $0.title == "Discover Weekly – playlist by Spotify" }.count
            check(builtIn == 0 && mine == 1 && bar()?.inlineText != "spotify.com",
                  "built-in sites: Spotify in history shows once, as the visited page (\(describe()))")
            // A prefix of a name of several words, and an alias, need no history either.
            bar()?.type("yt")
        }
        wait(0.3)
        run { [self] in
            check(rows().first.map { isSite($0, "YouTube") } == true, "built-in sites: \"yt\" puts YouTube first (\(describe()))")
            bar()?.type("google cal")
        }
        wait(0.3)
        run { [self] in
            check(rows().first.map { isSite($0, "Google Calendar") } == true,
                  "built-in sites: \"google cal\" puts Google Calendar first (\(describe()))")
            c.closeCommandBar()
        }
    }
}
#endif

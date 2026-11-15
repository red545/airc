// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// P12's shot, `--script marketing` part `parityp12` (`scripts/marketing-shots.sh --parts parityp12`):
///   - live-folders: the Work Space on linear.app with a "Pull Requests" Live Folder at the top of its pinned tabs,
///     open, its live glyph at the row's end, filled from a synthetic GitHub (AircKit's FakeGitHub on a loopback
///     port: fictional pull requests, a synthetic account kept in memory; only the rows' icon comes from github.com).
extension SnapshotRunner {
    func mkParityP12Shots(_ d: MarketingDemo) {
        let center = LiveFolderCenter.shared
        let gh = FakeGitHub(pageSize: 50)
        var server: P12FakeGitHubServer?
        var folder = ""
        mkShow(d, "work", "linear")
        mkPutAwaySignInCards()
        step { [self] done in
            let s = P12FakeGitHubServer(gh)
            server = s
            s.start { port in
                guard let port else { self.note("marketing: MISSING live-folders: no loopback port"); return done() }
                let base = "http://127.0.0.1:\(port)"
                // The API is the loopback fake; the rows link to github.com as real ones do (never loaded in the shot),
                // so they show GitHub's icon and no local address.
                gh.webBase = "https://github.com"
                gh.apiOrigin = base
                center.endpoint = GitHubEndpoint(api: URL(string: base)!, web: URL(string: base)!)
                center.http = URLSessionLiveHTTP(timeout: 5)
                center.accounts.inMemory = true
                done()
            }
        }
        run { [self] in
            let store = c.store
            guard let work = d.space["work"] else { return note("marketing: MISSING live-folders: no Work Space") }
            gh.addToken("demo-token", login: "sam")
            center.accounts.save(token: "demo-token", login: "sam", forProfile: store.profile(ofSpace: work).id)
            gh.open("airc-demo/app", 412, "Bump the design tokens to v3", author: "sam")
            gh.open("airc-demo/app", 418, "Onboarding: shorter first-run tour", author: "lee", reviewers: ["sam"])
            gh.open("airc-demo/site", 77, "Pricing page copy", author: "sam", labels: ["copy"])
            gh.open("airc-demo/app", 421, "Fix crash when closing a split", author: "ana", reviewers: ["sam"])
            gh.open("airc-demo/app", 423, "Draft: offline mode", author: "sam", draft: true)
            folder = center.create(query: .yours, title: nil, inSpace: work, store: store)?.id ?? ""
        }
        step { done in self.waitUntil({ !folder.isEmpty && !center.refreshing.contains(folder) }, timeout: 8) { done() } }
        run { [self] in
            let rows = c.store.children(of: .pinned(spaceID: d.space["work"] ?? ""), parent: folder).count
            note("marketing: live-folders: \(rows) pull requests")
            if rows < 5 { note("marketing: MISSING live-folders: the folder didn't fill (\(rows))") }
        }
        // linear.app fades its hero in after load: 8 s and 0.8 s left it black (P12's shot).
        mkSettleShown(extra: 3)
        step { [self] done in mkWindowShotNow("live-folders", dark: mkIsDark(), done) }
        run {
            server?.stop()
            center.stopUpdating(folder)
        }
    }

    /// No "Sign in to Google" card in the shot: each fresh demo profile has it put away, as its Not now does (as the
    /// social frames do, SocialFrames.swift).
    func mkPutAwaySignInCards() {
        run { [self] in
            for s in c.store.orderedSpaces where c.showsSignInCard(space: s) { c.dismissSignInCard(spaceID: s.id) }
        }
    }
}
#endif

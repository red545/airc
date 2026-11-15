// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script parityp07bc-real`: a manual smoke, never in the suite (it uses the real network). With the real on-device
/// model (no test override) and real results pages, synthetic queries only:
///   - Instant Links on the profile's built-in engine (Google) and on DuckDuckGo's HTML results page made the default
///     (P07d): what the resolver would open, the time, the path (first results or the model); the same links again
///     with their result marks taken away, so the real model picks; and once through the bar (⇧↵, preview, Return).
///   - Ask AI: each provider's address opened once in a new tab, its final address and title, and whether the question
///     shows on the page.
/// It logs NOTE lines with the evidence and PASS/FAIL only for what the code controls (a safe address, ≤ 5 links).
extension SnapshotRunner {
    func parityP07bcRealSmoke() {
        let tag = app?.engine is WebKitEngine ? "parityp07bc-real (WebKit)" : "parityp07bc-real (Chromium)"
        let queries = ["swift evolution proposals", "top 3 lisbon tram routes", "wwdc keynote video"]
        let profile = { self.c.store.profile(ofSpace: self.c.currentSpaceID) }
        var ddgID = ""
        var bar: CommandBarView? { self.c.commandBar }
        let model = InstantLinksFeature.model()
        var lastPlan: InstantLinksPlan?

        run { [self] in
            MainActor.assumeIsolated { AIFeatures.shared.testOverride = nil; AIFeatures.shared.refreshAvailability() }
            let availability = MainActor.assumeIsolated { AIFeatures.shared.availability }
            note("\(tag): Apple Intelligence: \(availability.label); real model: \(model != nil); macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            guard let s = app?.settings else { return }
            InstantLinksFeature.set(true, settings: s)
            check(s.values.instantLinks, "\(tag): Instant Links on with the real Apple Intelligence")
            if case .success(let site) = s.values.siteSearch.add(name: "DuckDuckGo HTML", keyword: "ddgh",
                                                                  template: "https://html.duckduckgo.com/html/?q=%s", to: profile().id) {
                ddgID = site.id
            }
        }

        func resolve(_ label: String, _ q: String, search: @escaping () -> DefaultSearch) {
            step { [self] done in
                let p = profile()
                let recorder = RecordingFetcher(HiddenResultsFetcher(profileID: p.id))
                let resolver = InstantLinksResolver(fetcher: recorder, model: model)
                let s = search()
                Task { @MainActor in
                    let t0 = CACurrentMediaTime()
                    let out = await resolver.resolve(q, search: s)
                    let t = CACurrentMediaTime() - t0
                    let links = recorder.links
                    let url = s.url(for: q) ?? URL(string: "about:blank")!
                    let candidates = InstantLinks.candidates(links, searchURL: url, search: s)
                    self.note("NOTE \(tag) \(label) “\(q)”: read \(links.count) links, \(candidates.count) candidates, \(candidates.filter(\.isResult).count) marked results, \(String(format: "%.2f", t)) s")
                    lastPlan = nil
                    switch out {
                    case .open(let plan):
                        lastPlan = plan
                        self.note("NOTE \(tag) \(label) “\(q)”: OPENS via \(plan.picker.rawValue): " + plan.links.map {
                            "\($0.title) <\($0.url.absoluteString.prefix(90))>" + ($0.displaySite.map { " shown as “\($0)”" } ?? "")
                        }.joined(separator: " | "))
                        self.check(plan.links.count <= InstantLinks.maxLinks && plan.links.allSatisfy { ["http", "https"].contains($0.url.scheme ?? "") }
                                   && plan.links.count == min(plan.requested, plan.links.count),
                                   "\(tag) \(label) “\(q)”: \(plan.links.count) of \(plan.requested) asked, all web pages")
                    case .search(let u, let why):
                        self.note("NOTE \(tag) \(label) “\(q)”: FALLBACK search (\(why.rawValue)) <\(u?.absoluteString ?? "-")>; \(links.filter(\.isResult).count) marked links; first links read: "
                                  + links.prefix(14).map { "\($0.title.prefix(32))\($0.isResult ? " [h]" : "") → \($0.href.prefix(70))" }.joined(separator: " | "))
                    case .cancelled:
                        self.note("NOTE \(tag) \(label) “\(q)”: cancelled")
                    }
                    // The same links without their result marks: the real model picks.
                    guard let model, !candidates.isEmpty else { return done() }
                    let replay = InstantLinksResolver(fetcher: ReplayFetcher(links.map { InstantLinksPageLink(title: $0.title, href: $0.href, isResult: false) }),
                                                      model: model)
                    let m0 = CACurrentMediaTime()
                    let mout = await replay.resolve(q, search: s)
                    let mt = CACurrentMediaTime() - m0
                    switch mout {
                    case .open(let plan):
                        self.note("NOTE \(tag) \(label) “\(q)”: MODEL picks in \(String(format: "%.2f", mt)) s: " + plan.links.map { "\($0.title) <\($0.url.absoluteString)>" }.joined(separator: " | "))
                    case .search(_, let why):
                        self.note("NOTE \(tag) \(label) “\(q)”: MODEL fell back (\(why.rawValue)) in \(String(format: "%.2f", mt)) s")
                    case .cancelled: break
                    }
                    done()
                }
            }
        }

        func barPass(_ label: String) {
            var before = Set<String>()
            run { [self] in
                before = Set(c.store.state.tabs.keys)
                c.openCommandBar(mode: .newTab)
                bar?.type("top 3 lisbon tram routes")
            }
            wait(0.5)
            run { [self] in bar?.shiftReturn() }
            step { [self] done in waitUntil({ bar?.instantStateLabel == "preview" || self.c.commandBar == nil }, timeout: 20, then: done) }
            run { [self] in
                note("NOTE \(tag) bar on \(label): state \(bar?.instantStateLabel ?? "closed"); rows: \(bar?.resultTitles.joined(separator: " | ") ?? "-")")
                if bar?.instantStateLabel == "preview" { bar?.shiftReturn() }
            }
            step { [self] done in
                waitUntil({ self.c.engineTab(for: self.c.shownTabID ?? "")?.isLoading == false && !Set(self.c.store.state.tabs.keys).subtracting(before).isEmpty }, timeout: 20) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: done)
                }
            }
            run { [self] in
                let page = c.engineTab(for: c.shownTabID ?? "")
                let opened = c.store.state.tabs.values.filter { !before.contains($0.id) }.map(\.url)
                note("NOTE \(tag) bar on \(label): opened \(opened.count) tab(s) \(opened) — shown “\(page?.title ?? "-")” <\(page?.url?.absoluteString ?? "-")>")
            }
        }

        /// Confirms the last plan as ⇧↵ / Return would (`openInstantLinks`), then reads where each tab ended up and whether
        /// it's the site the preview named.
        func confirm(_ label: String, _ q: String) {
            var before = Set<String>()
            var opened: [String] = []
            run { [self] in
                guard let plan = lastPlan else { return }
                before = Set(c.store.state.tabs.keys)
                c.openInstantLinks(plan.links, newTab: true)
            }
            step { [self] done in
                guard lastPlan != nil else { return done() }
                // Background tabs load when shown: show each in turn and wait for it to leave Google's redirect.
                var ids = Array(Set(self.c.store.state.tabs.keys).subtracting(before))
                func next() {
                    guard let id = ids.popLast() else { return DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: done) }
                    self.c.show(id, focus: false)
                    self.waitUntil({
                        let u = self.c.engineTab(for: id)?.url?.absoluteString ?? self.c.store.tab(id)?.url ?? ""
                        return !u.isEmpty && !(u.contains("google.") && u.contains("/goto")) && self.c.engineTab(for: id)?.isLoading == false
                    }, timeout: 20) { next() }
                }
                next()
            }
            run { [self] in
                guard let plan = lastPlan else { return }
                opened = c.store.state.tabs.values.filter { !before.contains($0.id) }.map { c.engineTab(for: $0.id)?.url?.absoluteString ?? $0.url }
                var matched = 0
                for l in plan.links {
                    let want = l.host
                    let hit = opened.contains { u in
                        var h = URL(string: u)?.host?.lowercased() ?? ""
                        if h.hasPrefix("www.") { h.removeFirst(4) }
                        return h == want || h.hasSuffix("." + want) || want.hasSuffix("." + h)
                    }
                    if hit { matched += 1 }
                }
                note("NOTE \(tag) \(label) “\(q)”: CONFIRMED, \(opened.count) tab(s) ended at \(opened.map { String($0.prefix(90)) }); \(matched) of \(plan.links.count) on the site the preview named")
                check(matched == plan.links.count && opened.count == plan.links.count, "\(tag) \(label) “\(q)”: every opened tab is the site the preview named")
                for t in c.store.state.tabs.values where !before.contains(t.id) { c.closeTab(t.id) }
            }
        }

        // Google, the profile's built-in engine.
        run { [self] in
            app?.settings.values.siteSearch.setDefault(nil, for: profile().id)
            note("\(tag): default search \(profile().defaultSearch.name)")
        }
        for q in queries { resolve("Google", q) { profile().defaultSearch }; confirm("Google", q) }
        barPass("Google")
        // A fresh profile meets Google's cookie consent (EU): answer it in the shown page as a person would, with "Reject
        // all" (this run's ephemeral profile only), then ask again.
        step { [self] done in
            guard let page = c.engineTab(for: c.shownTabID ?? "") else { return done() }
            let js = """
            (function(){var re=/^(Alle ablehnen|Reject all|Tout refuser|Rifiuta tutto|Rechazar todo)$/i;
            var b=[].slice.call(document.querySelectorAll('button,[role=button],input[type=submit]')).filter(function(e){return re.test(((e.innerText||e.value||'')+'').trim())});
            if(!b.length)return 'none'; b[0].click(); return 'clicked: '+((b[0].innerText||b[0].value||'')+'').trim()})()
            """
            page.evaluate(js) { v in
                self.note("NOTE \(tag) Google consent: \(v ?? "no answer")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: done)
            }
        }
        for q in queries { resolve("Google (consent answered)", q) { profile().defaultSearch }; confirm("Google (consent answered)", q) }
        // DuckDuckGo's HTML results page, made the profile's default (P07d).
        run { [self] in
            app?.settings.values.siteSearch.setDefault(ddgID, for: profile().id)
            note("\(tag): default search \(profile().defaultSearch.name)")
        }
        for q in queries { resolve("DuckDuckGo HTML", q) { profile().defaultSearch } }
        barPass("DuckDuckGo HTML")
        run { [self] in app?.settings.values.siteSearch.setDefault(nil, for: profile().id) }

        // Ask AI: each provider's real address, once.
        let prompt = "What is a monad? Answer in one sentence."
        for p in AskAIProvider.allCases {
            var tabs = Set<String>()
            run { [self] in
                app?.settings.values.askAI.set(p, for: profile().id)
                tabs = Set(c.store.state.tabs.keys)
                c.openCommandBar(mode: .newTab)
                bar?.enterScope(.ask(p), origin: "")
                bar?.type(prompt)
            }
            wait(0.4)
            run { [self] in
                guard let row = bar?.results.first else { return check(false, "\(tag): \(p.name) row") }
                if case .open(let u) = row.action { note("NOTE \(tag) \(p.name): asks <\(u.absoluteString)>") }
                c.closeCommandBar()
                c.performCommand(row.action, newTab: true, typed: false)
            }
            step { [self] done in
                waitUntil({ self.c.engineTab(for: self.c.shownTabID ?? "")?.isLoading == false && !Set(self.c.store.state.tabs.keys).subtracting(tabs).isEmpty }, timeout: 25) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: done)   // the site's own scripts
                }
            }
            step { [self] done in
                guard let page = c.engineTab(for: c.shownTabID ?? "") else { return done() }
                let js = """
                (function(){var q=\(String(reflecting: "monad"));var f=[].slice.call(document.querySelectorAll('textarea,input,[contenteditable=true],#prompt-textarea'));
                var inField=f.some(function(e){return ((e.value||e.innerText||'')+'').toLowerCase().indexOf(q)>=0});
                var inPage=((document.body&&document.body.innerText)||'').toLowerCase().indexOf(q)>=0;
                return {field:inField,page:inPage}})()
                """
                page.evaluate(js) { v in
                    let d = v as? [String: Any]
                    self.note("NOTE \(tag) \(p.name): opened “\(page.title)” <\(page.url?.absoluteString ?? "-")>; question in a field: \(d?["field"] ?? "-"), on the page: \(d?["page"] ?? "-")")
                    done()
                }
            }
        }
        run { [self] in
            app?.settings.values.askAI.set(nil, for: profile().id)
            app?.settings.values.instantLinks = false
            note("\(tag): done")
        }
    }
}

/// The smoke's fetcher: the real one, keeping what it read.
private final class RecordingFetcher: InstantLinksFetcher, @unchecked Sendable {
    private let inner: any InstantLinksFetcher
    private let lock = NSLock()
    private var _links: [InstantLinksPageLink] = []
    var links: [InstantLinksPageLink] { lock.withLock { _links } }
    init(_ inner: any InstantLinksFetcher) { self.inner = inner }
    func links(on searchURL: URL) async throws -> [InstantLinksPageLink] {
        let l = try await inner.links(on: searchURL)
        lock.withLock { _links = l }
        return l
    }
}

private struct ReplayFetcher: InstantLinksFetcher {
    let stored: [InstantLinksPageLink]
    init(_ stored: [InstantLinksPageLink]) { self.stored = stored }
    func links(on searchURL: URL) async throws -> [InstantLinksPageLink] { stored }
}
#endif

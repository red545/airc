// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script paritybangs` (docs/user/command-bar.md, "Bangs"): DuckDuckGo-style bangs in the Command Bar.
///
/// - "!yt test" → the first row "Search YouTube for “test”", no inline completion over the bang, Return opens YouTube's
///   results for "test"; "!gm vienna" → Google Maps; "hello !lb" → the profile's own site search "lb".
/// - "!yt" alone + Tab starts YouTube's site search; Backspace in its empty field puts "!yt" back.
/// - An unknown bang ("!nosuchbang") stays a normal search.
/// - Airc's sites (built-in bangs, seeded site searches) go to a loopback stand-in (SearchEngineStandIn), so the check
///   sees which site and address were asked and nothing leaves the Mac; the profile's own site is a loopback address.
///
/// With AIRC_REAL_KEYS=1 (and AIRC_REAL_CLICKS=1, AIRC_LA_AS_OWNER=1 for activation), text and keys are real key presses
/// through the stable UI driver, PID-targeted; otherwise text goes in through the field editor and keys through the
/// app's own event path (as parityp07). AIRC_BANGS_TIMING=1 adds per-key timings (a timing run: declare it).
extension SnapshotRunner {
    func parityBangsScenario() {
        var server: LocalPageServer?
        var port: UInt16 = 0
        let lock = NSLock()
        var requests: [String] = []
        var home = ""
        var bar: CommandBarView? { self.c.commandBar }
        let real = UIDriverClient.requested
        func requested(_ target: String) -> Bool { lock.withLock { requests.contains(target) } }
        func lastRequest() -> String { lock.withLock { requests.last ?? "none" } }
        func shown() -> String? { c.engineTab(for: c.shownTabID ?? "")?.url?.absoluteString }

        func openBar() {
            run { [self] in
                c.closeCommandBar()
                c.openCommandBar(mode: .newTab)
                bar?.keyLog = []
            }
            wait(0.2)
        }

        /// What's typed: real keys (the layout's own keys for each character) or the field editor's insertText.
        func typeText(_ text: String, _ what: String) {
            step { [self] done in
                if real {
                    guard let keys = UIDriverClient.keys(typing: text) else {
                        note("FAIL-ENV paritybangs [real keys] \(what): \(UIDriverClient.layoutName) can't type “\(text)”")
                        return done()
                    }
                    UIDriverClient.press(keys, pid: getpid()) { ok, out in
                        if !ok { self.note("FAIL-ENV paritybangs [real keys] \(what): \(out)") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
                    }
                } else {
                    for ch in text { bar?.type((bar?.query ?? "") + String(ch)) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: done)
                }
            }
        }

        func key(_ k: P07Key) {
            step { [self] done in
                if real {
                    let combo: String = switch k {
                    case .tab: "tab"
                    case .backspace: "delete"
                    case .escape: "esc"
                    case .enter: "return"
                    default: "space"
                    }
                    UIDriverClient.press([combo], pid: getpid()) { ok, out in
                        self.check(ok, "paritybangs real key \(k): driver delivered (\(out))")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: done)
                    }
                    return
                }
                let before = bar?.keyLog.count ?? 0
                NSApp.sendEvent(Self.keyEvent(k, window: c.window))
                if let log = bar?.keyLog, !log.dropFirst(before).contains(where: { k.evidence.contains($0) }) {
                    c.window.sendEvent(Self.keyEvent(k, window: c.window))
                }
                NSApp.sendEvent(Self.keyEvent(k, window: c.window, type: .keyUp))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: done)
            }
        }

        func waitFor(_ condition: @escaping () -> Bool, timeout: Double = 4) {
            step { [self] done in waitUntil(condition, timeout: timeout, then: done) }
        }

        if real { activateForRealInput() }
        step { done in
            server = LocalPageServer(pages: [:])
            server?.requestHandler = { r in
                lock.withLock { requests.append(r.target) }
                return LocalPageServer.Page(body: "<title>Bang result</title><p>ok</p>")
            }
            server?.start { p in port = p ?? 0; done() }
        }
        run { [self] in
            note("paritybangs: engine \(app?.engine.name ?? "?"), real keys \(real), app active \(NSApp.isActive), key window \(c.window.isKeyWindow), "
                 + "on active Space \(c.window.isOnActiveSpace), layout \(Self.layoutName)")
            check(port != 0, "paritybangs: loopback listens")
            SearchEngineStandIn.origin = "http://127.0.0.1:\(port)"
            app?.settings.values.suggestionsEnabled = false
            if !real { Self.emulateKeyWindow(c) { [weak self] in self?.note($0) } }
            home = c.store.profile(ofSpace: c.currentSpaceID).id
            guard var s = app?.settings.values.siteSearch else { return check(false, "paritybangs: settings") }
            if case .failure(let p) = s.add(name: "Loopback", keyword: "lb", template: "http://127.0.0.1:\(port)/find?q=%s", to: home) {
                check(false, "paritybangs: own site search added (\(p.message))")
            }
            app?.settings.values.siteSearch = s
            // A page that starts like "!y…" can't exist, but give the bar something to complete for "y…" and "t…".
            app?.history.recordVisit(profileID: home, url: "https://www.youtube.com/", title: "YouTube", typed: true)
            app?.history.recordVisit(profileID: home, url: "https://test.example.org/", title: "test page", typed: true)
            c.reloadAll(animated: false)
        }
        wait(1.0)

        /// Types `text`, checks the first row and what Return opens: `path` on the loopback (or `full`, a whole address).
        func bangCase(_ label: String, _ text: String, row: String, target: String) {
            uiCase(window: { self.c.window }) {
                openBar()
                typeText(text, label)
                waitFor({ bar?.query == text })
                run { [self] in
                    let first = bar?.results.first
                    let want = "http://127.0.0.1:\(port)" + target
                    check(bar?.fieldText == text && bar?.inlineText == nil,
                          "paritybangs \(label): the field shows “\(text)” as typed, nothing completed (“\(bar?.fieldText ?? "-")”, inline \(bar?.inlineText ?? "none"))")
                    check(first?.title == row && Self.url(of: first) == want,
                          "paritybangs \(label): first row “\(row)” → \(want) (\(first?.title ?? "none") → \(Self.url(of: first) ?? "none"); \(bar?.resultTitles.prefix(3) ?? []))")
                    if case .site(let page, _)? = first?.icon { note("paritybangs \(label): row icon from \(page)") }
                }
                key(.enter)
                waitFor({ requested(target) }, timeout: 10)
                waitFor({ shown() == "http://127.0.0.1:\(port)" + target }, timeout: 5)
                run { [self] in
                    let want = "http://127.0.0.1:\(port)" + target
                    check(c.commandBar == nil && requested(target) && shown() == want,
                          "paritybangs \(label): Return opens it (asked \(lastRequest()), shown \(shown() ?? "none"))")
                }
            }
        }

        bangCase("A", "!yt test", row: "Search YouTube for “test”", target: "/www.youtube.com/results?search_query=test")
        bangCase("B", "!gm vienna", row: "Search Google Maps for “vienna”", target: "/www.google.com/maps/search/vienna")
        bangCase("C", "hello !lb", row: "Search Loopback for “hello”", target: "/find?q=hello")
        bangCase("D", "Ein Test !YT", row: "Search YouTube for “Ein Test”", target: "/www.youtube.com/results?search_query=Ein+Test")

        // E: a bang alone, then Tab: YouTube's site search; Backspace in its empty field puts "!yt" back.
        uiCase(window: { self.c.window }) {
            openBar()
            typeText("!yt", "E")
            waitFor({ bar?.query == "!yt" })
            run { [self] in
                let first = bar?.results.first
                check(first?.title == "Search YouTube" && first?.startsScope != nil && bar?.siteCandidate?.name == "YouTube",
                      "paritybangs E: “!yt” alone → “Search YouTube · Press Return or Tab” first (\(bar?.resultTitles.prefix(2) ?? []))")
            }
            key(.tab)
            run { [self] in
                check(bar?.scope?.name == "YouTube" && bar?.fieldText == "", "paritybangs E: Tab starts YouTube's search (\(bar?.scope?.name ?? "none"))")
            }
            key(.backspace)
            run { [self] in check(bar?.scope == nil && bar?.fieldText == "!yt", "paritybangs E: Backspace leaves it, “!yt” back (“\(bar?.fieldText ?? "-")”)") }
            run { [self] in c.closeCommandBar() }
        }

        // F: an unknown bang is a normal search; "!" alone and a URL with "!" are no bangs.
        uiCase(window: { self.c.window }) {
            for text in ["!nosuchbang cats", "!", "example.com/#!/yt"] {
                openBar()
                typeText(text, "F")
                waitFor({ bar?.query == text })
                run { [self] in
                    let first = bar?.results.first
                    check(bar?.bang == nil && first?.subtitle.hasPrefix("!") != true && bar?.fieldText.hasPrefix(text) == true,
                          "paritybangs F: “\(text)” isn't a bang (\(bar?.resultTitles.prefix(2) ?? []))")
                }
            }
            run { [self] in c.closeCommandBar() }
        }

        // Screenshots last: a capture hides the bar's views while it renders the page, which takes the field's focus,
        // so no key may follow one.
        for (name, text) in [("bangs-yt", "!yt test"), ("bangs-gm", "!gm vienna"), ("bangs-own", "hello !lb"), ("bangs-alone", "!yt")] {
            run { [self] in c.closeCommandBar(); c.openCommandBar(mode: .newTab); bar?.type(text) }
            wait(0.4)
            capture(name)
        }
        run { [self] in c.closeCommandBar() }

        if ProcessInfo.processInfo.environment["AIRC_BANGS_TIMING"] == "1" {
            var bang: [Double] = [], plain: [Double] = []
            for i in 0..<10 {
                for (list, prefix) in [(0, "!yt cat"), (1, "cat")] {
                    run { [self] in c.closeCommandBar(); c.openCommandBar(mode: .newTab); bar?.type(prefix) }
                    wait(0.15)
                    step { [self] done in
                        guard let b = bar else { return done() }
                        FrameTiming.measure({ b.type(prefix + (i % 2 == 0 ? "s" : "z")) }) { t in
                            if list == 0 { bang.append(t.work) } else { plain.append(t.work) }
                            done()
                        }
                    }
                }
            }
            run { [self] in
                c.closeCommandBar()
                func med(_ a: [Double]) -> Double { a.isEmpty ? -1 : a.sorted()[a.count / 2] }
                note(String(format: "paritybangs timing: keystroke main thread, bang text %.2f ms (max %.2f), plain text %.2f ms (max %.2f); load %@",
                            med(bang), bang.max() ?? -1, med(plain), plain.max() ?? -1, Self.loadAverage()))
            }
        }

        run {
            SearchEngineStandIn.origin = nil
            server?.stop()
        }
    }
}
#endif

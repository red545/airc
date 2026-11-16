// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script cbflicker` (owner bug, 0.1.18): the Command Bar's search suggestion rows must never disappear while you
/// type. Live suggestions on, as a real user has them, from a loopback stand-in for the profile's engine
/// (SearchEngineStandIn) that answers each query after 30–150 ms. A word is typed one key at a time; every time the bar
/// makes its rows (`onRowsReloaded`: what the next frame shows) the suggestion rows are counted. Once suggestions have
/// shown, any state with none of them while the word grows is a FAIL, as is a final list that isn't the last answer.
///
/// Passes: real keys (AIRC_REAL_KEYS=1: the stable UI driver, ~0.3 s apart, PID-targeted), then keys faster than the
/// answers (the field editor's insertText every 40 ms, so answers overlap keys). `AIRC_CB_KEEP_SUGGESTIONS=0` brings
/// back the old clearing (it must fail); `AIRC_CB_KEYFRAME2=0` bisects keyframe2.
extension SnapshotRunner {
    func commandBarFlickerCheck() {
        var server: LocalPageServer?
        var port: UInt16 = 0
        let lock = NSLock()
        var answered = 0
        var bar: CommandBarView? { self.c.commandBar }
        let real = UIDriverClient.requested
        /// Each rows state while typing: (what's typed, suggestion rows).
        var states: [(String, Int)] = []
        var recording = false

        /// The stand-in's answer: three suggestions that start with the words.
        func answer(_ q: String) -> [String] { [q + " forecast", q + " today", q + " radar"] }

        if real { activateForRealInput() }
        step { done in
            server = LocalPageServer(pages: [:])
            var n = 0
            server?.requestHandler = { r in
                guard r.target.contains("q="),
                      let q = URLComponents(string: "http://x" + r.target)?.queryItems?.first(where: { $0.name == "q" })?.value
                else { return nil }
                // 30–150 ms, varied: the answer comes after a real engine's usual delay.
                n += 1
                lock.withLock { answered += 1 }
                let list = answer(q).map { "\"\($0)\"" }.joined(separator: ",")
                return LocalPageServer.Page(headers: ["Content-Type": "application/json"], body: "[\"\(q)\",[\(list)]]",
                                            delay: Double(30 + n * 37 % 121) / 1000)
            }
            server?.start { p in port = p ?? 0; done() }
        }
        run { [self] in
            check(port != 0, "cbflicker: loopback suggestion endpoint listens")
            SearchEngineStandIn.origin = "http://127.0.0.1:\(port)"
            app?.settings.values.suggestionsEnabled = true
            if !real { Self.emulateKeyWindow(c) { [weak self] in self?.note($0) } }
            note("cbflicker: engine \(app?.engine.name ?? "?"), real keys \(real), keep suggestions \(CommandBarView.keepsSuggestions), "
                 + "keyframe2 \(ProcessInfo.processInfo.environment["AIRC_CB_KEYFRAME2"] ?? "on"), app active \(NSApp.isActive), "
                 + "key window \(c.window.isKeyWindow), load \(Self.loadAverage())")
        }

        func pass(_ label: String, word: String, gap: Double, realKeys: Bool) {
            run { [self] in
                c.closeCommandBar()
                c.openCommandBar(mode: .newTab)
                states = []
                recording = true
                bar?.onRowsReloaded = { b in if recording { states.append((b.query, b.suggestionRowCount)) } }
            }
            wait(0.2)
            for ch in word {
                step { [self] done in
                    if realKeys {
                        UIDriverClient.press(UIDriverClient.keys(typing: String(ch)) ?? [String(ch)], pid: getpid()) { ok, out in
                            if !ok { self.note("FAIL-ENV cbflicker [real keys] \(label) “\(ch)”: \(out)") }
                            DispatchQueue.main.asyncAfter(deadline: .now() + gap, execute: done)
                        }
                    } else {
                        bar?.type((bar?.query ?? "") + String(ch))
                        DispatchQueue.main.asyncAfter(deadline: .now() + gap, execute: done)
                    }
                }
            }
            step { [self] done in
                waitUntil({ bar?.suggestionRowCount ?? 0 > 0 && bar?.results.contains { $0.title == answer(word)[0] } == true }, timeout: 3, then: done)
            }
            run { [self] in
                recording = false
                bar?.onRowsReloaded = nil
                let typedAll = bar?.query == word
                // From the first state with suggestions on, while the words have two letters or more.
                let start = states.firstIndex { $0.1 > 0 } ?? states.count
                let after = states[start...].filter { $0.0.count >= 2 }
                let empty = after.filter { $0.1 == 0 }
                let counts = states.map { "\($0.0):\($0.1)" }.joined(separator: " ")
                note("cbflicker \(label): rows states \(states.count), answers so far \(lock.withLock { answered }): \(counts)")
                check(typedAll, "cbflicker \(label): “\(word)” typed (field “\(bar?.query ?? "-")”)")
                check(start < states.count && empty.isEmpty,
                      "cbflicker \(label): suggestion rows never drop to 0 while typing (\(empty.count) of \(after.count) states had none: \(empty.map(\.0)))")
                let shown = bar?.results.filter { $0.badge == "Search" && $0.subtitle.isEmpty }.map(\.title) ?? []
                check(shown == answer(word), "cbflicker \(label): the last answer's suggestions are shown (\(shown))")
                c.closeCommandBar()
            }
        }

        if real { pass("real keys", word: "weather", gap: 0.05, realKeys: true) }
        pass("fast keys", word: "lisbon trams", gap: 0.04, realKeys: false)
        pass("slow keys", word: "vienna", gap: 0.25, realKeys: false)

        // An address or one letter gets no suggestions: none are kept for it.
        run { [self] in
            c.openCommandBar(mode: .newTab)
            bar?.type("weather")
        }
        step { [self] done in waitUntil({ bar?.suggestionRowCount ?? 0 > 0 }, timeout: 3, then: done) }
        run { [self] in
            bar?.type("w")
            check(bar?.suggestionRowCount == 0, "cbflicker: one letter keeps no suggestions (\(bar?.suggestionRowCount ?? -1))")
            bar?.type("example.com/weather")
            check(bar?.suggestionRowCount == 0, "cbflicker: an address keeps no suggestions (\(bar?.suggestionRowCount ?? -1))")
            c.closeCommandBar()
            SearchEngineStandIn.origin = nil
            server?.stop()
        }
    }
}
#endif

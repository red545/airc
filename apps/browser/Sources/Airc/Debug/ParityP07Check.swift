// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script parityp07` (P07a, docs/user/command-bar.md): Arc's Site Search and suggestion deletion in the Command Bar.
///
/// - Site Search: a shortcut ("yt") or the start of a name ("you"), then Tab (or Space where the profile allows it),
///   starts the site's search; the pill, the placeholder, Backspace on an empty query and Esc leave it; Return opens the
///   query percent-encoded as Chromium encodes it (a loopback site sees the bytes: query and path forms).
/// - Profiles keep their own sites and their own Tab / "Space or Tab" choice; malformed templates are refused; the
///   lists survive a settings reload.
/// - Input methods: marked text (pinyin "you", Japanese とうきょう) is never completed, replaced or turned into a site
///   search, in the plain bar and in a site search, through NSTextInputClient's marked-text calls on the field editor.
/// - ⌥⌘⌫ (Arc) removes the highlighted history suggestion; ⇧⌫ on a row you didn't move to stays a text deletion.
/// - Timings as cblocal's: the keystroke's main-thread work and the time to its Core Animation commit, rows checked
///   before that commit.
///
/// Keys are real key events through the app's own event path: `NSApp.sendEvent` (the app's key monitor, then the key
/// window, with the shortcuts check's key-window stand-in, since scripted runs are never key), and the window's own
/// `sendEvent` when that didn't reach the field editor (a window off the active Space). Never HID events. Text goes in
/// through the field editor's `insertText`, as an input method commits it. A key that didn't arrive while the window
/// was off the active Space, covered or locked is FAIL-ENV, with the evidence.
extension SnapshotRunner {
    func parityP07Scenario() {
        var server: LocalPageServer?
        var port: UInt16 = 0
        let requestLock = NSLock()
        var requests: [String] = []
        var home = "", work = "", homeSpace = "", workSpace = ""
        let youtubeVideo = "https://www.youtube.com/watch?v=p07quokka"
        let deletable = "https://history.example.org/p07-deletable"
        var bar: CommandBarView? { self.c.commandBar }
        /// Which path delivered each key ("app": NSApp.sendEvent; "window": the window's sendEvent).
        var keyPaths: [String: Int] = [:]
        func requested(_ p: String) -> Bool { requestLock.withLock { requests.contains(p) } }

        // MARK: Steps

        func editor() -> NSTextView? { c.window.firstResponder as? NSTextView }

        func openBar() {
            run { [self] in
                c.closeCommandBar()
                c.openCommandBar(mode: .newTab)
                bar?.keyLog = []
            }
            wait(0.15)
        }

        func closeBar() { run { [self] in c.closeCommandBar() } }

        /// As an input method commits text: through the field editor at its selection (CommandBarView.type).
        func typeText(_ text: String) {
            step { [self] done in
                bar?.type(text)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: done)
            }
        }

        /// A key through the app's own event path: `NSApp.sendEvent` (the app's key monitor, then the key window,
        /// here the key-window stand-in). If the field editor didn't get it (a window off the active Space doesn't
        /// always), the window's own `sendEvent` (its first responder, the field editor). Never HID events. The bar's
        /// key log shows where it landed: the delivery evidence (`P07Key.evidence`), and which path is logged.
        func key(_ k: P07Key) {
            step { [self] done in
                let before = bar?.keyLog.count ?? 0
                func arrived() -> Bool {
                    guard let log = self.c.commandBar?.keyLog else { return true }   // Esc closed the bar
                    return log.dropFirst(before).contains { k.evidence.contains($0) }
                }
                NSApp.sendEvent(Self.keyEvent(k, window: c.window))
                var path = "app"
                if !arrived(), !k.monitorOnly {
                    c.window.sendEvent(Self.keyEvent(k, window: c.window))
                    path = "window"
                }
                NSApp.sendEvent(Self.keyEvent(k, window: c.window, type: .keyUp))
                waitUntil({ arrived() }, timeout: 0.5) {
                    let delivered = arrived()
                    self.uiAttempt?.recordInputDelivery(delivered)
                    keyPaths[path, default: 0] += delivered ? 1 : 0
                    if !delivered { self.note("parityp07: \(k) not delivered (\(self.inputBlocked ?? "no reason seen"))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: done)
                }
            }
        }

        func waitFor(_ condition: @escaping () -> Bool, timeout: Double = 3) {
            step { [self] done in waitUntil(condition, timeout: timeout, then: done) }
        }

        step { done in
            server = LocalPageServer(pages: [:])
            server?.handler = { path in
                requestLock.withLock { requests.append(path) }
                return LocalPageServer.Page(body: "<title>P07 result</title><p>ok</p>")
            }
            server?.start { p in port = p ?? 0; done() }
        }
        run { [self] in
            note("parityp07: engine \(app?.engine.name ?? "?"), window on active Space \(c.window.isOnActiveSpace), "
                 + "visible \(c.window.occlusionState.contains(.visible)), screen locked \(Self.screenLocked), "
                 + "input \(inputBlocked ?? "free"), layout \(Self.layoutName)")
            check(port != 0, "parityp07: loopback search site listens")
            app?.settings.values.suggestionsEnabled = false
            Self.emulateKeyWindow(c) { [weak self] in self?.note($0) }
            home = c.store.profile(ofSpace: c.currentSpaceID).id
            homeSpace = c.currentSpaceID
            do {
                let p = try c.profiles.createProfile(name: "Work", emoji: "💼", color: RGBA(hex: "7EB6D5"))
                work = p.id
                workSpace = try c.store.createSpace(name: "Work", icon: .emoji("💼"), profileID: p.id, after: homeSpace).id
            } catch {
                check(false, "parityp07: second profile and Space (\(error))")
            }
            guard var s = app?.settings.values.siteSearch else { return }
            let lb = s.add(name: "Loopback", keyword: "lb", template: "http://127.0.0.1:\(port)/find?q=%s", to: work)
            let lp = s.add(name: "Loopback Path", keyword: "lp", template: "http://127.0.0.1:\(port)/search/%s", to: work)
            let ho = s.add(name: "Home Only", keyword: "ho", template: "http://127.0.0.1:\(port)/home?q=%s", to: home)
            check(lb.isSuccess && lp.isSuccess && ho.isSuccess, "parityp07: custom sites added per profile")
            // Malformed templates are refused and change nothing.
            let before = s
            let refused = ["javascript:alert(%s)", "https://%s.example.com/", "https://example.com/search?q=", "data:text/html,%s",
                           "https://exa mple.com/?q=%s", "file:///etc/%s"].map { s.add(name: "Bad", keyword: "bad", template: $0, to: work) }
            check(refused.allSatisfy { !$0.isSuccess } && s == before, "parityp07: malformed templates refused (\(refused.compactMap(\.problem).joined(separator: " | ")))")
            check(!s.add(name: "Clash", keyword: "LB", template: "https://e.example/?q=%s", to: work).isSuccess && s == before,
                  "parityp07: a shortcut taken in the profile is refused, ignoring case")
            s.setSpaceTriggers(true, for: work)
            app?.settings.values.siteSearch = s
            app?.history.recordVisit(profileID: home, url: youtubeVideo, title: "P07 quokka video", typed: true)
            app?.history.recordVisit(profileID: home, url: deletable, title: "P07 deletable quokka page", typed: true)
            app?.history.recordVisit(profileID: home, url: "https://elsewhere.example.org/p07", title: "P07 quokka elsewhere", typed: true)
            c.reloadAll(animated: false)
            c.switchToSpace(homeSpace, animated: false)
        }
        wait(1.2)

        // A: the shortcut, Tab, the pill; Backspace on the empty query puts "yt" back.
        uiCase(window: { self.c.window }) {
            openBar()
            typeText("yt")
            run { [self] in
                check(bar?.siteCandidate?.name == "YouTube", "parityp07 A: “yt” offers YouTube")
                let hint = bar?.results.first { $0.startsScope != nil }
                check(hint?.title == "Search YouTube" && hint?.subtitle == "Press Tab" && bar?.results.firstIndex { $0.startsScope != nil } == 1,
                      "parityp07 A: the second row says “Search YouTube · Press Tab” (\(bar?.resultTitles ?? []))")
            }
            key(.tab)
            run { [self] in
                check(bar?.scope == .site(SiteSearchSettings.defaults.first { $0.name == "YouTube" }!), "parityp07 A: Tab starts YouTube's search")
                check(bar?.fieldText == "" && bar?.placeholderText == "Search YouTube…",
                      "parityp07 A: empty field, placeholder “Search YouTube…” (“\(bar?.fieldText ?? "-")”, “\(bar?.placeholderText ?? "-")”)")
                let pill = bar?.scopePillFrame ?? .zero, field = bar?.inputFrame ?? .zero
                check(pill.width > 40 && field.minX >= pill.maxX, "parityp07 A: the pill leads the field (pill \(pill), field \(field))")
            }
            typeText("p07 quokka")
            waitFor({ bar?.results.contains { $0.historyURL == youtubeVideo } == true })
            run { [self] in
                let rows = bar?.results ?? []
                check(rows.first?.title == "p07 quokka" && Self.url(of: rows.first) == "https://www.youtube.com/results?search_query=p07+quokka",
                      "parityp07 A: Return searches YouTube for the query (\(Self.url(of: rows.first) ?? "none"))")
                check(rows.contains { $0.historyURL == youtubeVideo } && !rows.contains { $0.historyURL == deletable || $0.historyURL?.contains("elsewhere") == true },
                      "parityp07 A: your pages on that site only (\(rows.map(\.title)))")
            }
            typeText("")
            key(.backspace)
            run { [self] in
                check(bar?.scope == nil && bar?.fieldText == "yt" && bar?.query == "yt", "parityp07 A: Backspace on the empty query leaves it, “yt” back (\(bar?.fieldText ?? "-"))")
            }
            key(.backspace)
            run { [self] in check(bar?.scope == nil && bar?.query == "y", "parityp07 A: the next Backspace deletes text (\(bar?.query ?? "-"))") }
            closeBar()
        }

        // B: the start of a name, Tab; Esc leaves the search, the next Esc closes the bar.
        uiCase(window: { self.c.window }) {
            openBar()
            typeText("you")
            key(.tab)
            run { [self] in check(bar?.scope?.name == "YouTube", "parityp07 B: “you” + Tab starts YouTube's search") }
            typeText("cats")
            key(.escape)
            run { [self] in check(bar?.scope == nil && bar?.fieldText == "you cats", "parityp07 B: Esc leaves it, the text back (\(bar?.fieldText ?? "-"))") }
            key(.escape)
            run { [self] in check(c.commandBar == nil, "parityp07 B: a second Esc closes the bar") }
            run { [self] in c.closeCommandBar() }
        }

        // C: Space or Tab (Work) and Tab only (Personal); profiles keep their own sites. Query encoding end to end.
        uiCase(window: { self.c.window }) {
            run { [self] in c.switchToSpace(workSpace, animated: false) }
            wait(0.3)
            openBar()
            run { [self] in check(bar?.siteCandidate == nil, "parityp07 C: nothing typed, nothing offered") }
            typeText("ho")
            run { [self] in check(bar?.siteCandidate == nil, "parityp07 C: Work doesn't have Personal's “ho”") }
            typeText("")
            typeText("lb")
            run { [self] in
                check(bar?.results.first { $0.startsScope != nil }?.subtitle == "Press Space or Tab", "parityp07 C: Work's hint says Space or Tab")
            }
            key(.space)
            run { [self] in check(bar?.scope?.name == "Loopback" && bar?.fieldText == "", "parityp07 C: Space after “lb” starts its search in Work") }
            typeText("東京 & c++ 50%")
            run { [self] in
                let want = "http://127.0.0.1:\(port)/find?q=%E6%9D%B1%E4%BA%AC+%26+c%2B%2B+50%25"
                check(Self.url(of: bar?.results.first) == want, "parityp07 C: query encoded as Chromium does (\(Self.url(of: bar?.results.first) ?? "none"))")
            }
            key(.enter)
            waitFor({ requested("/find") }, timeout: 8)
            run { [self] in
                let want = "http://127.0.0.1:\(port)/find?q=%E6%9D%B1%E4%BA%AC+%26+c%2B%2B+50%25"
                let shown = c.engineTab(for: c.shownTabID ?? "")?.url?.absoluteString
                check(c.commandBar == nil && requested("/find") && shown == want, "parityp07 C: Return opens it in the engine (\(shown ?? "none"))")
            }
            run { [self] in c.switchToSpace(homeSpace, animated: false) }
            wait(0.3)
            openBar()
            typeText("lb")
            run { [self] in check(bar?.siteCandidate == nil, "parityp07 C: Personal doesn't have Work's “lb”") }
            typeText("")
            typeText("yt")
            key(.space)
            run { [self] in check(bar?.scope == nil && bar?.fieldText == "yt ", "parityp07 C: Space stays a space in Personal (Tab only, Arc's default)") }
            closeBar()
        }

        // D: a path template (no "?" before %s): path escaping, "/" and "&" kept, space as %20.
        uiCase(window: { self.c.window }) {
            run { [self] in c.switchToSpace(workSpace, animated: false) }
            wait(0.3)
            openBar()
            typeText("lp")
            key(.tab)
            typeText("AC/DC live & loud")
            key(.enter)
            waitFor({ requested("/search/AC/DC%20live%20&%20loud") }, timeout: 8)
            run { [self] in
                check(requested("/search/AC/DC%20live%20&%20loud"),
                      "parityp07 D: a path template's request is /search/AC/DC%20live%20&%20loud (\(requestLock.withLock { requests.last } ?? "none"))")
            }
            run { [self] in c.switchToSpace(homeSpace, animated: false) }
            wait(0.3)
        }

        // E: input methods in the plain bar: Latin marked text (pinyin) never completes or offers a site; Tab while
        // composing stays the input method's.
        uiCase(window: { self.c.window }) {
            openBar()
            run { [self] in
                guard let b = bar, let ed = editor() else { return check(false, "parityp07 E: the field editor has the keyboard") }
                ed.setMarkedText("you", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                check(ed.hasMarkedText() && ed.markedRange() == NSRange(location: 0, length: 3) && b.fieldText == "you",
                      "parityp07 E: pinyin “you” stays marked (\(NSStringFromRange(ed.markedRange())), “\(b.fieldText)”)")
                check(b.inlineText == nil && b.siteCandidate == nil && !b.results.contains { $0.startsScope != nil },
                      "parityp07 E: nothing completes or offers a site while composing (inline \(b.inlineText ?? "-"))")
                check(!b.control(NSTextField(), textView: ed, doCommandBy: #selector(NSResponder.insertTab(_:))) && b.scope == nil,
                      "parityp07 E: Tab while composing is the input method's")
                ed.setMarkedText("有", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                ed.insertText("有", replacementRange: NSRange(location: NSNotFound, length: 0))
                check(!ed.hasMarkedText() && b.query == "有" && b.fieldText == "有", "parityp07 E: the committed text is the query (\(b.query))")
                // Japanese: kana, converted, committed.
                ed.insertText("", replacementRange: NSRange(location: 0, length: (ed.string as NSString).length))
                for kana in ["と", "とう", "とうき", "とうきょ", "とうきょう"] {
                    ed.setMarkedText(kana, selectedRange: NSRange(location: (kana as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                check(b.fieldText == "とうきょう" && ed.markedRange().length == 5, "parityp07 E: Japanese marked text intact (\(b.fieldText))")
                ed.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                ed.insertText("東京", replacementRange: NSRange(location: NSNotFound, length: 0))
                check(b.query == "東京" && b.results.first?.title == "東京", "parityp07 E: committed 東京 searches (\(b.resultTitles.prefix(2)))")
            }
            closeBar()
        }

        // F: input methods in a site search: marked text, Backspace while composing, the commit's encoding.
        uiCase(window: { self.c.window }) {
            openBar()
            typeText("yt")
            key(.tab)
            run { [self] in
                guard let b = bar, let ed = editor(), b.scope?.name == "YouTube" else { return check(false, "parityp07 F: YouTube's search started") }
                for kana in ["と", "とう", "とうきょう"] {
                    ed.setMarkedText(kana, selectedRange: NSRange(location: (kana as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                check(b.scope?.name == "YouTube" && b.fieldText == "とうきょう" && ed.markedRange() == NSRange(location: 0, length: 5),
                      "parityp07 F: marked text in YouTube's search intact (“\(b.fieldText)”)")
                // The input method's caret at the start of its marked text: the field's Backspace rule must not apply.
                ed.setMarkedText("と", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: 0, length: (ed.string as NSString).length))
                check(ed.hasMarkedText() && ed.selectedRange() == NSRange(location: 0, length: 0)
                      && !b.control(NSTextField(), textView: ed, doCommandBy: #selector(NSResponder.deleteBackward(_:))) && b.scope?.name == "YouTube",
                      "parityp07 F: Backspace while composing (caret at the start) never leaves the search")
                ed.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                ed.insertText("東京", replacementRange: NSRange(location: NSNotFound, length: 0))
                check(Self.url(of: b.results.first) == "https://www.youtube.com/results?search_query=%E6%9D%B1%E4%BA%AC",
                      "parityp07 F: committed 東京 searches YouTube for %E6%9D%B1%E4%BA%AC (\(Self.url(of: b.results.first) ?? "none"))")
                ed.insertText("北京", replacementRange: NSRange(location: 0, length: (ed.string as NSString).length))
                check(Self.url(of: b.results.first) == "https://www.youtube.com/results?search_query=%E5%8C%97%E4%BA%AC",
                      "parityp07 F: Chinese 北京 too")
            }
            closeBar()
        }

        // G: suggestion deletion. ⇧⌫ on the default highlight deletes text; ⌥⌘⌫ (Arc) removes the highlighted page.
        uiCase(window: { self.c.window }) {
            openBar()
            typeText("P07 deletable quokka page")
            waitFor({ bar?.results.first?.historyURL == deletable })
            run { [self] in check(bar?.results.first?.historyURL == deletable, "parityp07 G: the page is the highlighted first row (\(bar?.resultTitles.prefix(2) ?? []))") }
            key(.shiftBackspace)
            run { [self] in
                check(app?.history.entry(profileID: home, url: deletable) != nil && bar?.query == "P07 deletable quokka pag",
                      "parityp07 G: ⇧⌫ on the default highlight deletes text, not history (“\(bar?.query ?? "-")”)")
            }
            typeText("P07 deletable quokka page")
            waitFor({ bar?.results.first?.historyURL == deletable })
            key(.optionCommandBackspace)
            run { [self] in
                check(app?.history.entry(profileID: home, url: deletable) == nil && !(bar?.results.contains { $0.historyURL == deletable } ?? true)
                      && bar?.query == "P07 deletable quokka page",
                      "parityp07 G: ⌥⌘⌫ removes the highlighted page from history and the rows, the text stays")
            }
            typeText("qxqxq wvwvw")
            key(.optionCommandBackspace)
            run { [self] in
                check(app?.history.entry(profileID: home, url: youtubeVideo) != nil, "parityp07 G: ⌥⌘⌫ on a search row removes nothing (field “\(bar?.fieldText ?? "-")”)")
                guard let b = bar, let ed = editor() else { return }
                b.type("P07 quokka video")
                ed.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                let e = Self.keyEvent(.optionCommandBackspace, window: c.window)
                check(!b.handleSuggestionKey(e) && app?.history.entry(profileID: home, url: youtubeVideo) != nil,
                      "parityp07 G: ⌥⌘⌫ while composing is the input method's")
                ed.unmarkText()
            }
            closeBar()
        }

        // H: the pill's menu, the Settings command, persistence.
        run { [self] in
            c.openCommandBar(mode: .newTab)
            bar?.type("yt")
            _ = bar?.control(NSTextField(), textView: editor() ?? NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
            check(bar?.scopeMenuTitles == ["Change Site Search", "Remove YouTube Site Search", "Manage Site Searches…"], "parityp07 H: the pill's menu (\(bar?.scopeMenuTitles ?? []))")
            bar?.type("kept")
            bar?.leaveScope(restoring: false)
            check(bar?.scope == nil && bar?.query == "kept", "parityp07 H: Remove … Site Search keeps the query")
            bar?.type("/site search")
            check(bar?.resultTitles.first == "Site Search Settings…", "parityp07 H: “Site Search Settings…” is an action (\(bar?.resultTitles.first ?? "-"))")
            c.closeCommandBar()
            if let app {
                let restored = AppSettings(directory: AppPaths.dataDirectory)
                check(restored.values.siteSearch == app.settings.values.siteSearch && restored.values.siteSearch.spaceTriggers(for: work),
                      "parityp07 H: profiles' sites and Space choice survive a settings reload")
            }
        }

        // Timings, as cblocal's: main-thread work and the commit of the keystroke's frame; rows checked before it.
        var tab: [Double] = [], tabFrame: [Double] = [], keys: [Double] = [], keyFrames: [Double] = [], plain: [Double] = []
        var inFrame = 0
        for i in 0..<8 {
            run { [self] in c.closeCommandBar(); c.openCommandBar(mode: .newTab); bar?.type("yt") }
            wait(0.15)
            step { [self] done in
                guard let b = bar, let ed = editor() else { return done() }
                FrameTiming.measure({ _ = b.control(NSTextField(), textView: ed, doCommandBy: #selector(NSResponder.insertTab(_:))) }) { t in
                    tab.append(t.work); tabFrame.append(t.frame); done()
                }
            }
            run { bar?.type("p07 quo") }
            wait(0.15)
            step { [self] done in
                guard let b = bar else { return done() }
                var rowsBeforeCommit = false
                FrameTiming.measure({
                    b.type("p07 quok" + (i % 2 == 0 ? "k" : ""))
                    rowsBeforeCommit = b.results.contains { $0.historyURL == youtubeVideo }
                }) { t in
                    keys.append(t.work); keyFrames.append(t.frame)
                    if rowsBeforeCommit { inFrame += 1 }
                    done()
                }
            }
            run { [self] in c.closeCommandBar(); c.openCommandBar(mode: .newTab); bar?.type("y") }
            wait(0.1)
            step { [self] done in
                guard let b = bar else { return done() }
                FrameTiming.measure({ b.type("yt") }) { t in plain.append(t.work); done() }
            }
            run { [self] in c.closeCommandBar() }
            wait(0.15)
        }
        run { [self] in
            func med(_ a: [Double]) -> Double { a.isEmpty ? -1 : a.sorted()[a.count / 2] }
            note(String(format: "parityp07 timing: Tab → site search: main %.2f ms (max %.2f), commit %.2f ms; keystroke in it → rows: main %.2f ms (max %.2f), commit %.2f ms, history row before the commit %d/%d; “yt” in the plain bar (hint row): main %.2f ms (max %.2f)",
                        med(tab), tab.max() ?? -1, med(tabFrame), med(keys), keys.max() ?? -1, med(keyFrames), inFrame, keys.count, med(plain), plain.max() ?? -1))
            note("parityp07 timing samples: tab \(tab.map { String(format: "%.2f", $0) }), keys \(keys.map { String(format: "%.2f", $0) }), plain \(plain.map { String(format: "%.2f", $0) })")
            check(med(keys) < 8.3 && (keys.max() ?? 99) < 16 && med(tab) < 8.3 && inFrame == keys.count,
                  "parityp07 timing: within one 120 Hz frame's budget, history rows in the keystroke's frame")
            note("parityp07: keys delivered by path: " + keyPaths.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            server?.stop()
        }

    }

    enum P07Key: CustomStringConvertible {
        case tab, space, backspace, shiftBackspace, optionCommandBackspace, escape, enter

        var description: String {
            switch self {
            case .tab: "Tab"
            case .space: "Space"
            case .backspace: "Backspace"
            case .shiftBackspace: "⇧⌫"
            case .optionCommandBackspace: "⌥⌘⌫"
            case .escape: "Esc"
            case .enter: "Return"
            }
        }

        /// What the bar's key log shows once the key landed: the field editor's command or text change, or the app's
        /// key monitor (⌥⌘⌫ is taken there).
        var evidence: Set<String> {
            switch self {
            case .tab: ["insertTab:"]
            case .space: ["text"]
            case .backspace, .shiftBackspace: ["deleteBackward:"]
            case .optionCommandBackspace: ["suggestionKey"]
            case .escape: ["cancelOperation:"]
            case .enter: ["insertNewline:"]
            }
        }

        /// Only the app's key monitor takes it (when it doesn't, it isn't sent on to the field a second way).
        var monitorOnly: Bool { self == .optionCommandBackspace }

        /// Key code, characters and modifiers; these keys have the same codes on every layout.
        var event: (UInt16, String, NSEvent.ModifierFlags) {
            switch self {
            case .tab: (48, "\t", [])
            case .space: (49, " ", [])
            case .backspace: (51, "\u{7f}", [])
            case .shiftBackspace: (51, "\u{7f}", .shift)
            case .optionCommandBackspace: (51, "\u{7f}", [.option, .command])
            case .escape: (53, "\u{1b}", [])
            case .enter: (36, "\r", [])
            }
        }
    }

    static func keyEvent(_ k: P07Key, window: NSWindow, type: NSEvent.EventType = .keyDown) -> NSEvent {
        let (code, chars, mods) = k.event
        return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    static func url(of r: CommandResult?) -> String? {
        if case .open(let u)? = r?.action { return u.absoluteString }
        return nil
    }
}

private extension Result where Success == SiteSearch, Failure == SiteSearchProblem {
    var isSuccess: Bool { if case .success = self { true } else { false } }
    var problem: String? { if case .failure(let p) = self { p.message } else { nil } }
}
#endif

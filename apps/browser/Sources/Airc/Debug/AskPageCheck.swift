// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script askpage` (docs/user/ai.md, Ask on Page), both engines, on loopback pages with a fake streaming model
/// (`ScriptedAskModel`), so it runs the same with or without Apple Intelligence: off by default (no ✦ in ⌘F, no
/// Command Bar action); without Apple Intelligence the switch stays off; on, the Command Bar's "Ask This Page…" opens
/// ⌘F in Ask mode and ↩ (the field's own handler) asks; the answer streams into the card, only the page's real
/// sentences come back as quotes, and a click on one scrolls the page to it and highlights it; what the model saw is
/// the page's text within the context budget, the host and the question only; a page too large, an empty one, a model
/// that hangs, no model, and a private window are refused gracefully; off records only `ai.ask_page` on, off and used.
/// Last, with Apple Intelligence on, a timed question to the real on-device model on a synthetic page (SKIP otherwise).
extension SnapshotRunner {
    @MainActor func askPageScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = "askpage (\(chromium ? "chromium" : "webkit"))"
        let ai = AIFeatures.shared
        let fake = ScriptedAskModel()
        let question = "When does the castle open?"
        let castle = "The Castelo de São Jorge opens at 9:00 and closes at 21:00 from March to October."
        fake.answers[question] = .init(parts: ["The castle", "The castle opens at 9:00", "The castle opens at 9:00 and closes",
                                               "The castle opens at 9:00 and closes at 21:00 from March to October."],
                                       quotes: [castle, "The castle has a rooftop café open every evening until midnight."])
        fake.hang = ["Is this one stuck?"]
        // The real model's "No." to a question the page never covers, "quoting" its opening sentence.
        fake.answers["Is there a beach nearby?"] = .init(parts: ["No."], quotes: ["Lisbon is a city of hills, trams and tiled façades."])
        // The real model's "No" with the castle's opening hours as its proof (the AI-2 review's M8).
        fake.answers["Does the castle have a café?"] = .init(parts: ["No."], quotes: [castle])
        // A stream that breaks after its first words (a guided answer that fails to decode partway).
        fake.answers["Is this one broken?"] = .init(parts: ["The castle opens", "The castle opens at 9:00."], quotes: [castle])
        fake.failAfterFirst = ["Is this one broken?"]
        // The check of an answer against its quotes (AskPageVerifier): what it finds, by question.
        fake.evidence[question] = .supports
        fake.evidence["Does the castle have a café?"] = .neither
        fake.answers["Is the castle closed in summer?"] = .init(parts: ["Yes."], quotes: [castle])
        fake.evidence["Is the castle closed in summer?"] = .contradicts
        fake.answers["When does the castle open in March?"] = .init(parts: ["At 9:00."], quotes: [castle])
        fake.checkHangs = ["When does the castle open in March?"]
        var server: LocalPageServer?
        var port: UInt16 = 0
        var tabs: [String: String] = [:]
        var privateWindow: PrivateWindowController?
        var streamed: [String] = []
        weak var closedRun: AskPageRun?
        var finds = 0
        var otherTab: String?
        var otherProfile = "", mainProfile = ""
        var askedBefore = 0
        func url(_ p: String) -> String { "http://127.0.0.1:\(port)/\(p).html?ref=private-token" }
        func page(_ p: String) -> EngineTab? { tabs[p].flatMap { c.engineTab(for: $0) } }
        func session() -> AskPageFeature.Session? { AskPageFeature.session(of: c) }
        func ask(_ q: String) {
            guard let bar = c.findBar else { return }
            bar.field.stringValue = q
            // ↩ through the field's own command handler (ask mode).
            _ = bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        }
        /// Typing into the field: the field editor's own insertion (its action follows, as for keys), else the action.
        func type(_ bar: FindBarView, _ text: String) -> String {
            c.window.makeFirstResponder(bar.field)
            if let editor = bar.field.currentEditor() as? NSTextView {
                editor.selectAll(nil)
                editor.insertText(text, replacementRange: editor.selectedRange())
                return "the field editor"
            }
            bar.field.stringValue = text
            _ = bar.field.sendAction(bar.field.action, to: bar.field.target)
            return "the field's action"
        }

        run { [self] in note("\(tag): environment at the start: \(aiEnvironment.line)") }
        run {
            AskPageFeature.testOptions = {
                var o = AskPageRun.Options()
                o.firstPartTimeout = 2.5
                o.totalTimeout = 6
                return o
            }()
            ai.testOverride = (.notEnabled, nil)
            ai.testModels = .init(ask: fake)
        }
        step { [self] done in
            let filler = (0..<36).map { i in
                "<p>Section \(i) of the guide talks about the neighbourhood's streets, its cafés and the view from the hill, "
                    + "with a few words on getting around by tram and on foot.</p>"
            }.joined()
            let lisbon = """
                <!doctype html><meta charset="utf-8"><title>Lisbon in three days – Example Travel</title>
                <style>body{font:17px/1.5 -apple-system,sans-serif;max-width:720px;margin:40px auto;padding:0 24px;color:#222}
                nav a{margin-right:12px}.hidden{display:none}</style>
                <nav><a href="/">Home</a><a href="/guides">Guides</a></nav>
                <h1>Lisbon in three days</h1>
                <p>Lisbon is a city of hills, trams and tiled façades. This itinerary covers the old town, Belém and the river.</p>
                <p class="hidden">Secret text that nobody can see on this page.</p>
                \(filler)
                <h2>Day one: Alfama</h2>
                <p id="castle">Start in Alfama. \(castle) Tickets cost fifteen euros.</p>
                <h2>Day two: Belém</h2>
                <p>In Belém, the Jerónimos Monastery is closed on Mondays.</p>
                """
            let big = "<!doctype html><title>Very long page</title>" + (0..<2400).map { i in
                "<p>Paragraph \(i): " + String(repeating: "words about nothing in particular ", count: 3) + "</p>"
            }.joined()
            server = LocalPageServer(pages: [
                "/lisbon.html": lisbon, "/big.html": big,
                "/empty.html": "<!doctype html><title>Empty</title><div style='height:2000px'></div>",
                "/private.html": "<!doctype html><title>Private page</title><p>A private page about the castle and when it opens, with enough words.</p>",
            ])
            server?.start { p in
                guard let p else { self.check(false, "\(tag): the loopback page server starts"); return self.finish() }
                port = p
                for name in ["lisbon", "big", "empty"] {
                    if let t = try? self.c.store.openTab(url: url(name), inSpace: self.c.currentSpaceID) { tabs[name] = t.id }
                }
                self.c.reloadAll(animated: false)
                if let id = tabs["lisbon"] { self.c.show(id, focus: false) }
                done()
            }
        }
        step { [self] done in
            waitUntil({ page("lisbon").map { !$0.isLoading && $0.title.hasPrefix("Lisbon") } ?? false }, timeout: 12) { done() }
        }

        // 1. Off by default.
        run { [self] in
            c.showFind()
            let bar = c.findBar
            aiCheck(app?.settings.values.askPage == false && bar?.askButton.isHidden == true
                  && !c.commandActions().contains { $0.title == "Ask This Page…" },
                  "\(tag): Ask on Page is off by default: no ✦ in ⌘F's bar, no \"Ask This Page…\" in the Command Bar")
            c.closeFind(refocusPage: false)
            // 2. Without Apple Intelligence the switch can't turn it on.
            if let s = app?.settings { ai.setAskPage(true, settings: s) }
            aiCheck(app?.settings.values.askPage == false, "\(tag): without Apple Intelligence the switch stays off (\(ai.availability.label))")
            app?.showSettings(page: .ai)
        }
        wait(0.8)
        run { [self] in captureAISettings2("askpage-settings-unavailable") }
        run { [self] in
            ai.testOverride = (.available, nil)
            if let s = app?.settings { ai.setAskPage(true, settings: s) }
            aiCheck(app?.settings.values.askPage == true && ai.canAsk && ai.lastToggleEvent == .featureUsed(.aiAskPage(.on)),
                  "\(tag): with Apple Intelligence, Settings → AI turns Ask on Page on (feature.used ai.ask_page on)")
        }
        wait(0.5)
        run { [self] in
            captureAISettings2("askpage-settings-on")
            app?.settingsWindow?.window.orderOut(nil)
        }

        // 3. The Command Bar's action opens ⌘F in Ask mode; ↩ asks; the answer streams.
        run { [self] in
            let action = c.commandActions().first { $0.title == "Ask This Page…" }
            aiCheck(action != nil, "\(tag): the Command Bar offers \"Ask This Page…\"")
            action?.run()
            aiCheck(c.findBar?.isAsking == true && c.findBar?.askButton.isHidden == false
                  && c.findBar?.field.placeholderString == "Ask about this page",
                  "\(tag): it opens ⌘F's bar in Ask mode (\(c.findBar?.field.placeholderString ?? "no bar"))")
            ask(question)
        }
        step { done in
            // Watch the card as the answer arrives.
            let start = Date()
            @MainActor func poll() {
                let s = session()?.run?.state
                if let a = s?.answer, !a.isEmpty, streamed.last != a { streamed.append(a) }
                if s?.isFinished == true || Date().timeIntervalSince(start) > 10 { return done() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { poll() }
            }
            poll()
        }
        run { [self] in
            let s = session()
            let state = s?.run?.state
            aiCheck(streamed.count >= 3 && zip(streamed, streamed.dropFirst()).allSatisfy { $1.hasPrefix($0) },
                  "\(tag): the answer streams into the card (\(streamed.count) steps: \(streamed.map { "\($0.count)" }.joined(separator: " → ")) characters)")
            aiCheck(state?.phase == .done && s?.card.answerLabel.stringValue == fake.answers[question]?.parts.last,
                  "\(tag): the finished answer shows (\(s?.card.answerLabel.stringValue ?? "none"))")
            let checkRequest = fake.checked.last
            aiCheck(state?.grounding == .verified && checkRequest?.question == question && checkRequest?.quotes == [castle]
                    && s?.card.relatedLabel.stringValue.isEmpty == true && s?.card.footer.stringValue.hasPrefix("Checked against") == true,
                    "\(tag): the answer is checked against its quote (the check: the question, the answer and the page's sentence only) "
                    + "and shown as backed up (\(s?.card.footer.stringValue ?? ""))")
            let quotes = state?.quotes ?? []
            aiCheck(quotes.count == 1 && quotes.first?.text == castle && s?.card.quoteRows.count == 1 && state?.unmatchedQuotes == 1,
                  "\(tag): only the page's real sentence comes back as a quote; the invented one is dropped (\(quotes.map(\.text)))")
            let r = fake.asked.first
            let text = r?.passages.map(\.text).joined(separator: "\n") ?? ""
            let tokens = r?.passages.reduce(0) { $0 + $1.tokens } ?? 0
            let budget = AskPageBudget(contextTokens: AppleIntelligence.contextSize).passageTokens(question: question)
            aiCheck(fake.asked.count == 1 && r?.question == question && r?.host == "127.0.0.1" && text.contains(castle)
                  && !text.contains("Secret text") && !(r.map { "\($0)" } ?? "").contains("private-token") && tokens <= budget,
                  "\(tag): the model got the question, the host and the page's visible text within the budget (\(tokens) of \(budget) tokens, "
                  + "\(r?.passages.count ?? 0) passages; hidden text and the address's query left out; read in "
                  + String(format: "%.0f ms)", PageReader.lastReadSeconds * 1000))
            aiCheck(ai.events.contains(.featureUsed(.aiAskPage(.used))), "\(tag): asking records feature.used ai.ask_page used")
        }
        captureAIOnTop("askpage-answer") { [self] in [c.findBar, session()?.card].compactMap { $0 } }

        // 4. A quote's click scrolls the page to it and highlights it.
        run { [self] in
            aiCheck(session()?.card.quoteRows.first?.action != nil, "\(tag): the quote is a row with an action")
            session()?.card.quoteRows.first?.action?()
        }
        wait(1.2)
        step { [self] done in
            page("lisbon")?.evaluate("""
                (function(){ var r = null, api = !!(window.CSS && CSS.highlights);
                  var h = api ? CSS.highlights.get('airc-ask') : null;
                  if (h) h.forEach(function (x) { r = x; });
                  if (!r) { var s = getSelection(); if (s.rangeCount) r = s.getRangeAt(0); }
                  if (!r) return { found: false, y: scrollY };
                  var b = r.getBoundingClientRect();
                  return { found: true, text: r.toString(), top: b.top, bottom: b.bottom, vh: innerHeight, y: scrollY, hl: !!h };
                })()
                """) { [self] v in
                let d = v as? [String: Any] ?? [:]
                let top = (d["top"] as? NSNumber)?.doubleValue ?? -1, bottom = (d["bottom"] as? NSNumber)?.doubleValue ?? -1
                let vh = (d["vh"] as? NSNumber)?.doubleValue ?? 0, y = (d["y"] as? NSNumber)?.doubleValue ?? 0
                aiCheck((d["found"] as? Bool) == true && (d["text"] as? String) == castle && top >= 0 && bottom <= vh && y > 300,
                      "\(tag): a click on the quote scrolls the page to it and highlights it (scrolled \(Int(y)) px, "
                      + "quote at \(Int(top))–\(Int(bottom)) of \(Int(vh)), \((d["hl"] as? Bool) == true ? "a CSS highlight" : "the selection"))")
                done()
            }
        }
        captureAIOnTop("askpage-jump") { [self] in [c.findBar, session()?.card].compactMap { $0 } }

        // 4b. A yes or a no that nothing on the page backs up.
        run { [self] in ask("Is there a beach nearby?") }
        step { [self] done in waitUntil({ session()?.run?.state.isFinished == true && session()?.run?.question == "Is there a beach nearby?" }, timeout: 8) { done() } }
        run { [self] in
            let s = session()
            aiCheck(s?.card.answerLabel.stringValue == "The page doesn't say." && s?.run?.state.quotes.isEmpty == true
                    && s?.run?.state.answerReplaced == true && s?.card.footer.stringValue.contains("No sentence") == false,
                    "\(tag): a yes or a no with no sentence of the page behind it shows \"The page doesn't say.\" (\(s?.card.answerLabel.stringValue ?? "none"))")
        }

        // 4c. A real sentence about the same thing isn't proof of a yes or a no: words never confirm, and the check said
        // neither.
        run { [self] in ask("Does the castle have a café?") }
        step { [self] done in waitUntil({ session()?.run?.state.isFinished == true && session()?.run?.question == "Does the castle have a café?" }, timeout: 8) { done() } }
        run { [self] in
            let s = session()
            aiCheck(s?.card.answerLabel.stringValue == "The page doesn't say." && s?.run?.state.answerReplaced == true
                    && s?.run?.state.grounding == .unconfirmed && s?.card.relatedLabel.stringValue == "Related text, not proof" && s?.card.quoteRows.count == 1,
                    "\(tag): \"No\" to \"Does the castle have a café?\" with the castle's opening hours as its quote shows "
                    + "\"\(s?.card.answerLabel.stringValue ?? "none")\", the hours as related text, not proof")
        }
        // A yes the check finds the page contradicts.
        run { [self] in ask("Is the castle closed in summer?") }
        step { [self] done in waitUntil({ session()?.run?.state.isFinished == true && session()?.run?.question == "Is the castle closed in summer?" }, timeout: 8) { done() } }
        run { [self] in
            let s = session()
            aiCheck(s?.card.answerLabel.stringValue == "The page seems to say otherwise:" && s?.run?.state.grounding == .contradicted
                    && s?.card.quoteRows.first?.quote.text == castle && s?.card.relatedLabel.stringValue.isEmpty == true,
                    "\(tag): a \"Yes.\" the page contradicts shows \"\(s?.card.answerLabel.stringValue ?? "none")\" and the page's sentence")
        }

        // 4d. A stream that fails after its first words: never shown as a finished answer.
        run { [self] in ask("Is this one broken?") }
        step { [self] done in waitUntil({ session()?.run?.state.isFinished == true && session()?.run?.question == "Is this one broken?" }, timeout: 8) { done() } }
        run { [self] in
            let s = session()
            aiCheck(s?.run?.state.phase == .failed && s?.run?.state.isUnfinished == true && s?.card.answerLabel.stringValue == "The castle opens…"
                    && s?.card.footer.stringValue.contains("stopped before finishing") == true && s?.card.quoteRows.isEmpty == true,
                    "\(tag): an answer whose stream failed partway shows as unfinished (\"\(s?.card.answerLabel.stringValue ?? "")\", "
                    + "\"\(s?.card.footer.stringValue ?? "")\")")
        }

        // 4e. The keys in both modes: asking, typing and ⌘G search nothing and ⌘F goes back to Find; finding, typing, ↩
        // and ⌘G search and ⌘↩ asks.
        run { [self] in
            guard let bar = c.findBar else { return aiCheck(false, "\(tag): the bar is up") }
            let original = bar.onFind
            bar.onFind = { text, forward in finds += 1; original?(text, forward) }
            let how = type(bar, "castle")
            c.findAgain(forward: true)
            aiCheck(bar.isAsking && finds == 0, "\(tag): asking, typing (through \(how)) and ⌘G don't search the page (\(finds) searches)")
            c.showFind()
            aiCheck(!bar.isAsking && session() == nil && bar.field.placeholderString == "Find on page",
                    "\(tag): ⌘F while asking goes back to Find (the card closes)")
            _ = type(bar, "castle")
            let typed = finds, before = fake.asked.count
            bar.modifiers = { [] }
            _ = bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            c.findAgain(forward: true)
            aiCheck(typed >= 1 && finds >= typed + 2 && !bar.isAsking && fake.asked.count == before,
                    "\(tag): finding, typing, ↩ and ⌘G search the page (\(typed) for typing, \(finds) in all), nothing is asked")
            bar.modifiers = { [.command] }
            bar.field.stringValue = question
            _ = bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            bar.modifiers = { NSApp.currentEvent?.modifierFlags ?? [] }
            bar.onFind = original
            aiCheck(bar.isAsking && session() != nil, "\(tag): ⌘↩ while finding asks the field's question (Ask mode)")
        }
        step { [self] done in waitUntil({ session()?.run?.state.isFinished == true }, timeout: 8) { done() } }

        // 5. Refusals: too large, empty, a model that hangs, no model, a private window.
        run { [self] in
            closedRun = session()?.run
            c.closeFind(refocusPage: false)
            aiCheck(session() == nil, "\(tag): Esc (closing the bar) closes the card and stops the question")
            if let id = tabs["big"] { c.show(id, focus: false) }
        }
        wait(0.4)
        run { [self] in aiCheck(closedRun == nil, "\(tag): the closed card's run (its page, question and answer) is let go") }
        step { [self] done in waitUntil({ page("big").map { !$0.isLoading } ?? false }, timeout: 10) { done() } }
        run { [self] in
            c.showAsk(question: question)
        }
        step { [self] done in waitUntil({ session()?.card.refusal != nil }, timeout: 12) { done() } }
        run { [self] in
            let r = session()?.card.refusal
            if case .tooLarge? = r {} else { aiCheck(false, "\(tag): a page too large is refused (\(String(describing: r)))") }
            if case .tooLarge? = r {
                aiCheck(fake.asked.count == 6, "\(tag): a page too large is refused before the model (\(session()?.card.answerLabel.stringValue ?? ""))")
            }
            c.closeFind(refocusPage: false)
            if let id = tabs["empty"] { c.show(id, focus: false) }
        }
        step { [self] done in waitUntil({ page("empty").map { !$0.isLoading } ?? false }, timeout: 10) { done() } }
        run { [self] in c.showAsk(question: question) }
        step { [self] done in waitUntil({ session()?.card.refusal != nil }, timeout: 8) { done() } }
        run { [self] in
            aiCheck(session()?.card.refusal == .emptyPage && fake.asked.count == 6,
                  "\(tag): a page without text is refused (\(session()?.card.answerLabel.stringValue ?? ""))")
            c.closeFind(refocusPage: false)
            if let id = tabs["lisbon"] { c.show(id, focus: false) }
            c.showAsk(question: "Is this one stuck?")
        }
        step { [self] done in waitUntil({ session()?.run?.state.isFinished == true }, timeout: 8) { done() } }
        run { [self] in
            aiCheck(session()?.run?.state.phase == .timedOut && session()?.card.answerLabel.stringValue.contains("too long") == true,
                  "\(tag): a model that never answers is let go after its timeout (\(session()?.card.answerLabel.stringValue ?? ""))")
            c.closeFind(refocusPage: false)
            ai.testOverride = (.notReady, nil)
            c.showAsk(question: question)
            aiCheck(session()?.card.refusal == .unavailable && fake.asked.count == 7,
                  "\(tag): without the model, Ask says so and nothing is asked (\(session()?.card.answerLabel.stringValue ?? ""))")
            c.closeFind(refocusPage: false)
            ai.testOverride = (.available, nil)
            ai.testModels = .init(ask: fake)
            guard let app else { return }
            PrivateBrowsing.shared.open(app: app) { w in privateWindow = w }
        }
        step { [self] done in waitUntil({ privateWindow != nil }, timeout: 8) { done() } }
        run { privateWindow?.openPage(URL(string: url("private"))) }
        step { [self] done in waitUntil({ privateWindow?.shownPage.map { !$0.isLoading && $0.title == "Private page" } ?? false }, timeout: 10) { done() } }
        run { [self] in
            privateWindow?.showFind()
            aiCheck(privateWindow?.findBar != nil && privateWindow?.findBar?.askButton.isHidden == true
                  && AskPageRefusal.check(question: question, page: lisbonLike, isPrivate: true, available: true) == .privateWindow
                  && fake.asked.count == 7,
                  "\(tag): a private window's ⌘F has no Ask, and its pages never reach the model")
            privateWindow?.closeWindow()
        }

        // 5b. Clear Data (Settings → Profiles, the real action) purges the profile's Ask sessions: a finished answer, a
        // page read on its way, a model call and a check under way. A session about another profile's page stays.
        run { [self] in
            if let id = tabs["lisbon"] { c.show(id, focus: false) }
            c.showAsk(question: question)
        }
        step { [self] done in waitUntil({ session()?.run?.state.isFinished == true }, timeout: 10) { done() } }
        run { [self] in
            guard let app else { return }
            let mine = session()
            closedRun = mine?.run
            let card = mine?.card
            mainProfile = mine?.profileID ?? ""
            SettingsActions.clearData(of: mainProfile, model: SettingsModel(app: app))
            aiCheck(!mainProfile.isEmpty && session() == nil && c.findBar?.isAsking == false && c.findBar?.field.stringValue.isEmpty == true,
                    "\(tag): Clear Data closes the profile's Ask: the session (its page, question and answer) goes, the bar is back to Find, the question cleared")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                aiCheck(card?.superview == nil && closedRun == nil, "\(tag): its card is gone and its run let go")
            }
        }
        wait(0.6)
        // A page read on its way: the page is busy, the read waits; Clear Data now, and the read's answer starts nothing.
        run { [self] in
            askedBefore = fake.asked.count
            page("lisbon")?.evaluate("setTimeout(function () { var end = Date.now() + 2500; while (Date.now() < end) {} }, 30); true", completion: nil)
        }
        wait(0.2)
        run { [self] in
            guard let app else { return }
            c.showAsk(question: question)
            let pending = session()?.run == nil && session()?.card.hasContent == true
            SettingsActions.clearData(of: mainProfile, model: SettingsModel(app: app))
            aiCheck(pending && session() == nil, "\(tag): Clear Data during the page's read closes the session (the read was still on its way)")
        }
        wait(3.5)
        run { [self] in
            aiCheck(fake.asked.count == askedBefore && session() == nil,
                    "\(tag): the read that answered after Clear Data started no question (\(fake.asked.count - askedBefore) asked)")
            c.showAsk(question: "Is this one stuck?")
        }
        // A model call under way.
        step { [self] done in waitUntil({ fake.asked.last?.question == "Is this one stuck?" }, timeout: 8) { done() } }
        run { [self] in
            guard let app else { return }
            closedRun = session()?.run
            let answering = closedRun?.state.phase == .answering
            SettingsActions.clearData(of: mainProfile, model: SettingsModel(app: app))
            aiCheck(answering && session() == nil, "\(tag): Clear Data during the model's answer closes the session")
        }
        wait(0.4)
        run { [self] in
            aiCheck(closedRun == nil, "\(tag): the answering run is let go at once (its stream ended), not at its timeout")
            c.showAsk(question: "When does the castle open in March?")
        }
        // A check under way.
        step { [self] done in waitUntil({ session()?.run?.state.checking == true }, timeout: 8) { done() } }
        run { [self] in
            guard let app else { return }
            closedRun = session()?.run
            SettingsActions.clearData(of: mainProfile, model: SettingsModel(app: app))
            aiCheck(session() == nil, "\(tag): Clear Data during the answer's check closes the session")
        }
        wait(0.4)
        run { [self] in aiCheck(closedRun == nil, "\(tag): the checking run is let go at once") }
        // Another profile's page: its session stays when the first profile is cleared, and goes when its own is.
        step { [self] done in
            do {
                let first = c.store.selectedSpace
                let other = try c.store.createProfile(name: "Ask test")
                otherProfile = other.id
                let space = try c.store.createSpace(name: "Other", icon: nil, theme: first.theme, profileID: other.id, after: first.id)
                let t = try c.store.openTab(url: url("lisbon"), inSpace: space.id).id
                otherTab = t
                c.profiles.whenLoaded(other.id, { [self] _ in
                    c.reloadAll(animated: false)
                    c.switchToSpace(space.id, animated: false)
                    c.show(t, focus: false)
                    done()
                }, failed: { [self] in aiCheck(false, "\(tag): the second profile loads"); done() })
            } catch {
                aiCheck(false, "\(tag): a second profile's Space (\(error))")
                done()
            }
        }
        step { [self] done in
            waitUntil({ otherTab.flatMap { c.engineTab(for: $0) }.map { c.shownTabID == otherTab && !$0.isLoading && $0.title.hasPrefix("Lisbon") } ?? false },
                      timeout: 12) { done() }
        }
        run { [self] in c.showAsk(question: question) }
        step { [self] done in waitUntil({ session()?.run?.state.isFinished == true }, timeout: 10) { done() } }
        run { [self] in
            guard let app else { return }
            let theirs = session()
            aiCheck(theirs?.profileID == otherProfile && otherProfile != mainProfile, "\(tag): a finished answer about the other profile's page")
            SettingsActions.clearData(of: mainProfile, model: SettingsModel(app: app))
            let kept = session()
            aiCheck(kept != nil && kept === theirs && kept?.page != nil && kept?.card.answerLabel.stringValue == fake.answers[question]?.parts.last,
                    "\(tag): Clear Data of the first profile leaves the other profile's session as it was, with its answer")
            SettingsActions.clearData(of: otherProfile, model: SettingsModel(app: app))
            aiCheck(session() == nil, "\(tag): Clear Data of its own profile closes it")
            c.closeFind(refocusPage: false)
            ai.setAskPage(false, settings: app.settings)
            aiCheck(app.settings.values.askPage == false && !c.commandActions().contains { $0.title == "Ask This Page…" },
                  "\(tag): off, the Command Bar's action goes")
            checkAIEvents(tag, ai.events, expect: ["ai.ask_page:on", "ai.ask_page:used", "ai.ask_page:off"])
        }

        // 6. The real on-device model, when this Mac has Apple Intelligence on: a synthetic page, timed.
        step { [self] done in
            ai.testOverride = nil
            ai.testModels = nil
            guard let model = AppleIntelligence.askModel() else {
                skip("\(tag): real on-device run: this Mac's model is unavailable (\(AppleIntelligence.availability.label))")
                return done()
            }
            Task { @MainActor in
                let r = AskPageRun(question: question, page: lisbonLike, model: model)
                let start = CACurrentMediaTime()
                var first: Double?
                r.onUpdate = { s in if first == nil, !s.answer.isEmpty { first = CACurrentMediaTime() - start } }
                r.start()
                while !r.state.isFinished, CACurrentMediaTime() - start < 60 { try? await Task.sleep(nanoseconds: 50_000_000) }
                let total = CACurrentMediaTime() - start
                self.note("\(tag): real model: \"\(r.state.answer)\" quotes \(r.state.quotes.map(\.text)) (\(r.state.unmatchedQuotes) unmatched, \(r.state.grounding))")
                self.check(r.state.phase == .done && !r.state.answer.isEmpty,
                           "\(tag): the real on-device model answered (" + String(format: "first words %.2f s, all %.2f s, ", first ?? -1, total)
                           + "\(r.state.quotes.count) quotes found on the page, \(r.state.grounding))")
                // The real check, timed, on a supported answer and on the review's two kinds of unsupported ones.
                if let verifier = model as? any AskPageVerifier {
                    let cases: [(String, String, String, Bool)] = [
                        ("When does the castle open?", "The castle opens at 9:00.", castle, true),
                        ("Does the castle have a café?", "No.", "The castle has a café in its courtyard, open until six.", false),
                        ("Is the hotel pool heated?", "Yes.", "The hotel pool closes at six.", false),
                    ]
                    for (q, a, quote, supported) in cases {
                        let t = CACurrentMediaTime()
                        let outcome = await AIDeadline.run(timeout: 15) { try await verifier.check(AskPageCheckRequest(question: q, answer: a, quotes: [quote])) }
                        let took = CACurrentMediaTime() - t
                        var found = "failed"
                        if case .value(let e) = outcome { found = e.rawValue }
                        self.check(supported ? found == "supports" : found != "supports" && found != "failed",
                                   "\(tag): the real on-device check of \"\(a)\" to \"\(q)\" with \"\(quote)\": \(found) ("
                                   + String(format: "%.2f s)", took))
                    }
                }
                done()
            }
        }
        run { [self] in
            note("\(tag): environment at the end: \(aiEnvironment.line)")
            server?.stop()
            AskPageFeature.testOptions = nil
        }
    }

    /// The synthetic Lisbon page as AircKit text (the private-window refusal, the real-model run).
    var lisbonLike: PageText {
        PageText(title: "Lisbon in three days – Example Travel", url: "https://travel.example/lisbon", blocks: [
            PageTextBlock(index: 0, text: "Lisbon in three days", isHeading: true),
            PageTextBlock(index: 1, text: "Lisbon is a city of hills, trams and tiled façades. This itinerary covers the old town, Belém and the river."),
            PageTextBlock(index: 2, text: "Day one: Alfama", isHeading: true),
            PageTextBlock(index: 3, text: "Start in Alfama. The Castelo de São Jorge opens at 9:00 and closes at 21:00 from March to October. Tickets cost fifteen euros."),
            PageTextBlock(index: 4, text: "Day two: Belém", isHeading: true),
            PageTextBlock(index: 5, text: "In Belém, the Jerónimos Monastery is closed on Mondays."),
        ])
    }

    /// Settings → AI as drawn now.
    func captureAISettings2(_ name: String) {
        guard let w = app?.settingsWindow?.window, let v = w.contentView else { return }
        v.layoutSubtreeIfNeeded()
        guard let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
        note("wrote \(name).png")
    }
}
#endif

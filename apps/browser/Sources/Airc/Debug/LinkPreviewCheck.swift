// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script linkpreview` (docs/user/ai.md, link previews), both engines, on loopback pages with a fake summarizer
/// (`ScriptedSummaryModel`): off by default (no page-script part); without Apple Intelligence the switch stays off; on,
/// pages already open get the part; ⇧ over a link, through the link's own handler (the page's events, dispatched on
/// the link: the check stands in for the person, `LinkPreviewFeature.trustSynthetic` and `input`), shows a card under
/// it with the target's title, summary and key points, read in the background in the same profile and never in the
/// sidebar or Airc's history; leaving the link hides it; the same link again comes from the session's cache; ⇧ not
/// really down, a link to the page itself, a site set to never, and a private window's page get nothing; a press held
/// on a link shows its card and the click that ends it doesn't open the link; a page with too little text says so; off
/// removes the part and forgets the previews, and only `ai.link_preview` on, off and used is recorded. Last, with Apple
/// Intelligence on, a timed preview by the real on-device model (SKIP otherwise).
extension SnapshotRunner {
    @MainActor func linkPreviewScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = "linkpreview (\(chromium ? "chromium" : "webkit"))"
        let ai = AIFeatures.shared
        let feature = LinkPreviewFeature.shared
        let fake = ScriptedSummaryModel()
        let articleTitle = "Harbour project opens in May – Example News"
        let summary = LinkSummary(summary: "The new harbour opens to visitors in May. Ferries to the islands will run every hour from the new pier.",
                                  keyPoints: ["Market hall in the old warehouses", "Hourly ferries from the new pier", "Free bike parking"])
        fake.answers[articleTitle] = summary
        fake.answers["New ferry timetable – Example News"] = LinkSummary(summary: "The ferry timetable changes in June. Evening sailings are added on weekends.",
                                                                         keyPoints: ["Changes in June", "More evening sailings"])
        var server: LocalPageServer?
        var port: UInt16 = 0
        var source: String?
        var privateWindow: PrivateWindowController?
        var shift = true, button = false
        let lock = NSLock()
        var served: [String] = []
        var loadedBefore = 0
        var tabsBefore = -1
        var otherTab: String?
        var homeSpace = ""
        var firstCard: LinkPreviewCardView?
        var closeAsked = 0.0
        func base(_ host: String = "127.0.0.1") -> String { "http://\(host):\(port)" }
        func page() -> EngineTab? { source.flatMap { c.engineTab(for: $0) } }
        func otherPage() -> EngineTab? { otherTab.flatMap { c.engineTab(for: $0) } }
        func card() -> LinkPreviewCardView? { feature.card }
        func ready() -> Bool { if case .ready? = card()?.state { return true } else { return false } }
        func count(_ path: String) -> Int { lock.withLock { served.filter { $0 == path }.count } }
        /// The page's own events on a link (the part listens on the window, as for a person's).
        func fire(_ tab: EngineTab?, _ id: String, _ type: String, _ extra: String = "", then: (() -> Void)? = nil) {
            tab?.evaluate("""
                (function () {
                  var a = document.getElementById('\(id)'), r = a.getBoundingClientRect();
                  var o = { bubbles: true, cancelable: true, composed: true, view: window, clientX: r.left + 4, clientY: r.top + 4, button: 0 \(extra) };
                  var e = '\(type)'.indexOf('pointer') === 0 ? new PointerEvent('\(type)', Object.assign({ pointerId: 1, isPrimary: true, pointerType: 'mouse' }, o))
                        : '\(type)' === 'keydown' ? new KeyboardEvent('keydown', { key: 'Shift', bubbles: true })
                        : new MouseEvent('\(type)', o);
                  ('\(type)' === 'keydown' ? document : a).dispatchEvent(e);
                  return true;
                })()
                """) { _ in then?() }
        }

        run { [self] in note("\(tag): environment at the start: \(aiEnvironment.line)") }
        run {
            LinkPreviewFeature.trustSynthetic = true
            HiddenPageReader.loadTimeout = 6
            LinkPreviewFeature.input = {
                // Over the page's middle, with ⇧ and the button as the check says.
                var mouse = NSPoint.zero
                if let v = page()?.view, let w = v.window { let r = w.convertToScreen(v.convert(v.bounds, to: nil)); mouse = NSPoint(x: r.midX, y: r.midY) }
                return (shift, button, mouse)
            }
            ai.testOverride = (.notEnabled, nil)
            ai.testModels = .init(links: fake)
        }
        step { [self] done in
            let words = (0..<8).map { "<p>Paragraph \($0) of the story says more about the harbour, the new pier and how visitors will get there by ferry or bike.</p>" }.joined()
            let sourceHTML = """
                <!doctype html><meta charset="utf-8"><title>Reading list</title>
                <style>body{font:17px/1.6 -apple-system,sans-serif;max-width:680px;margin:48px auto;padding:0 24px;color:#222}
                a{color:#0b57d0}</style>
                <h1>Reading list</h1>
                <p>This week: <a id="a1" href="/article.html">the harbour opening</a> and
                <a id="a2" href="/ferry.html" onclick="window.__clicks=(window.__clicks||0)+1">the new ferry times</a>.</p>
                <p>Elsewhere: <a id="a3" href="http://localhost:PORT/article.html">the same story on another host</a>,
                <a id="a4" href="/tiny.html">a tiny page</a> and <a id="a5" href="#notes">notes below</a>.</p>
                <h2 id="notes">Notes</h2><p>Nothing here yet.</p>
                """
            func article(_ title: String) -> String {
                "<!doctype html><meta charset=\"utf-8\"><title>\(title)</title><nav><a href=\"/\">Home</a> <a href=\"/news\">News</a></nav>"
                    + "<h1>\(title)</h1>" + words
            }
            let s = LocalPageServer(pages: [
                "/source.html": sourceHTML, "/article.html": article(articleTitle), "/ferry.html": article("New ferry timetable – Example News"),
                "/tiny.html": "<!doctype html><title>Tiny</title><p>Just a few words.</p>",
                "/private.html": sourceHTML.replacingOccurrences(of: "Reading list", with: "Private reading list"),
            ])
            // The page with a link to another host (localhost) gets the port the server listens on.
            s?.handler = { path in
                lock.withLock { served.append(path) }
                guard path == "/source.html" else { return nil }
                return LocalPageServer.Page(body: sourceHTML.replacingOccurrences(of: "PORT", with: String(lock.withLock { port })))
            }
            server = s
            server?.start { p in
                guard let p else { self.check(false, "\(tag): the loopback page server starts"); return self.finish() }
                lock.withLock { port = p }
                if let t = try? self.c.store.openTab(url: base() + "/source.html", inSpace: self.c.currentSpaceID) { source = t.id }
                self.c.reloadAll(animated: false)
                if let id = source { self.c.show(id, focus: false) }
                done()
            }
        }
        step { [self] done in waitUntil({ page().map { !$0.isLoading && $0.title == "Reading list" } ?? false }, timeout: 12) { done() } }

        // 1. Off by default; not without Apple Intelligence; on, open pages get the part.
        run { [self] in
            aiCheck(app?.settings.values.linkPreviews == false && PageScripts.shared?.contains("linkpreview") == false && !feature.installed,
                  "\(tag): link previews are off by default (no page-script part)")
            if let s = app?.settings { ai.setLinkPreviews(true, settings: s) }
            aiCheck(app?.settings.values.linkPreviews == false, "\(tag): without Apple Intelligence the switch stays off")
            ai.testOverride = (.available, nil)
            if let s = app?.settings { ai.setLinkPreviews(true, settings: s) }
            aiCheck(app?.settings.values.linkPreviews == true && feature.installed && PageScripts.shared?.contains("linkpreview") == true
                  && ai.lastToggleEvent == .featureUsed(.aiLinkPreview(.on)),
                  "\(tag): with Apple Intelligence, Settings → AI turns link previews on; the part is in the page script")
        }
        wait(0.6)

        // 2. ⇧ over a link: the card, from a page read in the background.
        run { [self] in
            loadedBefore = HiddenPageReader.shared.loadCount
            tabsBefore = c.store.todayTabs(ofSpace: c.currentSpaceID).count
            fire(page(), "a1", "mouseover", ", shiftKey: true")
        }
        step { [self] done in waitUntil({ ready() }, timeout: 15) { done() } }
        run { [self] in
            let tabsInSpace = c.store.todayTabs(ofSpace: c.currentSpaceID).count
            let r = fake.asked.first
            aiCheck(ready() && card()?.summaryLabel.stringValue == summary.summary && card()?.pointLabels.count == 3
                  && card()?.titleLabel.stringValue == articleTitle,
                  "\(tag): ⇧ over a link shows its card: the target's title, a summary and \(card()?.pointLabels.count ?? 0) key points")
            if let card = card() {
                let a = card.anchor
                aiCheck(card.frame.minY + LinkPreviewCardView.margin >= a.maxY - 1 && c.card.frame.insetBy(dx: -30, dy: -30).contains(card.frame),
                      "\(tag): the card hangs under the link, inside the page (link \(Int(a.minX)),\(Int(a.maxY)); card at \(Int(card.frame.minX)),\(Int(card.frame.minY)))")
            }
            aiCheck(count("/article.html") == 1 && HiddenPageReader.shared.loadCount == loadedBefore + 1
                  && r?.title == articleTitle && r?.host == "127.0.0.1" && r?.text.contains("new pier") == true && r?.text.contains("Home") == false,
                  "\(tag): the target was read once in the background and summarized from its text (no menus; \(r?.text.count ?? 0) characters)")
            let profileID = c.store.profile(ofSpace: c.currentSpaceID).id
            aiCheck(app?.history.entry(profileID: profileID, url: base() + "/article.html") == nil && tabsInSpace == tabsBefore,
                  "\(tag): the background page isn't in the sidebar (\(tabsInSpace) tabs, as before) or Airc's history")
            aiCheck(ai.events.contains(.featureUsed(.aiLinkPreview(.used))), "\(tag): a preview records feature.used ai.link_preview used")
        }
        captureAIOnTop("linkpreview-card") { [card()].compactMap { $0 } }
        // Leaving the link hides it.
        run { fire(page(), "a1", "mouseout") }
        wait(0.7)
        run { [self] in
            // The card stays while the real pointer rests on it: with the window on screen, the person's own pointer may.
            if let card = card(), let w = card.window {
                let onScreen = w.convertToScreen(card.convert(card.cardRect, to: nil))
                if card.isHovered || onScreen.contains(NSEvent.mouseLocation) {
                    note("FAIL-ENV \(tag): leaving the link hides the card (the real pointer rests on the card: hovered \(card.isHovered), "
                         + "pointer \(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y)) in \(onScreen.integral); \(aiEnvironment.line))")
                    feature.hide(animated: false)
                    return
                }
            }
            aiCheck(card() == nil, "\(tag): leaving the link hides the card")
        }

        // 3. The same link again: the session's preview, no new load.
        run { fire(page(), "a1", "mouseover", ", shiftKey: true") }
        wait(0.4)
        run { [self] in
            aiCheck(ready() && count("/article.html") == 1 && fake.asked.count == 1 && ai.links.stats.cacheHits >= 1,
                  "\(tag): the same link again shows the kept preview at once (no load, no model call)")
            fire(page(), "a1", "mouseout")
        }
        wait(0.6)

        // 3b. One window, the same link on another Space's page (on Chromium in another profile, as a work and a personal
        // account at one address): the card goes as soon as its page does, and the other page's card is its own.
        run { fire(page(), "a1", "mouseover", ", shiftKey: true") }
        step { [self] done in waitUntil({ ready() }, timeout: 8) { done() } }
        step { [self] done in
            firstCard = card()
            homeSpace = c.currentSpaceID
            let first = c.store.selectedSpace
            do {
                let profileID = try chromium ? c.store.createProfile(name: "Previews test").id : first.profileID
                let space = try c.store.createSpace(name: "Second", icon: nil, theme: first.theme, profileID: profileID, after: first.id)
                otherTab = try c.store.openTab(url: base() + "/source.html", inSpace: space.id).id
                c.profiles.whenLoaded(profileID, { [self] _ in
                    c.reloadAll(animated: false)
                    c.switchToSpace(space.id, animated: false)
                    if let otherTab { c.show(otherTab, focus: false) }
                    done()
                }, failed: { [self] in aiCheck(false, "\(tag): the second profile loads"); done() })
            } catch {
                aiCheck(false, "\(tag): a second Space (\(error))")
                done()
            }
        }
        run { [self] in
            aiCheck(firstCard != nil && card() == nil && firstCard?.superview == nil,
                    "\(tag): showing another Space hides the card at once (its page left the screen)")
        }
        step { [self] done in waitUntil({ otherPage().map { !$0.isLoading && $0.title == "Reading list" } ?? false }, timeout: 12) { done() } }
        wait(0.6)
        run { fire(otherPage(), "a1", "mouseover", ", shiftKey: true") }
        step { [self] done in waitUntil({ ready() && feature.shownTab === otherPage() }, timeout: 15) { done() } }
        run { [self] in
            let own = ready() && feature.shownTab === otherPage() && card() !== firstCard
            if chromium {
                aiCheck(own && count("/article.html") == 2 && fake.asked.count == 2,
                        "\(tag): the same link on another profile's page gets its own card, read in that profile "
                        + "(\(count("/article.html")) loads, \(fake.asked.count) summaries)")
            } else {
                aiCheck(own, "\(tag): the same link on another tab gets its own card (one profile here: the kept preview)")
            }
            closeAsked = CACurrentMediaTime()
            if let otherTab { c.closeTab(otherTab) }
        }
        // Chromium closes a page asynchronously (its unload handlers first): the card goes when the page has.
        step { [self] done in waitUntil({ card() == nil }, timeout: 3) { done() } }
        run { [self] in
            aiCheck(card() == nil, "\(tag): closing the card's tab hides it (" + String(format: "%.0f ms after the close was asked)", (CACurrentMediaTime() - closeAsked) * 1000))
            c.switchToSpace(homeSpace, animated: false)
            if let id = source { c.show(id, focus: false) }
        }
        wait(0.6)

        // 4. Nothing without ⇧ really down, or for a link to the page itself.
        run {
            shift = false
            fire(page(), "a2", "mouseover", ", shiftKey: true")
        }
        wait(0.5)
        run { [self] in
            aiCheck(card() == nil && feature.lastRefusal == "⇧ isn't down" && count("/ferry.html") == 0,
                  "\(tag): a page's event alone, without ⇧ really down, loads nothing (\(feature.lastRefusal ?? "-"))")
            shift = true
            fire(page(), "a2", "mouseout")
            fire(page(), "a5", "mouseover", ", shiftKey: true")
        }
        wait(0.5)
        run { [self] in
            aiCheck(card() == nil && (feature.lastRefusal ?? "").contains("samePage"), "\(tag): a link to the page itself gets no card (\(feature.lastRefusal ?? "-"))")
            fire(page(), "a5", "mouseout")
            // Without ⇧ the pointer only passes; ⇧ pressed over the link asks.
            fire(page(), "a4", "mouseover")
        }
        wait(0.4)
        run { [self] in
            aiCheck(card() == nil, "\(tag): a link passed without ⇧ gets no card")
            fire(page(), "a4", "keydown")
        }
        step { [self] done in waitUntil({ card()?.state.isFinished == true }, timeout: 12) { done() } }
        run { [self] in
            aiCheck(card()?.state == .unavailable(title: "Tiny", .tooLittleText)
                  && card()?.summaryLabel.stringValue.contains("enough text") == true,
                  "\(tag): ⇧ pressed over a link asks too; a page with too little text says so (\(card()?.summaryLabel.stringValue ?? "no card"))")
            fire(page(), "a4", "mouseout")
        }
        wait(0.6)

        // 5. A press held on a link: its card, and the click that ends it doesn't open the link.
        run {
            button = true
            fire(page(), "a2", "pointerdown")
        }
        step { [self] done in waitUntil({ ready() && card()?.titleLabel.stringValue.hasPrefix("New ferry") == true }, timeout: 15) { done() } }
        run { [self] in
            aiCheck(ready() && card()?.titleLabel.stringValue.hasPrefix("New ferry") == true,
                  "\(tag): a press held on a link shows its card (\(card()?.titleLabel.stringValue ?? "no card"))")
            button = false
            fire(page(), "a2", "pointerup")
            fire(page(), "a2", "click")
        }
        wait(0.6)
        step { [self] done in
            page()?.evaluate("[location.pathname, window.__clicks || 0]") { [self] v in
                let a = v as? [Any] ?? []
                aiCheck(a.first as? String == "/source.html" && (a.last as? NSNumber)?.intValue == 0,
                      "\(tag): the click that ends the long press doesn't open the link (still on \(a.first ?? "?"), page's handler ran \(a.last ?? "?") times)")
                fire(page(), "a2", "mouseout")
                done()
            }
        }
        wait(0.6)

        // 6. Never preview a site; private windows never.
        run { fire(page(), "a3", "mouseover", ", shiftKey: true") }
        step { [self] done in waitUntil({ card()?.hostLabel.stringValue.hasPrefix("localhost") == true && card()?.state.isFinished == true }, timeout: 15) { done() } }
        run { [self] in
            card()?.menuNever()
            aiCheck(app?.settings.values.linkPreviewNever == ["localhost"] && card() == nil
                    && feature.lastToast == "Links to localhost won't be previewed",
                  "\(tag): the card's \"Never Preview Links on localhost\" adds the site to Settings → AI's list and says so (\(feature.lastToast ?? "no toast"))")
            fire(page(), "a3", "mouseout")
        }
        wait(0.4)
        run { [self] in
            app?.showSettings(page: .ai)
            fire(page(), "a3", "mouseover", ", shiftKey: true")
        }
        wait(0.6)
        run { [self] in
            aiCheck(card() == nil && (feature.lastRefusal ?? "").contains("never"),
                  "\(tag): a site set to never gets no previews (\(feature.lastRefusal ?? "-"))")
            captureAISettings2("linkpreview-settings")
            app?.settingsWindow?.window.orderOut(nil)
            fire(page(), "a3", "mouseout")
            loadedBefore = HiddenPageReader.shared.loadCount
            guard let app else { return }
            PrivateBrowsing.shared.open(app: app) { w in privateWindow = w }
        }
        step { [self] done in waitUntil({ privateWindow != nil }, timeout: 8) { done() } }
        run { privateWindow?.openPage(URL(string: base() + "/private.html")) }
        step { [self] done in waitUntil({ privateWindow?.shownPage.map { !$0.isLoading && $0.title == "Private reading list" } ?? false }, timeout: 10) { done() } }
        run { fire(privateWindow?.shownPage, "a1", "mouseover", ", shiftKey: true") }
        wait(0.8)
        run { [self] in
            aiCheck(card() == nil && HiddenPageReader.shared.loadCount == loadedBefore && feature.lastRefusal == "not a page of a main window",
                  "\(tag): a private window's links get no preview and nothing is loaded (\(feature.lastRefusal ?? "-"))")
            privateWindow?.closeWindow()
            // 7. Off: the part goes, the previews are forgotten.
            if let s = app?.settings { ai.setLinkPreviews(false, settings: s) }
            aiCheck(app?.settings.values.linkPreviews == false && !feature.installed && PageScripts.shared?.contains("linkpreview") == false
                  && ai.links.count == 0,
                  "\(tag): off, the page-script part goes and the session's previews are forgotten")
            fire(page(), "a1", "mouseover", ", shiftKey: true")
        }
        wait(0.6)
        run { [self] in
            aiCheck(card() == nil, "\(tag): off, ⇧ over a link does nothing")
            checkAIEvents(tag, ai.events, expect: ["ai.link_preview:on", "ai.link_preview:used", "ai.link_preview:off"])
            app?.settings.values.linkPreviewNever = []
        }

        // 8. The real on-device model, when this Mac has Apple Intelligence on: the article read in the background, timed.
        step { [self] done in
            ai.testOverride = nil
            ai.testModels = nil
            guard let model = AppleIntelligence.summaryModel(), let profile = page()?.profile, let u = URL(string: base() + "/article.html") else {
                skip("\(tag): real on-device run: this Mac's model is unavailable (\(AppleIntelligence.availability.label))")
                return done()
            }
            let start = CACurrentMediaTime()
            HiddenPageReader.shared.read(u, profile: profile, cap: LinkPreviewFeature.readCap) { [self] text in
                let read = CACurrentMediaTime() - start
                guard let text, let r = LinkSummaryPrompt.request(for: text) else {
                    aiCheck(false, "\(tag): real run: the article is read in the background")
                    return done()
                }
                Task { @MainActor in
                    let t = CACurrentMediaTime()
                    let outcome = await AIDeadline.run(timeout: 30) { try await model.summarize(r) }
                    let took = CACurrentMediaTime() - t
                    if case .value(let s) = outcome, let shown = LinkSummaryRules.accept(s, title: r.title) {
                        self.note("\(tag): real model: \"\(shown.summary)\" points \(shown.keyPoints)")
                        self.check(true, "\(tag): the real on-device model summarized the page (" + String(format: "read %.2f s, summary %.2f s)", read, took))
                    } else {
                        self.check(false, "\(tag): the real on-device model summarized the page (\(outcome))")
                    }
                    done()
                }
            }
        }
        run { [self] in
            note("\(tag): environment at the end: \(aiEnvironment.line)")
            server?.stop()
            LinkPreviewFeature.trustSynthetic = false
        }
    }
}
#endif

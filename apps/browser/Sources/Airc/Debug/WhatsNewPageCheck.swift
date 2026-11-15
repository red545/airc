// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// whatsnew2, the second half of `--script paritywhatsnew` (both engines): the "What's New in Airc" tab
/// (Browser/WhatsNewPage.swift).
///   1. The default, Open a tab: an update from 0.1.13 to 0.1.15 through the real launch path opens one Today tab at
///      airc://whats-new?from=0.1.13&to=0.1.15 in the front window, with the native page in the card: 0.1.15's and
///      0.1.14's lines, each with its detail, its pictures loaded. No card, no "Updated!" toast. Light and dark shots.
///   2. Every "Show me" / "Try it" on the page, with a real driver click, does its thing: ⌘T's Command Bar with its
///      hint, Settings on the right page scrolled to the right section, the Library on the right section, Send
///      Feedback; Read the full changelog opens the changelog in a new tab. A page from 0.1.12 adds 0.1.13's Agents,
///      What's new and Feedback buttons.
///   2b. wnactions: a 7-line release (the cap since wnactions): the page lays out all seven, one under the other;
///      real clicks on Settings › AI (scrolled to Downloads) and Settings › Shortcuts; a line with no action has no
///      button; the sidebar card for the same release shows five lines and "And more", inside its plate.
///   3. Show a small card: the card shows; a real click on its body, then on See All, opens the same tab (never two).
///   4. Don't show: no tab, no card, the "Updated!" toast. A settings file from before the choice ("Show what's new"
///      off) reads as Don't show, on as Open a tab.
extension SnapshotRunner {
    private static let tabRunning = "0.1.15 (202611141334)"
    private static let tabFrom = "0.1.13 (202611131851)"

    func whatsNewTabCases(_ catalog: WhatsNewCatalog, spaceID: String, _ ok: @escaping (Bool, String) -> Void) {
        let center = WhatsNewCenter.shared
        func simulateUpdate(_ style: WhatsNewStyle, from: String = SnapshotRunner.tabFrom) {
            run { [self] in
                closeWhatsNewTabs()
                app?.settings.values.whatsNewStyle = style
                center.settingChanged(style)
                center.showForCheck(nil)
                c.updatedToast?.removeFromSuperview()
                try? FileManager.default.removeItem(at: WhatsNewCenter.stateFile)
                try? Data(from.utf8).write(to: UpdateCenter.lastVersionFile)
                UpdateCenter.runningVersionOverride = Self.tabRunning
                UpdateCenter.shared.noteLaunchedVersion(inScriptedRun: true)
            }
        }

        // 1. Open a tab (the default), after an update from 0.1.13. (Colours: the Space the tab opens in, the current one.)
        _ = spaceID
        run { [self] in
            UpdateCenter.shared.setReady(nil)
            let d = AppSettings.Values()
            ok(d.whatsNewStyle == .tab, "After an update is “Open a tab” by default (\(d.whatsNewStyle))")
        }
        simulateUpdate(.tab)
        step { [self] done in waitUntil({ self.shownWhatsNewPage != nil }, timeout: 8) { done() } }
        run { [self] in
            let want = WhatsNewURL.make(from: "0.1.13", to: "0.1.15")
            let tab = c.store.tab(c.shownTabID)
            let tabs = c.store.state.tabs.values.filter { WhatsNewURL.isPage($0.url) }
            ok(tab?.url == want && tab?.title == WhatsNewURL.title && tab?.isToday == true && tabs.count == 1,
               "the update from 0.1.13 opens one Today tab at \(want) in the front window (\(tab?.url ?? "-"), \(tabs.count) tab(s))")
            guard let page = shownWhatsNewPage else { return ok(false, "the tab shows the native What's new page in the card") }
            ok(page.host.superview === c.card && c.engineTab(for: c.shownTabID ?? "") == nil,
               "the tab shows the native page in the card, with no engine page (works offline, the same on both engines)")
            let content = page.model.content
            let expected = WhatsNewPageContent.make(catalog, from: "0.1.13", current: "0.1.15")
            ok(content == expected && content?.sections.map(\.version) == ["0.1.15", "0.1.14"],
               "it merges 0.1.15 and 0.1.14, newest first (\(content?.sections.map(\.version) ?? []))")
            let items = content?.sections.flatMap(\.highlights) ?? []
            ok(items.count == 9 && items.allSatisfy { ($0.detail?.count ?? 0) > 60 },
               "all \(items.count) lines, each with a sentence or two on what it does")
            let pics = items.compactMap(\.image)
            ok(!pics.isEmpty && pics.allSatisfy { page.model.image($0) != nil },
               "its pictures load from the bundle (\(pics.joined(separator: ", ")))")
            ok(c.sidebar.update.whatsNew == nil && c.updatedToast?.shownText == nil,
               "no card and no “Updated!” toast with the tab")
            let s = center.state
            ok(s.version == "0.1.15" && s.from == "0.1.13" && s.dismissed && s.offered.contains("0.1.15"),
               "the state file: 0.1.15 since 0.1.13, offered once, nothing pending")
            // VoiceOver: the page is in the card's accessibility tree with its buttons named.
            let row = c.store.tab(c.shownTabID)
            ok(row.map { LocalDocumentURL.isLocal($0.url) } == true, "the tab is a local document (not synced, never loaded)")
        }
        capture("whatsnew-tab-light")
        run { [self] in
            try? c.store.updateSpace(c.currentSpaceID) { $0.theme.appearance = .dark }
            c.reloadAll(animated: false)
        }
        wait(0.5)
        run { [self] in ok(shownWhatsNewPage?.model.theme.isDark == true, "dark: the page follows the Space's colours") }
        capture("whatsnew-tab-dark")
        run { [self] in
            shownWhatsNewPage?.model.scrollTarget = WhatsNewPageModel.footerID
        }
        wait(0.5)
        capture("whatsnew-tab-dark-end")
        run { [self] in
            try? c.store.updateSpace(c.currentSpaceID) { $0.theme.appearance = .light }
            c.reloadAll(animated: false)
        }
        wait(0.4)
        // A second open of the same range brings the same tab back (never two).
        run { [self] in
            let before = c.store.state.tabs.values.filter { WhatsNewURL.isPage($0.url) }.map(\.id)
            let again = center.openTab(from: "0.1.13", to: "0.1.15", in: c)
            ok(before.count == 1 && again == before.first, "opening it again shows the same tab")
        }

        // 2. Every Show me / Try it, with real clicks.
        pointerInWindow("whatsnew-tab")
        let page15 = WhatsNewPageContent.make(catalog, from: "0.1.13", current: "0.1.15")
        for s in page15?.sections ?? [] {
            for h in s.highlights { if let a = h.action { actionCase(a, id: WhatsNewPageModel.id(s.version, h), ok) } }
        }
        // 0.1.13's buttons (Agents, What's new, Feedback): the page from 0.1.12.
        run { [self] in center.openTab(from: "0.1.12", to: "0.1.15", in: c) }
        wait(0.6)
        let page13 = WhatsNewPageContent.make(catalog, from: "0.1.12", current: "0.1.15")
        for h in page13?.sections.first(where: { $0.version == "0.1.13" })?.highlights ?? [] {
            if let a = h.action { actionCase(a, id: WhatsNewPageModel.id("0.1.13", h), ok) }
        }
        // The full changelog, at the bottom.
        var tabsBefore = 0
        run { [self] in
            shownWhatsNewPage?.model.scrollTarget = WhatsNewPageModel.footerID
            tabsBefore = c.pages.count
        }
        wait(0.6)
        step { [self] done in tabClick("whatsnew.changelog") { done() } }
        step { [self] done in
            let want = ParityCommandCatalog.releaseNotes.absoluteString + "#v0.1.15"
            waitUntil({ self.c.shownTabID.flatMap { self.c.engineTab(for: $0) }?.url?.absoluteString == want }, timeout: 8) {
                let url = self.c.shownTabID.flatMap { self.c.engineTab(for: $0) }?.url?.absoluteString ?? "-"
                ok(url == want && self.c.pages.count == tabsBefore + 1,
                   "Read the full changelog opens \(want) in a new tab (\(url))")
                done()
            }
        }

        // 2b. wnactions: a 7-line release with the two new actions and a deliberate "none".
        sevenLineCases(catalog, ok)

        // 3. Show a small card: its body and See All open the tab.
        simulateUpdate(.card)
        wait(0.8)
        run { [self] in
            let b = c.sidebar.update
            ok(b.whatsNew?.version == "0.1.15" && c.store.state.tabs.values.allSatisfy { !WhatsNewURL.isPage($0.url) },
               "“Show a small card”: the card shows and no tab opens")
        }
        step { [self] done in cardClick(c.sidebar.update.title, "the card's body") { done() } }
        step { [self] done in waitUntil({ self.shownWhatsNewPage != nil }, timeout: 4) { done() } }
        run { [self] in
            let tab = c.store.tab(c.shownTabID)
            ok(tab?.url == WhatsNewURL.make(from: "0.1.13", to: "0.1.15") && shownWhatsNewPage != nil,
               "a click on the card opens the What's new tab (\(tab?.url ?? "-"))")
            ok(c.sidebar.update.whatsNew != nil, "the card stays (× closes it)")
            if let any = c.store.state.tabs.values.first(where: { !WhatsNewURL.isPage($0.url) && $0.spaceID == c.currentSpaceID }) { c.show(any.id) }
        }
        wait(0.4)
        step { [self] done in cardClick(c.sidebar.update.seeAll, "See All") { done() } }
        step { [self] done in waitUntil({ self.shownWhatsNewPage != nil }, timeout: 4) { done() } }
        run { [self] in
            let tabs = c.store.state.tabs.values.filter { WhatsNewURL.isPage($0.url) }
            ok(shownWhatsNewPage != nil && tabs.count == 1, "See All opens the same tab, not a second one (\(tabs.count))")
            ok(c.sidebar.update.seeAll.accessibilityLabel() == "See what’s new, explained", "VoiceOver names See All for the tab")
        }

        // 4. Don't show: the toast, as before What's new.
        simulateUpdate(.off)
        wait(1.4)
        run { [self] in
            ok(c.store.state.tabs.values.allSatisfy { !WhatsNewURL.isPage($0.url) } && c.sidebar.update.whatsNew == nil
               && c.updatedToast?.shownText != nil,
               "“Don’t show”: no tab, no card, just “Updated!” (\(c.updatedToast?.shownText ?? "no toast"))")
            // The old toggle's files.
            func decode(_ json: String) -> WhatsNewStyle? { (try? JSONDecoder().decode(AppSettings.Values.self, from: Data(json.utf8)))?.whatsNewStyle }
            ok(decode(#"{"showWhatsNewAfterUpdates":false}"#) == .off && decode(#"{"showWhatsNewAfterUpdates":true}"#) == .tab
               && decode(#"{"showWhatsNewAfterUpdates":true,"whatsNewStyle":"card"}"#) == .card,
               "a settings file from before the choice keeps its meaning (off → Don’t show, on → Open a tab)")
            c.updatedToast?.removeFromSuperview()
            app?.settings.values.whatsNewStyle = .tab
            center.settingChanged(.tab)
            ok(app?.settings.values.showWhatsNewAfterUpdates == true, "older builds still read the toggle (on with Open a tab)")
            UpdateCenter.runningVersionOverride = nil
            closeWhatsNewTabs()
        }
    }

    // MARK: wnactions: seven lines, Settings › AI and Settings › Shortcuts

    static let sevenVersion = "0.1.99"
    static let sevenLines: [WhatsNewHighlight] = [
        .init(title: "Automatic download names", icon: "arrow.down.circle",
              detail: "Turn on Rename automatically in Settings › AI › Downloads, and a download with an unclear name gets a clear one by itself.",
              lead: "Tidy Downloads renames automatically", action: .settingsAI),
        .init(title: "Edit and Help shortcuts", icon: "command",
              detail: "Every menu command now has a keyboard shortcut you can change. Settings › Shortcuts lists them all, with a search field.",
              lead: "Edit and Help shortcuts", action: .settingsShortcuts),
        .init(title: "Dark mode reads better", icon: "moon",
              detail: "Text in dark mode now meets standard contrast in every Space colour, so labels and addresses are easier to read.",
              lead: "Dark mode reads better"),
        .init(title: "Share Quote", icon: "quote.bubble",
              detail: "Select a few words on a page and a Share Quote button shows under the address. Click it to copy a link to that text.",
              lead: "Share Quote", action: .settingsGeneral),
        .init(title: "Sync a little faster", icon: "icloud",
              detail: "Changes on one Mac now reach your other Macs sooner, and a Space you rename shows its new name everywhere right away.",
              lead: "Sync a little faster", action: .settingsSync),
        .init(title: "Notes in the Library", icon: "note.text",
              detail: "Every note you wrote, in every Space, is in the Library under Notes, newest first, with a search field at the top.",
              lead: "Notes in the Library", action: .libraryNotes),
        .init(title: "Tell us what you think", icon: "bubble.left.and.text.bubble.right",
              detail: "The speech bubble at the bottom of the sidebar sends us a note, with a screenshot if you want one. We read every one.",
              lead: "Tell us what you think", action: .sendFeedback),
    ]

    private func sevenLineCases(_ base: WhatsNewCatalog, _ ok: @escaping (Bool, String) -> Void) {
        let center = WhatsNewCenter.shared
        let v = Self.sevenVersion
        let fixture: WhatsNewCatalog = {
            var f = base
            f.releases.removeAll { $0.version == v }
            f.releases.insert(WhatsNewRelease(version: v, highlights: Self.sevenLines), at: 0)
            return f
        }()
        // From the newest bundled release, so the page and the card show only the fixture's seven lines.
        let since = base.releases.compactMap { WhatsNewVersion($0.version) }.filter { $0 < WhatsNewVersion(v)! }.max()?.description ?? "0.1.15"
        run { [self] in
            var eight = fixture
            eight.releases[0].highlights.append(.init(title: "One too many", icon: "star", detail: "An eighth line."))
            ok((try? fixture.validate()) != nil && WhatsNewCatalog.maxPerRelease == 7
               && (try? eight.validate()) == nil,
               "a release may carry 7 lines (an 8th is refused)")
            center.catalogOverride = fixture
            _ = center.openTab(from: since, to: v, in: c)
        }
        wait(0.8)
        run { [self] in
            guard let page = shownWhatsNewPage else { return ok(false, "the 7-line page shows") }
            page.host.layoutSubtreeIfNeeded()
            let ids = Self.sevenLines.map { WhatsNewPageModel.id(v, $0) }
            ok(page.model.content?.sections.map(\.version) == [v] && page.model.content?.sections.first?.highlights.count == 7,
               "the page lists all 7 lines of \(v) (since \(since): \(page.model.content?.sections.map(\.version) ?? []))")
            let frames = ids.compactMap { TestAnchors.frame("whatsnew.item.\($0)", in: page.host) }
            let stacked = frames.count == 7 && zip(frames, frames.dropFirst()).allSatisfy { $1.minY >= $0.maxY + 8 - 0.5 }
            let aligned = frames.allSatisfy { abs($0.minX - frames[0].minX) < 0.5 && abs($0.width - frames[0].width) < 0.5 }
            ok(stacked && aligned && frames.allSatisfy { $0.height > 60 },
               "the 7 lines stack one under the other, same width, none overlapping (\(frames.map { "\(Int($0.minY))+\(Int($0.height))" }.joined(separator: " ")))")
            // Each line's button sits in its own line; the deliberate no-action line ("none") has none.
            guard frames.count == 7 else { return }
            var placed: [String] = []
            for (h, f) in zip(Self.sevenLines, frames) {
                let buttons = Self.sevenLines.compactMap(\.action).filter { a in
                    TestAnchors.frame("whatsnew.action.\(a.rawValue)", in: page.host).map { f.contains(CGPoint(x: $0.midX, y: $0.midY)) } == true
                }
                placed.append("\(h.action?.rawValue ?? "none"):\(buttons.map(\.rawValue).joined(separator: "+"))")
            }
            let want = Self.sevenLines.map { h in "\(h.action?.rawValue ?? "none"):\(h.action?.rawValue ?? "")" }
            ok(placed == want, "every line has its own Show me and the no-action line has none (\(placed.joined(separator: ", ")))")
            shownWhatsNewPage?.model.scrollTarget = WhatsNewPageModel.id(v, Self.sevenLines[0])
        }
        wait(0.5)
        capture("whatsnew-tab-seven")
        run { [self] in shownWhatsNewPage?.model.scrollTarget = WhatsNewPageModel.id(v, Self.sevenLines[6]) }
        wait(0.5)
        capture("whatsnew-tab-seven-end")
        // The two new buttons, with real clicks.
        for h in Self.sevenLines.prefix(2) { if let a = h.action { actionCase(a, id: WhatsNewPageModel.id(v, h), ok) } }
        // The sidebar card for the same release: five lines and "And more", inside its plate.
        run { [self] in
            center.showForCheck(WhatsNewContent.merge(fixture, from: since, current: v))
        }
        wait(0.6)
        run { [self] in
            let b = c.sidebar.update
            c.sidebar.layoutSubtreeIfNeeded()
            let titles = b.lineLabels.filter { !$0.isHidden }.map(\.stringValue)
            ok(b.whatsNew?.version == v && titles == Self.sevenLines.prefix(WhatsNewContent.maxLines).map(\.title),
               "the card shows the first \(WhatsNewContent.maxLines) of 7 lines: \(titles.joined(separator: " | "))")
            ok(b.whatsNew?.more == true && !b.moreLabel.isHidden, "and says “And more” for the other two")
            let inside = b.lineLabels.filter { !$0.isHidden }.allSatisfy { $0.frame.maxX <= b.pillRect.maxX && $0.frame.minY >= b.pillRect.minY && $0.frame.maxY <= b.pillRect.maxY }
                && b.moreLabel.frame.maxY <= b.pillRect.maxY && b.seeAll.frame.maxY <= b.pillRect.maxY
            ok(inside && abs(b.pillRect.height - UpdateButtonView.cardHeight(mode: b.mode, rows: b.rowLines)) < 0.5,
               "every line, “And more” and See All sit inside the card (\(Int(b.pillRect.height)) pt)")
        }
        capture("whatsnew-card-seven")
        run { [self] in
            center.showForCheck(nil)
            center.catalogOverride = nil
        }
        wait(0.4)
    }

    // MARK: Helpers

    /// The What's new page in the card now, if any.
    var shownWhatsNewPage: WhatsNewPage? {
        guard let id = c.shownTabID, WhatsNewURL.isPage(c.store.tab(id)?.url), let p = WhatsNewPage.existing(id),
              p.host.superview === c.card, !p.host.isHidden else { return nil }
        return p
    }

    private func closeWhatsNewTabs() {
        for t in c.store.state.tabs.values where WhatsNewURL.isPage(t.url) { c.closeTab(t.id) }
    }

    /// One "Show me": scrolls its line into view, clicks its button for real, checks what it opened, and puts it away.
    private func actionCase(_ a: WhatsNewAction, id: String, _ ok: @escaping (Bool, String) -> Void) {
        var before = 0
        run { [self] in
            shownWhatsNewPage?.model.scrollTarget = id
            before = shownWhatsNewPage?.model.performed.count ?? 0
        }
        wait(0.5)
        step { [self] done in tabClick("whatsnew.action.\(a.rawValue)") { done() } }
        wait(0.6)
        step { [self] done in
            let settings = { self.app?.settingsWindow.flatMap { $0.window.isVisible ? $0.model : nil } }
            func settingsOn(_ p: SettingsPage, _ section: String? = nil) -> () -> Bool {
                { settings()?.page == p && (section == nil || settings()?.revealed == section) }
            }
            let cond: () -> Bool
            let what: String
            switch a {
            case .commandBar: cond = { self.c.commandBar != nil && self.c.toast.shownText?.contains("⌘T") == true }; what = "opens the Command Bar with its hint"
            case .settingsAppIcon: cond = settingsOn(.appearance, "App Icon"); what = "opens Settings › Appearance at App Icon"
            case .settingsSitePreviews: cond = settingsOn(.appearance, "Site Previews"); what = "opens Settings › Appearance at Site Previews"
            case .settingsAgents: cond = settingsOn(.agents); what = "opens Settings › Agents"
            case .settingsSync: cond = settingsOn(.sync); what = "opens Settings › Sync"
            case .settingsImport: cond = settingsOn(.importing); what = "opens Settings › Import"
            case .settingsBoosts: cond = settingsOn(.boosts); what = "opens Settings › Boosts"
            case .settingsGeneral: cond = settingsOn(.general); what = "opens Settings › General"
            case .settingsUpdates: cond = settingsOn(.general, "Automatic Updates"); what = "opens Settings › General at Automatic Updates"
            case .libraryArchive: cond = { self.c.library?.model.section == .archive }; what = "opens the Library on Archived Tabs"
            case .libraryNotes: cond = { self.c.library?.model.section == .notes }; what = "opens the Library on Notes"
            case .sendFeedback: cond = { FeedbackSheet.active != nil }; what = "opens Send Feedback"
            case .settingsAI:
                // Scrolled for real: the Downloads switch is on screen in the window.
                let downloadsShown = {
                    guard let host = self.app?.settingsWindow?.window.contentView,
                          let f = TestAnchors.frame("ai.tidyDownloads", in: host) else { return false }
                    return f.minY >= 0 && f.maxY <= host.bounds.height
                }
                cond = { settingsOn(.ai, "Downloads")() && downloadsShown() }; what = "opens Settings › AI scrolled to Downloads"
            case .settingsShortcuts: cond = settingsOn(.shortcuts); what = "opens Settings › Shortcuts"
            }
            waitUntil(cond, timeout: 4) {
                let performed = self.shownWhatsNewPage?.model.performed ?? []
                ok(cond() && performed.count == before + 1 && performed.last == a.rawValue,
                   "“\(a.buttonTitle)” for \(a.rawValue) \(what) (performed \(performed.suffix(1)), last hit \(TestAnchors.lastHit["whatsnew.action.\(a.rawValue)"] ?? "real click"))")
                // Put it away, so the next click lands on the page.
                switch a {
                case .commandBar: self.c.closeCommandBar()
                case .libraryArchive, .libraryNotes: if self.c.library != nil { self.c.toggleLibrary() }
                case .sendFeedback: FeedbackSheet.active?.close()
                default: self.app?.settingsWindow?.window.orderOut(nil)
                }
                self.c.window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
            }
        }
    }

    /// A real driver click on a page anchor (posted when the driver can't be used, and the log says which).
    private func tabClick(_ anchor: String, _ done: @escaping () -> Void) {
        guard let page = shownWhatsNewPage else {
            check(false, "paritywhatsnew: \(anchor): no What's new page on screen")
            return done()
        }
        page.host.layoutSubtreeIfNeeded()
        guard let p = anchorPoint(anchor, in: page.host) else {
            check(false, "paritywhatsnew: \(anchor) is on the page")
            return done()
        }
        let frame = c.window.contentView?.superview
        let hit = frame.flatMap { $0.hitTest($0.convert(p, from: nil)) }
        if hit.map({ $0.isDescendant(of: page.host) }) != true {
            check(false, "paritywhatsnew: \(anchor) at \(NSStringFromPoint(p)) is uncovered (hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing"))")
        }
        realOrPostedClick(p, anchor, done)
    }

    private func cardClick(_ view: NSView, _ name: String, _ done: @escaping () -> Void) {
        c.window.layoutIfNeeded()
        realOrPostedClick(view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), name, done)
    }

    private func realOrPostedClick(_ p: NSPoint, _ name: String, _ done: @escaping () -> Void) {
        if realPointerInput {
            eventsRealClick(p) { good, out in
                self.note("paritywhatsnew: \(name): real driver click at \(NSStringFromPoint(p))\(good ? "" : " FAILED: \(out.prefix(160))")")
                if !good { self.check(false, "paritywhatsnew: the driver clicks \(name)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
            }
        } else {
            note("paritywhatsnew: \(name): posted click (no UI driver in this run)")
            click(at: p, in: c.window) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done) }
        }
    }
}
#endif

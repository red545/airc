// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// An update whose feed item carries highlights (the fixture appcast's `<airc:highlights>`); nothing installs.
final class FakeHighlightsUpdate: ReadyUpdate {
    let version: String
    let highlights: [WhatsNewHighlight]
    private(set) var installs = 0
    init(version: String, highlights: [WhatsNewHighlight]) {
        self.version = version
        self.highlights = highlights
    }
    func installAndRelaunch() { installs += 1 }
}

/// `--script paritywhatsnew`, then `--script paritywhatsnew-relaunch` on the same data folder (both engines): the
/// "What's new" card after an update (Browser/WhatsNewCard.swift) and the highlights on Restart to Update.
///   1. An update is simulated: LastVersion says 0.1.10, the running version is 0.1.12 (a test build is always 0.1.0),
///      and the real launch path runs (`noteLaunchedVersion`) with the bundled WhatsNew.json. The card shows in the
///      update pill's spot with the pill's metrics: "Airc 0.1.12 is here", 0.1.12's and 0.1.11's lines merged newest
///      first, five at most, "And more"; no "Updated!" toast; VoiceOver labels. Light and dark.
///   2. Reduce Motion: the card's height changes at once (no spring).
///   3. See All (a real driver click) opens https://aircbrowser.com/changelog#v0.1.12 in a new tab; × (a real driver
///      click) dismisses it, and the state file says so.
///   4. A fixture appcast's item with `<airc:highlights>`, read as Sparkle does (its propertiesDictionary keeps unknown
///      elements by qualified name): the Restart to Update card shows its three lines under the pill. A feed item
///      without them keeps the plain 34 pt pill. Light and dark.
///   relaunch: LastVersion is now 0.1.12 and the card was dismissed: no card, no toast. Then the three-launch rule on
///   the real state file, and a fresh data folder (no LastVersion) gets nothing.
/// Real clicks need the UI driver in a dedicated session (`AIRC_REAL_KEYS=1`, `AIRC_UI_DEDICATED_SESSION=1`); without
/// them the clicks are posted and the log says so.
extension SnapshotRunner {
    private var wnButton: UpdateButtonView { c.sidebar.update }
    private static let wnRunning = "0.1.12 (202611131000)"

    func parityWhatsNewScenario(relaunch: Bool) {
        let center = WhatsNewCenter.shared
        var spaceID = ""
        let tag = "paritywhatsnew\(relaunch ? "-relaunch" : "")"
        func ok(_ good: Bool, _ what: String) { check(good, "\(tag): \(what)") }
        guard let catalog = WhatsNewCenter.bundled else {
            run { [self] in check(false, "\(tag): the app bundles a valid WhatsNew.json") }
            return
        }
        run { [self] in
            ok(true, "the app bundles a valid WhatsNew.json (\(catalog.releases.map(\.version).joined(separator: ", ")))")
            UpdateCenter.runningVersionOverride = Self.wnRunning
            spaceID = c.currentSpaceID
            try? c.store.updateSpace(spaceID) { $0.theme.appearance = .light }
            c.reloadAll(animated: false)
            ok(app?.settings.values.showWhatsNewAfterUpdates == true, "Show what's new after updates is on by default")
            // whatsnew2: the card is now the "Show a small card" choice (the default opens a tab: WhatsNewPageCheck.swift).
            app?.settings.values.whatsNewStyle = .card
        }
        if relaunch { return relaunchCases(catalog, ok) }

        // 1. The update, through the real launch path.
        run { [self] in
            try? FileManager.default.removeItem(at: WhatsNewCenter.stateFile)
            try? Data("0.1.10 (202611122138)".utf8).write(to: UpdateCenter.lastVersionFile)
            UpdateCenter.shared.noteLaunchedVersion(inScriptedRun: true)
        }
        wait(0.8)
        run { [self] in
            let b = wnButton, sidebar = c.sidebar
            sidebar.layoutSubtreeIfNeeded()
            let expected = WhatsNewContent.merge(catalog, from: "0.1.10", current: "0.1.12")
            guard let shown = b.whatsNew, let expected else {
                return ok(false, "the card shows after 0.1.10 → 0.1.12 (content \(String(describing: b.whatsNew)), expected \(String(describing: expected)))")
            }
            ok(shown == expected && shown.versions == ["0.1.12", "0.1.11"],
               "the card merges 0.1.12 and 0.1.11, newest first (\(shown.versions))")
            ok(b.title.stringValue == "Airc 0.1.12 is here", "it reads “\(b.title.stringValue)”")
            let titles = b.lineLabels.filter { !$0.isHidden }.map(\.stringValue)
            ok(titles == expected.lines.map(\.title) && titles.count == 5,
               "five lines, newest first: \(titles.joined(separator: " | "))")
            ok(shown.more && !b.moreLabel.isHidden && b.moreLabel.stringValue == UpdateButtonView.moreTitle,
               "past five lines it says “And more”")
            // The pill's spot and metrics.
            let plate = sidebar.convert(b.pillRect, from: b), footerTop = sidebar.footer.frame.minY
            ok(abs(plate.maxY + UpdateButtonView.bottomInset - footerTop) < 0.5 && plate.minY >= sidebar.pager.frame.maxY - 0.5,
               "in the update pill's spot, just above the footer (card \(NSStringFromRect(plate)), footer at \(footerTop))")
            ok(abs(plate.minX - AircMetrics.Sidebar.inset) < 0.5 && abs(plate.width - (sidebar.bounds.width - 2 * AircMetrics.Sidebar.inset)) < 0.5,
               "the pill's insets and width (\(plate.minX), \(plate.width) in a \(sidebar.bounds.width) pt sidebar)")
            ok(abs(b.pillRect.height - UpdateButtonView.cardHeight(mode: b.mode, rows: b.rowLines)) < 0.5
               && abs(b.height - (UpdateButtonView.topInset + b.pillRect.height + UpdateButtonView.bottomInset)) < 0.5,
               "its height is the header's 34 pt plus 20 pt rows (\(b.pillRect.height))")
            ok(b.title.font == AircFont.callout.weight(.semibold).appFont, "the title is the pill's (callout semibold)")
            let inside = b.lineLabels.filter { !$0.isHidden }.allSatisfy { $0.frame.maxX <= b.pillRect.maxX && $0.frame.minY >= b.pillRect.minY && $0.frame.maxY <= b.pillRect.maxY }
                && b.seeAll.frame.maxY <= b.pillRect.maxY && b.close.frame.maxX <= b.pillRect.maxX
            ok(inside, "every line, See All and × sit inside the plate")
            ok(c.updatedToast?.shownText == nil, "no “Updated!” toast on top of the card")
            // VoiceOver.
            let label = b.accessibilityLabel() ?? ""
            ok(b.accessibilityRole() == .group && label.hasPrefix("Airc 0.1.12 is here") && expected.lines.allSatisfy { label.contains($0.spoken) },
               "VoiceOver reads the card as a group: “\(label.prefix(90))…”")
            ok(b.seeAll.accessibilityLabel() == "See what’s new, explained" && b.close.accessibilityLabel() == "Dismiss What’s New",
               "VoiceOver names See All and × (\(b.seeAll.accessibilityLabel() ?? "-"), \(b.close.accessibilityLabel() ?? "-"))")
            let s = center.state
            ok(s.version == "0.1.12" && s.from == "0.1.10" && s.shownLaunches == 1 && !s.dismissed && s.offered.contains("0.1.12"),
               "the state file: 0.1.12 since 0.1.10, launch 1 of 3")
            ok(hits(b.close) && hits(b.seeAll), "clicks on See All and × reach them")
        }
        widthCases("card", ok)
        capture("whatsnew-light")
        run { [self] in
            try? c.store.updateSpace(spaceID) { $0.theme.appearance = .dark }
            c.reloadAll(animated: false)
        }
        wait(0.4)
        capture("whatsnew-dark")
        run { [self] in
            try? c.store.updateSpace(spaceID) { $0.theme.appearance = .light }
            c.reloadAll(animated: false)
        }

        // 2. Reduce Motion: no spring, the height is there at once (and springs without it).
        var shownContent: WhatsNewContent?
        var full: CGFloat = 0
        run { [self] in
            shownContent = center.content
            MainActor.assumeIsolated { AircMotion.reduceMotionOverride = true }
            center.showForCheck(nil)
            let gone = wnButton.height
            center.showForCheck(shownContent)
            full = wnButton.height
            MainActor.assumeIsolated { AircMotion.reduceMotionOverride = nil }
            ok(gone == 0 && full > 100, "Reduce Motion: the card goes and comes at once, no spring (\(gone), \(full))")
            center.showForCheck(nil)
        }
        wait(0.8)
        run { [self] in
            center.showForCheck(shownContent)
            ok(wnButton.height < full - 1, "without Reduce Motion it rises on the row spring (\(wnButton.height) of \(full) right after)")
        }
        wait(0.8)

        // 3. See All, then ×, with real clicks.
        pointerInWindow("whatsnew")
        var tabsBefore = 0
        step { [self] done in
            tabsBefore = c.pages.count
            wnClick(wnButton.seeAll, "See All") { done() }
        }
        step { [self] done in
            // whatsnew2: See All opens the What's new tab (which links the full changelog), not the website.
            let want = WhatsNewURL.make(from: "0.1.10", to: "0.1.12")
            waitUntil({ self.shownWhatsNewPage != nil }, timeout: 8) {
                let url = self.c.store.tab(self.c.shownTabID)?.url ?? "-"
                ok(url == want && self.shownWhatsNewPage != nil && self.c.pages.count == tabsBefore && center.openedForCheck?.absoluteString == want,
                   "See All opens the What's new tab at \(want) (\(url), engine pages \(tabsBefore) → \(self.c.pages.count))")
                ok(self.wnButton.whatsNew != nil, "the card stays after See All")
                if let other = self.c.store.state.tabs.values.first(where: { !WhatsNewURL.isPage($0.url) && $0.spaceID == self.c.currentSpaceID }) { self.c.show(other.id) }
                done()
            }
        }
        wait(0.5)
        step { [self] done in wnClick(wnButton.close, "×") { done() } }
        step { [self] done in
            waitUntil({ self.wnButton.whatsNew == nil && self.wnButton.height == 0 }, timeout: 3) {
                let s = center.state
                ok(self.wnButton.whatsNew == nil && !self.wnButton.isShowing && s.dismissed,
                   "× dismisses it, for good (height \(self.wnButton.height), dismissed \(s.dismissed))")
                done()
            }
        }

        // 4. Restart to Update with the fixture appcast's highlights.
        var fake: FakeHighlightsUpdate?
        run { [self] in
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:airc="\(WhatsNewAppcast.namespace)" version="2.0"><channel><title>Airc</title>
            <item><title>Airc 0.1.13 (stable)</title><sparkle:version>202611140900</sparkle:version><sparkle:shortVersionString>0.1.13</sparkle:shortVersionString>
            <sparkle:releaseNotesLink>https://aircbrowser.com/changelog#v0.1.13</sparkle:releaseNotesLink>
            <airc:highlights>[{"title":"What’s new after updates","lead":"A What’s new card after every update","detail":"A What’s new card after every update","icon":"sparkles"},{"title":"New windows in full screen","lead":"Full-screen windows open in their own Space","detail":"Full-screen windows open in their own Space","icon":"macwindow"},{"title":"Shared Quotes with ⌘C","icon":"text.quote"}]</airc:highlights>
            </item></channel></rss>
            """
            let url = dir.appendingPathComponent("fixture-appcast.xml")
            try? Data(xml.utf8).write(to: url)
            let properties = Self.appcastItemProperties(url)
            let lines = WhatsNewAppcast.highlights(properties: properties)
            ok(lines.count == 3 && lines[0].title == "What’s new after updates" && lines.allSatisfy { $0.title.count <= WhatsNewCatalog.titleMax },
               "the fixture appcast's <airc:highlights> reads as 3 lines (keys \(properties.keys.compactMap { $0 as? String }.sorted()))")
            let f = FakeHighlightsUpdate(version: "0.1.13 (202611140900)", highlights: lines)
            fake = f
            UpdateCenter.shared.setReady(f)
        }
        wait(0.8)
        run { [self] in
            let b = wnButton, sidebar = c.sidebar
            sidebar.layoutSubtreeIfNeeded()
            let titles = b.lineLabels.filter { !$0.isHidden }.map(\.stringValue)
            ok(b.mode == .update && titles == fake?.highlights.map(\.title),
               "Restart to Update shows the incoming version's lines: \(titles.joined(separator: " | "))")
            ok(UpdateButtonView.titles.contains(b.title.stringValue) && b.showsRestartGlyph, "the pill's own title and restart glyph stay (“\(b.title.stringValue)”)")
            let plate = sidebar.convert(b.pillRect, from: b)
            ok(abs(b.pillRect.height - UpdateButtonView.cardHeight(mode: .update, rows: b.rowLines)) < 0.5 && b.rowLines.count == 3
               && abs(plate.maxY + UpdateButtonView.bottomInset - sidebar.footer.frame.minY) < 0.5,
               "the plate grows by three 20 pt rows, still on the footer (\(NSStringFromRect(plate)))")
            ok((b.accessibilityLabel() ?? "").contains("What’s new: A What’s new card after every update"),
               "VoiceOver reads the lines with the button: “\(b.accessibilityLabel() ?? "")”")
        }
        widthCases("Restart to Update", ok)
        capture("whatsnew-update-light")
        run { [self] in
            try? c.store.updateSpace(spaceID) { $0.theme.appearance = .dark }
            c.reloadAll(animated: false)
        }
        wait(0.4)
        capture("whatsnew-update-dark")
        // The setting off: the lines go, the plain pill stays.
        run { [self] in
            app?.settings.values.whatsNewStyle = .off
            center.settingChanged(.off)
        }
        wait(0.6)
        run { [self] in
            ok(wnButton.lineLabels.allSatisfy(\.isHidden) && abs(wnButton.pillRect.height - UpdateButtonView.pillHeight) < 0.5,
               "with Show what's new off, Restart to Update is the plain pill")
            app?.settings.values.whatsNewStyle = .card
            center.settingChanged(.card)
            // An older feed: no element, the plain pill.
            UpdateCenter.shared.setReady(FakeHighlightsUpdate(version: "0.1.13 (202611140901)",
                                                              highlights: WhatsNewAppcast.highlights(properties: ["title": "Airc 0.1.13"])))
        }
        wait(0.6)
        run { [self] in
            ok(wnButton.mode == .update && wnButton.lineLabels.allSatisfy(\.isHidden) && abs(wnButton.pillRect.height - UpdateButtonView.pillHeight) < 0.5,
               "a feed item without highlights keeps the plain 34 pt pill")
            UpdateCenter.shared.setReady(nil)
            try? c.store.updateSpace(spaceID) { $0.theme.appearance = .light }
            c.reloadAll(animated: false)
        }
        wait(0.6)
        run { [self] in ok(!wnButton.isShowing && wnButton.whatsNew == nil, "no update and a dismissed card: the spot is empty") }
        // 5. whatsnew2: the What's new tab (WhatsNewPageCheck.swift). The relaunch reads LastVersion and the state file
        // as the card's cases left them: they're put back afterwards.
        var saved: (last: Data?, state: Data?) = (nil, nil)
        run { saved = (try? Data(contentsOf: UpdateCenter.lastVersionFile), try? Data(contentsOf: WhatsNewCenter.stateFile)) }
        whatsNewTabCases(catalog, spaceID: spaceID, ok)
        run { [self] in
            if let l = saved.last { try? l.write(to: UpdateCenter.lastVersionFile) }
            if let st = saved.state { try? st.write(to: WhatsNewCenter.stateFile) }
            app?.settings.values.whatsNewStyle = .card
            UpdateCenter.runningVersionOverride = Self.wnRunning
        }
    }

    private func relaunchCases(_ catalog: WhatsNewCatalog, _ ok: @escaping (Bool, String) -> Void) {
        let center = WhatsNewCenter.shared
        run { [self] in
            app?.settings.values.whatsNewStyle = .card   // the card's rules (the tab's are in WhatsNewPageCheck.swift)
            let last = (try? String(contentsOf: UpdateCenter.lastVersionFile, encoding: .utf8)) ?? "-"
            let before = center.state
            UpdateCenter.shared.noteLaunchedVersion(inScriptedRun: true)
            ok(last == Self.wnRunning && before.dismissed, "the relaunch finds LastVersion \(last) and the card dismissed")
        }
        wait(1.2)
        run { [self] in
            ok(wnButton.whatsNew == nil && !wnButton.isShowing, "after × a relaunch shows no card")
            ok(c.updatedToast?.shownText == nil, "and no “Updated!” toast (the same version as last time)")
            // Three launches: launch 2 and 3 show it, the 4th doesn't (the real state file and launch path).
            var s = center.state
            s.dismissed = false
            s.shownLaunches = 1
            center.state = s
            var shown: [Bool] = []
            for _ in 0..<3 {
                UpdateCenter.shared.noteLaunchedVersion(inScriptedRun: true)
                shown.append(wnButton.whatsNew != nil)
            }
            ok(shown == [true, true, false], "undismissed, it stays for launches 2 and 3 and is gone on the 4th (\(shown))")
            // A fresh install (no LastVersion): nothing, and that version is never offered later.
            try? FileManager.default.removeItem(at: UpdateCenter.lastVersionFile)
            try? FileManager.default.removeItem(at: WhatsNewCenter.stateFile)
            UpdateCenter.runningVersionOverride = "0.1.11 (202611130133)"
            UpdateCenter.shared.noteLaunchedVersion(inScriptedRun: true)
            ok(wnButton.whatsNew == nil && center.state.offered == ["0.1.11"], "a fresh install gets no card (\(center.state.offered))")
            UpdateCenter.runningVersionOverride = nil
        }
    }

    /// At the default 228 pt sidebar every title takes one line, whole; at the 164 pt minimum none is cut off: a title
    /// that doesn't fit wraps to a second line, and the rows, See All and the plate still stack above the footer.
    /// Captures `whatsnew-<kind>-164.png` and puts the default width back.
    private func widthCases(_ kind: String, _ ok: @escaping (Bool, String) -> Void) {
        let file = kind == "card" ? "whatsnew-164" : "whatsnew-update-164"
        func needed(_ l: NSTextField) -> Int {
            let f = UpdateButtonView.lineFont, one = ceil(f.ascender - f.descender + f.leading)
            let r = (l.stringValue as NSString).boundingRect(with: NSSize(width: l.frame.width - 4, height: 1000),
                                                             options: [.usesLineFragmentOrigin], attributes: [.font: f])
            return Int((ceil(r.height) / one).rounded())
        }
        func measure(_ width: CGFloat) -> (rows: [Int], needed: [Int], stacked: Bool, why: String) {
            c.setSidebarWidth(width)
            c.root.layoutSubtreeIfNeeded()
            c.sidebar.layoutSubtreeIfNeeded()
            let b = wnButton
            // The new width can change the rows (setFrameSize), and so the card's height: lay out again.
            c.sidebar.needsLayout = true
            c.sidebar.layoutSubtreeIfNeeded()
            b.layoutSubtreeIfNeeded()
            let shown = b.lineLabels.filter { !$0.isHidden }
            let n = shown.map(needed)
            var stacked = true, last = b.pillRect.minY + UpdateButtonView.linesTop - 0.5
            for (i, l) in shown.enumerated() {
                let r = b.lineRect(i)
                stacked = stacked && r.minY >= last && l.frame.maxY <= r.maxY + 1 && l.frame.height + 1 >= CGFloat(n[i]) * 14
                last = r.maxY - 0.5
            }
            stacked = stacked && b.pillRect.maxY <= b.bounds.height && (b.whatsNew == nil || b.seeAll.frame.minY >= last)
            let plate = c.sidebar.convert(b.pillRect, from: b)
            stacked = stacked && abs(plate.maxY + UpdateButtonView.bottomInset - c.sidebar.footer.frame.minY) < 0.5
            return (b.rowLines, n, stacked, "rows \(b.rowLines), needed \(n), plate \(NSStringFromRect(plate)), text \(Int(shown.first?.frame.width ?? 0)) pt")
        }
        run { [self] in
            let d = measure(AircMetrics.Sidebar.defaultWidth)
            ok(d.rows.allSatisfy { $0 == 1 } && d.needed.allSatisfy { $0 == 1 } && d.stacked,
               "\(kind): at the default \(Int(AircMetrics.Sidebar.defaultWidth)) pt sidebar every title is one whole line (\(d.why))")
            let m = measure(AircMetrics.Sidebar.minWidth)
            let header = wnButton.title, hf = header.font ?? UpdateButtonView.lineFont
            let headerFits = ceil((header.stringValue as NSString).size(withAttributes: [.font: hf]).width) + 4 <= header.frame.width
            ok(headerFits && (kind != "card" || header.stringValue == "Airc 0.1.12"),
               "\(kind): at the minimum width the header is whole too (“\(header.stringValue)” in \(Int(header.frame.width)) pt)")
            ok(m.needed.allSatisfy { $0 <= UpdateButtonView.maxTitleLines } && zip(m.rows, m.needed).allSatisfy { $0 == $1 } && m.stacked,
               "\(kind): at the \(Int(AircMetrics.Sidebar.minWidth)) pt minimum no title is cut off: long ones wrap to two lines (\(m.why))")
            ok(kind != "card" || m.rows.contains(2), "\(kind): at the minimum width some titles do wrap (\(m.rows))")
        }
        wait(0.3)
        capture(file)
        run { [self] in
            c.setSidebarWidth(AircMetrics.Sidebar.defaultWidth)
            c.root.layoutSubtreeIfNeeded()
        }
        wait(0.3)
    }

    /// The item's children as Sparkle's SUAppcastItem.propertiesDictionary has them: each element by its qualified
    /// name, with its text.
    static func appcastItemProperties(_ url: URL) -> [AnyHashable: Any] {
        guard let doc = try? XMLDocument(contentsOf: url, options: []),
              let item = try? doc.nodes(forXPath: "/rss/channel/item").first as? XMLElement else { return [:] }
        var out: [AnyHashable: Any] = [:]
        for case let e as XMLElement in item.children ?? [] {
            if let name = e.name { out[name] = e.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        }
        return out
    }

    /// A click reaches `view` (the window's hit test at its centre).
    private func hits(_ view: NSView) -> Bool {
        guard let frame = c.window.contentView?.superview, view.window != nil else { return false }
        let p = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return frame.hitTest(frame.convert(p, from: nil)) === view
    }

    /// A real driver click at `view`'s centre (posted when the driver can't be used, and the log says which).
    private func wnClick(_ view: NSView, _ name: String, _ done: @escaping () -> Void) {
        c.window.layoutIfNeeded()
        let p = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        if realPointerInput {
            eventsRealClick(p) { ok, out in
                self.note("paritywhatsnew: \(name): real driver click at \(NSStringFromPoint(p))\(ok ? "" : " FAILED: \(out.prefix(160))")")
                if !ok { self.check(false, "paritywhatsnew: the driver clicks \(name)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
            }
        } else {
            note("paritywhatsnew: \(name): posted click (no UI driver in this run)")
            click(at: p, in: c.window) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done) }
        }
    }
}

private extension UpdateButtonView {
    /// The restart glyph shows (the pill, not What's new).
    var showsRestartGlyph: Bool { whatsNew == nil }
}
#endif

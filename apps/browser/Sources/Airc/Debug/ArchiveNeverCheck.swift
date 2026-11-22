// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script archivenever` (both engines; AircKit's ArchiveInterval, docs/user/sidebar.md): auto-archive's Never and
/// 1 hour, picked with real input (AIRC_REAL_KEYS=1, the stable UI driver, AIRC_UI_DEDICATED_SESSION=1) in the tidy
/// card's "Archive after" popup on a synthetic Space of 14 Today tabs on made-up example.* sites, with the picker flag
/// on (`ArchiveInterval.moreChoicesOverride`):
///   1. the popup offers 1 hour, 6 hours, 12 hours, 24 hours, 7 days, 30 days, Never (Settings › Profiles shows the
///      same list, `ArchiveInterval.choices`);
///   2. a real click opens it and real arrow keys + Return pick Never: the profile's setting is Never, and choosing it
///      adds no undo step (as for every value before);
///   3. the store's clock (the test hook) moves 400 days on and the archive timer's action runs: no Today tab is
///      archived and no archive timer is due;
///   4. Clear still clears, and a real ⌘Z brings the tabs back (Undo unchanged); the setting stays Never;
///   5. 1 hour, picked the same way: nothing at 59 minutes, every Today tab but the one on screen at 61 minutes, as
///      auto-archived, with no undo step.
/// Zero-guard: the run fails if it made no assertion.
extension SnapshotRunner {
    @MainActor func archiveNeverScenario() {
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        let tag = "archivenever (\(engine))"
        guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
            run { [self] in note("FAIL-ENV \(tag): real input needs AIRC_REAL_KEYS=1, the stable UI driver and AIRC_UI_DEDICATED_SESSION=1") }
            return
        }
        var space = "", profile = "", ids: [String] = [], before = ArchiveInterval.default
        var asserted = 0
        var realNow: () -> Date = Date.init
        func expect(_ ok: Bool, _ what: String) { asserted += 1; check(ok, "\(tag): \(what)") }
        func card() -> TidyHintCardView? { c.pageView(for: space)?.rows["tidyhint"] as? TidyHintCardView }
        func reload() { run { [self] in c.reloadAll(animated: false); c.pageView(for: space)?.layoutSubtreeIfNeeded() } }
        func newDay(_ d: String) { run { TidyHint.dayOverride = d; TidyHint.reloadAll() }; wait(0.4); reload() }
        func interval() -> ArchiveInterval { c.store.profile(profile)?.archiveAfter ?? .default }
        func todayIDs() -> Set<String> { Set(c.store.todayRowTabs(ofSpace: space).map(\.id)) }
        func autoArchived() -> Set<String> {
            Set(c.store.state.archive.values.filter { $0.reason == .auto && ids.contains($0.tab.id) }.map(\.tab.id))
        }
        func activate() {
            step { [self] done in
                NSApp.activate(ignoringOtherApps: true)
                c.window.makeKeyAndOrderFront(nil)
                waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) { done() }
            }
        }
        /// A real key: HID by default (an open menu takes it), PID-targeted (foreground-verified) for shortcuts.
        func key(_ combo: String, pid: Bool = false, settle: Double = 0.3) {
            step { [self] done in
                var args = ["--key", combo]
                if pid { args += ["--pid", "\(getpid())"] }
                UIDriverClient.run(args) { ok, out in
                    if !ok { self.note("FAIL-ENV \(tag) [real key] \(combo): \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: done)
                }
            }
        }
        /// A real click on the card's popup, then real arrow keys to `target` and Return.
        func pick(_ target: ArchiveInterval) {
            step { [self] done in
                c.pageView(for: space)?.layoutSubtreeIfNeeded()
                guard let k = card(), let w = k.window, let primary = NSScreen.screens.first, !k.archivePopUp.isHidden else {
                    expect(false, "[real click] the Archive after popup is on screen")
                    return done()
                }
                let v = k.archivePopUp
                let inWindow = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
                guard w.contentView?.bounds.contains(inWindow) == true else {
                    expect(false, "[real click] the popup is inside the window (\(NSStringFromPoint(inWindow)))")
                    return done()
                }
                let g = w.convertPoint(toScreen: inWindow)
                UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]) { ok, out in
                    if !ok { self.note("FAIL-ENV \(tag) [real click] popup: \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
                }
            }
            // The open menu's type-select: one real key, the label's first character ("n" for Never, "1" for 1 hour,
            // the first item starting with it). Arrow keys can't do it: in the open menu only the first of several
            // presses arrived (archivenever r1/r2, both engines), even one press at a time.
            let first = target.label.prefix(1).lowercased()
            key(first, settle: 0.5)
            run { [self] in
                note("\(tag): menu highlight before Return: \(card()?.archivePopUp.menu?.highlightedItem?.title ?? "none") (target \(target.label), typed \(first))")
            }
            key("return", settle: 0.6)
            // A menu still open (a lost key) would hold the next steps: close it.
            run { card()?.archivePopUp.menu?.cancelTracking() }
        }
        /// The store's clock at `offset` from now, then what the archive timer does when it fires.
        func advance(_ offset: TimeInterval) {
            run { [self] in
                let base = realNow
                c.store.now = { base().addingTimeInterval(offset) }
                c.runAutoArchive()
                c.scheduleArchive()
            }
            wait(1.5)
        }

        run { [self] in
            ArchiveInterval.moreChoicesOverride = true
            TidyHint.dayOverride = "2031-04-01"
            TidyHint.allowedInScripts = true
            c.store.setLocalValue(TidyHint.dayKey, nil)
            c.window.setFrame(NSRect(x: 80, y: 60, width: 1200, height: 860), display: true)
            let s = c.store
            realNow = s.now
            do {
                let sp = try s.createSpace(name: "Archive Never", profileID: s.selectedSpace.profileID)
                space = sp.id
                profile = sp.profileID
                before = interval()
                let hosts = ["news", "shop", "recipes", "docs", "maps", "music", "photos", "forum", "bank", "calendar", "notes", "weather", "travel", "books"]
                for (i, h) in hosts.enumerated().reversed() {
                    let tab = try s.openTab(url: "https://\(h).example.com/\(i)", inSpace: sp.id, activate: false, title: "\(h.capitalized) page")
                    ids.insert(tab.id, at: 0)
                }
                c.switchToSpace(sp.id, animated: false)
                c.reloadAll(animated: false)
            } catch {
                expect(false, "made the synthetic Space (\(error))")
            }
        }
        activate()
        wait(0.8)
        reload()

        // 1. The choices.
        run { [self] in
            let want = ["1 hour", "6 hours", "12 hours", "24 hours", "7 days", "30 days", "Never"]
            expect(card()?.archivePopUp.itemTitles == want,
                   "the card's Archive after offers \(want.joined(separator: ", ")) (\(card()?.archivePopUp.itemTitles ?? []))")
            expect(ArchiveInterval.choices(current: interval()).map(\.label) == want,
                   "[in-app] Settings › Profiles offers the same list (ArchiveInterval.choices)")
        }

        // 2. Never, with real input.
        var undoBefore: String?, couldUndo = false
        run { [self] in undoBefore = c.store.undoLabel; couldUndo = c.store.canUndo }
        pick(.never)
        run { [self] in
            expect(interval() == .never, "[real click + keys] picking Never sets the profile's auto-archive to Never (\(interval().rawValue))")
            expect(c.store.undoLabel == undoBefore && c.store.canUndo == couldUndo,
                   "choosing an interval adds no undo step, as before (\(c.store.undoLabel ?? "none"))")
            expect(c.toast.shownText == "Today tabs never archive on their own", "the toast says so (\(c.toast.shownText ?? "-"))")
        }

        // 3. 400 days later: nothing archived.
        advance(400 * 86400)
        run { [self] in
            let left = todayIDs()
            expect(ids.allSatisfy(left.contains) && autoArchived().isEmpty,
                   "[clock hook] with Never, 400 days on no Today tab is archived (\(left.count)/\(ids.count) left, \(autoArchived().count) archived)")
            expect(c.store.nextAutoArchiveDate() == nil, "with Never no archive timer is due")
        }

        // 4. Clear still clears; a real ⌘Z brings them back.
        var kept = Set<String>()
        run { [self] in
            kept = c.visibleTabIDs
            c.clearToday()
        }
        wait(0.8)
        run { [self] in
            expect(todayIDs().isSubset(of: kept) && c.store.undoLabel == "Clear Today",
                   "[in-app] Clear still archives Today with Never (\(todayIDs().count) left, undo \(c.store.undoLabel ?? "none"))")
        }
        activate()
        key("cmd+z", pid: true, settle: 0.8)
        run { [self] in
            expect(Set(ids).isSubset(of: todayIDs()), "[real key] ⌘Z after Clear brings every tab back (\(todayIDs().count)/\(ids.count))")
            expect(interval() == .never, "⌘Z leaves the setting at Never")
        }
        advance(400 * 86400)
        run { [self] in expect(autoArchived().isEmpty && Set(ids).isSubset(of: todayIDs()), "[clock hook] the restored tabs don't auto-archive either") }

        // 5. 1 hour (tomorrow's card, as the card puts itself away for the day after a choice).
        run { [self] in c.store.now = realNow }
        newDay("2031-04-02")
        activate()
        pick(.oneHour)
        run { [self] in expect(interval() == .oneHour, "[real click + keys] picking 1 hour sets it (\(interval().rawValue))") }
        run { [self] in undoBefore = c.store.undoLabel }
        advance(59 * 60)
        run { [self] in expect(autoArchived().isEmpty, "[clock hook] with 1 hour, nothing is archived at 59 minutes (\(autoArchived().count))") }
        advance(61 * 60)
        step { [self] done in
            let shown = c.visibleTabIDs
            waitUntil({ ids.filter { !shown.contains($0) }.allSatisfy { autoArchived().contains($0) } }, timeout: 8) { done() }
        }
        run { [self] in
            let shown = c.visibleTabIDs
            let due = ids.filter { !shown.contains($0) }
            expect(!due.isEmpty && due.allSatisfy(autoArchived().contains) && shown.allSatisfy { c.store.tab($0) != nil },
                   "[clock hook] at 61 minutes every Today tab but the one on screen is auto-archived (\(autoArchived().count)/\(due.count))")
            expect(c.store.undoLabel == undoBefore, "auto-archiving adds no undo step, as before (\(c.store.undoLabel ?? "none"))")
        }

        run { [self] in
            c.store.now = realNow
            try? c.store.updateProfile(profile) { $0.archiveAfter = before }
            ArchiveInterval.moreChoicesOverride = nil
            TidyHint.dayOverride = nil
            TidyHint.allowedInScripts = false
            check(asserted >= 15, "\(tag): zero-guard: \(asserted) assertions made (15 expected)")
        }
    }
}
#endif

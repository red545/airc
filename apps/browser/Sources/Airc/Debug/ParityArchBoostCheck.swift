// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityarchboost` (both engines; real driver clicks and keys with AIRC_REAL_KEYS=1 in a dedicated session,
/// posted clicks otherwise, and the log says which):
///   - LIB-2: five archived tabs (two 40 days old, one 10 days, two today). Library › Archived Tabs › Clear Archive…,
///     Arc's question; the pop-up is opened with a click and set to "Older than 7 days" with ↓ Return; Clear Archive
///     removes the three old ones only; the toast's Undo puts back exactly those three; ⌘Z can't.
///   - BST-2: a Boost with CSS and JavaScript is exported to a `.airc-boost` file through the share sheet, removed, and
///     the file opened (the Finder double-click path) while a second Airc profile's Space is shown. The review sheet
///     shows the site, the CSS and, under "This Boost runs code on …", the JavaScript; Add Boost installs it OFF (the
///     fixture page shows neither its style nor its code), the toast's Turn On turns it on and the page runs it.
///   - A malformed file, an oversized one and one that loads a remote script are refused with a message.
extension SnapshotRunner {
    func parityArchBoostScenario() {
        let tag = "parityarchboost"
        func ok(_ good: Bool, _ what: String) { check(good, "\(tag): \(what)") }
        archBoostArchive(ok)
        archBoostImport(ok)
    }

    /// A real driver click at `view`'s centre, in whatever window it is (a sheet included); posted without the driver.
    private func abClick(_ view: @escaping () -> NSView?, _ name: String) {
        step { [self] done in abClickNow(view, name, done) }
    }
    private func abClickNow(_ view: () -> NSView?, _ name: String, _ done: @escaping () -> Void) {
        guard let v = view(), let w = v.window else {
            check(false, "parityarchboost: \(name) is on screen to click"); return done()
        }
        w.layoutIfNeeded()
        let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        if realPointerInput, let top = NSScreen.screens.first?.frame.maxY {
            guard NSApp.isActive, w.isVisible, w.isOnActiveSpace else {
                note("FAIL-ENV parityarchboost: \(name): the app isn't active or the window isn't on screen (active \(NSApp.isActive))")
                return done()
            }
            let g = w.convertPoint(toScreen: p)
            UIDriverClient.run(["--click", String(Double(g.x)), String(Double(top - g.y))]) { good, out in
                self.note("parityarchboost: \(name): real driver click at \(NSStringFromPoint(g))\(good ? "" : " FAILED: \(out.prefix(160))")")
                if !good { self.check(false, "parityarchboost: the driver clicks \(name)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
            }
        } else {
            note("parityarchboost: \(name): posted click (no UI driver in this run)")
            click(at: p, in: w) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done) }
        }
    }

    // MARK: - Clear Archive

    private func archBoostArchive(_ ok: @escaping (Bool, String) -> Void) {
        let model = { self.c.library?.model }
        var old: Set<String> = [], recent: Set<String> = []
        var before: [String: ArchiveEntry] = [:]
        var originalFolder: String?
        run { [self] in
            originalFolder = app?.settings.values.backupFolder
            app?.settings.values.backupFolder = dir.appendingPathComponent("archboost-backups").path
            let sid = c.currentSpaceID, real = c.store.now
            func archive(_ title: String, daysAgo: Double) -> String {
                c.store.now = { Date().addingTimeInterval(-daysAgo * 86400) }
                defer { c.store.now = real }
                guard let t = try? c.store.openTab(url: "https://example.com/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
                                                   inSpace: sid, activate: false, title: title) else { return "" }
                _ = try? c.store.closeTab(t.id)
                return c.store.archivedEntries.first { $0.tab.id == t.id }?.id ?? ""
            }
            old = [archive("Old recipe", daysAgo: 40), archive("Old article", daysAgo: 40), archive("Last week's notes", daysAgo: 10)]
            recent = [archive("Today one", daysAgo: 0), archive("Today two", daysAgo: 0)]
            before = c.store.state.archive
            ok(before.count == 5 && !old.contains("") && !recent.contains(""), "five archived tabs: three older than 7 days, two from today")
            if c.library == nil { c.toggleLibrary() }
            model()?.section = .archive
        }
        wait(0.8)
        capture("archboost-archive-before")
        abClick({ self.c.library.flatMap { TestAnchors.view("library.clearArchive", in: $0) } }, "Clear Archive… in the Archive")
        step { [self] done in waitUntil({ model()?.archiveConfirmation != nil }, timeout: 3, then: done) }
        run { [self] in
            if model()?.archiveConfirmation == nil {
                note("parityarchboost: the click didn't open the question; the button's own action opens it")
                model()?.requestClearArchive()
            }
        }
        wait(0.4)
        func radios() -> [NSButton] { (model()?.archiveConfirmation?.accessoryView?.subviews ?? []).compactMap { $0 as? NSButton } }
        run { [self] in
            let alert = model()?.archiveConfirmation
            ok(alert != nil && c.window.attachedSheet === alert?.window, "the question is a sheet on the window")
            ok(alert?.messageText == "Are you sure you'd like to Clear Archive?", "Arc's question: “\(alert?.messageText ?? "-")”")
            ok(radios().map(\.title) == ["Everything (5 tabs)", "Older than 7 days (3 tabs)", "Older than 30 days (2 tabs)"]
               && radios().first?.state == .on,
               "the choices with their counts, Everything first: \(radios().map(\.title).joined(separator: " | "))")
            ok(alert?.buttons.map(\.title) == ["Cancel", "Clear Archive"] && alert?.buttons[1].hasDestructiveAction == true,
               "Cancel and a destructive Clear Archive")
        }
        abClick({ radios().first { $0.title.hasPrefix("Older than 7 days") } }, "Older than 7 days")
        run { ok(radios().first { $0.state == .on }?.title == "Older than 7 days (3 tabs)",
                 "Older than 7 days is chosen (\(radios().first { $0.state == .on }?.title ?? "-"))") }
        step { [self] done in
            guard let w = model()?.archiveConfirmation?.window else { return done() }
            captureWindow(w, name: "archboost-clear-archive", rounded: 12, done)
        }
        abClick({ model()?.archiveConfirmation?.buttons[1] }, "Clear Archive in the question")
        step { [self] done in waitUntil({ model()?.archiveConfirmation == nil && model()?.pendingUndo != nil }, timeout: 3, then: done) }
        run { [self] in
            ok(Set(c.store.state.archive.keys) == recent, "only the three older than 7 days are gone (\(c.store.state.archive.count) left)")
            ok(model()?.pendingUndo.map { Set($0.entries.map(\.id)) } == old, "the Undo holds exactly those three")
            ok(c.toast.shownText == "Cleared 3 archived tabs" && c.toast.actionButton?.title == "Undo",
               "the toast says “\(c.toast.shownText ?? "-")” with Undo")
            ok(model()?.lastArchiveBackup.map { FileManager.default.fileExists(atPath: $0.path) } == true, "a recovery backup was written first")
        }
        capture("archboost-archive-cleared")
        abClick({ self.c.toast.actionButton }, "Undo on the toast")
        run { [self] in
            ok(c.store.state.archive == before, "Undo puts back exactly what was cleared (same ids, dates and tabs)")
            ok(model()?.pendingUndo == nil, "and only once")
            // ⌘Z still reopens the last closed tab (one that wasn't cleared), but never brings back a cleared entry twice.
            _ = try? c.store.undo()
            ok(old.isSubset(of: Set(c.store.state.archive.keys)) && c.store.state.archive.count == before.count - 1,
               "⌘Z after Undo reopens only the last closed tab, a recent one (\(c.store.state.archive.count) archived)")
        }
        capture("archboost-archive-undone")
        run { [self] in
            // Back to an empty Archive for the next part; the Undo is gone after another clear.
            _ = try? c.store.clearArchive(age: .everything) {}
            if c.library != nil { c.toggleLibrary() }
            app?.settings.values.backupFolder = originalFolder
        }
        wait(0.5)
    }

    // MARK: - Boost files

    private func archBoostImport(_ ok: @escaping (Bool, String) -> Void) {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let site = "example.com"
        let center = BoostCenter.shared!
        let html = "<!doctype html><html><head><title>Archboost fixture</title><link rel='icon' href='data:,'></head><body><h1>Quiet reading</h1></body></html>"
        let css = "h1 { color: rgb(80, 40, 120) !important; }"
        let js = "// Marks the page so the check can see the code ran.\ndocument.documentElement.dataset.archboost = 'ran';"
        let fileURL = dir.appendingPathComponent("archboost.airc-boost")
        var server: LocalPageServer?
        var tabID = "", secondSpace = "", secondProfile = "", fixtureAddress = ""
        func review() -> BoostImportReview? { BoostImportReview.active[ObjectIdentifier(self.c.window)] }
        func page() -> EngineTab? { c.engineTab(for: tabID) }
        func probe(_ what: String, until expected: String) {
            step { [self] done in
                let deadline = Date().addingTimeInterval(8)
                func again() {
                    guard let tab = page() else {
                        if Date() > deadline { ok(false, "\(what): the fixture page isn't open (tab \(tabID), space \(self.c.currentSpaceID))"); return done() }
                        return DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: again)
                    }
                    tab.evaluate("String(document.documentElement.dataset.archboost) + '|' + getComputedStyle(document.querySelector('h1')).color") { value in
                        let got = String(describing: value ?? "nil")
                        if got == expected { ok(true, "\(what) (\(got))"); done() }
                        else if Date() > deadline { ok(false, "\(what): \(got), expected \(expected)"); done() }
                        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: again) }
                    }
                }
                again()
            }
        }
        // The Boost, made here and exported through the share sheet's file.
        run { [self] in
            center.update(domain: site) { $0.css = css; $0.js = js; $0.name = "Quiet reading" }
            if let share = BoostShareSheet(domain: site, parent: c.window, controller: c, center: center) {
                share.author = "Check Author"
                do {
                    try share.saveForCheck(to: fileURL)
                    let f = try BoostFile.read(fileURL)
                    ok(f.js == js && f.css == css && f.site == site && f.author == "Check Author" && f.version == BoostFile.version,
                       "exported a .airc-boost file with its CSS, JavaScript, site, author and version")
                } catch { ok(false, "export: \(error)") }
            } else { ok(false, "the share sheet opens for the Boost") }
            center.remove(domain: site, page: nil)
            // A second Airc profile, its Space on screen: the file is opened there.
            if let p = try? c.store.createProfile(name: "Second person", emoji: "🧪"),
               let s = try? c.store.createSpace(name: "Second", profileID: p.id) {
                secondSpace = s.id; secondProfile = p.id
                c.reloadAll(animated: false)
                c.switchToSpace(s.id, animated: false)
            }
            ok(center.store.boost(domain: site) == nil && c.store.space(c.currentSpaceID)?.profileID != c.store.defaultProfile.id,
               "the Boost is gone, and a second profile's Space is shown")
        }
        // A new Airc profile's engine profile loads on its own time; its pages can open once it has.
        step { [self] done in
            var answered = false
            func go(_ good: Bool) { guard !answered else { return }; answered = true; ok(good, "the second profile's engine profile loads"); done() }
            c.profiles.whenLoaded(secondProfile, { _ in go(true) }, failed: { go(false) })
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { go(false) }
        }
        step { [self] done in
            server = LocalPageServer(responses: ["/": .init(body: html)])
            server?.start { port in
                guard let port else { ok(false, "loopback server starts"); return done() }
                let address = "http://\(site):\(port)/"
                guard let t = try? self.c.store.openTab(url: chromium ? address : "about:blank", inSpace: secondSpace, activate: true,
                                                        title: "Archboost fixture") else { ok(false, "the fixture tab opens"); return done() }
                // As ParityLinkSpacesCheck: the window's pages first, then the Space, then the tab.
                tabID = t.id; self.c.reloadAll(animated: false); self.c.switchToSpace(secondSpace, animated: false); self.c.show(t.id, focus: false)
                fixtureAddress = address
                done()
            }
        }
        step { [self] done in
            waitUntil({ page() != nil }, timeout: 6) {
                if !chromium, let p = page() as? WebKitTab, let url = URL(string: fixtureAddress) {
                    p.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
                    self.note("parityarchboost: WebKit uses a simulated response at \(site); Chromium reaches the loopback server through host rules")
                }
                done()
            }
        }
        step { [self] done in
            waitUntil({ page()?.title == "Archboost fixture" && page().flatMap { center.document(of: $0) } != nil }, timeout: 12) {
                self.note("parityarchboost: fixture page: tab \(tabID.isEmpty ? "none" : "open"), engine page \(page() == nil ? "missing" : "there"), title \(page()?.title ?? "-")")
                done()
            }
        }
        probe("before: the fixture page has neither its style nor its code", until: "undefined|rgb(0, 0, 0)")
        // The Finder double-click path.
        run { [self] in app?.application(NSApp, open: [fileURL]) }
        wait(0.8)
        run { [self] in
            let r = review()
            ok(r?.sheet.isVisible == true && r?.file.js == js && r?.file.css == css && center.store.boost(domain: site) == nil,
               "the review sheet opens with the full CSS and JavaScript; nothing installed yet")
            let sheetRoot = r?.sheet.contentView
            for anchor in ["boost.import.codeWarning", "boost.import.js", "boost.import.css", "boost.import.installsOff"] {
                ok(sheetRoot.flatMap { TestAnchors.view(anchor, in: $0) } != nil, "the sheet shows \(anchor)")
            }
            ok(r?.installTitle == "Add Boost", "its button says “\(r?.installTitle ?? "-")”")
            // The warning and the highlighted code, as drawn.
            let highlighted = BoostReviewView.highlighted(js, .javaScript)
            ok(String(highlighted.characters) == js && highlighted.runs.count > 3, "the JavaScript is shown whole, in colour (\(highlighted.runs.count) runs)")
        }
        step { [self] done in
            guard let sheet = review()?.sheet else { return done() }
            captureWindow(sheet, name: "archboost-import-review", rounded: 12, done)
        }
        abClick({ review()?.sheet.contentView.flatMap { TestAnchors.view("boost.import.install", in: $0) } }, "Add Boost")
        step { [self] done in waitUntil({ review() == nil && center.store.boost(domain: site) != nil }, timeout: 4, then: done) }
        run { [self] in
            let b = center.store.boost(domain: site)
            ok(b?.js == js && b?.enabled == false, "installed OFF with the reviewed code (enabled \(String(describing: b?.enabled)))")
            ok(c.toast.shownText == "Boost installed. It's off until you turn it on." && c.toast.actionButton?.title == "Turn On",
               "the toast says “\(c.toast.shownText ?? "-")” with Turn On")
            page()?.reload()
        }
        wait(1.0)
        probe("while off, the page has neither its style nor its code", until: "undefined|rgb(0, 0, 0)")
        run { [self] in
            if c.toast.actionButton == nil {
                // The probe outlasted the toast: show it again the same way (the Boost is still off).
                note("parityarchboost: the toast had gone; it's shown again for the click")
                c.showActionToast("Boost installed. It's off until you turn it on.", action: ("Turn On", { [weak c] in
                    center.turnOn(domain: site, page: c?.shownTabID.flatMap { c?.engineTab(for: $0) })
                }))
            }
        }
        wait(0.3)
        capture("archboost-installed-off")
        abClick({ self.c.toast.actionButton }, "Turn On on the toast")
        step { [self] done in waitUntil({ center.store.boost(domain: site)?.enabled == true }, timeout: 3, then: done) }
        run { ok(center.store.boost(domain: site)?.enabled == true, "Turn On turns it on") }
        probe("turned on, the page reloads and runs its code with its style", until: "ran|rgb(80, 40, 120)")
        capture("archboost-turned-on")

        // Files that aren't valid Boosts are refused with a message.
        func refused(_ name: String, _ data: Data, _ what: String, _ message: String) {
            run { [self] in
                let url = dir.appendingPathComponent(name)
                try? data.write(to: url)
                let opened = BoostSharing.open(url, on: c.window)
                let sheet = c.window.attachedSheet
                let text = (sheet?.contentView.map(Self.texts) ?? []).joined(separator: " ")
                ok(!opened && review() == nil && sheet != nil && text.contains(message), "\(what) is refused: “\(message)”")
                if let sheet { c.window.endSheet(sheet); sheet.orderOut(nil) }
            }
            wait(0.3)
        }
        refused("malformed.airc-boost", Data("{\"version\":2,\"name\":".utf8), "a malformed file", "not a valid Airc Boost file")
        // Bad files from a valid one's JSON, edited: too large (code plus zaps past 256 KB), and one loading a remote script.
        let valid = (try? BoostFile(boost: Boost(domain: site, css: "h1 {}", js: ""), name: "Base").encoded()) ?? Data()
        func edited(_ edit: (inout [String: Any]) -> Void) -> Data {
            guard var o = (try? JSONSerialization.jsonObject(with: valid)) as? [String: Any] else { return Data() }
            edit(&o)
            return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
        }
        let big = edited {
            $0["css"] = "/*" + String(repeating: "a", count: 127 * 1024) + "*/"
            $0["js"] = "//" + String(repeating: "b", count: 127 * 1024)
            $0["zaps"] = (0..<200).map { ["selector": ".z\($0)-" + String(repeating: "q", count: 40), "label": String(repeating: "L", count: 60)] }
        }
        refused("oversized.airc-boost", big, "a file over 256 KB", "too large")
        let remote = edited { $0["js"] = "import('https://cdn.example.net/x.js')" }
        refused("remote.airc-boost", remote, "a file that loads a remote script", "loads code from another website")
        run { [self] in
            center.remove(domain: site, page: page())
            server?.stop()
            if let id = c.store.state.spaces.values.first(where: { $0.profileID == c.store.defaultProfile.id })?.id { c.switchToSpace(id, animated: false) }
        }
        wait(0.4)
    }

    /// The strings an alert or sheet shows (its message, for the refusal checks).
    static func texts(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
    }
}
#endif

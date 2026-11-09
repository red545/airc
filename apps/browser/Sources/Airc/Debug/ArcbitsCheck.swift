// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    func arcbitsScenario() {
        var server: LocalPageServer?, url = "", tab = ""
        let board = NSPasteboard.withUniqueName()
        let oldBoard = WindowController.linkPasteboard
        var little: LittleArcController?, remembered = ""
        step { done in
            server = LocalPageServer(pages: ["/article": "<title>A [Title] (one)</title><p id=q>Selected [words] (here)</p>"])
            server?.start { port in url = "http://127.0.0.1:\(port ?? 0)/article"; done() }
        }
        step { [self] done in
            WindowController.linkPasteboard = board
            app?.settings.values.suggestionsEnabled = false
            if let t = try? c.store.openTab(url: url, inSpace: c.currentSpaceID) { tab = t.id; c.reloadAll(animated: false); c.show(tab, focus: false) }
            waitUntil({ self.c.engineTab(for: tab)?.title == "A [Title] (one)" }, timeout: 10) { done() }
        }
        run { [self] in
            for id in ["edit.copyURLMarkdown", "edit.copyURLQuote", "view.showToolbar"] {
                let commands = CommandMenus.defaults.filter { $0.id == id }
                let combo = commands.first.flatMap { ShortcutCenter.combo($0.key, $0.modifiers) }
                check(commands.count == 1 && combo != nil && CommandMenus.defaults.filter { ShortcutCenter.combo($0.key, $0.modifiers) == combo }.count == 1,
                      "arcbits: unique, unreserved default shortcut for \(id)")
                var map = ShortcutCenter.shared.map
                let replacement = KeyCombo("9", [.control, .option, .command])
                _ = map.assign(replacement, to: id)
                check(map.key(id) == replacement, "arcbits: ShortcutMap remaps \(id)")
            }
            CommandMenus.all.first { $0.id == "edit.copyURLMarkdown" }?.run(c)
            check(board.string(forType: .string) == URLRules.markdownLink(title: "A [Title] (one)", url: url), "arcbits: Markdown command writes the run's pasteboard")
        }
        step { [self] done in
            c.engineTab(for: tab)?.evaluate("var r=document.createRange();r.selectNodeContents(document.getElementById('q'));getSelection().removeAllRanges();getSelection().addRange(r);true") { _ in done() }
        }
        step { [self] done in
            CommandMenus.all.first { $0.id == "edit.copyURLQuote" }?.run(c)
            let expected = URLRules.markdownQuote(title: "A [Title] (one)", url: url, selection: "Selected [words] (here)")
            waitUntil({ board.string(forType: .string) == expected }, timeout: 3) {
                self.check(board.string(forType: .string) == expected, "arcbits: Quote command copies selected text and backlink")
                done()
            }
        }
        step { [self] done in
            c.engineTab(for: tab)?.evaluate("getSelection().removeAllRanges();true") { _ in done() }
        }
        step { [self] done in
            c.copyURLQuote()
            let expected = URLRules.markdownQuote(title: "A [Title] (one)", url: url, selection: "")
            waitUntil({ board.string(forType: .string) == expected }, timeout: 3) {
                self.check(board.string(forType: .string) == expected, "arcbits: Quote without selection falls back to title")
                done()
            }
        }
        step { [self] done in
            let pid = c.store.profile(ofSpace: c.currentSpaceID).id
            app?.history.recordVisit(profileID: pid, url: "https://history.example.org/arcbits", title: "Arcbits unique history")
            c.openCommandBar(mode: .newTab); c.commandBar?.type("Arcbits unique history")
            waitUntil({ self.c.commandBar?.results.contains { $0.historyURL != nil } == true }, timeout: 3) {
                guard let bar = self.c.commandBar else { self.check(false, "arcbits: history bar exists"); return done() }
                let deletion = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                    windowNumber: self.c.window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
                self.check(!bar.handleSuggestionKey(deletion), "arcbits: default highlight leaves Shift-Delete to the editor")
                _ = bar.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
                for _ in 0..<bar.results.count where bar.results.indices.contains(bar.selected) && bar.results[bar.selected].historyURL == nil {
                    _ = bar.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
                }
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                        windowNumber: self.c.window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
                NSApp.sendEvent(e)
                self.check(self.app?.history.entry(profileID: pid, url: "https://history.example.org/arcbits") == nil,
                           "arcbits: Shift-Delete removes highlighted history via key dispatch")
                self.check(!bar.results.contains { $0.historyURL == "https://history.example.org/arcbits" }, "arcbits: removed history row disappears")
                bar.type("/Copy URL")
                self.check(!bar.handleSuggestionKey(e) && !bar.results.isEmpty, "arcbits: Shift-Delete leaves command actions alone")
                self.c.closeCommandBar(); done()
            }
        }
        step { [self] done in
            guard let app, let p = try? c.store.createProfile(name: "Remembered"),
                  let s = try? c.store.createSpace(name: "Remembered", profileID: p.id) else { check(false, "arcbits: profile setup"); return done() }
            remembered = s.id
            little = app.openLittleArc(url: URL(string: url))
            waitUntil({ little?.page?.url?.absoluteString == url }, timeout: 6) { done() }
        }
        step { [self] done in
            little?.switchSpace(remembered)
            little?.closeWindow()
            little = app?.openLittleArc(url: URL(string: url))
            check(little?.spaceID == remembered, "arcbits: Little Arc reopens in the remembered profile")
            if let app {
                let restored = AppSettings(directory: AppPaths.dataDirectory)
                check(restored.values.littleArcProfiles == app.settings.values.littleArcProfiles, "arcbits: profile memory survives settings reload")
            }
            little?.closeWindow(); done()
        }
        run { [self] in
            c.closeCommandBar()
            let off = c.card.frame
            check(c.pageToolbar == nil, "arcbits: toolbar defaults off")
            c.togglePageToolbar(); c.root.layoutSubtreeIfNeeded()
            if let toolbar = c.pageToolbar {
                let appearance = toolbar.appearance
                toolbar.appearance = NSAppearance(named: .aqua)
                let light = toolbar.layer?.backgroundColor, lightText = toolbar.address.textColor
                toolbar.appearance = NSAppearance(named: .darkAqua)
                check(light != nil && toolbar.layer?.backgroundColor != light && toolbar.address.textColor != lightText,
                      "arcbits: toolbar background and text follow appearance changes")
                toolbar.appearance = appearance
                let editor = c.windowWillReturnFieldEditor(c.window, to: toolbar.address) as? NSTextView
                check(editor === toolbar.fieldEditor && editor?.isAutomaticDashSubstitutionEnabled == false && editor?.isAutomaticQuoteSubstitutionEnabled == false,
                      "arcbits: toolbar URL editor disables smart punctuation")
            }
            check(c.pageToolbar?.address.stringValue == url && c.card.frame.minY == off.minY + PageToolbarView.height
                  && c.card.frame.height == off.height - PageToolbarView.height, "arcbits: toolbar shows full URL and reserves exactly its height")
            c.togglePageToolbar()
            check(c.card.frame == off && c.pageToolbar == nil, "arcbits: toolbar off restores page frame and removes view")
            c.togglePageToolbar()
            let right = c.sidebarOnRight, full = c.isFullscreen
            for r in [false, true] { for f in [false, true] {
                c.sidebarOnRight = r; c.isFullscreen = f; c.layoutRoot()
                check(c.pageToolbar?.frame.minX == c.card.frame.minX && c.pageToolbar?.frame.maxY == c.card.frame.minY,
                      "arcbits: toolbar geometry right=\(r) fullscreen=\(f)")
            } }
            c.sidebarOnRight = right; c.isFullscreen = full; c.layoutRoot()
            if let other = try? c.store.openTab(url: url, inSpace: c.currentSpaceID, background: true),
               let split = try? c.store.createSplit([tab, other.id], inSpace: c.currentSpaceID) {
                c.show(tab, focus: false); c.layoutRoot()
                check(c.shownSplitID == split.id && c.splitContainer.frame == c.card.frame, "arcbits: Split View uses reduced page frame")
            }
        }
        step { [self] done in
            guard let app else { return done() }
            let menu = CommandMenuItem()
            menu.app = app
            check(menu.validateToolbar(in: c.window) && menu.state == .on, "arcbits: main toolbar menu reflects its visible toolbar")
            PrivateBrowsing.shared.open(app: app) { privateWindow in
                guard let privateWindow else { self.check(false, "arcbits: private toolbar menu fixture opens"); return done() }
                self.check(!menu.validateToolbar(in: privateWindow.window) && menu.state == .off,
                           "arcbits: private toolbar menu is off and unavailable despite main toolbar")
                privateWindow.closeWindow()
                done()
            }
        }
        capture("arcbits-toolbar")
        run { [self] in
            if c.pageToolbar != nil { c.togglePageToolbar() }
            WindowController.linkPasteboard = oldBoard
            board.releaseGlobally(); server?.stop()
        }
    }
}
#endif

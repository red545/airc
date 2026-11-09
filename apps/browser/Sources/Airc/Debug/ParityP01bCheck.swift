// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityp01b` (P01b, docs/qa/parity-audit.md E14/K05), both engines, a loopback page and a note:
///   1. The menus: Edit's Delete, Use Selection to Find, Jump to Selection (⌘J) and its four submenus (Spelling and
///      Grammar, Substitutions, Transformations, Speech) with the Mac's own actions; Format › Font › Bold, Italic,
///      Underline; Help (Getting Started, Essential Keyboard Shortcuts, Release Notes, Privacy Policy) as the app's
///      Help menu, which gives it macOS's search field.
///   2. Responders: which of the editing actions the page answers on this engine (logged), and the note's editor
///      answering all of them; Make Upper Case and Bold in a note; Bold in an editable page.
///   3. Find: Jump to Selection scrolls the page to its selection; Use Selection to Find fills the find bar, in a page
///      and in a note.
///   4. Disabled states: editing actions and Format in the sidebar, Find's additions with nothing on screen.
///   5. Essential Keyboard Shortcuts shows the person's own keys (a remap shows at once); its window draws off screen.
///   6. The Command Bar offers the menu bar's commands (with other words for them, e.g. "read aloud"), not the plain
///      editing ones or numbered runs, and one runs from there.
/// Windows are never made key and nothing is shown on screen: validation is asked of the window's own responders, as
/// the menus would ask them while it is key.
extension SnapshotRunner {
    func parityP01bScenario() {
        var server: LocalPageServer?, tab = ""
        let page = { self.c.engineTab(for: tab) }
        let menus = { (title: String) in NSApp.mainMenu?.items.first { $0.submenu?.title == title }?.submenu }
        step { [self] done in
            let body = "<!doctype html><title>Edit page</title><body style='font:20px -apple-system;padding:30px'>"
                + "<div id=ed contenteditable style='min-height:40px;border:1px solid #ccc'>hello world</div>"
                + "<p id=far style='margin-top:3000px'>far words here</p><p style='margin-bottom:3000px'>end</p>"
            server = LocalPageServer(pages: ["/edit.html": body])
            server?.start { port in
                guard let port, let t = try? self.c.store.openTab(url: "http://127.0.0.1:\(port)/edit.html", inSpace: self.c.currentSpaceID) else {
                    self.check(false, "parityp01b: the loopback page opens"); return self.finish()
                }
                tab = t.id
                self.c.reloadAll(animated: false)
                self.c.show(tab, focus: true)
                self.waitUntil({ page()?.title == "Edit page" && page()?.isLoading == false }, timeout: 10) { done() }
            }
        }

        // 1. The menus.
        run { [self] in
            let edit = menus("Edit")
            var structureOK = true, details: [String] = []
            for s in NativeEditingMenus.submenus {
                let sub = edit?.items.first { $0.title == s.title }?.submenu
                let want = s.actions.map { $0.map { "\($0.title)=\(NSStringFromSelector($0.selector))" } ?? "—" }
                let have = sub?.items.map { $0.isSeparatorItem ? "—" : "\($0.title)=\($0.action.map(NSStringFromSelector) ?? "nil")" } ?? []
                if want != have { structureOK = false; details.append("\(s.title): \(have)") }
            }
            let titles = edit?.items.map(\.title) ?? []
            let jump = edit?.items.first { $0.title == "Jump to Selection" }
            check(structureOK && titles.contains("Delete") && titles.contains("Use Selection to Find")
                  && jump?.keyEquivalent == "j" && jump?.keyEquivalentModifierMask == .command,
                  "parityp01b: Edit has Delete, Use Selection to Find, Jump to Selection (⌘J) and Spelling and Grammar, Substitutions, "
                  + "Transformations, Speech with the Mac's actions" + (details.isEmpty ? "" : " (\(details))"))
            let font = menus("Format")?.items.first { $0.title == "Font" }?.submenu
            check(font?.items.map { "\($0.title)⌘\($0.keyEquivalent)" } == ["Bold⌘b", "Italic⌘i", "Underline⌘u"],
                  "parityp01b: Format › Font › Bold ⌘B, Italic ⌘I, Underline ⌘U (\(font?.items.map(\.title) ?? []))")
            let help = menus("Help")
            help?.update()
            let helpTitles = help?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
            check(help != nil && NSApp.helpMenu === help
                  && helpTitles == ["Getting Started", "Essential Keyboard Shortcuts", "Release Notes", "Privacy Policy", "Troubleshooting"]
                  && help?.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled) == true,
                  "parityp01b: Help is the app's Help menu (macOS adds its search) with \(helpTitles)")
            check(ParityCommandCatalog.releaseNotes.host == "aircbrowser.com" && ParityCommandCatalog.privacyPolicy.path == "/privacy",
                  "parityp01b: Help's pages are Airc's own (\(ParityCommandCatalog.gettingStarted), \(ParityCommandCatalog.releaseNotes))")
        }

        // 2. The page's editing responders (engine by engine), then Bold in its editable text.
        step { [self] done in
            page()?.focus()
            waitUntil({ (self.c.window.firstResponder as? NSView).map { $0 === page()?.view || $0.isDescendant(of: page()!.view) } == true }, timeout: 3) {
                var answered: [String] = [], missing: [String] = []
                for s in NativeEditingMenus.submenus { for a in s.actions.compactMap({ $0 }) {
                    if let t = NativeEditingMenus.target(of: a.selector, in: self.c.window) { answered.append("\(a.title)\(t.enabled ? "" : " (disabled)")") }
                    else { missing.append(a.title) }
                } }
                self.note("parityp01b: \(self.app?.engine.name ?? "?") page answers: \(answered.joined(separator: ", "))")
                self.note("parityp01b: \(self.app?.engine.name ?? "?") page doesn't answer: \(missing.joined(separator: ", "))")
                let speech = ["Start Speaking", "Stop Speaking"].allSatisfy { t in answered.contains { $0.hasPrefix(t) } }
                self.check(speech && answered.contains { $0.hasPrefix("Show Spelling and Grammar") },
                           "parityp01b: the page answers Speech and Spelling and Grammar")
                done()
            }
        }
        step { [self] done in
            page()?.evaluate("var e=document.getElementById('ed');e.focus();var r=document.createRange();r.selectNodeContents(e.firstChild);"
                             + "r.setEnd(e.firstChild,5);getSelection().removeAllRanges();getSelection().addRange(r);true") { _ in done() }
        }
        wait(0.4)
        step { [self] done in
            let item = NSMenuItem(title: "Bold", action: #selector(FormatRouter.apply(_:)), keyEquivalent: "b")
            item.tag = FormatRouter.Trait.bold.rawValue
            let enabled = FormatRouter.shared.validate(item, in: c.window)
            FormatRouter.shared.apply(.bold, in: c.window)
            page()?.evaluate("[document.queryCommandState('bold'), document.hasFocus(), (document.activeElement||{}).id||'']") { v in
                let a = v as? [Any] ?? []
                let bold = (a.first as? Bool) == true
                self.check(enabled && bold, "parityp01b: Format › Bold in an editable page bolds its selection (enabled \(enabled), bold \(bold))")
                done()
            }
        }

        // 3. Find in the page: Jump to Selection, Use Selection to Find.
        step { [self] done in
            page()?.evaluate("document.activeElement.blur();var p=document.getElementById('far');var r=document.createRange();r.selectNodeContents(p);"
                             + "getSelection().removeAllRanges();getSelection().addRange(r);window.scrollTo(0,0);true") { _ in done() }
        }
        step { [self] done in
            let cmd = CommandMenus.all.first { $0.id == "edit.jumpToSelection" }
            cmd?.run(c)
            waitUntil({ false }, timeout: 0.5) {
                page()?.evaluate("[window.scrollY, Math.round(document.getElementById('far').getBoundingClientRect().top), window.innerHeight]") { v in
                    let a = v as? [NSNumber] ?? []
                    let y = a.first?.doubleValue ?? 0, top = a.dropFirst().first?.doubleValue ?? -1, h = a.last?.doubleValue ?? 0
                    self.check(y > 1000 && abs(top - h / 2) < h / 3, "parityp01b: Jump to Selection scrolls the page's selection to the middle (scrollY \(y), top \(top) of \(h))")
                    done()
                }
            }
        }
        step { [self] done in
            c.useSelectionForFind()
            waitUntil({ self.c.findBar?.field.stringValue == "far words here" }, timeout: 3) {
                self.check(self.c.findBar?.field.stringValue == "far words here",
                           "parityp01b: Use Selection to Find fills the find bar with the page's selection (\(self.c.findBar?.field.stringValue ?? "no bar"))")
                self.c.closeFind(refocusPage: false)
                done()
            }
        }

        // 4. Disabled states: the sidebar has the keyboard; nothing on screen.
        run { [self] in
            guard let sidebarPage = c.pageView(for: c.currentSpaceID) else { return check(false, "parityp01b: the Space's sidebar page exists") }
            c.window.makeFirstResponder(sidebarPage)
            let upper = NativeEditingMenus.target(of: NSSelectorFromString("uppercaseWord:"), in: c.window)
            let item = NSMenuItem(title: "Bold", action: #selector(FormatRouter.apply(_:)), keyEquivalent: "b")
            item.tag = FormatRouter.Trait.bold.rawValue
            check(upper == nil && !FormatRouter.shared.validate(item, in: c.window),
                  "parityp01b: with the sidebar's keyboard, Make Upper Case and Bold are disabled (\(upper.map { "\(type(of: $0.responder))" } ?? "no responder"))")
            let find = CommandMenus.all.first { $0.id == "edit.useSelectionForFind" }
            let before = find?.isEnabled?(c) ?? false
            c.showEmpty()
            let empty = find?.isEnabled?(c) ?? true
            c.show(tab, focus: false)
            check(before && !empty, "parityp01b: Use Selection to Find is enabled with a page, disabled with nothing on screen")
        }

        // 2b. A note: every editing action answered by its editor; Make Upper Case, Bold, Find.
        run { [self] in c.newNote(source: .shortcut) }
        step { [self] done in waitUntil({ self.c.shownNote != nil }, timeout: 4) { done() } }
        step { [self] done in
            guard let tv = c.shownNote?.textView else { check(false, "parityp01b: a new note shows its editor"); return done() }
            c.window.makeFirstResponder(tv)
            tv.insertText("hello world", replacementRange: NSRange(location: NSNotFound, length: 0))
            let start = (tv.string as NSString).range(of: "hello")
            tv.setSelectedRange(start)
            var notAnswered: [String] = []
            for s in NativeEditingMenus.submenus { for a in s.actions.compactMap({ $0 }) {
                let t = NativeEditingMenus.target(of: a.selector, in: c.window)
                // Stop Speaking is answered but off while nothing is being spoken.
                if !(t?.responder === tv && (t?.enabled == true || a.title == "Stop Speaking")) { notAnswered.append(a.title) }
            } }
            check(notAnswered.isEmpty, "parityp01b: a note's editor answers every editing action" + (notAnswered.isEmpty ? "" : " (not: \(notAnswered))"))
            NSApp.sendAction(NSSelectorFromString("uppercaseWord:"), to: tv, from: nil)
            let item = NSMenuItem(title: "Bold", action: #selector(FormatRouter.apply(_:)), keyEquivalent: "b")
            item.tag = FormatRouter.Trait.bold.rawValue
            tv.setSelectedRange((tv.string as NSString).range(of: "HELLO"))
            FormatRouter.shared.apply(.bold, in: c.window)
            let ticked = FormatRouter.shared.validate(item, in: c.window) && item.state == .on
            check(tv.string.contains("HELLO world") && tv.marks(at: (tv.string as NSString).range(of: "HELLO").location).contains(.bold) && ticked,
                  "parityp01b: in a note, Make Upper Case and Format › Bold (ticked) apply to the selection (\(tv.string.prefix(20)))")
            c.useSelectionForFind()
            waitUntil({ self.c.findBar?.field.stringValue == "HELLO" }, timeout: 3) {
                self.check(self.c.findBar?.field.stringValue == "HELLO", "parityp01b: Use Selection to Find in a note (\(self.c.findBar?.field.stringValue ?? "no bar"))")
                self.c.closeFind(refocusPage: false)
                done()
            }
        }
        // The Command Bar with a note: its editing actions are there.
        run { [self] in
            ParityCommandCatalog.cache = nil
            let titles = Set(c.commandActions().map(\.title))
            check(["Make Upper Case", "Start Speaking", "Bold"].allSatisfy(titles.contains),
                  "parityp01b: with a note on screen, the Command Bar offers its editing actions (Make Upper Case, Start Speaking, Bold)")
            c.show(tab, focus: false)
        }

        // 5. Essential Keyboard Shortcuts: the person's own keys.
        run { [self] in
            func row(_ title: String) -> String? { ParityCommandCatalog.essentialRows().flatMap(\.rows).first { $0.title == title }?.keys }
            let standard = row("Copy URL")
            let remapped = KeyCombo("9", [.control, .option, .command])
            ShortcutCenter.shared.update { m in m.assign(remapped, to: "edit.copyURL") }
            let after = row("Copy URL")
            ShortcutCenter.shared.update { m in m.assign(KeyCombo("c", [.shift, .command]), to: "edit.copyURL") }
            let w = EssentialShortcutsWindow.makeWindow()
            w.setFrameOrigin(NSPoint(x: -6000, y: -3000))
            let size = w.contentView?.fittingSize ?? .zero
            check(standard == "⇧⌘C" && after == remapped.display && row("Copy URL") == "⇧⌘C" && size.width > 200 && size.height > 200
                  && !w.isVisible && w.title == "Essential Keyboard Shortcuts",
                  "parityp01b: Essential Keyboard Shortcuts lists the person's keys (Copy URL \(standard ?? "-"), remapped \(after ?? "-")); its window draws (\(Int(size.width))×\(Int(size.height)))")
            w.close()
        }

        // 6. The Command Bar: the menu bar's commands, searchable, and one runs.
        run { [self] in
            ParityCommandCatalog.cache = nil
            let actions = c.commandActions()
            let titles = Set(actions.map(\.title))
            let want = ["Jump to Selection", "Use Selection to Find", "Essential Keyboard Shortcuts", "Release Notes", "Getting Started",
                        "Privacy Policy", "Start Speaking", "Developer Tools", "History", "Settings…", "Reload Ignoring Cache"]
            let missing = want.filter { !titles.contains($0) }
            let leftOut = ["Undo", "Copy", "Paste", "Select All", "Space 1", "Sidebar Tab 1", "New Tab", "Quit Airc"].filter(titles.contains)
            let dupes = Dictionary(grouping: actions, by: \.title).filter { $0.value.count > 1 }.keys
            check(missing.isEmpty && leftOut.isEmpty && dupes.isEmpty,
                  "parityp01b: the Command Bar offers the menu bar's commands once each, without plain editing or numbered runs"
                  + (missing.isEmpty ? "" : " (missing \(missing))") + (leftOut.isEmpty ? "" : " (should be left out: \(leftOut))")
                  + (dupes.isEmpty ? "" : " (twice: \(Array(dupes)))"))
            let speak = actions.first { $0.title == "Start Speaking" }
            check(speak?.keywords.contains("read aloud") == true && speak?.keywords.contains("speech") == true,
                  "parityp01b: \"read aloud\" and its menu (Speech) find Start Speaking")
        }
        step { [self] done in
            page()?.evaluate("var p=document.getElementById('far');var r=document.createRange();r.selectNodeContents(p);"
                             + "getSelection().removeAllRanges();getSelection().addRange(r);window.scrollTo(0,0);true") { _ in done() }
        }
        step { [self] done in
            c.commandActions().first { $0.title == "Jump to Selection" }?.run()
            waitUntil({ false }, timeout: 0.8) {
                page()?.evaluate("window.scrollY") { v in
                    self.check(((v as? NSNumber)?.doubleValue ?? 0) > 1000, "parityp01b: Jump to Selection runs from the Command Bar (scrollY \(v ?? "nil"))")
                    done()
                }
            }
        }
        run { [self] in
            server?.stop()
            note("parityp01b: done on \(app?.engine.name ?? "?") (window key \(c.window.isKeyWindow))")
        }
    }
}
#endif

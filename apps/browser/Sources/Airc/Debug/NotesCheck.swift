// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script notes`, then `--script notes-read` on the same data folder (both engines; docs/user/notes.md). The editor is
/// driven through its own methods and the app's key monitor (posted keys), never the owner's clipboard: pasteboards are
/// the run's own, as Capture's check does. Nothing here needs the window drawn, except the Capture's picture (the
/// engine's), which is reported FAIL-ENV with the evidence when it can't be had, and a synthetic PNG in Capture's own
/// pasteboard format stands in for the paste.
///   - New Note from the Command Bar, ⌃⇧N (a posted key) and the File menu, the sidebar's "+": pinned, shown, no page;
///   - typing with markdown (`- `, `[] `), Return continuing and ending lists, ⌘B ⌘I, Tab, ⇧⌘7 ⇧⌘9, a tick, undo,
///     a link pasted onto text; the title follows the first line in the sidebar;
///   - a Capture pasted (its file kept once by content) at its size on screen, not its pixel size (the PNG's
///     resolution); Find (Airc's bar, "1 of 2", ⌘G, Esc);
///   - archive and restore through ⌘W and the Library's restore; an empty note closes without the Archive, ⌘Z;
///   - each note's own undo; a private window can't make one;
///   - export and import in every format, and the app New Note opens (Debug/NotesExportCheck.swift);
///   - New Note in Split beside a page, and the split after a relaunch (Debug/NotesSplitCheck.swift);
///   - notes-read: after a relaunch the note is shown again as it was, its picture there, an orphan note gone.
extension SnapshotRunner {
    private var notesExpected: URL { dir.appendingPathComponent("notes-expected.json") }

    func notesScenario() {
        let board = NSPasteboard(name: NSPasteboard.Name("org.airc.test.notes.\(getpid())"))
        let scratch = dir.appendingPathComponent("notes-downloads", isDirectory: true)
        var server: LocalPageServer?
        var base = ""
        var first = "", second = "", third = ""
        var pageTab = ""
        let store = { self.c.store }
        let tv = { self.c.shownNote?.textView }
        func doc(_ tab: String) -> NoteDocument? { store().note(forTab: tab)?.document }
        /// One person's action as one undo group. AppKit makes one per event; a scripted run in a window that is never key
        /// never ends its automatic groups (everything would be one step), so the run brackets each action itself.
        func grouped(_ body: () -> Void) {
            guard let um = tv()?.undoManager else { return body() }
            if um.groupsByEvent, um.groupingLevel == 0 { um.groupsByEvent = false }
            guard !um.groupsByEvent else { return body() }
            um.beginUndoGrouping()
            body()
            um.endUndoGrouping()
        }
        func type(_ s: String) {
            grouped {
                for ch in s {
                    if ch == "\n" { tv()?.insertNewline(nil) } else { tv()?.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                }
            }
        }
        func select(_ text: String, occurrence: Int = 0) {
            guard let t = tv() else { return }
            let s = t.string as NSString
            var r = NSRange(location: 0, length: s.length), found = NSRange(location: NSNotFound, length: 0)
            for _ in 0...occurrence {
                found = s.range(of: text, range: r)
                guard found.location != NSNotFound else { return }
                r = NSRange(location: NSMaxRange(found), length: s.length - NSMaxRange(found))
            }
            t.setSelectedRange(found)
        }
        func caretAtEnd() { tv()?.setSelectedRange(NSRange(location: (tv()?.string as NSString?)?.length ?? 0, length: 0)) }
        func key(_ chars: String, code: UInt16, _ mods: NSEvent.ModifierFlags) -> Bool {
            guard let t = tv(), let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                                       windowNumber: c.window.windowNumber, context: nil, characters: chars,
                                                       charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return false }
            c.window.makeFirstResponder(t)
            var used = false
            grouped { used = t.performKeyEquivalent(with: e) }
            return used
        }
        func lines(_ d: NoteDocument?) -> String {
            (d?.blocks ?? []).map { b in
                "\(b.kind.rawValue)\(b.indent > 0 ? "+\(b.indent)" : "")\(b.checked ? "✓" : ""):" + b.runs.map { r in
                    r.image != nil ? "[image]" : r.text + (r.marks.isEmpty ? "" : "{" + r.marks.sorted().map(\.rawValue).joined(separator: ",") + "}")
                        + (r.link.map { "<\($0)>" } ?? "")
                }.joined()
            }.joined(separator: " | ")
        }
        func pinnedNote(_ tab: String) -> Item? { store().item(store().tab(tab)?.itemID) }
        /// The end of a person's keystroke: AppKit closes the undo group a run-loop pass opened (groupsByEvent).
        func endTurn() {
            run { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            wait(0.05)
        }

        // Setup: Capture's places of the run's own, a loopback page to capture.
        step { [self] done in
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            CaptureSession.downloadsDirectory = { scratch }
            CaptureSession.pasteboard = { board }
            CaptureSession.recordUse = { _ in }
            let page = """
            <title>Blocks</title><style>html,body{margin:0;height:100%;overflow:hidden}div{position:fixed;width:50vw;height:50vh}
            #r{left:0;top:0;background:#e53935}#g{right:0;top:0;background:#43a047}#b{left:0;bottom:0;background:#1e88e5}
            #y{right:0;bottom:0;background:#fdd835}</style><div id=r></div><div id=g></div><div id=b></div><div id=y></div>
            """
            server = LocalPageServer(responses: ["/blocks.html": .init(body: page)])
            server?.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }

        // 1. Where New Note is: the File menu (⌃⇧N), Settings → Shortcuts, the Command Bar, the "+" menu.
        run { [self] in
            let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items.first { $0.title == "New Note" }
            let menuKey = ShortcutCenter.menuEquivalent("n", [.control, .shift])
            check(item?.keyEquivalent == menuKey.0 && item?.keyEquivalentModifierMask == menuKey.1,
                  "notes: File › New Note has ⌃⇧N (Arc's key; \(item.map { "\($0.keyEquivalent) \($0.keyEquivalentModifierMask.rawValue)" } ?? "none"))")
            let same = ShortcutCenter.shared.commands.filter { $0.key.lowercased() == "n" && $0.modifiers == [.control, .shift] }.map(\.id)
            check(same == ["file.newNote"], "notes: ⌃⇧N is New Note's only (\(same))")
            check(KeyReservation.of(KeyCombo("n", [.control, .shift])) == nil, "notes: ⌃⇧N isn't a reserved key")
            let action = c.commandActions().first { $0.title == "New Note" }
            check(action?.hint == "⌃⇧N" && action?.keywords.contains("scratchpad") == true, "notes: the Command Bar's New Note action (⌃⇧N)")
            let plus = c.plusMenu().items.map(\.title)
            check(plus.firstIndex(of: "New Note").map { $0 == (plus.firstIndex(of: "New Folder…") ?? -9) + 1 } == true,
                  "notes: the \"+\" menu has New Note after New Folder… (\(plus.joined(separator: ", ")))")
        }

        // 2. Made three ways: pinned at the bottom of the Space, shown in the card, no engine page.
        run { [self] in
            let before = Set(store().state.notes.keys)
            c.commandActions().first { $0.title == "New Note" }?.run()
            first = c.shownTabID ?? ""
            let item = pinnedNote(first)
            check(store().state.notes.count == before.count + 1 && store().isNoteTab(first), "notes: the Command Bar makes a note")
            check(item != nil && store().pinnedRoots(ofSpace: c.currentSpaceID).last?.id == item?.id,
                  "notes: a new note is pinned at the bottom of the Space's pinned tabs (Arc)")
            check(c.shownNote != nil && c.shownNote?.view.superview === c.card && c.engineTab(for: first) == nil,
                  "notes: the note's editor is in the page card, with no engine page")
            check(URLRules.displayHost(store().tab(first)?.url ?? "") == "Note" && item?.displayTitle == "New Note",
                  "notes: the address field says Note; the row says New Note")
        }
        run { [self] in postKey("n", keyCode: 45, modifiers: [.control, .shift]) }
        wait(0.3)
        run { [self] in
            second = c.shownTabID ?? ""
            check(second != first && store().isNoteTab(second) && pinnedNote(second) != nil, "notes: ⌃⇧N (through the key monitor) makes a note")
            let m = c.plusMenu()
            m.performActionForItem(at: m.indexOfItem(withTitle: "New Note"))
            third = c.shownTabID ?? ""
            check(third != second && store().isNoteTab(third), "notes: the \"+\" menu makes a note")
            check(store().state.notes.count == 3, "notes: three notes (\(store().state.notes.count))")
        }

        // 3. Typing, markdown, lists. (No automatic corrections: the typed text is the test's.)
        run { [self] in
            c.show(first)
            if let t = tv() {
                t.isAutomaticSpellingCorrectionEnabled = false
                t.isAutomaticTextReplacementEnabled = false
                t.isAutomaticDashSubstitutionEnabled = false
                t.isAutomaticQuoteSubstitutionEnabled = false
            }
            type("Groceries\n- milk\neggs\n\n[] call the bakery\nbuy flowers")
            let l = lines(doc(first))
            check(l == "heading1:Groceries | bullet:milk | bullet:eggs | checkbox:call the bakery | checkbox:buy flowers",
                  "notes: typed title, `- ` list, Return twice ends it, `[] ` checkboxes (\(l))")
            check(store().tab(first)?.title == "Groceries" && pinnedNote(first)?.displayTitle == "Groceries",
                  "notes: the note's row takes its first line as its title")
        }
        // 4. Formatting, one step each: undo groups what one run-loop turn does, as a person's keystrokes are.
        var results: [String: Bool] = [:]
        var formatted = ""
        run { [self] in select("eggs"); results["b"] = key("b", code: 11, .command) }
        endTurn()
        run { [self] in select("milk"); results["i"] = key("i", code: 34, .command) }
        endTurn()
        run { [self] in select("eggs"); grouped { tv()?.insertTab(nil) } }
        endTurn()
        run { [self] in
            select("buy flowers")
            results["7"] = key("&", code: 26, [.command, .shift])
            results["numbered"] = lines(doc(first)).contains("numbered:buy flowers")
        }
        endTurn()
        run { [self] in
            results["9"] = key("(", code: 25, [.command, .shift])
            formatted = lines(doc(first))
            check(results["b"] == true && results["i"] == true && formatted.contains("bullet:milk{italic}") && formatted.contains("bullet+1:eggs{bold}"),
                  "notes: ⌘B, ⌘I and Tab (\(formatted))")
            check(results["7"] == true && results["numbered"] == true && results["9"] == true && formatted.contains("checkbox:buy flowers"),
                  "notes: ⇧⌘7 numbers a line, ⇧⌘9 makes it a checkbox again")
        }
        // ⌘Z three times: back to before Tab; ⇧⌘Z three times: as it was. The note's own history.
        for k in 0..<3 {
            endTurn()
            run { [self] in
                let name = tv()?.undoManager?.undoActionName ?? "-"
                tv()?.undo(nil)
                note("notes: ⌘Z #\(k + 1) (\(name)) → \(lines(doc(first))); text view: \((tv()?.string ?? "").replacingOccurrences(of: "\n", with: "⏎"))")
            }
        }
        endTurn()
        run { [self] in
            let undone = lines(doc(first))
            // ⇧⌘9, ⇧⌘7 and Tab undone: eggs back at the first level, still bold; milk still italic.
            check(undone.contains("bullet:eggs{bold}") && undone.contains("bullet:milk{italic}") && undone.contains("checkbox:buy flowers"),
                  "notes: ⌘Z undoes the last three changes (\(undone); grouping level \(tv()?.undoManager?.groupingLevel ?? -1))")
        }
        for _ in 0..<3 { endTurn(); run { [self] in tv()?.redo(nil) } }
        endTurn()
        run { [self] in
            check(lines(doc(first)) == formatted, "notes: ⇧⌘Z redoes them (\(lines(doc(first))))")
            // A tick, and a link pasted onto text (Arc).
            let s = (tv()?.string ?? "") as NSString
            grouped { tv()?.toggleCheckbox(s.range(of: "call the bakery").location) }
            select("bakery")
            board.clearContents()
            board.setString("https://bakery.example/", forType: .string)
            grouped { _ = tv()?.readSelection(from: board, type: .string) }
            let after = lines(doc(first))
            check(after.contains("checkbox✓:call the bakery<https://bakery.example/>"),
                  "notes: a tick, and an address pasted onto \"bakery\" links it (\(after))")
        }

        // Copying lines out gives other apps Markdown; another app's rich text keeps bold, not its font.
        run { [self] in
            guard let t = tv() else { return }
            let s = t.string as NSString
            let from = s.range(of: "milk").location, to = NSMaxRange(s.range(of: "eggs"))
            t.setSelectedRange(NSRange(location: from, length: to - from))
            board.clearContents()
            _ = t.writeSelection(to: board, types: [.string, NoteTextView.noteFragment])
            let md = board.string(forType: .string) ?? ""
            check(md == "- *milk*\n    - **eggs**", "notes: lines copied out are Markdown (\(md.replacingOccurrences(of: "\n", with: "⏎")))")
            let rich = NSMutableAttributedString(string: "Bold from Pages", attributes: [.font: NSFont(name: "Georgia", size: 22) ?? NSFont.systemFont(ofSize: 22)])
            rich.addAttribute(.font, value: NSFontManager.shared.convert(NSFont(name: "Georgia", size: 22) ?? NSFont.systemFont(ofSize: 22), toHaveTrait: .boldFontMask),
                              range: NSRange(location: 0, length: 4))
            board.clearContents()
            if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length)) { board.setData(rtf, forType: .rtf) }
            // Pages' picture of the text beside its RTF: the text must win.
            let picture = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in NSColor.gray.setFill(); r.fill(); return true }
            if let tiff = picture.tiffRepresentation { board.setData(tiff, forType: .tiff) }
            caretAtEnd()
            grouped { _ = t.readSelection(from: board) }
            let l = lines(doc(first))
            let font = t.textStorage?.attribute(.font, at: max(0, (t.string as NSString).length - 2), effectiveRange: nil) as? NSFont
            check(l.hasSuffix("Bold{bold} from Pages") && font?.familyName != "Georgia",
                  "notes: pasted rich text keeps bold, not Georgia (\(l.components(separatedBy: " | ").last ?? ""), \(font?.familyName ?? "-"))")
        }
        endTurn()

        // 5. A Capture pasted into the note.
        run { [self] in
            guard !base.isEmpty else { return check(false, "notes: a loopback server") }
            pageTab = (try? store().openTab(url: base + "/blocks.html", inSpace: c.currentSpaceID, title: "Blocks"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(pageTab, focus: false)
            check(c.shownNote == nil && !c.card.subviews.contains { $0 is NoteEditorView }, "notes: a page shown: no note in the card")
        }
        step { [self] done in
            waitUntil({
                guard let p = self.c.engineTab(for: pageTab) else { return false }
                return !p.isLoading && p.title == "Blocks" && p.view.window === self.c.window && !p.view.isHiddenOrHasHiddenAncestor
            }, timeout: 15) { done() }
        }
        wait(1.5)
        run { [self] in c.startCapture() }
        step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
        /// The Capture's size on screen, in points: what the pasted picture should measure in the note.
        var shownSize = CGSize(width: 200, height: 120)
        run { [self] in
            board.clearContents()
            let before = board.changeCount
            if let s = CaptureSession.active(in: c.window), s.picturesReady, s.shots.contains(where: { $0.image != nil }) {
                let o = s.overlay
                let mid = CGPoint(x: o.bounds.midX, y: o.bounds.midY)
                o.pressed(at: CGPoint(x: mid.x - 100, y: mid.y - 60))
                o.dragged(to: CGPoint(x: mid.x + 100, y: mid.y + 60))
                o.released(at: CGPoint(x: mid.x + 100, y: mid.y + 60))
                shownSize = o.selection?.size ?? shownSize
                s.confirm()
                o.bar.copyButton.action?()
            } else {
                let s = CaptureSession.active(in: c.window)
                let p = c.engineTab(for: pageTab)
                note("FAIL-ENV notes: no Capture picture to copy (session \(s != nil), picturesReady \(s?.picturesReady ?? false), shots \(s?.shots.count ?? 0), "
                     + "page \(p.map { "loading \($0.isLoading), title \($0.title), in window \($0.view.window === c.window), hidden \($0.view.isHiddenOrHasHiddenAncestor)" } ?? "none"), "
                     + "shown \(c.shownTabID == pageTab), screen locked \(Self.screenLocked), window visible \(c.window.occlusionState.contains(.visible))); a PNG in Capture's format stands in")
                s?.cancel()
                // 200 × 120 pt at the window's backing scale, as Capture would make it.
                let scale = c.window.backingScaleFactor
                let ctx = CGContext(data: nil, width: Int(200 * scale), height: Int(120 * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.setFillColor(CGColor(srgbRed: 0.9, green: 0.22, blue: 0.21, alpha: 1))
                ctx?.fill(CGRect(x: 0, y: 0, width: 200 * scale, height: 120 * scale))
                if let cg = ctx?.makeImage(), let png = CaptureSession.png(cg, scale: scale) {
                    // As Capture's Copy writes it (CaptureSession.copyImage).
                    board.clearContents()
                    let item = NSPasteboardItem()
                    item.setData(png, forType: .png)
                    board.writeObjects([item])
                }
            }
            check(board.changeCount != before && board.data(forType: .png) != nil, "notes: a Capture's PNG is on the run's pasteboard")
        }
        run { [self] in
            c.show(first)
            caretAtEnd()
            var pasted = false
            grouped { pasted = tv()?.readSelection(from: board) == true }
            let d = doc(first)
            let files = d?.imageFiles ?? []
            let file = files.first.flatMap(NoteImages.url)
            check(pasted && files.count == 1 && file.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                  "notes: the Capture pasted into the note is kept in Notes/Images (\(files.first ?? "none"))")
            // Its size in the note is the Capture's on screen (the PNG's 144 dpi at 2×), not its pixels: as kept, and as laid out.
            let kept = d?.blocks.flatMap(\.runs).compactMap(\.image).first
            var laidOut: NSSize?
            if let t = tv(), let lm = t.layoutManager, let storage = t.textStorage, let tc = t.textContainer {
                lm.ensureLayout(for: tc)
                storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                    guard value is NSTextAttachment else { return }
                    laidOut = lm.attachmentSize(forGlyphAt: lm.glyphIndexForCharacter(at: range.location))
                    stop.pointee = true
                }
            }
            let pixels = board.data(forType: .png).flatMap(NSBitmapImageRep.init(data:)).map { "\($0.pixelsWide) × \($0.pixelsHigh) px" } ?? "-"
            check(kept.map { CGSize(width: $0.width, height: $0.height) } == shownSize && laidOut == shownSize,
                  "notes: the pasted Capture measures its size on screen, \(shownSize.width) × \(shownSize.height) pt (kept "
                  + "\(kept.map { "\($0.width) × \($0.height)" } ?? "-"), laid out \(laidOut.map { "\($0.width) × \($0.height)" } ?? "-"), "
                  + "the PNG \(pixels) at \(c.window.backingScaleFactor)×)")
        }
        endTurn()
        run { [self] in
            caretAtEnd()
            grouped { _ = tv()?.readSelection(from: board) }
        }
        endTurn()
        run { [self] in
            let again = doc(first)
            let runs = again?.blocks.flatMap(\.runs).compactMap(\.image) ?? []
            check(runs.count == 2 && Set(runs.map(\.file)).count == 1 && runs.first.map { $0.width > 0 && $0.height > 0 } == true,
                  "notes: pasted twice, one file (\(runs.count) pictures, \(Set(runs.map(\.file)).count) file)")
            tv()?.undo(nil)
            check((doc(first)?.blocks.flatMap(\.runs).compactMap(\.image).count ?? 0) == 1, "notes: ⌘Z takes the second picture out")
        }
        endTurn()
        run { [self] in
            caretAtEnd()
            type("\n\n\noat milk")
        }
        run { [self] in
            func shot(_ v: NSView?, _ name: String) {
                guard let v, let img = render(v) else { return note("notes: no picture of \(name)") }
                try? img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent(name + ".png"))
                note("wrote \(name).png (screen locked: \(Self.screenLocked))")
            }
            shot(c.shownNote?.view, "notes-editor")
            shot(c.root, "notes-window")
            c.show(third)
            shot(c.shownNote?.view, "notes-empty")
            c.show(first)
        }

        // 6. Find in the note: Airc's find bar, as on a page.
        run { [self] in
            caretAtEnd()
            c.showFind()
            guard let bar = c.findBar else { return check(false, "notes: ⌘F opens the find bar on a note") }
            check(bar.field.placeholderString == "Find in note" && bar.askButton.isHidden, "notes: ⌘F's bar says Find in note (no Ask)")
            bar.field.stringValue = "milk"
            bar.find(forward: true)
            let s = (tv()?.string ?? "") as NSString
            let firstSel = tv()?.selectedRange() ?? NSRange()
            let firstStatus = bar.statusText
            c.findAgain(forward: true)
            let secondSel = tv()?.selectedRange() ?? NSRange()
            let secondStatus = bar.statusText
            c.findAgain(forward: false)
            check(s.substring(with: firstSel) == "milk" && firstStatus == "1 of 2" && secondStatus == "2 of 2"
                  && secondSel.location > firstSel.location && tv()?.selectedRange() == firstSel,
                  "notes: Find selects each \"milk\" in turn (\(firstStatus), ⌘G \(secondStatus), ⇧⌘G back)")
            let highlighted = tv()?.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: secondSel.location, effectiveRange: nil) != nil
            c.closeFind(refocusPage: true)
            let cleared = tv()?.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: secondSel.location, effectiveRange: nil) == nil
            check(highlighted && cleared && c.findBar == nil && c.window.firstResponder === tv(),
                  "notes: every match is highlighted; Esc clears them and gives the note the keyboard back")
        }

        // 7. Archive and restore; an empty note isn't kept; each note's own undo.
        var kept: NoteDocument?
        run { [self] in
            kept = doc(first)
            c.show(first)
            c.togglePin()
            check(store().tab(first)?.isToday == true, "notes: ⌘D moves the note to Today")
            c.closeCurrentTab()
            let entry = store().archivedEntries.first { $0.tab.id == first }
            check(entry?.title == "Groceries" && store().tab(first) == nil && c.shownNote?.noteID != NoteURL.noteID(entry?.url),
                  "notes: ⌘W archives the note (\"\(entry?.title ?? "none")\")")
            check(entry.flatMap { store().note(NoteURL.noteID($0.url)) }?.document == kept, "notes: the archived note keeps what it says")
            guard let entry, let t = try? store().restoreArchived(entry.id, fallbackSpaceID: c.currentSpaceID) else { return check(false, "notes: restore") }
            c.show(t.id)
            check(c.shownNote?.textView.document == kept && store().tab(first) != nil, "notes: restored from the Archive, as it was")
            c.togglePin()
            check(pinnedNote(first) != nil, "notes: ⌘D pins it again")
        }
        run { [self] in
            c.show(third)
            c.togglePin()
            let noteID = NoteURL.noteID(store().tab(third)?.url)
            let archived = store().archivedEntries.count
            c.closeCurrentTab()
            check(store().tab(third) == nil && store().note(noteID) == nil && store().archivedEntries.count == archived,
                  "notes: closing an empty note deletes it instead of archiving it (Arc)")
            c.undo()
            check(store().tab(third) != nil && store().note(noteID) != nil, "notes: ⌘Z brings the empty note back")
        }
        var firstUndo: UndoManager?, secondUndo: UndoManager?, beforeX = ""
        run { [self] in c.show(first); beforeX = lines(doc(first)); caretAtEnd(); type(" X"); firstUndo = tv()?.undoManager }
        endTurn()
        run { [self] in c.show(second); type("Second"); secondUndo = tv()?.undoManager }
        endTurn()
        run { [self] in
            c.show(first)
            tv()?.undo(nil)
            check(secondUndo != nil && secondUndo !== firstUndo && lines(doc(second)) == "heading1:Second" && lines(doc(first)) == beforeX,
                  "notes: each note has its own undo (⌘Z here undid this note's typing, not the other's)")
            // An orphan for notes-read: the second note's row deleted (its note goes at the next launch).
            if let item = pinnedNote(second)?.id { c.forgetPage(second, close: true); try? store().deleteItem(item) }
        }

        // 8. A private window can't make one.
        step { [self] done in
            PrivateBrowsing.shared.open(app: app!) { p in
                guard let p else { self.skip("notes: no private window"); return done() }
                let count = self.c.store.state.notes.count
                let menu = p.perform(menuTitle: "New Note")
                let key = p.action(forKey: "n", modifiers: [.control, .shift])
                self.check(!menu && key == nil && self.c.store.state.notes.count == count,
                           "notes: a private window has no New Note (menu \(menu), key \(key != nil))")
                p.closeWindow()
                done()
            }
        }

        // 9. As a person types (lead, 2026-11-08): keys posted to the app's own event queue (NSApp.postEvent, never HID)
        //    go through the key monitor, AppKit's key-window order (the shortcuts check's stand-in for a window that can't
        //    be key) and the text view's own keyDown/interpretKeyEvents, ⌘V and ⌘Z through the Edit menu. AppKit ends an
        //    undo group after each event, as for a person: each typing burst, format change and paste is one ⌘Z.
        var keysTab = ""
        var before = ""
        var states: [String] = []
        let cmd = { (c: String, code: UInt16, shift: Bool) in Key("⌘" + c, code, c, nil, shift ? [.command, .shift] : .command) }
        func keys(_ text: String) -> [Key] {
            text.map { ch -> Key in
                switch ch {
                case "\r", "\n": return Key("return", 36, "\r", nil, [])
                case " ": return Key("space", 49, " ", nil, [])
                default:
                    let s = String(ch)
                    let upper = s != s.lowercased()
                    return Key(s, 0, s, upper ? s.lowercased() : nil, upper ? [.shift] : [])
                }
            }
        }
        func typeKeys(_ text: String) {
            run { [self] in for k in keys(text) { postKey(k) } }
            wait(0.25 + Double(text.count) * 0.03)
        }
        run { [self] in
            Self.emulateKeyWindow(c) { [weak self] in self?.note($0) }
            // AppKit's last step for a key window, its first responder's keyDown, which an inactive app's NSApplication
            // skips (it has no key window): the same event, in the same pass of the event loop.
            let keyWindowOrder = KeyMonitor.testKeyWindowDispatch
            KeyMonitor.testKeyWindowDispatch = { [weak self] e in
                if keyWindowOrder?(e) == true { return true }
                guard let self, e.type == .keyDown, e.window === self.c.window, let r = self.c.window.firstResponder else { return false }
                r.keyDown(with: e)
                return true
            }
            NoteTextView.pasteboard = { board }
            postKey(Key("⌃⇧N", 45, "n", nil, [.control, .shift]))
        }
        wait(0.5)
        run { [self] in
            keysTab = c.shownTabID ?? ""
            check(store().isNoteTab(keysTab) && ![first, second, third].contains(keysTab) && c.window.firstResponder === tv(),
                  "notes keys: ⌃⇧N through the app's event loop makes a note with the keyboard in it")
            if let t = tv() {
                t.isAutomaticSpellingCorrectionEnabled = false
                t.isAutomaticTextReplacementEnabled = false
                t.isAutomaticDashSubstitutionEnabled = false
                t.isAutomaticQuoteSubstitutionEnabled = false
            }
        }
        typeKeys("Plan\r- milk\reggs")
        run { [self] in
            let l = lines(doc(keysTab))
            check(l == "heading1:Plan | bullet:milk | bullet:eggs", "notes keys: typed with the text view's own key handling, `- ` makes a list (\(l))")
            select("eggs")
            postKey(cmd("b", 11, false))
        }
        wait(0.4)
        run { [self] in
            board.clearContents()
            let img = NSImage(size: NSSize(width: 160, height: 90), flipped: false) { r in
                NSColor(srgbRed: 0.26, green: 0.53, blue: 0.9, alpha: 1).setFill(); r.fill(); return true
            }
            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = CaptureSession.png(cg, scale: CGFloat(cg.width) / 160) {
                let item = NSPasteboardItem()
                item.setData(png, forType: .png)
                board.writeObjects([item])
            }
            caretAtEnd()
            postKey(cmd("v", 9, false))
        }
        wait(0.5)
        typeKeys("so *very* good ")
        run { [self] in
            select("good")
            board.clearContents()
            board.setString("https://good.example/", forType: .string)
            postKey(cmd("v", 9, false))
        }
        wait(0.5)
        run { [self] in
            before = lines(doc(keysTab))
            check(before == "heading1:Plan | bullet:milk | bullet:eggs{bold} | paragraph:[image] | paragraph:so very{bold} good<https://good.example/> ",
                  "notes keys: ⌘B, ⌘V a picture (its own line), `*very*` typed becomes bold, ⌘V an address onto \"good\" (\(before))")
        }
        for _ in 0..<6 {
            run { [self] in postKey(cmd("z", 6, false)) }
            wait(0.4)
            run { [self] in states.append(lines(doc(keysTab))) }
        }
        run { [self] in
            for (i, st) in states.enumerated() { note("notes keys: ⌘Z #\(i + 1) → \(st)") }
            let expected = [
                "heading1:Plan | bullet:milk | bullet:eggs{bold} | paragraph:[image] | paragraph:so very{bold} good ",
                "heading1:Plan | bullet:milk | bullet:eggs{bold} | paragraph:[image] | paragraph:so very{bold} ",
                "heading1:Plan | bullet:milk | bullet:eggs{bold} | paragraph:[image] | paragraph:so *very* ",
                "heading1:Plan | bullet:milk | bullet:eggs{bold} | paragraph:[image] | paragraph:",
                "heading1:Plan | bullet:milk | bullet:eggs",
            ]
            let names = ["the link pasted onto \"good\"", "typing \"good \"", "`*very*` made bold", "typing \"so *very* \"", "the picture's paste"]
            for (i, want) in expected.enumerated() {
                let got = states.count > i ? states[i] : "-"
                // The picture's paste and ⌘B: after the paste the empty line under the picture may stay or go with it.
                let ok = i == 4 ? got.hasPrefix("heading1:Plan | bullet:milk | bullet:eggs{bold}") && !got.contains("[image]") : got == want
                check(ok, "notes keys: ⌘Z #\(i + 1) undoes \(names[i]) alone (\(got))")
            }
            let sixth = states.count > 5 ? states[5] : "-"
            check(sixth.hasPrefix("heading1:Plan | bullet:milk | bullet:eggs") && !sixth.contains("{bold}"), "notes keys: ⌘Z #6 undoes ⌘B alone (\(sixth))")
        }
        for _ in 0..<6 {
            run { [self] in postKey(cmd("z", 6, true)) }
            wait(0.4)
        }
        run { [self] in
            let after = lines(doc(keysTab))
            check(after == before, "notes keys: ⇧⌘Z six times puts it all back (\(after))")
            NoteTextView.pasteboard = { .general }
            KeyMonitor.testKeyWindowDispatch = nil
        }

        // 10. Export and import, the app New Note opens (P13).
        notesExportChecks()   // Debug/NotesExportCheck.swift
        // 11. New Note in Split (P13).
        notesSplitChecks()    // Debug/NotesSplitCheck.swift

        // For notes-read: what must come back.
        run { [self] in
            try? store().flush()
            let expected: [String: Any] = [
                "first": first, "doc": (try? JSONEncoder().encode(doc(first) ?? NoteDocument())).map { String(decoding: $0, as: UTF8.self) } ?? "",
                "orphan": NoteURL.noteID(store().tab(second)?.url) ?? NoteURL.noteID(store().state.notes.keys.first { id in
                    !store().referencedNoteIDs.contains(id) }.map(NoteURL.make)) ?? "",
                "files": Array(doc(first)?.imageFiles ?? []),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: expected) { try? data.write(to: notesExpected) }
            note("notes: wrote notes-expected.json")
            server?.stop()
        }
    }

    func notesReadScenario() {
        var expected: [String: Any] = [:]
        run { [self] in
            expected = (try? Data(contentsOf: notesExpected)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            guard let first = expected["first"] as? String, let json = expected["doc"] as? String,
                  let doc = try? JSONDecoder().decode(NoteDocument.self, from: Data(json.utf8)) else {
                return check(false, "notes-read: notes-expected.json from --script notes")
            }
            let store = c.store
            check(store.note(forTab: first)?.document == doc && store.item(store.tab(first)?.itemID) != nil,
                  "notes-read: after a relaunch the pinned note is there as it was")
            if c.shownTabID != first { c.show(first) }
            check(c.shownNote?.textView.document == doc, "notes-read: its editor shows it")
            let files = expected["files"] as? [String] ?? []
            check(!files.isEmpty && files.allSatisfy { NoteImages.url($0).map { FileManager.default.fileExists(atPath: $0.path) } == true },
                  "notes-read: its picture is still in Notes/Images")
            check(store.newerSchemaVersion == nil && store.unreadableRows.isEmpty, "notes-read: the store reads cleanly (schema \(SpacesStore.schemaVersion))")
        }
        // The launch's maintenance (10 s after the window) removes the orphan.
        wait(11)
        run { [self] in
            let orphan = expected["orphan"] as? String ?? ""
            check(!orphan.isEmpty && c.store.note(orphan) == nil, "notes-read: a note no row points at went at launch")
            let files = expected["files"] as? [String] ?? []
            check(!files.isEmpty && files.allSatisfy { NoteImages.url($0).map { FileManager.default.fileExists(atPath: $0.path) } == true },
                  "notes-read: the picture a note shows stays after the launch's clean-up")
        }
        notesSplitReadChecks()   // Debug/NotesSplitCheck.swift
    }
}
#endif

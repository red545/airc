// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import UniformTypeIdentifiers

/// `--script parityp04` (both engines): files, folders, links and text into the sidebar, and the portable export (P04;
/// docs/user/files.md). Everything comes from a synthetic folder in the run's own temporary folder (deleted at the end)
/// and a loopback page; drops are real pasteboards handed to the sidebar's import, as its drop target does.
///   - a mixed drop (a file, a folder with nested folders, a hidden file, a link back up and a broken link, and a link
///     with its title): the file and the link at the top of Today in the drop's order, the first shown and its page
///     loaded from disk; the folder at the end of Pinned in Finder's order, the cycle and the broken link left out;
///   - text: a phrase is a search in the profile's engine, lines that are all links a tab each, longer text a note;
///   - a drop into a pinned folder lands at the drop line's place;
///   - one ⌘Z takes a whole drop back;
///   - a big folder (400 files): the question appears as a sheet, Cancel makes nothing; Add makes the first 300 in a
///     folder; a cancel while it's being read makes nothing;
///   - Add Files… opens an open panel on the window; Cancel adds nothing;
///   - Export: Markdown and bookmarks HTML with the Space's names, folders, order and addresses, no user names or
///     passwords, notes without their text; the save panel's Format pop-up switches the extension; Cancel writes nothing.
extension SnapshotRunner {
    func parityP04Scenario() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("airc-p04-\(UUID().uuidString)")
        var server: LocalPageServer?
        var base = ""
        var sid = ""
        func write(_ path: String, _ text: String) {
            let u = root.appendingPathComponent(path)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
        func board(files: [URL] = [], links: [(String, String)] = [], text: String? = nil) -> NSPasteboard {
            let pb = NSPasteboard.withUniqueName()
            pb.clearContents()
            var items: [NSPasteboardItem] = []
            for f in files {
                let i = NSPasteboardItem()
                i.setString(f.absoluteString, forType: .fileURL)
                items.append(i)
            }
            for (u, t) in links {
                let i = NSPasteboardItem()
                i.setString(u, forType: .URL)
                i.setString(t, forType: SidebarFileImport.urlNameType)
                i.setString(u, forType: .string)
                items.append(i)
            }
            if let text {
                let i = NSPasteboardItem()
                i.setString(text, forType: .string)
                items.append(i)
            }
            pb.writeObjects(items)
            return pb
        }
        /// Drops `pb` and waits for the import to end.
        /// Drops the pasteboard `make` gives when the step runs (the loopback port is known by then).
        func drop(_ make: @escaping () -> NSPasteboard, _ dest: @escaping () -> SidebarFileDestination? = { nil },
                  then: @escaping (SidebarFileImportOperation?) -> Void) {
            step { [self] done in
                let pb = make()
                let accepted = c.importIntoSidebar(pb, destination: dest())
                let op = accepted ? SidebarFileImport.latest : nil
                waitUntil({ op?.isFinished ?? true }, timeout: 8) {
                    pb.releaseGlobally()
                    then(op)
                    done()
                }
            }
        }
        var counts = (tabs: 0, items: 0, notes: 0)
        func snapshot() { counts = (c.store.state.tabs.count, c.store.state.items.count, c.store.state.notes.count) }
        func unchanged() -> Bool { counts == (c.store.state.tabs.count, c.store.state.items.count, c.store.state.notes.count) }
        func titles(_ parent: String?) -> [String] { c.store.children(of: .pinned(spaceID: sid), parent: parent).map(\.displayTitle) }

        step { [self] done in
            write("menu.html", "<!doctype html><title>Lunch menu</title><h1>Lunch</h1>")
            write("Lisbon/Itinerary.html", "<!doctype html><title>Itinerary</title><p>Day 1</p>")
            write("Lisbon/Packing list.txt", "sunscreen")
            write("Lisbon/.DS_Store", "")
            write("Lisbon/Tickets/Tram 28.html", "<title>Tram 28</title>")
            try? fm.createSymbolicLink(at: root.appendingPathComponent("Lisbon/Tickets/back up"), withDestinationURL: root.appendingPathComponent("Lisbon"))
            try? fm.createSymbolicLink(at: root.appendingPathComponent("Lisbon/missing"), withDestinationURL: root.appendingPathComponent("nowhere"))
            for i in 0..<400 { write("Big/file \(i).txt", "\(i)") }
            sid = c.currentSpaceID
            SidebarFileImport.confirmOverride = nil
            server = LocalPageServer(pages: ["/linked": "<!doctype html><title>Linked page</title><p>linked</p>"])
            server?.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                done()
            }
        }

        // A mixed drop into Today.
        run { snapshot() }
        drop({ board(files: [root.appendingPathComponent("menu.html"), root.appendingPathComponent("Lisbon")], links: [("\(base)/linked", "Linked page")]) }) { [self] op in
            let today = c.store.todayTabs(ofSpace: sid)
            let firstTwo = today.prefix(2).map(\.title)
            let folder = c.store.pinnedRoots(ofSpace: sid).last
            let inside = folder.map { titles($0.id) } ?? []
            let tickets = folder.flatMap { f in c.store.children(of: .pinned(spaceID: sid), parent: f.id).first { $0.kind == .folder } }
            let skipped = op?.plan?.skipped
            // The file's tab may already have its page's title.
            check(["menu.html", "Lunch menu"].contains(firstTwo.first ?? "") && firstTwo.last == "Linked page" && today.first?.url.hasPrefix("file://") == true
                  && c.shownTabID == today.first?.id,
                  "P04 drop: a file and a link go to the top of Today in the drop's order, the first one shown (\(firstTwo), shown \(c.shownTabID == today.first?.id))")
            check(folder?.kind == .folder && folder?.title == "Lisbon" && inside == ["Itinerary.html", "Packing list.txt", "Tickets"]
                  && tickets.map { titles($0.id) } == ["Tram 28.html"] && skipped?.hidden == 1 && skipped?.cycles == 1 && skipped?.unreadable == 1,
                  "P04 drop: a folder becomes a pinned folder in Finder's order, nested folders kept, the hidden file, the link back up and the "
                  + "broken link left out (\(folder?.title ?? "-"): \(inside), Tickets: \(tickets.map { titles($0.id) } ?? []), skipped "
                  + "\(skipped.map { "hidden \($0.hidden), cycles \($0.cycles), unreadable \($0.unreadable)" } ?? "-"))")
        }
        step { [self] done in
            let id = c.store.todayTabs(ofSpace: sid).first?.id
            waitUntil({ id.flatMap { self.c.engineTab(for: $0) }?.title == "Lunch menu" }, timeout: 8) {
                let page = id.flatMap { self.c.engineTab(for: $0) }
                self.check(page?.title == "Lunch menu" && page?.url?.isFileURL == true,
                           "P04 drop: the file's tab loads the file from disk (title “\(page?.title ?? "-")”, \(page?.url?.scheme ?? "-"))")
                done()
            }
        }
        // File tabs show their file type's icon (a folder's for a directory); web pages keep their own.
        step { [self] done in
            let file = c.store.todayTabs(ofSpace: sid).first
            let folder = c.store.pinnedRoots(ofSpace: sid).last
            let packing = folder.flatMap { f in c.store.children(of: .pinned(spaceID: sid), parent: f.id).first { $0.pageTitle == "Packing list.txt" } }
            func shown(_ id: String?) -> NSImage? {
                id.flatMap { (c.pageView(for: sid)?.rows[$0] as? TabRowView)?.faviconViewForTesting.shownImage }
            }
            waitUntil({ shown(file?.id) != nil && shown(packing?.id) != nil }, timeout: 6) {
                let fileIcon = FaviconCache.fileIcon(forPage: file?.url)
                let packingIcon = FaviconCache.fileIcon(forPage: packing?.savedURL)
                let dir = FaviconCache.fileIcon(forPage: root.appendingPathComponent("Lisbon").absoluteString)
                let folderLike = dir.flatMap(Self.p04Pixels) == Self.p04Pixels(NSWorkspace.shared.icon(for: .folder))
                self.check(fileIcon != nil && shown(file?.id) === fileIcon && packingIcon != nil && shown(packing?.id) === packingIcon
                           && folderLike && FaviconCache.fileIcon(forPage: "\(base)/linked") == nil,
                           "P04 icons: a file tab and an unloaded pinned file show their file type's icon, a directory the folder icon, a web "
                           + "page none of these (file \(shown(file?.id) === fileIcon), pinned \(shown(packing?.id) === packingIcon), folder \(folderLike))")
                done()
            }
        }
        run { [self] in
            c.undo()
            check(unchanged(), "P04 undo: one ⌘Z takes the whole drop back (tabs \(c.store.state.tabs.count) vs \(counts.tabs), rows "
                  + "\(c.store.state.items.count) vs \(counts.items))")
        }

        // Text.
        run { snapshot() }
        drop({ board(text: "pastel de nata recipe") }) { [self] _ in
            let t = c.store.todayTabs(ofSpace: sid).first
            let want = c.store.profile(ofSpace: sid).searchEngine.searchURL(for: "pastel de nata recipe").absoluteString
            check(t?.url == want, "P04 text: a phrase is a search in the profile's engine (\(t?.url ?? "-"))")
        }
        drop({ board(text: "https://one.example\nhttps://two.example/x") }) { [self] _ in
            // A loaded page's address comes back as the engine writes it ("https://one.example/" on Chromium).
            let urls = c.store.todayTabs(ofSpace: sid).prefix(2).map(\.url)
            let bare = urls.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            check(bare == ["https://one.example", "https://two.example/x"], "P04 text: lines that are all links open a tab each (\(urls))")
        }
        drop({ board(text: "Packing\nsunscreen\nhat\ncamera") }) { [self] _ in
            let t = c.store.todayTabs(ofSpace: sid).first
            let note = NoteURL.noteID(t?.url).flatMap { c.store.state.notes[$0] }
            check(note?.document.title == "Packing", "P04 text: longer text becomes a note (\(t?.title ?? "-"))")
        }
        run { [self] in
            c.undo(); c.undo(); c.undo()
            check(unchanged(), "P04 undo: three text drops, three ⌘Z, nothing left")
        }

        // Into a pinned folder, at the drop line's place.
        var folderID = ""
        run { [self] in
            folderID = (try? c.store.createFolder(named: "Reading", inSpace: sid))?.id ?? ""
            try? c.store.applySidebarFilePlan(SidebarFilePlan(nodes: [.tab(title: "First", url: "https://first.example"), .tab(title: "Last", url: "https://last.example")]),
                                              to: SidebarFileDestination(spaceID: sid, section: .pinned(parentID: folderID, index: nil)), engine: .google)
        }
        drop({ board(links: [("\(base)/linked", "Middle")]) }, { SidebarFileDestination(spaceID: sid, section: .pinned(parentID: folderID, index: 1)) }) { [self] _ in
            check(titles(folderID) == ["First", "Middle", "Last"], "P04 drop: into a pinned folder at the drop line's place (\(titles(folderID)))")
        }

        // A big folder: the question as a real sheet; Cancel; then Add (the first 300); a cancel while reading.
        run { snapshot() }
        step { [self] done in
            _ = c.importIntoSidebar([.file(root.appendingPathComponent("Big"))])
            let op = SidebarFileImport.latest
            waitUntil({ self.c.window.attachedSheet != nil && op?.state == .asking }, timeout: 6) {
                let alert = self.c.window.attachedSheet
                let text = (alert?.contentView.map(Self.p04Texts) ?? []).joined(separator: " | ")
                let cancel = alert?.contentView.flatMap { Self.p04Button("Cancel", in: $0) }
                cancel?.performClick(nil)
                self.waitUntil({ op?.state == .cancelled && self.c.window.attachedSheet == nil }, timeout: 3) {
                    self.check(text.contains("Add 300 tabs") && text.contains("Only the first 300 files") && op?.state == .cancelled && unchanged(),
                               "P04 big folder: 400 files ask first, on a sheet (“\(text.prefix(140))”); Cancel makes nothing (\(String(describing: op?.state)))")
                    done()
                }
            }
        }
        run { SidebarFileImport.confirmOverride = { _ in true } }
        drop({ board(files: [root.appendingPathComponent("Big")]) }) { [self] op in
            let folder = c.store.pinnedRoots(ofSpace: sid).last
            let n = folder.map { c.store.children(of: .pinned(spaceID: sid), parent: $0.id).count } ?? 0
            check(folder?.title == "Big" && n == 300 && op?.plan?.truncated == true, "P04 big folder: Add makes the first 300 in a folder (\(n))")
            c.undo()
            check(unchanged(), "P04 big folder: ⌘Z takes the 300 back")
        }
        run { [self] in
            SidebarFileImport.confirmOverride = nil
            let op = c.importIntoSidebar([.file(root.appendingPathComponent("Big"))])
            op?.cancel()
            check(op?.state == .cancelled, "P04 cancel: a cancel while the folder is read ends the import")
        }
        wait(1.0)
        run { [self] in check(unchanged() && c.window.attachedSheet == nil, "P04 cancel: and makes nothing, no sheet left") }

        // Add Files…: an open panel on the window; Cancel adds nothing.
        step { [self] done in
            c.addFiles()
            waitUntil({ self.c.window.attachedSheet is NSOpenPanel }, timeout: 4) {
                let panel = self.c.window.attachedSheet as? NSOpenPanel
                let ok = panel.map { $0.canChooseFiles && $0.canChooseDirectories && $0.allowsMultipleSelection } ?? false
                panel?.cancel(nil)
                self.waitUntil({ self.c.window.attachedSheet == nil }, timeout: 3) {
                    self.check(ok && unchanged(), "P04 Add Files…: an open panel for files and folders, several at once; Cancel adds nothing "
                               + "(panel \(panel != nil), rows unchanged \(unchanged()))")
                    done()
                }
            }
        }

        // Export.
        run { [self] in
            _ = try? c.store.openTab(url: "https://reader:secret@127.0.0.1:9/private", inSpace: sid, activate: false, title: "Signed in")
            _ = try? c.store.createNote(inSpace: sid, pinned: false, document: NoteDocument(lines: ["Shopping", "keep this here"]))
            let space = c.store.space(sid)?.name ?? "?"
            let md = c.exportDocument(sid, format: .markdown) ?? ""
            let html = c.exportDocument(sid, format: .html) ?? ""
            check(md.contains("# ") && md.contains(space) && md.contains("- Reading\n  - [First](https://first.example)\n  - [Middle](")
                  && md.contains("- [Signed in](https://127.0.0.1:9/private)") && md.contains("- Shopping (note)")
                  && !md.contains("secret") && !md.contains("keep this here"),
                  "P04 export: Markdown keeps the Space's name, folders, order and links; no password, no note text (\(md.count) characters)")
            check(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>") && html.contains("<DT><H3>Reading</H3>")
                  && html.contains("<DT><A HREF=\"https://first.example\">First</A>") && !html.contains("secret") && !html.contains("keep this here"),
                  "P04 export: bookmarks HTML that browsers import, the same tree, nothing private")
            let file = root.appendingPathComponent("export.html")
            try? SidebarExportFile.write(c, spaceID: sid, format: .html, to: file)
            check((try? String(contentsOf: file, encoding: .utf8)) == html, "P04 export: written to a file as shown")
        }
        step { [self] done in
            c.exportSpace(sid)
            waitUntil({ self.c.window.attachedSheet is NSSavePanel }, timeout: 4) {
                let panel = self.c.window.attachedSheet as? NSSavePanel
                let popup = panel?.accessoryView.flatMap { Self.p04Popup(in: $0) }
                let first = panel?.nameFieldStringValue ?? ""
                popup?.selectItem(at: 1)
                if let popup, let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
                let second = panel?.nameFieldStringValue ?? ""
                panel?.cancel(nil)
                self.waitUntil({ self.c.window.attachedSheet == nil }, timeout: 3) {
                    let written = (try? fm.contentsOfDirectory(atPath: root.path))?.filter { $0.hasSuffix(".md") || $0 == "\(second)" } ?? []
                    self.check(first.hasSuffix(".md") && second.hasSuffix(".html") && popup?.numberOfItems == 2 && written.isEmpty,
                               "P04 export: the save panel offers Markdown and HTML, the name follows (\(first) → \(second)); Cancel writes nothing")
                    done()
                }
            }
        }
        // The window's drop target.
        parityP04DropTarget { root.appendingPathComponent("menu.html") }
        run { [self] in
            server?.stop()
            try? fm.removeItem(at: root)
            note("P04: removed the synthetic folder")
        }
    }

    /// An icon drawn at 32 × 32, to compare two icons by what they show.
    static func p04Pixels(_ img: NSImage) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        return rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * 32) }
    }

    static func p04Texts(_ v: NSView) -> [String] {
        ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(p04Texts)
    }

    static func p04Button(_ title: String, in v: NSView) -> NSButton? {
        if let b = v as? NSButton, b.title == title { return b }
        for s in v.subviews { if let b = p04Button(title, in: s) { return b } }
        return nil
    }

    static func p04Popup(in v: NSView) -> NSPopUpButton? {
        if let p = v as? NSPopUpButton { return p }
        for s in v.subviews { if let p = p04Popup(in: s) { return p } }
        return nil
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import PDFKit

/// Part of `--script notes` (docs/user/notes.md "Export and import", Notes/NoteExport.swift):
///   - a note with every line kind, mark, a link and a picture written as Markdown (its picture in "<name> files"),
///     RTFD, RTF, PDF and HTML into the run's own folder, and each read back by Import: the same note (RTF without
///     the picture; PDF only checked for its pages and text);
///   - Export All Notes into "Airc Notes", then "Airc Notes 2"; Import Notes… of two files and one that isn't a note;
///   - where Export is: File, a note row's menu, the editor's menu, the Command Bar;
///   - the app New Note opens (Settings → General → Notes): Google Docs opens doc.new in a tab (recorded, never
///     loaded), the menus name it, New Airc Note stays; offline, an Airc note and a toast; a value from a newer build
///     reads as Airc's notes.
extension SnapshotRunner {
    func notesExportChecks() {
        let folder = dir.appendingPathComponent("notes-export-\(getpid())", isDirectory: true)
        let store = { self.c.store }
        var tab = ""
        var original = NoteDocument()
        var picture: NoteImage?
        func lines(_ d: NoteDocument?) -> String {
            (d?.blocks ?? []).map { b in
                "\(b.kind.rawValue)\(b.indent > 0 ? "+\(b.indent)" : "")\(b.checked ? "✓" : ""):" + b.runs.map { r in
                    r.image.map { "[\($0.file.prefix(8)) \(Int($0.width))×\(Int($0.height))]" }
                        ?? (r.text + (r.marks.isEmpty ? "" : "{" + r.marks.sorted().map(\.rawValue).joined(separator: ",") + "}")
                            + (r.link.map { "<\($0)>" } ?? ""))
                }.joined()
            }.joined(separator: " | ")
        }
        /// What differs between two notes, line by line.
        func diff(_ a: NoteDocument, _ b: NoteDocument?) -> String {
            let x = lines(a).components(separatedBy: " | "), y = lines(b).components(separatedBy: " | ")
            var out: [String] = []
            for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : "∅") != (i < y.count ? y[i] : "∅") {
                out.append("#\(i): \(i < x.count ? x[i] : "∅") ≠ \(i < y.count ? y[i] : "∅")")
            }
            return out.isEmpty ? "same" : out.joined(separator: "; ")
        }

        // The note: every line kind and mark, a link, a picture (synthetic, the run's own).
        run { [self] in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(red: 0.18, green: 0.5, blue: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 120, height: 160).fill()
            NSColor(red: 0.99, green: 0.85, blue: 0.21, alpha: 1).setFill(); NSRect(x: 120, y: 0, width: 120, height: 160).fill()
            NSGraphicsContext.restoreGraphicsState()
            picture = rep.representation(using: .png, properties: [:]).flatMap { NoteImages.store($0, ext: "png") }
            guard let picture else { return check(false, "notes export: a picture to export") }
            original = NoteDocument(blocks: [
                NoteBlock(kind: .heading1, runs: [NoteRun("Export plan")]),
                NoteBlock(runs: [NoteRun("Trams, "), NoteRun("tiles", marks: [.bold]), NoteRun(", "), NoteRun("light", marks: [.italic]),
                                 NoteRun(", "), NoteRun("both", marks: [.bold, .italic]), NoteRun(", "), NoteRun("views", marks: [.underline]),
                                 NoteRun(", "), NoteRun("queues", marks: [.strikethrough]), NoteRun(" and "), NoteRun("tram28()", marks: [.code]),
                                 NoteRun(".")]),
                NoteBlock(runs: [NoteRun("See "), NoteRun("the guide", link: "https://trips.example/lisbon"), NoteRun(" and "),
                                 NoteRun("this", marks: [.bold], link: "https://trips.example/tram"), NoteRun(".")]),
                NoteBlock(kind: .heading2, runs: [NoteRun("Before we go")]),
                NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("Book the train")]),
                NoteBlock(kind: .checkbox, runs: [NoteRun("Tram 28 before nine")]),
                NoteBlock(kind: .checkbox, indent: 1, runs: [NoteRun("Tickets")]),
                NoteBlock(kind: .heading3, runs: [NoteRun("Food")]),
                NoteBlock(kind: .bullet, runs: [NoteRun("Pastéis")]),
                NoteBlock(kind: .bullet, indent: 1, runs: [NoteRun("Belém, "), NoteRun("the original", marks: [.italic])]),
                NoteBlock(kind: .numbered, indent: 1, runs: [NoteRun("early")]),
                NoteBlock(kind: .numbered, runs: [NoteRun("One")]),
                NoteBlock(kind: .numbered, runs: [NoteRun("Two")]),
                NoteBlock(runs: [NoteRun(image: picture)]),
                NoteBlock(),
                NoteBlock(runs: [NoteRun("The end")]),
            ])
            tab = (try? store().createNote(inSpace: c.currentSpaceID, document: original))?.id ?? ""
            c.show(tab)
            check(c.shownNote != nil, "notes export: the note to export is shown")
        }

        // Each format, written and read back.
        run { [self] in
            guard let picture else { return }
            let noPicture = NoteDocument(blocks: original.blocks.map { b in
                var b = b
                b.runs = b.runs.filter { $0.image == nil }
                return b
            })
            for format in NoteExportFormat.allCases {
                let url = folder.appendingPathComponent("Export plan").appendingPathExtension(format.fileExtension)
                do {
                    try NoteExport.write(original, title: "Export plan", format: format, to: url)
                } catch {
                    check(false, "notes export: \(format.rawValue) written (\(error))")
                    continue
                }
                let back: NoteDocument? = format == .pdf ? nil : (try? NoteExport.read(url))
                switch format {
                case .markdown:
                    let md = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    let copy = folder.appendingPathComponent("Export plan files/Picture 1.png")
                    let same = (try? Data(contentsOf: copy)) == NoteImages.url(picture.file).flatMap { try? Data(contentsOf: $0) }
                    check(md.hasPrefix("# Export plan\n\nTrams, **tiles**, *light*, ***both***, <u>views</u>, ~~queues~~ and `tram28()`.\n")
                          && md.contains("\n- [x] Book the train\n- [ ] Tram 28 before nine\n    - [ ] Tickets\n")
                          && md.contains("![](<Export plan files/Picture 1.png>)") && same,
                          "notes export: Markdown, its picture beside it in “Export plan files” (\(md.count) characters, picture copied \(same))")
                    check(back == original, "notes export: Markdown reads back as the same note (\(diff(original, back)))")
                case .rtfd:
                    check(back == original, "notes export: RTFD reads back as the same note, picture included (\(diff(original, back)))")
                case .rtf:
                    check(back == noPicture, "notes export: RTF reads back as the same note without its picture (\(diff(noPicture, back)))")
                case .html:
                    let html = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    check(html.contains("<img src=\"data:image/png;base64,") && html.contains("☑ Book the train"),
                          "notes export: HTML is one page with its picture inside (\(html.count) characters)")
                    check(back == original, "notes export: HTML (Arc's export format) reads back as the same note (\(diff(original, back)))")
                case .pdf:
                    let pdf = PDFDocument(url: url)
                    let text = pdf?.string ?? ""
                    check((pdf?.pageCount ?? 0) >= 1 && text.contains("Export plan") && text.contains("Book the train") && text.contains("The end"),
                          "notes export: PDF, \(pdf?.pageCount ?? 0) page(s) with the note's text")
                }
            }
        }

        // Export All Notes, and Import Notes… of the exports (and a file that isn't a note).
        run { [self] in
            let all = NoteExport.allNotes(store())
            check(all.contains { $0.document == original } && all.allSatisfy { !$0.document.isEmpty },
                  "notes export: Export All has every note with something in it (\(all.count))")
            let one = try? NoteExport.writeAll(all, format: .markdown, into: folder)
            let two = try? NoteExport.writeAll(all, format: .html, into: folder)
            let files = (one?.folder).flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?.filter { $0.hasSuffix(".md") } ?? []
            check(one?.folder.lastPathComponent == "Airc Notes" && two?.folder.lastPathComponent == "Airc Notes 2"
                  && one?.count == all.count && files.count == all.count && files.contains("Export plan.md"),
                  "notes export: Export All writes “Airc Notes”, then “Airc Notes 2”, a file per note (\(files.sorted().joined(separator: ", ")))")
            let bogus = folder.appendingPathComponent("not a note.md")
            try? Data().write(to: bogus)
            let before = store().state.notes.count
            let made = c.importNotes(from: [folder.appendingPathComponent("Export plan.md"), folder.appendingPathComponent("Export plan.rtfd"), bogus])
            let docs = made.compactMap { store().note(forTab: $0)?.document }
            check(made.count == 2 && docs == [original, original] && store().state.notes.count == before + 2
                  && made.allSatisfy { store().item(store().tab($0)?.itemID) != nil } && c.shownTabID == made.last,
                  "notes import: two files are two pinned notes as they were, the last shown (\(made.count))")
            check(c.toast.shownText == "Airc couldn’t read “not a note.md” as a note", "notes import: an empty file says so (\(c.toast.shownText ?? "no toast"))")
            for t in made { if let item = store().tab(t)?.itemID { c.forgetPage(t, close: true); try? store().deleteItem(item) } }
        }

        // Where Export is.
        run { [self] in
            c.show(tab)
            let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu
            let export = file?.items.first { $0.title == "Export Note…" } as? CommandMenuItem
            check(export.map { $0.validateMenuItem($0) } == true && file?.items.contains { $0.title == "Export All Notes…" } == true
                  && file?.items.contains { $0.title == "Import Notes…" } == true,
                  "notes export: File has Export Note… (on for a note), Export All Notes… and Import Notes…")
            let titles = c.commandActions().map(\.title)
            check(titles.contains("Export Note…") && titles.contains("Export All Notes…") && titles.contains("Import Notes…"),
                  "notes export: the Command Bar has Export Note…, Export All Notes… and Import Notes…")
            if let item = store().item(store().tab(tab)?.itemID) {
                let rowMenu = c.noteMenu(for: .pinned(item, depth: 0, store().tab(tab)))
                check(rowMenu?.items.contains { $0.title == "Export Note…" } == true, "notes export: a note row's menu has Export Note…")
            }
            if let tv = c.shownNote?.textView, let e = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                                          windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                check(tv.menu(for: e)?.items.contains { $0.title == "Export Note…" } == true, "notes export: the editor's menu has Export Note…")
            }
        }

        // The app New Note opens.
        run { [self] in
            guard let settings = app?.settings else { return check(false, "notes app: settings") }
            let saved = (settings.values.newNoteApp, NoteApps.open, NoteApps.isOnline)
            var opened: [URL] = []
            NoteApps.open = { _, url in opened.append(url) }
            NoteApps.isOnline = { true }
            settings.values.newNoteApp = .googleDocs
            let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu
            let item = file?.items.first { ($0 as? CommandMenuItem)?.command?.id == "file.newNote" } as? CommandMenuItem
            _ = item.map { $0.validateMenuItem($0) }
            let titles = c.commandActions().map(\.title), plus = c.plusMenu().items.map(\.title)
            check(item?.title == "New Google Doc" && titles.contains("New Google Doc") && titles.contains("New Airc Note")
                  && plus.contains("New Google Doc") && plus.contains("New Airc Note"),
                  "notes app: with Google Docs chosen, the menus say New Google Doc and keep New Airc Note (\(item?.title ?? "none"); \(plus.joined(separator: ", ")))")
            let before = store().state.notes.count
            c.newNote(source: .shortcut)
            check(opened == [URL(string: "https://doc.new")!] && store().state.notes.count == before,
                  "notes app: New Note opens a new Google Doc in a tab, no Airc note (\(opened))")
            NoteApps.isOnline = { false }
            c.newNote(source: .shortcut)
            let fallback = c.shownTabID ?? ""
            check(opened.count == 1 && store().state.notes.count == before + 1 && store().isNoteTab(fallback)
                  && c.toast.shownText == "You’re offline, so this is an Airc note, not a Google Doc",
                  "notes app: offline, New Note makes an Airc note and says so (\(c.toast.shownText ?? "no toast"))")
            NoteApps.isOnline = { true }
            c.commandActions().first { $0.title == "New Airc Note" }?.run()
            let aircNote = c.shownTabID ?? ""
            check(opened.count == 1 && store().isNoteTab(aircNote) && aircNote != fallback, "notes app: New Airc Note is always an Airc note")
            settings.values.newNoteApp = .airc
            _ = item.map { $0.validateMenuItem($0) }
            check(item?.title == "New Note" && !c.commandActions().map(\.title).contains("New Airc Note"), "notes app: Airc Notes again: New Note, one entry")
            let newer = try? JSONDecoder().decode(AppSettings.Values.self, from: Data(#"{"newNoteApp":"evernote"}"#.utf8))
            let notion = try? JSONDecoder().decode(AppSettings.Values.self, from: Data(#"{"newNoteApp":"notion"}"#.utf8))
            check(newer?.newNoteApp == .airc && notion?.newNoteApp == .notion && AppSettings.Values().newNoteApp == .airc,
                  "notes app: Airc Notes by default; a choice from a newer build reads as Airc Notes")
            for t in [fallback, aircNote] where store().isNoteTab(t) {
                if let i = store().tab(t)?.itemID { c.forgetPage(t, close: true); try? store().deleteItem(i) }
            }
            (settings.values.newNoteApp, NoteApps.open, NoteApps.isOnline) = saved
            if !tab.isEmpty, let i = store().tab(tab)?.itemID { c.forgetPage(tab, close: true); try? store().deleteItem(i) }
        }
    }
}
#endif

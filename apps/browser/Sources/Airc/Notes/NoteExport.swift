// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Notes out of Airc and back in (docs/user/notes.md "Export and import"), and the app New Note opens (Arc's later
// "New Note opens your default notes app"; AircKit's NoteApp). Export Note… (File, a note's menu, the editor's menu,
// the Command Bar) writes Markdown with its pictures beside it, RTFD, RTF, PDF or one HTML page; Export All Notes…
// writes every note into a folder, as Arc's "Export Arc Notes" did; Import Notes… reads those files back as notes.

enum NoteExportFormat: String, CaseIterable {
    case markdown, rtfd, rtf, pdf, html

    var title: String {
        switch self {
        case .markdown: "Markdown, pictures in a folder beside it"
        case .rtfd: "Rich Text with Pictures (RTFD)"
        case .rtf: "Rich Text (RTF), without pictures"
        case .pdf: "PDF"
        case .html: "Web Page (HTML), pictures inside"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .rtfd: "rtfd"
        case .rtf: "rtf"
        case .pdf: "pdf"
        case .html: "html"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .rtfd: .rtfd
        case .rtf: .rtf
        case .pdf: .pdf
        case .html: .html
        }
    }
}

enum NoteExport {
    enum Failure: Error { case unreadable, empty, tooLarge, notWritten }

    /// The biggest file Import Notes… reads (a note of text and a few pictures is far smaller).
    static let maxImportBytes = 64 << 20
    private static let formatKey = "AircNoteExportFormat"

    /// A note's title as a file name: no slashes or colons, at most 120 characters, "Note" for none.
    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\0")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return String((cleaned.isEmpty || cleaned == NoteURL.untitled ? "Note" : cleaned).prefix(120))
    }

    // MARK: Writing

    /// Writes `doc` as `format` to `url`, replacing what's there (the save panel asked). Markdown's pictures go into
    /// "<name> files" beside it.
    static func write(_ doc: NoteDocument, title: String, format: NoteExportFormat, to url: URL) throws {
        switch format {
        case .markdown: try markdown(doc, to: url)
        case .rtfd:
            let text = richText(doc, pictures: true)
            let wrapper = try text.fileWrapper(from: NSRange(location: 0, length: text.length),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd, .title: title])
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        case .rtf:
            let text = richText(doc, pictures: false)
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf, .title: title])
            try data.write(to: url, options: .atomic)
        case .pdf: try pdf(doc, title: title, to: url)
        case .html:
            let page = NoteHTML.export(doc, title: title) { img in
                guard let u = NoteImages.url(img.file), let data = try? Data(contentsOf: u) else { return nil }
                return "data:\(mimeType(img.file));base64,\(data.base64EncodedString())"
            }
            try Data(page.utf8).write(to: url, options: .atomic)
        }
    }

    private static func markdown(_ doc: NoteDocument, to url: URL) throws {
        let folderName = url.deletingPathExtension().lastPathComponent + " files"
        let folder = url.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        // "Picture 1.png", "Picture 2.jpg": each picture once, in the order the note shows them.
        var names: [String: String] = [:]
        for b in doc.blocks {
            for r in b.runs {
                guard let img = r.image, names[img.file] == nil, let source = NoteImages.url(img.file),
                      FileManager.default.fileExists(atPath: source.path) else { continue }
                names[img.file] = "Picture \(names.count + 1).\((img.file as NSString).pathExtension)"
            }
        }
        if !names.isEmpty {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, name) in names {
                guard let source = NoteImages.url(file) else { continue }
                try Data(contentsOf: source).write(to: folder.appendingPathComponent(name), options: .atomic)
            }
        }
        let text = NoteMarkdown.export(doc) { img in names[img.file].map { folderName + "/" + $0 } }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// The note as rich text other apps read (TextEdit, Pages, Word): Helvetica Neue in the editor's sizes, lists as
    /// lists (checkboxes as ☐ and ☑ lists), pictures as attachments. What Import reads back as the same note.
    static func richText(_ doc: NoteDocument, pictures: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var lists: [NSTextList] = []   // the list at each level now
        var numbers: [Int] = []        // its last item's number
        let maxWidth = NoteEditorView.paperInfo().imageablePageBounds.width
        for (i, b) in doc.blocks.enumerated() {
            let p = NSMutableParagraphStyle()
            p.setParagraphStyle(NoteStyle.print.paragraphStyle(NoteLine(b.kind, indent: b.indent, checked: b.checked)))
            var marker = ""
            if b.kind.isList {
                let format: NSTextList.MarkerFormat = b.kind == .numbered ? .decimal
                    : b.kind == .checkbox ? (b.checked ? .check : .box) : (b.indent % 2 == 0 ? .disc : .circle)
                lists = Array(lists.prefix(b.indent + 1))
                numbers = Array(numbers.prefix(b.indent + 1))
                if lists.count == b.indent + 1, lists[b.indent].markerFormat != format {
                    lists.removeLast()
                    numbers.removeLast()
                    // RTF gives each level of one list one marker: a nested list of another kind needs lists of its
                    // own above it too, or it reads back as its neighbour's kind (the numbers go on as they were).
                    lists = lists.map { NSTextList(markerFormat: $0.markerFormat, options: 0) }
                }
                while lists.count < b.indent { lists.append(NSTextList(markerFormat: .disc, options: 0)); numbers.append(1) }
                if lists.count == b.indent { lists.append(NSTextList(markerFormat: format, options: 0)); numbers.append(0) }
                numbers[b.indent] += 1
                p.textLists = lists
                // TextEdit's layout: the marker after a tab, the text at the next.
                let indent = 36 * CGFloat(b.indent + 1)
                p.firstLineHeadIndent = 0
                p.headIndent = indent
                p.tabStops = [NSTextTab(textAlignment: .natural, location: indent - 22), NSTextTab(textAlignment: .natural, location: indent)]
                marker = "\t" + lists[b.indent].marker(forItemNumber: numbers[b.indent]) + "\t"
            } else {
                lists = []
                numbers = []
                switch b.kind {
                case .heading1: p.headerLevel = 1
                case .heading2: p.headerLevel = 2
                case .heading3: p.headerLevel = 3
                default: break
                }
            }
            let plain: [NSAttributedString.Key: Any] = [.font: font(b.kind, []), .paragraphStyle: p]
            if !marker.isEmpty { out.append(NSAttributedString(string: marker, attributes: plain)) }
            for r in b.runs {
                if let img = r.image {
                    guard pictures, let a = attachment(img, maxWidth: maxWidth) else { continue }
                    let s = NSMutableAttributedString(attachment: a)
                    s.addAttributes(plain, range: NSRange(location: 0, length: s.length))
                    out.append(s)
                    continue
                }
                var a = plain
                a[.font] = font(b.kind, r.marks)
                if r.marks.contains(.underline) { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if r.marks.contains(.strikethrough) { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if r.marks.contains(.code) { a[.backgroundColor] = NSColor(white: 0.94, alpha: 1) }
                if b.kind == .checkbox, b.checked { a[.foregroundColor] = NSColor(white: 0.55, alpha: 1) }
                if let link = r.link { a[.link] = URL(string: link) ?? link }
                out.append(NSAttributedString(string: r.text, attributes: a))
            }
            if i < doc.blocks.count - 1 { out.append(NSAttributedString(string: "\n", attributes: plain)) }
        }
        return out
    }

    /// Fonts that read back as what they were (RTF keeps Helvetica Neue's faces by name; the system font comes back as
    /// Helvetica Neue regular or bold, which would make every heading bold): headings Medium, bold Bold.
    private static func font(_ kind: NoteBlock.Kind, _ marks: Set<NoteRun.Mark>) -> NSFont {
        let size: CGFloat = switch kind {
        case .heading1: 26
        case .heading2: 20
        case .heading3: 17
        default: NoteStyle.bodySize
        }
        if marks.contains(.code) {
            return .monospacedSystemFont(ofSize: size - 1.5, weight: marks.contains(.bold) ? .semibold : .regular)
        }
        let heading = kind == .heading1 || kind == .heading2 || kind == .heading3
        let bold = marks.contains(.bold), italic = marks.contains(.italic)
        let face = bold ? (italic ? "HelveticaNeue-BoldItalic" : "HelveticaNeue-Bold")
            : heading ? (italic ? "HelveticaNeue-MediumItalic" : "HelveticaNeue-Medium")
            : (italic ? "HelveticaNeue-Italic" : "HelveticaNeue")
        return NSFont(name: face, size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : heading ? .medium : .regular)
    }

    private static func attachment(_ img: NoteImage, maxWidth: CGFloat) -> NSTextAttachment? {
        guard let u = NoteImages.url(img.file), let data = try? Data(contentsOf: u) else { return nil }
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = img.file
        let a = NSTextAttachment(fileWrapper: wrapper)
        let scale = img.width > maxWidth ? maxWidth / img.width : 1
        a.bounds = CGRect(x: 0, y: 0, width: img.width * scale, height: img.height * scale)
        return a
    }

    /// The note on paper, as Print shows it, saved as a PDF with no panel.
    private static func pdf(_ doc: NoteDocument, title: String, to url: URL) throws {
        let info = NoteEditorView.paperInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        let op = NSPrintOperation(view: NoteEditorView.paper(doc, info: info), printInfo: info)
        op.jobTitle = title
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: url.path) else { throw Failure.notWritten }
    }

    static func mimeType(_ file: String) -> String {
        switch (file as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "webp": "image/webp"
        case "tiff": "image/tiff"
        default: "image/png"
        }
    }

    // MARK: Reading

    /// A file as a note: Markdown (its pictures read from beside it), plain text, RTF, RTFD, HTML (Arc's exports).
    static func read(_ url: URL) throws -> NoteDocument {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory != true, (values?.fileSize ?? 0) > maxImportBytes { throw Failure.tooLarge }
        let doc: NoteDocument
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mdtext":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.unreadable }
            doc = NoteMarkdown.parse(text) { picture($0, besides: url) }
        case "txt", "text":
            guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            else { throw Failure.unreadable }
            doc = NoteDocument(lines: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        case "rtf", "rtfd", "html", "htm":
            let ext = url.pathExtension.lowercased()
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : ext == "rtfd" ? .rtfd : .html
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
            if type == .html { options[.characterEncoding] = String.Encoding.utf8.rawValue }
            guard let foreign = try? NSAttributedString(url: url, options: options, documentAttributes: nil) else { throw Failure.unreadable }
            var text = foreign
            // HTML ends its last paragraph with a newline of its own.
            if type == .html, text.string.hasSuffix("\n") { text = text.attributedSubstring(from: NSRange(location: 0, length: text.length - 1)) }
            let adopted = NoteText.adopt(text, style: .print, line: .paragraph, wholeDocument: true) { NoteImages.store(attachment: $0) }
            doc = NoteText.document(adopted, trailing: .paragraph)
        default:
            throw Failure.unreadable
        }
        guard !doc.isEmpty else { throw Failure.empty }
        return doc
    }

    /// A Markdown picture: a file beside the Markdown (as written, or with its %20s undone), or a file: address.
    /// Web pictures aren't fetched (they stay links).
    private static func picture(_ path: String, besides markdown: URL) -> NoteImage? {
        guard !path.isEmpty, !path.lowercased().hasPrefix("http"), !path.lowercased().hasPrefix("data:") else { return nil }
        var candidates: [URL] = []
        if let u = URL(string: path), u.isFileURL { candidates.append(u) }
        let folder = markdown.deletingLastPathComponent()
        for p in [path, path.removingPercentEncoding ?? path] {
            candidates.append(p.hasPrefix("/") ? URL(fileURLWithPath: p) : folder.appendingPathComponent(p))
        }
        for u in candidates {
            guard let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxImportBytes,
                  let data = try? Data(contentsOf: u) else { continue }
            if let img = NoteImages.store(data, ext: NoteImages.sniffedExtension(data) ?? u.pathExtension) { return img }
        }
        return nil
    }

    // MARK: Many notes

    /// Every note a row still points at (Today, pinned, in folders, archived), with text or pictures, by title.
    static func allNotes(_ store: SpacesStore) -> [Note] {
        let referenced = store.referencedNoteIDs
        return store.state.notes.values.filter { referenced.contains($0.id) && !$0.document.isEmpty }
            .sorted { ($0.displayTitle.localizedLowercase, $0.createdAt) < ($1.displayTitle.localizedLowercase, $1.createdAt) }
    }

    /// Writes `notes` into a new folder "Airc Notes" (or "Airc Notes 2", …) in `parent`, one file each, named by
    /// title ("Lisbon plan 2" for the second of that name). Returns the folder and how many were written.
    @discardableResult
    static func writeAll(_ notes: [Note], format: NoteExportFormat, into parent: URL) throws -> (folder: URL, count: Int) {
        let fm = FileManager.default
        var folder = parent.appendingPathComponent("Airc Notes", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("Airc Notes \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var used = Set<String>()
        var count = 0
        for note in notes {
            var name = fileName(note.displayTitle)
            var k = 2
            while used.contains(name.lowercased()) { name = fileName(note.displayTitle) + " \(k)"; k += 1 }
            used.insert(name.lowercased())
            try write(note.document, title: note.displayTitle, format: format,
                      to: folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension))
            count += 1
        }
        return (folder, count)
    }

    // MARK: The panels' format

    static var lastFormat: NoteExportFormat {
        get { NoteExportFormat(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .markdown }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: formatKey) }
    }

    /// "Format: [pop-up]" under a panel; `changed` gets the new choice.
    static func formatRow(_ selected: NoteExportFormat, changed: @escaping (NoteExportFormat) -> Void) -> (NSView, AnyObject) {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: NoteExportFormat.allCases.map(\.title))
        popup.selectItem(at: NoteExportFormat.allCases.firstIndex(of: selected) ?? 0)
        let chooser = FormatChooser { changed(NoteExportFormat.allCases[$0]) }
        popup.target = chooser
        popup.action = #selector(FormatChooser.changed(_:))
        let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        return (row, chooser)
    }

    private final class FormatChooser: NSObject {
        let onChange: (Int) -> Void
        init(_ onChange: @escaping (Int) -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: NSPopUpButton) { onChange(sender.indexOfSelectedItem) }
    }
}

/// The app New Note opens: Settings → General → Notes (AppSettings' newNoteApp), Airc's own notes unless the person
/// chose another.
enum NoteApps {
    static func chosen(_ app: AppDelegate?) -> NoteApp {
        let chosen = app?.settings?.values.newNoteApp ?? .airc
        // A web app needs the network: the path is watched from the first time it matters (no polling).
        if chosen != .airc { NetworkWatch.shared.start() }
        return chosen
    }

    /// Whether a web app can be reached now. Checks set it.
    static var isOnline: () -> Bool = { NetworkWatch.shared.isOnline }

    /// A new document of a web app: a new tab in the current Space, signed in as its profile is. Checks record it.
    static var open: (WindowController, URL) -> Void = { c, url in c.navigate(to: url, newTab: true) }

    /// New Note in Split's: the new document's Today tab, not shown yet (it becomes a pane). Checks give their own page.
    static var openTab: (WindowController, URL) -> String? = { c, url in
        (try? c.store.openTab(url: url.absoluteString, inSpace: c.currentSpaceID, background: true, activate: false))?.id
    }
}

/// Settings → General → Notes: the app New Note opens. An option, never a switch made for the person.
struct NoteAppSettingsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsSection(title: "Notes", help: "Airc’s notes stay on this Mac. Another app’s new document opens in a new tab, signed in as the Space’s profile is; offline, New Note makes an Airc note instead. New Airc Note stays in the Command Bar and the sidebar’s + menu.") {
            SettingsRow(title: "New Note opens", subtitle: "⌃⇧N, File › New Note, the sidebar’s + menu and the Command Bar.") {
                AircPopUp(options: NoteApp.allCases.map { ($0.name, $0) }, selection: model.settings.values.newNoteApp, width: 190) { v in
                    model.settings.values.newNoteApp = v
                    if v != .airc { NetworkWatch.shared.start() }
                }
            }
        }
    }
}

extension WindowController {
    /// The menus' and Command Bar's New Note, as the chosen app names it ("New Google Doc").
    var newNoteTitle: String { NoteApps.chosen(app).newTitle }

    /// The sidebar "+" menu's New Note, and New Airc Note beside it when another app is chosen.
    func addNewNoteItems(to m: NSMenu) {
        m.add(newNoteTitle, ShortcutCenter.hint("file.newNote", "⌃⇧N")) { [weak self] in self?.newNote(source: .plusMenu) }
        if NoteApps.chosen(app) != .airc {
            m.add("New Airc Note") { [weak self] in self?.newAircNote(source: .plusMenu) }
        }
    }

    /// The Command Bar's note actions besides New Note.
    func noteCommandActions() -> [CommandAction] {
        var a: [CommandAction] = []
        let chosen = NoteApps.chosen(app)
        if chosen != .airc {
            a.append(.init(title: "New Airc Note", symbol: "note.text", hint: "", keywords: ["note", "notes", "airc", "scratchpad", "write"]) { [weak self] in
                self?.newAircNote(source: .commandBar)
            })
        }
        // Arc's "New Note (in Split)": beside the page on screen (Notes/NoteSplit.swift).
        if canAddNoteInSplit {
            let title = chosen == .airc ? "New Note in Split" : chosen.newTitle + " in Split"
            a.append(.init(title: title, symbol: "rectangle.split.2x1", hint: "", keywords: ["note", "notes", "split", "beside", "side", "scratchpad"]) { [weak self] in
                self?.newNoteInSplit(source: .commandBar)
            })
        }
        if store.isNoteTab(shownTabID), let id = NoteURL.noteID(store.tab(shownTabID)?.url) {
            a.append(.init(title: "Export Note…", symbol: "square.and.arrow.up", hint: "", keywords: ["note", "markdown", "pdf", "rtf", "html", "save"]) { [weak self] in
                self?.exportNote(id)
            })
        }
        a += [
            .init(title: "Export All Notes…", symbol: "square.and.arrow.up.on.square", hint: "", keywords: ["notes", "export", "markdown", "backup"]) { [weak self] in
                self?.exportAllNotes()
            },
            .init(title: "Import Notes…", symbol: "square.and.arrow.down", hint: "", keywords: ["notes", "import", "markdown", "arc"]) { [weak self] in
                self?.importNotes()
            },
        ]
        return a
    }

    /// Export Note…: the note on screen (or `noteID`'s) in the format chosen under the save panel.
    func exportNote(_ noteID: String? = nil) {
        closeCommandBar()
        guard let id = noteID ?? NoteURL.noteID(store.tab(shownTabID)?.url) else { return NSSound.beep() }
        NoteCenter.shared.existingEditor(id)?.save()
        guard let note = store.note(id) else { return NSSound.beep() }
        let panel = NSSavePanel()
        let base = NoteExport.fileName(note.displayTitle)
        var format = NoteExport.lastFormat
        let (row, chooser) = NoteExport.formatRow(format) { f in
            format = f
            panel.allowedContentTypes = [f.contentType]
            panel.nameFieldStringValue = base + "." + f.fileExtension
        }
        panel.accessoryView = row
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = base + "." + format.fileExtension
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] r in
            withExtendedLifetime(chooser) {}
            guard let self, r == .OK, let url = panel.url else { return }
            NoteExport.lastFormat = format
            do {
                try NoteExport.write(note.document, title: note.displayTitle, format: format, to: url)
                self.showToast("Exported “\(url.lastPathComponent)”")
            } catch {
                self.showToast("Airc couldn’t export the note")
            }
        }
    }

    /// Export All Notes… (Arc's Help › Export Arc Notes): every note into a new "Airc Notes" folder.
    func exportAllNotes() {
        closeCommandBar()
        let notes = NoteExport.allNotes(store)
        guard !notes.isEmpty else { return showToast("There are no notes to export") }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = notes.count == 1 ? "Your note goes into a new folder, “Airc Notes”, here." : "Your \(notes.count) notes go into a new folder, “Airc Notes”, here."
        var format = NoteExport.lastFormat
        let (row, chooser) = NoteExport.formatRow(format) { format = $0 }
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { [weak self] r in
            withExtendedLifetime(chooser) {}
            guard let self, r == .OK, let parent = panel.url else { return }
            NoteExport.lastFormat = format
            do {
                let (folder, count) = try NoteExport.writeAll(notes, format: format, into: parent)
                self.showToast(count == 1 ? "Exported 1 note to “\(folder.lastPathComponent)”" : "Exported \(count) notes to “\(folder.lastPathComponent)”")
            } catch {
                self.showToast("Airc couldn’t export the notes")
            }
        }
    }

    /// Import Notes…: Markdown, text, RTF, RTFD and HTML files (Airc's exports, Arc's) as new notes pinned in this
    /// Space; the last one is shown.
    func importNotes() {
        closeCommandBar()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd"].compactMap { UTType(filenameExtension: $0) } + [.plainText, .rtf, .rtfd, .html]
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK else { return }
            self.importNotes(from: panel.urls)
        }
    }

    /// Makes a note of each file; says what didn't read. The notes made, in order.
    @discardableResult
    func importNotes(from urls: [URL]) -> [String] {
        var made: [String] = []
        var failed: [String] = []
        for u in urls {
            guard let doc = try? NoteExport.read(u), let t = try? store.createNote(inSpace: currentSpaceID, document: doc) else {
                failed.append(u.lastPathComponent)
                continue
            }
            made.append(t.id)
        }
        if let last = made.last { show(last) }
        if let f = failed.first {
            showToast(failed.count == 1 ? "Airc couldn’t read “\(f)” as a note" : "Airc couldn’t read \(failed.count) of the files as notes")
        } else if made.count > 1 {
            showToast("Imported \(made.count) notes")
        }
        return made
    }
}

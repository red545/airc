// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import CryptoKit
import UniformTypeIdentifiers

// The note editor (docs/user/notes.md): AppKit's text view on TextKit 1, so list markers and checkboxes can be drawn in
// the margin from the line kinds (NoteText.swift) instead of living in the text, and pictures are attachment cells
// sized to the column. Arc's own editor was the same kind of thing (ArcRichTextEditorView: a text view, a format menu,
// image attachment cells, markdown shortcuts).

// MARK: - Pictures

/// The data folder's Notes/Images: each picture once, named by its SHA-256 (NoteImage.file).
enum NoteImages {
    static var folder: URL {
        AppPaths.dataDirectory.appendingPathComponent("Notes", isDirectory: true).appendingPathComponent("Images", isDirectory: true)
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        return c
    }()

    static func url(_ file: String) -> URL? { NoteImage.isValidFile(file) ? folder.appendingPathComponent(file) : nil }

    static func image(_ file: String) -> NSImage? {
        if let i = cache.object(forKey: file as NSString) { return i }
        guard let u = url(file), let i = NSImage(contentsOf: u) else { return nil }
        cache.setObject(i, forKey: file as NSString)
        return i
    }

    /// Keeps picture bytes (PNG, JPEG, GIF, HEIC, WebP; TIFF is kept as PNG) and returns how a note names them.
    static func store(_ data: Data, ext: String) -> NoteImage? {
        var bytes = data
        var ext = ext.lowercased()
        if ext == "jpeg" { ext = "jpg" }
        if ext == "tif" || ext == "tiff" {
            guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return nil }
            bytes = png
            ext = "png"
        }
        guard ["png", "jpg", "gif", "heic", "webp"].contains(ext), let image = NSImage(data: bytes) else { return nil }
        var size = image.size
        if size.width < 1 || size.height < 1, let rep = image.representations.first {
            size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        guard size.width >= 1, size.height >= 1 else { return nil }
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let file = "\(hex).\(ext)"
        let target = folder.appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try bytes.write(to: target, options: .atomic)
            } catch {
                NSLog("Airc: couldn't keep a note's picture: %@", "\(error)")
                return nil
            }
        }
        cache.setObject(image, forKey: file as NSString)
        return NoteImage(file: file, width: Double(size.width), height: Double(size.height))
    }

    /// An image with no bytes of its own (another app's attachment, an NSImage): kept as PNG.
    static func store(_ image: NSImage) -> NoteImage? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return store(tiff, ext: "tiff")
    }

    /// A picture in pasted or imported rich text: its file's bytes (typed by what they are: HTML's data: pictures are
    /// all "unknown.png"), or its image.
    static func store(attachment a: NSTextAttachment) -> NoteImage? {
        if let data = a.fileWrapper?.regularFileContents {
            let named = ((a.fileWrapper?.preferredFilename ?? "") as NSString).pathExtension
            if let image = store(data, ext: sniffedExtension(data) ?? named) { return image }
        }
        return a.image.flatMap(store)
    }

    /// PNG, JPEG, GIF or WebP by their first bytes.
    static func sniffedExtension(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: Array("GIF8".utf8)) { return "gif" }
        if head.count >= 12, head.starts(with: Array("RIFF".utf8)), Array(head[8..<12]) == Array("WEBP".utf8) { return "webp" }
        return nil
    }

    /// The pictures of the pasteboard (a Capture's PNG, a copied image, image files), in order. Empty: none.
    static func read(_ pb: NSPasteboard) -> [NoteImage] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let images = urls.compactMap { u -> NoteImage? in
                guard let type = UTType(filenameExtension: u.pathExtension), type.conforms(to: .image),
                      let data = try? Data(contentsOf: u) else { return nil }
                return store(data, ext: u.pathExtension)
            }
            if !images.isEmpty { return images }
        }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
                            (NSPasteboard.PasteboardType("public.heic"), "heic"), (NSPasteboard.PasteboardType.tiff, "tiff")] {
            if let data = pb.data(forType: type), let image = store(data, ext: ext) { return [image] }
        }
        return []
    }

    /// Forgets pictures no note shows any more, unless a backup in `backups` names them (restoring it brings their notes
    /// back). Off the main thread; launch only, after orphan notes went (SpacesStore.removeOrphanNotes).
    static func collectGarbage(keeping keep: Set<String>, backups: URL) {
        let folder = self.folder
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
            let unused = files.filter { NoteImage.isValidFile($0) && !keep.contains($0) }
            guard !unused.isEmpty else { return }
            var named = Set<String>()
            for b in (try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [] where b.pathExtension == "json" {
                guard let text = try? String(contentsOf: b, encoding: .utf8) else { return }   // unreadable: keep everything
                for f in unused where text.contains(f) { named.insert(f) }
            }
            for f in unused where !named.contains(f) { try? fm.removeItem(at: folder.appendingPathComponent(f)) }
        }
    }
}

/// A note's picture in the text: one attachment character, drawn by NoteImageCell.
final class NoteImageAttachment: NSTextAttachment {
    let note: NoteImage

    init(_ note: NoteImage) {
        self.note = note
        super.init(data: nil, ofType: nil)
        attachmentCell = NoteImageCell(note)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func string(_ image: NoteImage, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let s = NSMutableAttributedString(attachment: NoteImageAttachment(image))
        s.addAttributes(attributes, range: NSRange(location: 0, length: s.length))
        return s
    }
}

/// At most the column's width, rounded like the page card; "Picture not on this Mac" for one whose file is gone (a
/// backup from elsewhere).
final class NoteImageCell: NSTextAttachmentCell {
    let note: NoteImage

    init(_ note: NoteImage) {
        self.note = note
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError() }

    override func cellSize() -> NSSize { NSSize(width: note.width, height: note.height) }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -4) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let maxWidth = max(40, lineFrag.width - 2 * textContainer.lineFragmentPadding - 2)
        var w = CGFloat(note.width), h = CGFloat(note.height)
        if w < 1 || h < 1 { w = 320; h = 200 }
        if w > maxWidth { h *= maxWidth / w; w = maxWidth }
        return NSRect(x: 0, y: -4, width: floor(w), height: floor(h))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: cellFrame, xRadius: 6, yRadius: 6).addClip()
        if let image = NoteImages.image(note.file) {
            image.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            NSColor.quaternaryLabelColor.setFill()
            cellFrame.fill()
            let s = NSAttributedString(string: "Picture not on this Mac", attributes: [.font: AircFont.callout.appFont, .foregroundColor: NSColor.secondaryLabelColor])
            let size = s.size()
            s.draw(at: NSPoint(x: cellFrame.midX - size.width / 2, y: cellFrame.midY - size.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool { false }
}

// MARK: - The text view

/// The editor. Markdown at a line's start (`# `, `- `, `1. `, `[] `), Return continues a list (twice ends it), Tab and
/// ⇧Tab nest, ⌘B ⌘I ⌘U ⇧⌘X mark, ⌘K links, ⌥⌘0–3 text and headings, ⇧⌘7 ⇧⌘8 ⇧⌘9 numbered, bulleted and checkbox lists
/// (Google Docs' keys: Airc's own ⇧⌘L and ⇧⌘T are taken).
final class NoteTextView: NSTextView, NSTextStorageDelegate {
    var style: NoteStyle { didSet { if style != oldValue { applyStyle() } } }
    /// The kind of an empty last line, which has no newline to carry it (NoteText.swift).
    private(set) var trailingLine = NoteLine(.heading1)
    /// Called after every change the person makes (typing, formatting, a tick).
    var onChange: (() -> Void)?
    var onOpenLink: ((URL) -> Void)?
    /// Where checkboxes were drawn, for clicks on them: the line's first character, or -1 for the empty last line.
    private var checkboxes: [(rect: NSRect, line: Int)] = []
    private var restyling = false
    /// Off for the printed copy: the column is the page's width.
    var centersColumn = true

    static let noteFragment = NSPasteboard.PasteboardType("org.airc.note.fragment")

    init(style: NoteStyle) {
        self.style = style
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        storage.delegate = self
        isRichText = true
        importsGraphics = true
        allowsUndo = true
        // ⌘F is Airc's find bar, as on pages (FindBar.swift; NoteEditorView.find), never AppKit's shared find pasteboard.
        usesFindBar = false
        isAutomaticLinkDetectionEnabled = true
        isContinuousSpellCheckingEnabled = true
        usesFontPanel = false
        usesRuler = false
        allowsImageEditing = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: NoteStyle.sideInset, height: NoteStyle.topInset)
        setAccessibilityLabel("Note")
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var storage: NSTextStorage { textStorage! }

    // MARK: Loading and reading

    func load(_ doc: NoteDocument) {
        let (text, trailing) = NoteText.attributedString(doc, style: style)
        trailingLine = trailing
        storage.setAttributedString(text)
        undoManager?.removeAllActions(withTarget: self)
        setSelectedRange(NSRange(location: storage.length, length: 0))
        fixTypingAttributes()
        needsDisplay = true
    }

    var document: NoteDocument { NoteText.document(storage, trailing: trailingLine) }

    private func applyStyle() {
        backgroundColor = style.background
        drawsBackground = true
        insertionPointColor = style.accent
        selectedTextAttributes = [.backgroundColor: style.accent.withAlphaComponent(style.isDark ? 0.35 : 0.22)]
        linkTextAttributes = [.foregroundColor: style.accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
        restyleAll()
    }

    private func restyleAll() {
        guard storage.length > 0 else { fixTypingAttributes(); return }
        restyling = true
        storage.beginEditing()
        NoteText.restyle(storage, in: NSRange(location: 0, length: storage.length), style: style)
        storage.endEditing()
        restyling = false
        fixTypingAttributes()
        needsDisplay = true
    }

    // Typing keeps each line one kind and redraws its fonts (NoteText.restyle).
    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !restyling else { return }
        NoteText.restyle(textStorage, in: editedRange, style: style)
    }

    // MARK: Lines

    private var nsString: NSString { storage.string as NSString }

    /// Whether `loc` is on the empty last line.
    private func isTrailing(_ loc: Int) -> Bool {
        let s = nsString
        return s.length == 0 || (loc >= s.length && s.character(at: s.length - 1) == 0x0A)
    }

    func line(at loc: Int) -> NoteLine {
        if isTrailing(loc) { return trailingLine }
        let s = nsString
        let p = s.paragraphRange(for: NSRange(location: min(loc, s.length - 1), length: 0))
        return (storage.attribute(.noteLine, at: p.location, effectiveRange: nil) as? NoteLine) ?? .paragraph
    }

    /// The lines the selection touches (character ranges), and whether it reaches the empty last line.
    private func selectedLines() -> (ranges: [NSRange], trailing: Bool) {
        let r = selectedRange()
        let s = nsString
        let n = s.length
        let trailing = isTrailing(NSMaxRange(r))
        guard n > 0 else { return ([], true) }
        var first = r.location
        var last = r.length > 0 ? NSMaxRange(r) - 1 : r.location
        if first >= n {
            if trailing { return ([], true) }
            first = n - 1
        }
        last = min(max(last, first), n - 1)
        var ranges: [NSRange] = []
        var loc = s.paragraphRange(for: NSRange(location: first, length: 0)).location
        while loc <= last {
            let p = s.paragraphRange(for: NSRange(location: loc, length: 0))
            ranges.append(p)
            loc = NSMaxRange(p)
        }
        return (ranges, trailing)
    }

    /// Changes the kind of every selected line, as one undo step.
    func setLines(_ change: (NoteLine) -> NoteLine) {
        let (ranges, trailing) = selectedLines()
        if let first = ranges.first, let last = ranges.last {
            let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            changeAttributes(in: whole, name: "Format") {
                for r in ranges {
                    let old = (self.storage.attribute(.noteLine, at: r.location, effectiveRange: nil) as? NoteLine) ?? .paragraph
                    self.storage.addAttribute(.noteLine, value: change(old), range: r)
                }
            }
        }
        if trailing { setTrailingLine(change(trailingLine)) }
        fixTypingAttributes()
        needsDisplay = true
    }

    /// Changes attributes in `range` (`change` edits the storage) as one undo step of its own: AppKit registers undo for
    /// typing, not for attribute changes made this way, so the old attributes are kept here and put back (and redone).
    private func changeAttributes(in range: NSRange, name: String, _ change: () -> Void) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        breakUndoCoalescing()
        let before = storage.attributedSubstring(from: range)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        restyling = true
        storage.beginEditing()
        change()
        NoteText.restyle(storage, in: range, style: style)
        storage.endEditing()
        restyling = false
        didChangeText()
        registerAttributeUndo(range, before, name: name)
    }

    private func registerAttributeUndo(_ range: NSRange, _ old: NSAttributedString, name: String) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { tv in
            guard NSMaxRange(range) <= tv.storage.length else { return }
            let now = tv.storage.attributedSubstring(from: range)
            guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
            tv.restyling = true
            tv.storage.beginEditing()
            old.enumerateAttributes(in: NSRange(location: 0, length: old.length)) { attrs, r, _ in
                tv.storage.setAttributes(attrs, range: NSRange(location: range.location + r.location, length: r.length))
            }
            tv.storage.endEditing()
            tv.restyling = false
            tv.didChangeText()
            tv.setSelectedRange(range)
            tv.needsDisplay = true
            tv.registerAttributeUndo(range, now, name: name)   // the redo
        }
        if !um.isUndoing && !um.isRedoing { um.setActionName(name) }
    }

    private func setTrailingLine(_ line: NoteLine) {
        guard line != trailingLine else { return }
        let old = trailingLine
        undoManager?.registerUndo(withTarget: self) { v in v.setTrailingLine(old); v.fixTypingAttributes() }
        trailingLine = line
        needsDisplay = true
        onChange?()
    }

    func setKind(_ kind: NoteBlock.Kind) {
        let all = selectedLines().ranges.map { line(at: $0.location) } + (selectedLines().trailing ? [trailingLine] : [])
        // A list kind every selected line already has turns them back into text (the menu's tick, Docs' keys).
        let off = kind.isList && !all.isEmpty && all.allSatisfy { $0.kind == kind }
        setLines { off ? .paragraph : $0.with(kind: kind, indent: kind.isList ? $0.indent : 0, checked: false) }
    }

    func indent(by delta: Int) {
        setLines { $0.kind.isList ? $0.with(indent: $0.indent + delta) : $0 }
    }

    /// The typing attributes of the caret's line and the run before it (a link doesn't carry on).
    func fixTypingAttributes() {
        let r = selectedRange()
        guard r.length == 0 else { return }
        var marks: NoteMarks = []
        let s = nsString
        if r.location > 0, r.location <= s.length, s.character(at: r.location - 1) != 0x0A {
            marks = NoteMarks.of(storage.attribute(.noteMarks, at: r.location - 1, effectiveRange: nil))
        }
        typingAttributes = style.attributes(line(at: r.location), marks)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { fixTypingAttributes() }
    }

    // MARK: Marks and links

    func toggle(_ mark: NoteMarks) {
        let r = selectedRange()
        if r.length == 0 {
            var m = NoteMarks.of(typingAttributes[.noteMarks])
            m.formSymmetricDifference(mark)
            typingAttributes = style.attributes(line(at: r.location), m)
            return
        }
        var all = true
        storage.enumerateAttribute(.noteMarks, in: r) { v, sub, stop in
            if self.storage.attribute(.attachment, at: sub.location, effectiveRange: nil) == nil, !NoteMarks.of(v).contains(mark) {
                all = false; stop.pointee = true
            }
        }
        changeAttributes(in: r, name: "Format") {
            self.storage.enumerateAttribute(.noteMarks, in: r) { v, sub, _ in
                var m = NoteMarks.of(v)
                if all { m.remove(mark) } else { m.insert(mark) }
                if m.isEmpty { self.storage.removeAttribute(.noteMarks, range: sub) }
                else { self.storage.addAttribute(.noteMarks, value: NSNumber(value: m.rawValue), range: sub) }
            }
        }
    }

    func marks(at loc: Int) -> NoteMarks {
        guard loc < storage.length else { return NoteMarks.of(typingAttributes[.noteMarks]) }
        return NoteMarks.of(storage.attribute(.noteMarks, at: loc, effectiveRange: nil))
    }

    func setLink(_ url: URL?, in range: NSRange) {
        changeAttributes(in: range, name: url == nil ? "Remove Link" : "Link") {
            if let url { self.storage.addAttribute(.link, value: url, range: range) } else { self.storage.removeAttribute(.link, range: range) }
        }
    }

    /// ⌘K: a link on the selection (or the word at the caret), or off again.
    func editLink() {
        var r = selectedRange()
        if r.length == 0 { r = selectionRange(forProposedRange: r, granularity: .selectByWord) }
        guard r.length > 0, let window else { return NSSound.beep() }
        let existing: String? = switch storage.attribute(.link, at: r.location, effectiveRange: nil) {
        case let u as URL: u.absoluteString
        case let s as String: s
        default: nil
        }
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Link" : "Edit Link"
        alert.informativeText = "The text “\(nsString.substring(with: r).prefix(60))” opens this address in a new tab."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "https://"
        let clip = NSPasteboard.general.string(forType: .string).flatMap(Self.webURL)
        field.stringValue = existing ?? clip?.absoluteString ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        if existing != nil { alert.addButton(withTitle: "Remove Link") }
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard let url = URLRules.normalizeInput(field.stringValue).flatMap(URL.init(string:)) ?? Self.webURL(field.stringValue) else { return NSSound.beep() }
                self.setLink(url, in: r)
            case .alertThirdButtonReturn: self.setLink(nil, in: r)
            default: break
            }
            self.window?.makeFirstResponder(self)
        }
    }

    /// A pasted or typed address a link can have: http(s) and mailto only.
    static func webURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: \.isWhitespace), let u = URL(string: t), let scheme = u.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme), scheme == "mailto" || u.host?.isEmpty == false else { return nil }
        return u
    }

    // MARK: Pictures

    /// Pictures go on lines of their own (Arc's editor inserted an image as a block), the text around them stays on its
    /// lines, and the caret ends up on the line under the last one.
    func insertImages(_ images: [NoteImage]) {
        guard !images.isEmpty else { return }
        let r = selectedRange()
        let s = nsString
        let current = line(at: r.location)
        let atLineStart = r.location == 0 || s.character(at: r.location - 1) == 0x0A
        let atEnd = NSMaxRange(r) >= s.length
        let plain = style.attributes(.paragraph, [])
        let out = NSMutableAttributedString()
        if !atLineStart { out.append(NSAttributedString(string: "\n", attributes: style.attributes(current, []))) }
        for (i, img) in images.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: plain)) }
            out.append(NoteImageAttachment.string(img, attributes: plain))
        }
        out.append(NSAttributedString(string: "\n", attributes: plain))
        breakUndoCoalescing()
        insertText(out, replacementRange: r)
        breakUndoCoalescing()
        if atEnd { setTrailingLine(.paragraph) }
        fixTypingAttributes()
    }

    @objc func chooseImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.insertImages(panel.urls.compactMap { u in (try? Data(contentsOf: u)).flatMap { NoteImages.store($0, ext: u.pathExtension) } })
        }
    }

    // MARK: The pasteboard

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.noteFragment, .fileURL, .png, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
         .tiff, .rtfd, .rtf, .html, .string]
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [Self.noteFragment, .rtf, .string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let r = selectedRange()
        guard r.length > 0 else { return false }
        let part = storage.attributedSubstring(from: r)
        switch type {
        case Self.noteFragment:
            let doc = NoteText.document(part, trailing: .paragraph)
            guard let data = try? JSONEncoder().encode(doc) else { return false }
            return pboard.setData(data, forType: type)
        case .string:
            // Other apps get several lines as Markdown (lists, ticks and headings survive), part of a line as its text.
            let doc = NoteText.document(part, trailing: .paragraph)
            return pboard.setString(part.string.contains("\n") ? doc.markdown : doc.plainText, forType: .string)
        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let r = selectedRange()
        let line = line(at: r.location)
        switch type {
        case Self.noteFragment:
            guard let data = pboard.data(forType: type), let doc = try? JSONDecoder().decode(NoteDocument.self, from: data) else { return false }
            var (text, _) = NoteText.attributedString(doc, style: style)
            // One line pasted into a line takes that line's kind; several keep theirs.
            if doc.blocks.count == 1 {
                let m = NSMutableAttributedString(attributedString: text)
                m.addAttribute(.noteLine, value: line, range: NSRange(location: 0, length: m.length))
                text = m
            }
            insertText(text, replacementRange: r)
            return true
        case .fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"):
            let images = NoteImages.read(pboard)
            guard !images.isEmpty else { return false }
            insertImages(images)
            return true
        case .rtfd, .rtf, .html:
            guard let data = pboard.data(forType: type) else { return false }
            let kind: NSAttributedString.DocumentType = type == .rtfd ? .rtfd : type == .rtf ? .rtf : .html
            guard let foreign = try? NSAttributedString(data: data, options: [.documentType: kind], documentAttributes: nil) else { return false }
            let text = NoteText.adopt(foreign, style: style, line: line) { NoteImages.store(attachment: $0) }
            insertText(text, replacementRange: r)
            return true
        case .string:
            guard var text = pboard.string(forType: .string) else { return false }
            // Arc: an address pasted onto selected text makes it a link.
            if r.length > 0, let url = Self.webURL(text), !nsString.substring(with: r).contains("\n") {
                setLink(url, in: r)
                setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
                return true
            }
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let lines = text.components(separatedBy: "\n")
            let out = NSMutableAttributedString()
            for (i, l) in lines.enumerated() {
                let lineKind = i == 0 ? line : line.kind.isList ? line.next : .paragraph
                out.append(NSAttributedString(string: l, attributes: style.attributes(lineKind, i == 0 ? NoteMarks.of(typingAttributes[.noteMarks]) : [])))
                if i < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: style.attributes(lineKind, []))) }
            }
            insertText(out, replacementRange: r)
            return true
        default:
            return super.readSelection(from: pboard, type: type)
        }
    }

    /// Where ⌘V and ⇧⌘V read. Scripted checks give it a pasteboard of their own: never the owner's clipboard.
    static var pasteboard: () -> NSPasteboard = { .general }

    override func paste(_ sender: Any?) {
        if readSelection(from: Self.pasteboard()) { undoManager?.setActionName("Paste") } else { NSSound.beep() }
    }

    // Paste and Match Style (⇧⌘V): the text only.
    override func pasteAsPlainText(_ sender: Any?) {
        breakUndoCoalescing()
        if readSelection(from: Self.pasteboard(), type: .string) { undoManager?.setActionName("Paste and Match Style") }
        breakUndoCoalescing()
    }

    /// Paste and drops: the first of this note's types the pasteboard has that reads (a Finder file that isn't a
    /// picture comes in as its name).
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        let available = Set(pboard.types ?? [])
        // A paste is one undo step of its own (AppKit's paste: too), never merged with the typing around it.
        breakUndoCoalescing()
        defer { breakUndoCoalescing() }
        // Word and Pages put a picture of the copied text beside its RTF: with RTF there, the text wins. A copied image
        // (a browser's Copy Image, a Capture) has none.
        var order = readablePasteboardTypes
        if available.contains(.rtf) || available.contains(.rtfd) {
            let text: [NSPasteboard.PasteboardType] = [Self.noteFragment, .rtfd, .rtf, .html, .string]
            order = text + order.filter { !text.contains($0) }
        }
        for type in order where available.contains(type) {
            if readSelection(from: pboard, type: type) { return true }
        }
        return false
    }

    // MARK: Keys

    override func insertNewline(_ sender: Any?) {
        let r = selectedRange()
        guard r.length == 0 else { return super.insertNewline(sender) }
        let current = line(at: r.location)
        let s = nsString
        let trailing = isTrailing(r.location)
        let p = trailing ? NSRange(location: s.length, length: 0) : s.paragraphRange(for: NSRange(location: r.location, length: 0))
        let contentsEnd = NSMaxRange(p) - (NSMaxRange(p) > p.location && s.character(at: NSMaxRange(p) - 1) == 0x0A ? 1 : 0)
        let empty = contentsEnd == p.location
        // Return on an empty list item: it moves out one level, then out of the list (Notes, Docs, Notion).
        if empty, current.kind.isList {
            return setLines { _ in current.indent > 0 ? current.with(indent: current.indent - 1) : .paragraph }
        }
        let next = current.next
        if r.location == contentsEnd, NSMaxRange(p) > contentsEnd {
            // At the end of a line that has a newline: a new empty line of the next kind after it (one undo step).
            insertText(NSAttributedString(string: "\n", attributes: style.attributes(next, [])), replacementRange: NSRange(location: NSMaxRange(p), length: 0))
            setSelectedRange(NSRange(location: NSMaxRange(p), length: 0))
        } else if r.location == contentsEnd {
            // At the end of the last line: its newline, then the empty last line takes the next kind.
            typingAttributes = style.attributes(current, [])
            super.insertNewline(sender)
            setTrailingLine(next)
        } else {
            typingAttributes = style.attributes(current, marks(at: max(0, r.location - 1)))
            super.insertNewline(sender)
        }
        fixTypingAttributes()
    }

    override func deleteBackward(_ sender: Any?) {
        let r = selectedRange()
        if r.length == 0 {
            let current = line(at: r.location)
            let s = nsString
            let atStart = isTrailing(r.location) || s.paragraphRange(for: NSRange(location: min(r.location, max(0, s.length - 1)), length: 0)).location == r.location
            // At a line's start: a list item moves out a level, then becomes text; a heading becomes text.
            if atStart, current.kind != .paragraph {
                return setLines { $0.kind.isList && $0.indent > 0 ? $0.with(indent: $0.indent - 1) : .paragraph }
            }
        }
        super.deleteBackward(sender)
    }

    override func insertTab(_ sender: Any?) {
        if selectedLinesHaveList { return indent(by: 1) }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if selectedLinesHaveList { return indent(by: -1) }
        super.insertBacktab(sender)
    }

    private var selectedLinesHaveList: Bool {
        let (ranges, trailing) = selectedLines()
        return ranges.contains { line(at: $0.location).kind.isList } || (trailing && trailingLine.kind.isList)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if typed == " " { applyMarkdownShortcut() }
        if typed.count == 1, let c = typed.first, c.isWhitespace || ".,;:!?)".contains(c) { applyInlineMarkdown() }
    }

    /// Arc's markdown as you type, inside a line: `*bold*` (Arc's own), `**bold**`, `_italic_`, `-strikethrough-` (Arc's
    /// own), `~~strikethrough~~` and `` `code` ``, each closed by a space or punctuation. The markers go, the text keeps
    /// the mark, and ⌘Z right after gives the markers back. The opening marker starts a line or follows a space.
    private static let inlinePatterns: [(NSRegularExpression, NoteMarks)] = ([
        (#"\*\*([^\s*](?:[^*\n]*[^\s*])?)\*\*$"#, .bold),
        (#"~~([^\s~](?:[^~\n]*[^\s~])?)~~$"#, .strikethrough),
        (#"`([^`\n]+)`$"#, .code),
        (#"\*([^\s*](?:[^*\n]*[^\s*])?)\*$"#, .bold),
        (#"_([^\s_](?:[^_\n]*[^\s_])?)_$"#, .italic),
        (#"-(\w+(?:\s\w+)*)-$"#, .strikethrough),
    ] as [(String, NoteMarks)]).map { (try! NSRegularExpression(pattern: "(?:^|(?<=\\s))" + $0.0), $0.1) }

    private func applyInlineMarkdown() {
        let caret = selectedRange()
        guard caret.length == 0, caret.location >= 2 else { return }
        let s = nsString
        let end = caret.location - 1   // the space or punctuation just typed stays
        let p = s.paragraphRange(for: NSRange(location: end, length: 0))
        guard end > p.location else { return }
        let before = NSRange(location: p.location, length: end - p.location)
        let text = s.substring(with: before)
        for (regex, mark) in Self.inlinePatterns {
            guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { continue }
            let whole = NSRange(location: p.location + m.range.location, length: m.range.length)
            let inner = NSRange(location: p.location + m.range(at: 1).location, length: m.range(at: 1).length)
            // Not across a picture or a link, and not inside code.
            if storage.attribute(.attachment, at: inner.location, effectiveRange: nil) != nil { return }
            let marked = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: inner))
            marked.enumerateAttribute(.noteMarks, in: NSRange(location: 0, length: marked.length)) { v, r, _ in
                marked.addAttribute(.noteMarks, value: NSNumber(value: NoteMarks.of(v).union(mark).rawValue), range: r)
            }
            breakUndoCoalescing()
            super.insertText(marked, replacementRange: whole)
            breakUndoCoalescing()
            setSelectedRange(NSRange(location: whole.location + inner.length + 1, length: 0))
            return
        }
    }

    /// `# `, `## `, `### `, `- ` or `* `, `1. `, `[] ` or `- [ ] ` (and `[x] `) typed at the start of a text line.
    private func applyMarkdownShortcut() {
        let loc = selectedRange().location
        let s = nsString
        guard loc > 0, loc <= s.length else { return }
        let p = s.paragraphRange(for: NSRange(location: loc - 1, length: 0))
        guard line(at: p.location).kind == .paragraph else { return }
        let prefix = s.substring(with: NSRange(location: p.location, length: loc - p.location))
        let target: NoteLine? = switch prefix {
        case "# ": NoteLine(.heading1)
        case "## ": NoteLine(.heading2)
        case "### ": NoteLine(.heading3)
        case "- ", "* ", "• ": NoteLine(.bullet)
        case "1. ", "1) ": NoteLine(.numbered)
        case "[] ", "[ ] ", "- [ ] ", "- [] ": NoteLine(.checkbox)
        case "[x] ", "- [x] ": NoteLine(.checkbox, checked: true)
        default: nil
        }
        guard let target else { return }
        let prefixRange = NSRange(location: p.location, length: loc - p.location)
        // Through the text view's own editing, as a step of its own: ⌘Z right after gives the typed `- ` back.
        breakUndoCoalescing()
        super.insertText("", replacementRange: prefixRange)
        setSelectedRange(NSRange(location: p.location, length: 0))
        setLines { _ in target }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Digits by key code: ⌥ and ⇧ type other characters on most layouts.
        let digit: String? = [29: "0", 18: "1", 19: "2", 20: "3", 26: "7", 28: "8", 25: "9"][Int(event.keyCode)]
        switch (mods, key, digit) {
        case (.command, "b", _): toggle(.bold)
        case (.command, "i", _): toggle(.italic)
        case (.command, "u", _): toggle(.underline)
        case ([.command, .shift], "x", _): toggle(.strikethrough)
        case (.command, "k", _): editLink()
        case ([.command, .option], _, "0"?): setKind(.paragraph)
        case ([.command, .option], _, "1"?): setKind(.heading1)
        case ([.command, .option], _, "2"?): setKind(.heading2)
        case ([.command, .option], _, "3"?): setKind(.heading3)
        case ([.command, .shift], _, "7"?): setKind(.numbered)
        case ([.command, .shift], _, "8"?): setKind(.bullet)
        case ([.command, .shift], _, "9"?): setKind(.checkbox)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: Checkboxes

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = checkboxes.first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }) {
            toggleCheckbox(hit.line)
            return
        }
        super.mouseDown(with: event)
    }

    /// Ticks or unticks the checkbox of the line starting at `loc` (-1: the empty last line). One undo step.
    func toggleCheckbox(_ loc: Int) {
        if loc < 0 { return setTrailingLine(trailingLine.with(checked: !trailingLine.checked)) }
        let p = nsString.paragraphRange(for: NSRange(location: loc, length: 0))
        guard let line = storage.attribute(.noteLine, at: p.location, effectiveRange: nil) as? NoteLine, line.kind == .checkbox else { return }
        changeAttributes(in: p, name: line.checked ? "Untick" : "Tick") {
            self.storage.addAttribute(.noteLine, value: line.with(checked: !line.checked), range: p)
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func setFrameSize(_ newSize: NSSize) {
        if centersColumn {
            let side = max(NoteStyle.sideInset, floor((newSize.width - NoteStyle.columnWidth) / 2))
            if textContainerInset.width != side { textContainerInset = NSSize(width: side, height: NoteStyle.topInset) }
        }
        super.setFrameSize(newSize)
    }

    // ⌘Z and ⇧⌘Z: this note's own history (its delegate's undo manager), never another note's or the window's.
    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case NSSelectorFromString("undo:"): return undoManager?.canUndo ?? false
        case NSSelectorFromString("redo:"): return undoManager?.canRedo ?? false
        // Paste reads `pasteboard` (NoteTextView.paste): it's on when that has something this note takes.
        case #selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:)), NSSelectorFromString("pasteAndMatchStyle:"):
            let available = Set(Self.pasteboard().types ?? [])
            return isEditable && readablePasteboardTypes.contains(where: available.contains)
        default: return super.validateUserInterfaceItem(item)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawMarkers(in: rect)
    }

    private func drawMarkers(in rect: NSRect) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        checkboxes.removeAll()
        let origin = textContainerOrigin
        let s = nsString
        let glyphs = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var loc = chars.location > 0 ? s.paragraphRange(for: NSRange(location: chars.location, length: 0)).location : 0
        while loc < min(NSMaxRange(chars) + 1, s.length) {
            let p = s.paragraphRange(for: NSRange(location: loc, length: 0))
            let line = (storage.attribute(.noteLine, at: p.location, effectiveRange: nil) as? NoteLine) ?? .paragraph
            if line.kind.isList {
                let g = lm.glyphIndexForCharacter(at: p.location)
                let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let baseline = frag.minY + lm.location(forGlyphAt: g).y
                drawMarker(line, number: line.kind == .numbered ? number(at: p.location, line) : 0,
                           baselineY: origin.y + baseline, lineStart: p.location)
            }
            loc = NSMaxRange(p)
        }
        // The empty last line, and the placeholders of a new note.
        let extra = lm.extraLineFragmentRect
        if extra.height > 0, trailingLine.kind.isList {
            let font = style.baseFont(trailingLine.kind)
            let n = trailingLine.kind == .numbered ? number(at: s.length, trailingLine) : 0
            drawMarker(trailingLine, number: n, baselineY: origin.y + extra.minY + font.ascender, lineStart: -1)
        }
        drawPlaceholders(extra: extra, origin: origin)
    }

    /// A numbered item's number: one more than the item before it at the same level (deeper items don't count).
    private func number(at loc: Int, _ line: NoteLine) -> Int {
        let s = nsString
        var n = 1
        var cursor = loc
        while cursor > 0 {
            let prev = s.paragraphRange(for: NSRange(location: cursor - 1, length: 0))
            let l = (storage.attribute(.noteLine, at: prev.location, effectiveRange: nil) as? NoteLine) ?? .paragraph
            if l.kind.isList, l.indent > line.indent { cursor = prev.location; continue }
            guard l.kind == .numbered, l.indent == line.indent else { break }
            n += 1
            cursor = prev.location
        }
        return n
    }

    private func drawMarker(_ line: NoteLine, number: Int, baselineY: CGFloat, lineStart: Int) {
        let font = style.baseFont(line.kind)
        let textX = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5) + NoteStyle.listIndent
            + CGFloat(line.indent) * NoteStyle.indentStep
        switch line.kind {
        case .bullet:
            // A dot, a ring, a square by level, centred on the x-height (a "•" glyph is too small and too light).
            let d: CGFloat = line.indent % 3 == 2 ? 5 : 5.5
            let dot = NSRect(x: textX - 14 - d / 2, y: baselineY - font.xHeight / 2 - d / 2, width: d, height: d)
            switch line.indent % 3 {
            case 0:
                style.secondary.setFill()
                NSBezierPath(ovalIn: dot).fill()
            case 1:
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.2
                style.secondary.setStroke()
                ring.stroke()
            default:
                style.secondary.setFill()
                NSBezierPath(roundedRect: dot, xRadius: 1, yRadius: 1).fill()
            }
        case .numbered:
            let s = NSAttributedString(string: "\(number).", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular), .foregroundColor: style.secondary])
            s.draw(at: NSPoint(x: textX - 7 - s.size().width, y: baselineY - font.ascender))
        case .checkbox:
            let side: CGFloat = 15
            let box = NSRect(x: textX - side - 8, y: baselineY - font.capHeight / 2 - side / 2, width: side, height: side)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
            if line.checked {
                style.accent.setFill()
                path.fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + 4, y: box.midY + 0.5))
                tick.line(to: NSPoint(x: box.minX + 6.5, y: box.maxY - 4.5))
                tick.line(to: NSPoint(x: box.maxX - 3.5, y: box.minY + 4.5))
                tick.lineWidth = 1.8
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                style.onAccent.setStroke()
                tick.stroke()
            } else {
                style.secondary.setStroke()
                path.lineWidth = 1.3
                path.stroke()
            }
            checkboxes.append((box, lineStart))
        default:
            break
        }
    }

    private func drawPlaceholders(extra: NSRect, origin: NSPoint) {
        let s = nsString
        let padding = textContainer?.lineFragmentPadding ?? 5
        func draw(_ text: String, _ kind: NoteBlock.Kind, at y: CGFloat) {
            let font = style.baseFont(kind)
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: style.tertiary])
                .draw(at: NSPoint(x: origin.x + padding, y: y))
        }
        if s.length == 0, extra.height > 0, !trailingLine.kind.isList {
            draw(trailingLine.kind == .heading1 ? NoteURL.untitled : "Your best ideas here", trailingLine.kind, at: origin.y + extra.minY)
            return
        }
        if s.length > 0, s.character(at: 0) == 0x0A, line(at: 0).kind == .heading1, let lm = layoutManager {
            // An empty title line above the text.
            draw(NoteURL.untitled, .heading1, at: origin.y + lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: 0), effectiveRange: nil).minY)
        }
        if extra.height > 0, trailingLine.kind == .paragraph, s.length > 0, s.range(of: "\n").location == s.length - 1 {
            // A title and nothing under it yet (Arc's body placeholder).
            draw("Your best ideas here", .paragraph, at: origin.y + extra.minY)
        }
    }

    // MARK: The menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let format = NSMenu(title: "Format")
        let current = line(at: selectedRange().location)
        func add(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, on: Bool, _ run: @escaping () -> Void) {
            let item = NoteMenuItem(title: title, run: run)
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
            item.state = on ? .on : .off
            format.addItem(item)
        }
        add("Text", "0", [.command, .option], on: current.kind == .paragraph) { [weak self] in self?.setKind(.paragraph) }
        add("Heading 1", "1", [.command, .option], on: current.kind == .heading1) { [weak self] in self?.setKind(.heading1) }
        add("Heading 2", "2", [.command, .option], on: current.kind == .heading2) { [weak self] in self?.setKind(.heading2) }
        add("Heading 3", "3", [.command, .option], on: current.kind == .heading3) { [weak self] in self?.setKind(.heading3) }
        format.addItem(.separator())
        add("Bulleted List", "8", [.command, .shift], on: current.kind == .bullet) { [weak self] in self?.setKind(.bullet) }
        add("Numbered List", "7", [.command, .shift], on: current.kind == .numbered) { [weak self] in self?.setKind(.numbered) }
        add("Checklist", "9", [.command, .shift], on: current.kind == .checkbox) { [weak self] in self?.setKind(.checkbox) }
        format.addItem(.separator())
        let m = marks(at: selectedRange().location)
        add("Bold", "b", .command, on: m.contains(.bold)) { [weak self] in self?.toggle(.bold) }
        add("Italic", "i", .command, on: m.contains(.italic)) { [weak self] in self?.toggle(.italic) }
        add("Underline", "u", .command, on: m.contains(.underline)) { [weak self] in self?.toggle(.underline) }
        add("Strikethrough", "x", [.command, .shift], on: m.contains(.strikethrough)) { [weak self] in self?.toggle(.strikethrough) }
        add("Code", "", [], on: m.contains(.code)) { [weak self] in self?.toggle(.code) }
        let top = [NoteMenuItem(title: "Format", run: {}), NoteMenuItem(title: "Add Link…", run: { [weak self] in self?.editLink() }),
                   NoteMenuItem(title: "Insert Image…", run: { [weak self] in self?.chooseImage(nil) }),
                   NoteMenuItem(title: "Export Note…", run: { [weak self] in
                       guard let editor = self?.delegate as? NoteEditor else { return }
                       editor.controller?.exportNote(editor.noteID)
                   })]
        top[0].submenu = format
        top[1].keyEquivalent = "k"
        top[1].keyEquivalentModifierMask = .command
        for (i, item) in top.enumerated() { menu.insertItem(item, at: i) }
        menu.insertItem(.separator(), at: top.count)
        return menu
    }
}

/// A menu item that runs a closure.
final class NoteMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

// MARK: - The view in the page card

/// A note in the page card: the text column on the card's `surface`, inside its rounded corners, with the card's
/// hairline on top.
final class NoteEditorView: NSView {
    let scrollView = NSScrollView()
    let textView: NoteTextView
    let noteID: String

    init(noteID: String, style: NoteStyle) {
        self.noteID = noteID
        textView = NoteTextView(style: style)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.cornerRadius = AircMetrics.Window.cardRadius
        layer?.cornerCurve = .circular
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.documentView = textView
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        addSubview(scrollView)
        applyStyle()
        setAccessibilityIdentifier("note-editor")
    }

    required init?(coder: NSCoder) { fatalError() }

    var style: NoteStyle {
        get { textView.style }
        set { textView.style = newValue; applyStyle() }
    }

    private func applyStyle() {
        layer?.backgroundColor = textView.style.background.cgColor
        layer?.borderColor = (textView.style.hairline ?? .clear).cgColor
        scrollView.backgroundColor = textView.style.background
        scrollView.appearance = NSAppearance(named: textView.style.isDark ? .darkAqua : .aqua)
    }

    override func layout() {
        super.layout()
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
    }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { if layer?.cornerRadius != newValue { layer?.cornerRadius = newValue } }
    }

    // MARK: Find (⌘F ⌘G ⇧⌘G) and Print (⌘P)

    private var found: [NSRange] = []
    private var foundText = ""

    /// Airc's find bar on a note, as on a page: every match highlighted, the next one (or the one before, `forward`
    /// false) selected, scrolled to and flashed. Case and accents don't matter. Returns how many there are and which one
    /// is selected (1-based; 0 when none).
    func find(_ text: String, forward: Bool) -> (matches: Int, active: Int) {
        guard let lm = textView.layoutManager else { return (0, 0) }
        let s = textView.string as NSString
        let all = NSRange(location: 0, length: s.length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        guard !text.isEmpty else { found = []; foundText = ""; return (0, 0) }
        let again = text == foundText
        found = []
        var rest = all
        while rest.length > 0 {
            let m = s.range(of: text, options: [.caseInsensitive, .diacriticInsensitive], range: rest)
            guard m.location != NSNotFound, m.length > 0 else { break }
            found.append(m)
            rest = NSRange(location: NSMaxRange(m), length: s.length - NSMaxRange(m))
        }
        foundText = text
        guard !found.isEmpty else { return (0, 0) }
        let fill = textView.style.accent.withAlphaComponent(textView.style.isDark ? 0.30 : 0.18)
        for m in found { lm.addTemporaryAttribute(.backgroundColor, value: fill, forCharacterRange: m) }
        let sel = textView.selectedRange()
        let current = found.firstIndex(of: sel)
        let index: Int
        if again, let current {
            index = (current + (forward ? 1 : found.count - 1)) % found.count
        } else if forward {
            // Typing the search: the first match from the selection on.
            index = found.firstIndex { $0.location >= sel.location } ?? 0
        } else {
            index = found.lastIndex { NSMaxRange($0) <= sel.location } ?? found.count - 1
        }
        let m = found[index]
        textView.setSelectedRange(m)
        textView.scrollRangeToVisible(m)
        if textView.window != nil { textView.showFindIndicator(for: m) }
        return (found.count, index + 1)
    }

    func stopFinding() {
        found = []
        foundText = ""
        textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
    }

    /// Print and Save as PDF (the print panel's PDF menu): the note on white paper, markers and pictures included.
    func printNote(from window: NSWindow, title: String) {
        let info = Self.paperInfo()
        let op = NSPrintOperation(view: Self.paper(textView.document, info: info), printInfo: info)
        op.jobTitle = title
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// The page Print and Export as PDF use: the default paper, 54 pt margins, the note's width fitted to it.
    static func paperInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        for m in [\NSPrintInfo.leftMargin, \.rightMargin, \.topMargin, \.bottomMargin] { info[keyPath: m] = 54 }
        return info
    }

    /// `doc` on white paper as wide as `info`'s printable area.
    static func paper(_ doc: NoteDocument, info: NSPrintInfo) -> NoteTextView {
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let paper = NoteTextView(style: .print)
        paper.centersColumn = false
        paper.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        paper.load(doc)
        paper.textContainerInset = .zero
        paper.layoutManager?.ensureLayout(for: paper.textContainer!)
        paper.sizeToFit()
        return paper
    }
}

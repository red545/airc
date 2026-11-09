// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Notes (Arc's Notes, docs/user/notes.md): a note is a sidebar row like a tab. Its tab or pinned item carries the
// note's address (`airc-note:<id>`), so it drags, pins, goes into folders, archives and restores by the tab rules; what
// it says is a `note` row in the store, and its pictures are files in the data folder (the app's NoteImages). Notes
// stay on this Mac: the sync adapter keeps their rows local-only (SyncStoreAdapter.isLocalOnly) and has no `note`
// record kind.

/// A note's address: what its tab or pinned item has for a URL. Never loaded by an engine.
public enum NoteURL {
    public static let scheme = "airc-note"

    public static func make(_ id: String) -> String { "\(scheme):\(id)" }

    /// The note an address is for, or nil when it isn't a note's.
    public static func noteID(_ url: String?) -> String? {
        guard let url, url.hasPrefix(scheme + ":") else { return nil }
        let id = url.dropFirst(scheme.count + 1)
        return id.isEmpty || id.contains("/") ? nil : String(id)
    }

    public static func isNote(_ url: String?) -> Bool { noteID(url) != nil }

    /// What the sidebar calls a note with no text yet (Arc's "+" menu item and Command Bar action are "New Note").
    public static let untitled = "New Note"
}

// MARK: - What a note says

/// A note's text: lines (paragraphs, headings, list items) of styled runs, pictures among them. A small model rather
/// than RTFD: the store, its op log and the backups hold readable JSON with no picture data (pictures are files, named
/// here), and the editor's attributed string maps onto it one to one (the app's NoteText). Arc's notes had the same
/// shape (ScratchpadBlock: a block type with rich-text properties). A value a newer build writes reads here as the
/// nearest thing this build knows: an unknown line kind is a paragraph, an unknown mark is dropped (code review H4).
public struct NoteDocument: Codable, Hashable, Sendable {
    public var blocks: [NoteBlock]

    public init(blocks: [NoteBlock] = []) { self.blocks = blocks }

    /// A note of plain lines (tests, fixtures).
    public init(lines: [String]) { blocks = lines.map { NoteBlock(kind: .paragraph, runs: [NoteRun($0)]) } }

    /// The longest title the sidebar keeps; the rest of the line stays in the note.
    public static let maxTitleLength = 120

    /// The note's name in the sidebar: its first line with text, trimmed (Arc's notes had a title; here, as in Apple's
    /// Notes, it's the first line). Empty for a note with no text.
    public var title: String {
        for b in blocks {
            let line = b.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            return line.count > Self.maxTitleLength ? String(line.prefix(Self.maxTitleLength)) + "…" : line
        }
        return ""
    }

    /// Every line's text, pictures left out.
    public var plainText: String { blocks.map(\.plainText).joined(separator: "\n") }

    /// No text and no picture: closing it deletes it instead of archiving it (Arc, 2023).
    public var isEmpty: Bool {
        blocks.allSatisfy { b in
            b.runs.allSatisfy { $0.image == nil && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    /// The picture files the note shows.
    public var imageFiles: Set<String> { Set(blocks.flatMap { $0.runs.compactMap { $0.image?.file } }) }

    /// Markdown for Copy as Markdown and the plain-text pasteboard (headings, lists, checkboxes, bold, italic, links;
    /// a picture is left out).
    public var markdown: String {
        var out: [String] = []
        var numbers: [Int: Int] = [:]
        for b in blocks {
            if b.kind != .numbered { numbers = numbers.filter { $0.key < b.indent } }
            let pad = String(repeating: "    ", count: b.indent)
            let text = b.runs.map(\.markdown).joined()
            switch b.kind {
            case .paragraph: out.append(text)
            case .heading1: out.append("# " + text)
            case .heading2: out.append("## " + text)
            case .heading3: out.append("### " + text)
            case .bullet: out.append(pad + "- " + text)
            case .checkbox: out.append(pad + (b.checked ? "- [x] " : "- [ ] ") + text)
            case .numbered:
                numbers = numbers.filter { $0.key <= b.indent }
                let n = (numbers[b.indent] ?? 0) + 1
                numbers[b.indent] = n
                out.append(pad + "\(n). " + text)
            }
        }
        return out.joined(separator: "\n")
    }
}

/// One line of a note.
public struct NoteBlock: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case paragraph, heading1, heading2, heading3, bullet, numbered, checkbox

        public var isList: Bool { self == .bullet || self == .numbered || self == .checkbox }

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .paragraph
        }
    }

    public var kind: Kind
    /// List nesting (Tab and ⇧Tab), 0 at the left. Always 0 outside lists.
    public var indent: Int
    /// A checkbox's tick.
    public var checked: Bool
    public var runs: [NoteRun]

    public static let maxIndent = 6

    public init(kind: Kind = .paragraph, indent: Int = 0, checked: Bool = false, runs: [NoteRun] = []) {
        self.kind = kind
        self.indent = kind.isList ? min(max(indent, 0), Self.maxIndent) : 0
        self.checked = kind == .checkbox && checked
        self.runs = runs
    }

    public var plainText: String { runs.filter { $0.image == nil }.map(\.text).joined() }

    private enum CodingKeys: String, CodingKey { case kind, indent, checked, runs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .paragraph
        self.init(kind: kind, indent: try c.decodeIfPresent(Int.self, forKey: .indent) ?? 0,
                  checked: try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false,
                  runs: try c.decodeIfPresent([NoteRun].self, forKey: .runs) ?? [])
    }

    /// Only what differs from the defaults is written: a plain line is `{"runs":[{"text":"…"}]}`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if kind != .paragraph { try c.encode(kind, forKey: .kind) }
        if indent != 0 { try c.encode(indent, forKey: .indent) }
        if checked { try c.encode(checked, forKey: .checked) }
        if !runs.isEmpty { try c.encode(runs, forKey: .runs) }
    }
}

/// Text with one style, or a picture.
public struct NoteRun: Codable, Hashable, Sendable {
    public enum Mark: String, Codable, Sendable, CaseIterable, Comparable {
        case bold, italic, underline, strikethrough, code
        public static func < (a: Mark, b: Mark) -> Bool { a.rawValue < b.rawValue }
    }

    /// The text; a picture's is U+FFFC, the attachment character.
    public var text: String
    public var marks: Set<Mark>
    /// A link's address (opens in a new tab).
    public var link: String?
    public var image: NoteImage?

    public static let attachmentCharacter = "\u{FFFC}"

    public init(_ text: String, marks: Set<Mark> = [], link: String? = nil) {
        self.text = text
        self.marks = marks
        self.link = link
        image = nil
    }

    public init(image: NoteImage) {
        text = Self.attachmentCharacter
        marks = []
        link = nil
        self.image = image
    }

    var markdown: String {
        guard image == nil else { return "" }
        var s = text
        if marks.contains(.code) { s = "`" + s + "`" }
        if marks.contains(.bold) { s = "**" + s + "**" }
        if marks.contains(.italic) { s = "*" + s + "*" }
        if marks.contains(.strikethrough) { s = "~~" + s + "~~" }
        if let link { s = "[" + s + "](" + link + ")" }
        return s
    }

    private enum CodingKeys: String, CodingKey { case text, marks, link, image }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decodeIfPresent(NoteImage.self, forKey: .image)
        text = image != nil ? Self.attachmentCharacter : (try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        // A mark a newer build added is dropped here, not the whole note.
        marks = Set((try c.decodeIfPresent([String].self, forKey: .marks) ?? []).compactMap(Mark.init(rawValue:)))
        link = try c.decodeIfPresent(String.self, forKey: .link)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let image { try c.encode(image, forKey: .image) } else { try c.encode(text, forKey: .text) }
        if !marks.isEmpty { try c.encode(marks.sorted().map(\.rawValue), forKey: .marks) }
        if let link { try c.encode(link, forKey: .link) }
    }
}

/// A picture in a note: a pasted Capture, an image from the clipboard or a file.
public struct NoteImage: Codable, Hashable, Sendable {
    /// Its file in the data folder's Notes/Images: the SHA-256 of its bytes and their type ("<hex>.png"), so the same
    /// picture is one file however often it's pasted, and a backup's notes find theirs again.
    public var file: String
    /// Its size in points, as pasted (the editor shows it at most as wide as the note).
    public var width: Double
    public var height: Double

    public init(file: String, width: Double, height: Double) {
        self.file = file
        self.width = width
        self.height = height
    }

    /// File names this build writes and reads: hex and an image extension, nothing that could climb out of the folder.
    public static func isValidFile(_ name: String) -> Bool {
        name.range(of: #"^[0-9a-f]{16,128}\.(png|jpg|jpeg|gif|tiff|heic|webp)$"#, options: .regularExpression) != nil
    }
}

// MARK: - The note row

/// A note in the store. Its rows (a tab, a pinned item, an archive entry) find it by `NoteURL.make(id)`.
public struct Note: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var document: NoteDocument
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = newID(), document: NoteDocument = NoteDocument(), createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.document = document
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var url: String { NoteURL.make(id) }

    /// What its rows show.
    public var displayTitle: String {
        let t = document.title
        return t.isEmpty ? NoteURL.untitled : t
    }
}

extension Note: StoreEntity {
    public static var entityKind: EntityKind { .note }
    public static var stateKeyPath: WritableKeyPath<StoreState, [String: Note]> { \.notes }
}

// MARK: - Store actions

extension SpacesStore {
    public func note(_ id: String?) -> Note? { id.flatMap { state.notes[$0] } }

    /// The note a tab shows, if it's a note's tab (nil also for a note tab whose note row is missing).
    public func note(forTab tabID: String?) -> Note? { note(NoteURL.noteID(tab(tabID)?.url)) }

    public func isNoteTab(_ tabID: String?) -> Bool { NoteURL.isNote(tab(tabID)?.url) }

    /// Arc's New Note (⌃⇧N, the Command Bar, the sidebar's "+" menu): a new note, pinned at the bottom of `spaceID`'s
    /// pinned tabs (or inside folder `parentID`), with its tab opened and made the Space's last used. Arc pinned new
    /// notes "so they're easier to access and harder to close" (2021); ⌘D moves one to Today. `pinned: false` opens it
    /// at the top of Today instead.
    @discardableResult
    public func createNote(inSpace spaceID: String, pinned: Bool = true, parentID: String? = nil,
                           document: NoteDocument = NoteDocument()) throws -> LiveTab {
        guard let s = space(spaceID) else { throw StoreError.notFound }
        if let parentID {
            guard let f = item(parentID), f.kind == .folder, f.container == .pinned(spaceID: spaceID) else { throw StoreError.invalidMove }
        }
        let note = Note(document: document, createdAt: now())
        var tab = LiveTab(profileID: s.profileID, spaceID: spaceID, url: note.url, title: note.displayTitle,
                          createdAt: now())
        try perform("New Note") {
            put(note)
            if pinned {
                let siblings = children(of: .pinned(spaceID: spaceID), parent: parentID)
                let item = Item(kind: .tab, container: .pinned(spaceID: spaceID), parentID: parentID,
                                order: Ordering.insertion(at: siblings.count, in: siblings.map(\.order)),
                                savedURL: note.url, pageTitle: note.displayTitle, createdAt: now())
                put(item)
                tab.itemID = item.id
            } else {
                tab.order = topOfToday(spaceID)
            }
            put(tab)
            markActive(tab.id, inSpace: spaceID)
        }
        return self.tab(tab.id)!
    }

    /// The editor's text as it's typed: in memory at once, on disk with the next flush (as a page's title is), never an
    /// undo step of the store (the editor has its own). The note's tabs and pinned items take its new title. A note
    /// tab whose row is missing gets it back.
    public func updateNote(_ id: String, document: NoteDocument) {
        let existed = note(id) != nil
        var n = note(id) ?? Note(id: id, createdAt: now())
        guard n.document != document || !existed else { return }
        let oldTitle = n.displayTitle
        n.document = document
        n.updatedAt = now()
        try? perform(nil, deferred: true, contentOnly: true) {
            put(n)
            if n.displayTitle != oldTitle || !existed { renameRows(of: n) }
        }
    }

    /// Every row of the note shows its title.
    private func renameRows(of n: Note) {
        let url = n.url, title = n.displayTitle
        for var t in state.tabs.values where t.url == url && t.title != title { t.title = title; put(t) }
        for var i in state.items.values where i.savedURL == url && i.pageTitle != title { i.pageTitle = title; put(i) }
    }

    /// Inside a transaction: the address a copy of a row gets. A note's row (⌥-drag, Duplicate) gets a note of its own
    /// with the same text, so no two rows ever share a note; any other address stays.
    func copiedAddress(_ url: String?) -> String? {
        guard let id = NoteURL.noteID(url) else { return url }
        let src = note(id) ?? Note(id: id, createdAt: now())
        let copy = Note(document: src.document, createdAt: now())
        put(copy)
        return copy.url
    }

    /// Notes no row points at any more (their tab and pinned item went and their archive entry was cleared or pruned)
    /// are removed; the app forgets their pictures (NoteImages). Only at launch, when no undo step can bring a row back,
    /// and never while rows this build can't read are kept: one of them may be a note's row (H4).
    @discardableResult
    public func removeOrphanNotes() throws -> [Note] {
        guard unreadableRows.isEmpty, !canUndo else { return [] }
        let used = referencedNoteIDs
        let orphans = state.notes.values.filter { !used.contains($0.id) }
        guard !orphans.isEmpty else { return [] }
        try perform(nil) { for n in orphans { remove(Note.self, n.id) } }
        return orphans
    }

    /// Whether a row other than tab `tabID` points at note `id` (a tab, a pinned item, an archive entry).
    func noteHasOtherRows(_ id: String, besidesTab tabID: String) -> Bool {
        let url = NoteURL.make(id)
        return state.tabs.values.contains { $0.id != tabID && $0.url == url }
            || state.items.values.contains { $0.savedURL == url }
            || state.archive.values.contains { $0.tab.url == url }
    }

    /// The notes some tab, pinned item or archive entry points at.
    public var referencedNoteIDs: Set<String> {
        var ids = Set<String>()
        for t in state.tabs.values { if let id = NoteURL.noteID(t.url) { ids.insert(id) } }
        for i in state.items.values { if let id = NoteURL.noteID(i.savedURL) { ids.insert(id) } }
        for a in state.archive.values { if let id = NoteURL.noteID(a.tab.url) { ids.insert(id) } }
        return ids
    }

    /// The picture files every note in the store shows.
    public var noteImageFiles: Set<String> { state.notes.values.reduce(into: Set<String>()) { $0.formUnion($1.document.imageFiles) } }
}

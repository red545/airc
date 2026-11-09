// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Notes out of Airc and back in (docs/user/notes.md "Export and import"): Markdown that reads back as the same note,
// one self-contained HTML page as Arc's "Export Arc Notes" wrote, and the app New Note opens (Arc's later "New Note
// opens your default notes app"). The app's Notes/NoteExport.swift writes and reads the files.

// MARK: - Markdown

/// Markdown, as written here and read back exactly:
///   - one line per line: `# ` `## ` `### ` headings; `- ` bullets, `1. ` numbered, `- [ ] ` and `- [x] ` checkboxes,
///     four spaces per level of nesting. Paragraphs and lists are one blank line apart, a list's items aren't; each
///     further blank line is an empty line of the note.
///   - in a line: `**bold**`, `*italic*`, `~~strikethrough~~`, `<u>underline</u>`, `` `code` ``, `[text](<address>)`
///     and a picture as `![](<its file>)`. Each run closes what it opens, and what Markdown would read as markup is
///     escaped with a backslash.
/// Markdown from elsewhere reads as well as it can: `_italic_`, `__bold__`, `* ` and `+ ` bullets, two-space or tab
/// nesting, `[X]`, quotes (as their text), fenced code (as code lines), `<https://…>` links.
public enum NoteMarkdown {
    /// The note as Markdown. `imagePath` is how the file refers to a picture ("Lisbon plan files/Picture 1.png"); nil
    /// leaves it out.
    public static func export(_ doc: NoteDocument, imagePath: (NoteImage) -> String?) -> String {
        var out = ""
        var numbers: [Int: Int] = [:]
        var previous: NoteBlock?
        for b in doc.blocks {
            if let p = previous { out += p.kind.isList && b.kind.isList ? "\n" : "\n\n" }
            if b.kind != .numbered { numbers = numbers.filter { $0.key < b.indent } }
            let pad = String(repeating: "    ", count: b.indent)
            let text = inline(b.runs, imagePath: imagePath, lineStart: b.kind == .paragraph)
            switch b.kind {
            case .paragraph: out += text
            case .heading1: out += "# " + text
            case .heading2: out += "## " + text
            case .heading3: out += "### " + text
            case .bullet: out += pad + "- " + text
            case .checkbox: out += pad + (b.checked ? "- [x] " : "- [ ] ") + text
            case .numbered:
                numbers = numbers.filter { $0.key <= b.indent }
                let n = (numbers[b.indent] ?? 0) + 1
                numbers[b.indent] = n
                out += pad + "\(n). " + text
            }
            previous = b
        }
        return out + "\n"
    }

    /// Markdown as a note. `image` makes a picture's address (as written, brackets and escapes gone) a picture of the
    /// note, or nil: a web address then stays a link, anything else is left out.
    public static func parse(_ text: String, image: (String) -> NoteImage?) -> NoteDocument {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let unit = indentUnit(lines)
        var blocks: [NoteBlock] = []
        var blank = 0
        var started = false
        var fence: String?
        func flushBlank(atEnd: Bool) {
            // Before the first line and at the end every two blank lines are one empty line; between lines the first
            // blank line is only the gap.
            let empties = !started || atEnd ? blank / 2 : max(0, (blank - 1) / 2)
            for _ in 0..<empties { blocks.append(NoteBlock()) }
            blank = 0
        }
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if trimmed.hasPrefix(f) { fence = nil; continue }
                blocks.append(NoteBlock(runs: raw.isEmpty ? [] : [NoteRun(raw, marks: [.code])]))
                continue
            }
            if trimmed.isEmpty { blank += 1; continue }
            flushBlank(atEnd: false)
            started = true
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix(3)); continue }
            blocks.append(block(raw, unit: unit, image: image))
        }
        flushBlank(atEnd: true)
        return NoteDocument(blocks: blocks)
    }

    // MARK: Writing

    private static func inline(_ runs: [NoteRun], imagePath: (NoteImage) -> String?, lineStart: Bool) -> String {
        var out = ""
        for r in runs {
            if let img = r.image {
                if let path = imagePath(img) { out += "![](<" + angle(path) + ">)" }
                continue
            }
            var text: String
            if r.marks.contains(.code) {
                text = code(r.text)
            } else {
                text = escape(r.text, lineStart: lineStart && out.isEmpty)
            }
            let wrapping = r.marks.subtracting([.code])
            if !wrapping.isEmpty {
                // The markers hug the text: spaces at a run's ends stay outside them (Markdown wants it so).
                let lead = text.prefix { $0 == " " }.count
                let trail = text.count == lead ? 0 : text.reversed().prefix { $0 == " " }.count
                var core = String(text.dropFirst(lead).dropLast(trail))
                if !core.isEmpty {
                    if r.marks.contains(.italic) { core = "*" + core + "*" }
                    if r.marks.contains(.bold) { core = "**" + core + "**" }
                    if r.marks.contains(.underline) { core = "<u>" + core + "</u>" }
                    if r.marks.contains(.strikethrough) { core = "~~" + core + "~~" }
                }
                text = String(repeating: " ", count: lead) + core + String(repeating: " ", count: trail)
            }
            if let link = r.link { text = "[" + text + "](<" + angle(link) + ">)" }
            out += text
        }
        return out
    }

    /// An address between angle brackets: only `>` (and `<`) can't be in it.
    private static func angle(_ s: String) -> String {
        s.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
    }

    private static func code(_ s: String) -> String {
        let fence = s.contains("`") ? "``" : "`"
        let pad = s.hasPrefix("`") || s.hasSuffix("`") ? " " : ""
        return fence + pad + s + pad + fence
    }

    private static func escape(_ s: String, lineStart: Bool) -> String {
        var out = ""
        for ch in s {
            if "\\`*_[]~<".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        // What would start a heading, a list or a quote at the start of a line is text.
        if lineStart, let i = out.firstIndex(where: { $0 != " " }) {
            if "#-+>".contains(out[i]) {
                out.insert("\\", at: i)
            } else if let m = out[i...].range(of: #"^\d+[.)]"#, options: .regularExpression) {
                out.insert("\\", at: out.index(before: m.upperBound))
            }
        }
        return out
    }

    // MARK: Reading

    /// The spaces one level of list nesting takes: 4 as written here, 2 or a tab (4) as elsewhere.
    private static func indentUnit(_ lines: [String]) -> Int {
        let indents = lines.compactMap { l -> Int? in
            let spaces = width(of: l)
            guard spaces > 0, String(l.drop { $0 == " " || $0 == "\t" }).range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil
            else { return nil }
            return spaces
        }
        return indents.min().map { min($0, 4) } ?? 4
    }

    private static func width(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func block(_ raw: String, unit: Int, image: (String) -> NoteImage?) -> NoteBlock {
        let level = width(of: raw) / unit
        let leading = raw.prefix { $0 == " " || $0 == "\t" }
        var line = String(raw.dropFirst(leading.count))
        // A quote is its text.
        var quoted = false
        while let q = line.range(of: #"^>\s?"#, options: .regularExpression) { line.removeSubrange(q); quoted = true }
        func runs(_ s: Substring) -> [NoteRun] { parseInline(String(s), image: image) }
        if let m = line.range(of: #"^#{1,6}(\s+|$)"#, options: .regularExpression) {
            let hashes = line[m].filter { $0 == "#" }.count
            let kind: NoteBlock.Kind = hashes == 1 ? .heading1 : hashes == 2 ? .heading2 : .heading3
            return NoteBlock(kind: kind, runs: runs(line[m.upperBound...]))
        }
        if let m = line.range(of: #"^[-*+]\s+\[([ xX]?)\](\s|$)"#, options: .regularExpression) {
            let checked = line[m].contains { $0 == "x" || $0 == "X" }
            return NoteBlock(kind: .checkbox, indent: level, checked: checked, runs: runs(line[m.upperBound...]))
        }
        if let m = line.range(of: #"^[-*+](\s+|$)"#, options: .regularExpression), line != "---", line != "***" {
            return NoteBlock(kind: .bullet, indent: level, runs: runs(line[m.upperBound...]))
        }
        if let m = line.range(of: #"^\d+[.)](\s+|$)"#, options: .regularExpression) {
            return NoteBlock(kind: .numbered, indent: level, runs: runs(line[m.upperBound...]))
        }
        // A paragraph keeps the spaces it starts with (a quote's text doesn't).
        let text = quoted || leading.contains("\t") ? line : String(raw)
        return NoteBlock(kind: .paragraph, runs: runs(text[...]))
    }

    /// One line's runs: marks turned on and off by their markers, links, pictures, backslash escapes.
    static func parseInline(_ s: String, image: (String) -> NoteImage?) -> [NoteRun] {
        var runs: [NoteRun] = []
        var marks = Set<NoteRun.Mark>()
        var text = ""
        func flush() {
            guard !text.isEmpty else { return }
            if let last = runs.last, last.image == nil, last.marks == marks, last.link == nil {
                runs[runs.count - 1].text += text
            } else {
                runs.append(NoteRun(text, marks: marks))
            }
            text = ""
        }
        let chars = Array(s)
        var i = 0
        func char(_ j: Int) -> Character? { j >= 0 && j < chars.count ? chars[j] : nil }
        func at(_ p: String) -> Bool {
            let a = Array(p)
            return i + a.count <= chars.count && Array(chars[i..<i + a.count]) == a
        }
        /// `[text](destination)` from `start` (its "["): the text, the destination and the index after ")".
        func bracket(from start: Int) -> (text: String, dest: String, end: Int)? {
            var j = start, depth = 0
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "[" { depth += 1 }
                if chars[j] == "]" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            guard j + 1 < chars.count, chars[j + 1] == "(" else { return nil }
            let inner = String(chars[(start + 1)..<j])
            var k = j + 2
            var dest = ""
            if char(k) == "<" {
                k += 1
                while k < chars.count, chars[k] != ">" { dest.append(chars[k]); k += 1 }
                while k < chars.count, chars[k] != ")" { k += 1 }
            } else {
                var parens = 0
                while k < chars.count, !(chars[k] == ")" && parens == 0) {
                    if chars[k] == "(" { parens += 1 }
                    if chars[k] == ")" { parens -= 1 }
                    dest.append(chars[k])
                    k += 1
                }
                // A title after the address: `(https://x.example "Title")`.
                if let space = dest.firstIndex(of: " ") { dest = String(dest[..<space]) }
            }
            guard k < chars.count else { return nil }
            dest = dest.replacingOccurrences(of: "%3C", with: "<").replacingOccurrences(of: "%3E", with: ">")
            return (inner, dest.trimmingCharacters(in: .whitespaces), k + 1)
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", let n = char(i + 1), "\\`*_[]~<>!#-+.()|{}".contains(n) {
                text.append(n)
                i += 2
                continue
            }
            if c == "!", char(i + 1) == "[", let b = bracket(from: i + 1) {
                flush()
                if let img = image(b.dest) {
                    runs.append(NoteRun(image: img))
                } else if b.dest.lowercased().hasPrefix("http") {
                    runs.append(NoteRun(b.text.isEmpty ? b.dest : b.text, marks: marks, link: b.dest))
                }
                i = b.end
                continue
            }
            if c == "[", let b = bracket(from: i) {
                flush()
                for var r in parseInline(b.text, image: image) {
                    r.marks.formUnion(marks)
                    if r.image == nil { r.link = b.dest }
                    runs.append(r)
                }
                i = b.end
                continue
            }
            if c == "`" {
                let fence = at("``") ? 2 : 1
                var j = i + fence
                while j < chars.count, !(chars[j] == "`" && (fence == 1 || char(j + 1) == "`")) { j += 1 }
                if j < chars.count {
                    flush()
                    var body = String(chars[(i + fence)..<j])
                    if body.count >= 2, body.hasPrefix(" "), body.hasSuffix(" ") { body = String(body.dropFirst().dropLast()) }
                    if !body.isEmpty { runs.append(NoteRun(body, marks: marks.union([.code]))) }
                    i = j + fence
                    continue
                }
            }
            if c == "<" {
                if at("<u>") { flush(); marks.insert(.underline); i += 3; continue }
                if at("</u>") { flush(); marks.remove(.underline); i += 4; continue }
                // An autolink: <https://…>.
                if let close = chars[i...].firstIndex(of: ">") {
                    let inner = String(chars[(i + 1)..<close])
                    if inner.range(of: #"^(https?|mailto):[^\s<]+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                        flush()
                        runs.append(NoteRun(inner, marks: marks, link: inner))
                        i = close + 1
                        continue
                    }
                }
            }
            if at("~~") {
                let on = marks.contains(.strikethrough)
                if on ? !(char(i - 1)?.isWhitespace ?? true) : !(char(i + 2)?.isWhitespace ?? true) {
                    flush()
                    if on { marks.remove(.strikethrough) } else { marks.insert(.strikethrough) }
                    i += 2
                    continue
                }
            }
            if c == "*" || c == "_" {
                var k = 0
                while char(i + k) == c { k += 1 }
                let before = char(i - 1), after = char(i + k)
                let wordChar: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber } ?? false }
                // snake_case is text.
                if !(c == "_" && wordChar(before) && wordChar(after)) {
                    flush()
                    var left = k
                    let canClose = !(before?.isWhitespace ?? true), canOpen = !(after?.isWhitespace ?? true)
                    if canClose {
                        // `**` closes bold; otherwise the inner italic first, then bold (`***` after both).
                        if left == 2, marks.contains(.bold) {
                            marks.remove(.bold); left = 0
                        } else {
                            if left >= 1, marks.contains(.italic) { marks.remove(.italic); left -= 1 }
                            if left >= 2, marks.contains(.bold) { marks.remove(.bold); left -= 2 }
                        }
                    }
                    if canOpen {
                        if left >= 2, !marks.contains(.bold) { marks.insert(.bold); left -= 2 }
                        if left >= 1, !marks.contains(.italic) { marks.insert(.italic); left -= 1 }
                    }
                    text += String(repeating: c, count: left)
                    i += k
                    continue
                }
            }
            text.append(c)
            i += 1
        }
        flush()
        return runs
    }
}

// MARK: - HTML

/// A note as one HTML page that needs nothing else, as Arc's "Export Arc Notes" wrote them (its pictures inside, as
/// data: URLs). Checkboxes are ☐ and ☑, so the text says it wherever it's opened, and reads back.
public enum NoteHTML {
    /// `imageSource` is a picture's `src` (a data: URL), or nil to leave it out.
    public static func export(_ doc: NoteDocument, title: String, imageSource: (NoteImage) -> String?) -> String {
        var body = ""
        var open: [String] = []   // the lists open now, outermost first: "ul", "ol", "ul class=checks"
        func closeLast() { body += "</li></\(open.removeLast().prefix(2))>" }
        for b in doc.blocks {
            let inner = b.runs.map { run($0, imageSource: imageSource) }.joined()
            guard b.kind.isList else {
                while !open.isEmpty { closeLast() }
                body += "\n"
                switch b.kind {
                case .heading1: body += "<h1>\(inner)</h1>"
                case .heading2: body += "<h2>\(inner)</h2>"
                case .heading3: body += "<h3>\(inner)</h3>"
                default: body += inner.isEmpty ? "<p><br></p>" : "<p>\(inner)</p>"
                }
                continue
            }
            let tag = b.kind == .numbered ? "ol" : b.kind == .checkbox ? "ul class=\"checks\"" : "ul"
            let depth = b.indent + 1
            while open.count > depth { closeLast() }
            if open.count == depth, open[depth - 1] != tag { closeLast() }
            if open.count == depth { body += "</li>" }
            while open.count < depth {
                // A level skipped holds the deeper list in an item of its own.
                let t = open.count == depth - 1 ? tag : "ul"
                body += (open.isEmpty ? "\n" : "") + "<\(t)>"
                open.append(t)
                if open.count < depth { body += "<li>" }
            }
            let box = b.kind == .checkbox ? (b.checked ? "☑ " : "☐ ") : ""
            body += "\n<li\(b.kind == .checkbox && b.checked ? " class=\"done\"" : "")>\(box)\(inner)"
        }
        while !open.isEmpty { closeLast() }
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>\(escape(title))</title>
        <meta name="generator" content="Airc">
        <style>
        body { font: 16px/1.5 -apple-system, system-ui, sans-serif; max-width: 680px; margin: 48px auto; padding: 0 24px; color: #1d1d1f; }
        h1 { font-size: 28px; } h2 { font-size: 21px; } h3 { font-size: 18px; }
        img { max-width: 100%; border-radius: 6px; }
        ul.checks { list-style: none; padding-left: 4px; } li.done { color: #86868b; }
        code { font: 14px ui-monospace, Menlo, monospace; background: #f2f2f2; padding: 1px 4px; border-radius: 4px; }
        </style>
        </head><body>\(body)
        </body></html>

        """
    }

    private static func run(_ r: NoteRun, imageSource: (NoteImage) -> String?) -> String {
        if let img = r.image {
            guard let src = imageSource(img) else { return "" }
            return "<img src=\"\(escape(src))\" width=\"\(Int(img.width.rounded()))\" height=\"\(Int(img.height.rounded()))\" alt=\"\">"
        }
        var s = escape(r.text)
        if r.marks.contains(.code) { s = "<code>\(s)</code>" }
        if r.marks.contains(.italic) { s = "<em>\(s)</em>" }
        if r.marks.contains(.bold) { s = "<strong>\(s)</strong>" }
        if r.marks.contains(.underline) { s = "<u>\(s)</u>" }
        if r.marks.contains(.strikethrough) { s = "<s>\(s)</s>" }
        if let link = r.link { s = "<a href=\"\(escape(link))\">\(s)</a>" }
        return s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - The app New Note opens

/// What New Note (⌃⇧N, File › New Note, the sidebar's "+", the Command Bar) makes: an Airc note, or a new document of
/// a web app in a tab, as Arc offered from 2024 (its `defaultNoteDocumentApp`, with these addresses). Airc's own notes
/// are the default; another app is only ever the person's choice in Settings, and New Airc Note stays.
public enum NoteApp: String, Codable, CaseIterable, Sendable {
    case airc, googleDocs, notion, word, confluence

    /// A value a newer build wrote reads as Airc's own notes.
    public init(from decoder: Decoder) throws {
        self = NoteApp(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .airc
    }

    public var name: String {
        switch self {
        case .airc: "Airc Notes"
        case .googleDocs: "Google Docs"
        case .notion: "Notion"
        case .word: "Microsoft Word"
        case .confluence: "Confluence"
        }
    }

    /// The menu item and Command Bar entry.
    public var newTitle: String {
        switch self {
        case .airc: "New Note"
        case .googleDocs: "New Google Doc"
        case .notion: "New Notion Page"
        case .word: "New Word Document"
        case .confluence: "New Confluence Page"
        }
    }

    /// What a new one is called in a sentence ("a Google Doc").
    public var documentName: String {
        switch self {
        case .airc: "note"
        case .googleDocs: "Google Doc"
        case .notion: "Notion page"
        case .word: "Word document"
        case .confluence: "Confluence page"
        }
    }

    /// The address that makes a new document (Arc's), nil for Airc's notes.
    public var newDocumentURL: URL? {
        switch self {
        case .airc: nil
        case .googleDocs: URL(string: "https://doc.new")
        case .notion: URL(string: "https://app.notion.com/new")
        case .word: URL(string: "https://word.new")
        case .confluence: URL(string: "https://confluence.new")
        }
    }

    /// What New Note does: open `url` in a new tab, or make an Airc note (`fallback`: because the chosen app can't be
    /// reached now; the window says so).
    public enum Route: Equatable, Sendable {
        case open(URL)
        case note(fallback: Bool)
    }

    /// A web app needs the network: offline, New Note makes an Airc note instead, and says so.
    public func route(online: Bool) -> Route {
        guard let url = newDocumentURL else { return .note(fallback: false) }
        return online ? .open(url) : .note(fallback: true)
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

// A note's text in the editor (docs/user/notes.md). AircKit's NoteDocument is what the store keeps; here it becomes an
// attributed string and back. Two attributes say what the text is, and everything else (fonts, colours, spacing) is
// drawn from them, so the editor never has to read a style back from a font:
//
//   .noteLine   on every character of a line, its newline included: the line's kind, nesting and tick (NoteLine)
//   .noteMarks  on runs: bold, italic, underline, strikethrough, code (a bit set)
//
// plus AppKit's own .link and attachments (NoteImageAttachment). A document's last line has no newline to carry it when
// it's empty; the editor keeps that line's kind itself (NoteTextView.trailingLine).

extension NSAttributedString.Key {
    static let noteLine = NSAttributedString.Key("org.airc.note.line")
    static let noteMarks = NSAttributedString.Key("org.airc.note.marks")
}

/// A line's kind as an attribute value. Equal values make one attribute run.
final class NoteLine: NSObject {
    let kind: NoteBlock.Kind
    let indent: Int
    let checked: Bool

    init(_ kind: NoteBlock.Kind, indent: Int = 0, checked: Bool = false) {
        let b = NoteBlock(kind: kind, indent: indent, checked: checked)
        self.kind = b.kind
        self.indent = b.indent
        self.checked = b.checked
    }

    static let paragraph = NoteLine(.paragraph)

    func with(kind: NoteBlock.Kind? = nil, indent: Int? = nil, checked: Bool? = nil) -> NoteLine {
        NoteLine(kind ?? self.kind, indent: indent ?? self.indent, checked: checked ?? self.checked)
    }

    /// The line a Return makes after this one: the same list (an unticked checkbox), or a paragraph after a heading.
    var next: NoteLine {
        switch kind {
        case .heading1, .heading2, .heading3, .paragraph: .paragraph
        case .bullet, .numbered, .checkbox: NoteLine(kind, indent: indent)
        }
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? NoteLine else { return false }
        return o.kind == kind && o.indent == indent && o.checked == checked
    }

    override var hash: Int { kind.hashValue ^ (indent << 8) ^ (checked ? 1 << 12 : 0) }
}

/// A run's marks as a bit set (an NSNumber in the text).
struct NoteMarks: OptionSet, Hashable {
    let rawValue: Int
    static let bold = NoteMarks(rawValue: 1)
    static let italic = NoteMarks(rawValue: 2)
    static let underline = NoteMarks(rawValue: 4)
    static let strikethrough = NoteMarks(rawValue: 8)
    static let code = NoteMarks(rawValue: 16)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ marks: Set<NoteRun.Mark>) {
        var m: NoteMarks = []
        for x in marks {
            switch x {
            case .bold: m.insert(.bold)
            case .italic: m.insert(.italic)
            case .underline: m.insert(.underline)
            case .strikethrough: m.insert(.strikethrough)
            case .code: m.insert(.code)
            }
        }
        self = m
    }

    var set: Set<NoteRun.Mark> {
        var s = Set<NoteRun.Mark>()
        if contains(.bold) { s.insert(.bold) }
        if contains(.italic) { s.insert(.italic) }
        if contains(.underline) { s.insert(.underline) }
        if contains(.strikethrough) { s.insert(.strikethrough) }
        if contains(.code) { s.insert(.code) }
        return s
    }

    static func of(_ value: Any?) -> NoteMarks { NoteMarks(rawValue: (value as? NSNumber)?.intValue ?? 0) }
}

/// The note's look in one Space's theme: the page card's `surface`, its ink, the accent for links and ticks.
struct NoteStyle: Equatable {
    var text: NSColor
    var secondary: NSColor
    var tertiary: NSColor
    var accent: NSColor
    var onAccent: NSColor
    var codeFill: NSColor
    var background: NSColor
    var hairline: NSColor?
    var isDark: Bool

    init(_ theme: ResolvedTheme) {
        text = theme.surfaceText.nsColor
        secondary = theme.surfaceTextSecondary.nsColor
        tertiary = theme.surfaceTextTertiary.nsColor
        accent = theme.accent.nsColor
        onAccent = theme.onAccent.nsColor
        codeFill = theme.surfaceHover.nsColor
        background = theme.surface.nsColor
        hairline = theme.pageCardShadow.hairline?.nsColor
        isDark = theme.isDark
    }

    /// Paper for Print and Save as PDF: black ink on white, whatever the Space.
    static var print: NoteStyle {
        var s = NoteStyle(DesignTheme.default.resolved(systemIsDark: false))
        s.text = .black
        s.secondary = NSColor(white: 0.35, alpha: 1)
        s.tertiary = NSColor(white: 0.55, alpha: 1)
        s.background = .white
        s.codeFill = NSColor(white: 0.94, alpha: 1)
        return s
    }

    // Sizes: body is AircFont.lead (15/22); headings are title1, title2 and a 17 pt step between title2 and body.
    static let bodySize: CGFloat = 15
    /// Where a list item's text starts, per nesting level.
    static let listIndent: CGFloat = 26
    static let indentStep: CGFloat = 24
    /// The widest the text column gets; wider cards centre it (design.md: calm, generous spacing).
    static let columnWidth: CGFloat = 680
    static let sideInset: CGFloat = 44
    static let topInset: CGFloat = 40

    func baseFont(_ kind: NoteBlock.Kind) -> NSFont {
        switch kind {
        case .heading1: AircFont.title1.appFont
        case .heading2: AircFont.title2.appFont
        case .heading3: NSFont.systemFont(ofSize: 17, weight: .semibold)
        default: NSFont.systemFont(ofSize: Self.bodySize, weight: .regular)
        }
    }

    func font(_ kind: NoteBlock.Kind, _ marks: NoteMarks) -> NSFont {
        var f = baseFont(kind)
        if marks.contains(.code) { f = NSFont.monospacedSystemFont(ofSize: f.pointSize - 1.5, weight: .regular) }
        if marks.contains(.bold) {
            let heading = kind == .heading1 || kind == .heading2 || kind == .heading3
            let weight: NSFont.Weight = heading ? .heavy : .semibold
            f = marks.contains(.code) ? NSFont.monospacedSystemFont(ofSize: f.pointSize, weight: weight)
                : NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask).withWeight(weight, design: kind == .heading1)
        }
        if marks.contains(.italic) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    func paragraphStyle(_ line: NoteLine) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        switch line.kind {
        case .heading1:
            p.paragraphSpacingBefore = 18; p.paragraphSpacing = 6; p.lineSpacing = 2
        case .heading2:
            p.paragraphSpacingBefore = 14; p.paragraphSpacing = 4; p.lineSpacing = 2
        case .heading3:
            p.paragraphSpacingBefore = 10; p.paragraphSpacing = 2; p.lineSpacing = 2
        case .paragraph:
            p.lineSpacing = 4; p.paragraphSpacing = 6
        case .bullet, .numbered, .checkbox:
            let x = Self.listIndent + CGFloat(line.indent) * Self.indentStep
            p.firstLineHeadIndent = x
            p.headIndent = x
            p.lineSpacing = 4; p.paragraphSpacing = 3
        }
        return p
    }

    /// Everything a run shows, from its line and marks.
    func attributes(_ line: NoteLine, _ marks: NoteMarks) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [
            .noteLine: line,
            .font: font(line.kind, marks),
            .paragraphStyle: paragraphStyle(line),
            .foregroundColor: line.kind == .checkbox && line.checked ? tertiary : text,
        ]
        if !marks.isEmpty { a[.noteMarks] = NSNumber(value: marks.rawValue) }
        if marks.contains(.underline) { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if marks.contains(.strikethrough) { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if marks.contains(.code) { a[.backgroundColor] = codeFill }
        return a
    }
}

private extension NSFont {
    /// The same family at `weight` (system fonts lose their weight through NSFontManager's bold trait).
    func withWeight(_ weight: NSFont.Weight, design rounded: Bool) -> NSFont {
        var d = NSFont.systemFont(ofSize: pointSize, weight: weight).fontDescriptor
        if rounded, let r = d.withDesign(.rounded) { d = r }
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}

/// NoteDocument ↔ the editor's attributed string.
enum NoteText {
    /// The text of `doc` in `style`, with its pictures (`image` loads one by file name; nil shows a placeholder).
    static func attributedString(_ doc: NoteDocument, style: NoteStyle) -> (NSAttributedString, trailing: NoteLine) {
        let out = NSMutableAttributedString()
        var trailing = NoteLine(.heading1)
        for (i, b) in doc.blocks.enumerated() {
            let line = NoteLine(b.kind, indent: b.indent, checked: b.checked)
            for r in b.runs {
                if let image = r.image {
                    out.append(NoteImageAttachment.string(image, attributes: style.attributes(line, [])))
                } else if !r.text.isEmpty {
                    var a = style.attributes(line, NoteMarks(r.marks))
                    if let link = r.link { a[.link] = URL(string: link) ?? link }
                    // A line never holds a newline of its own (an older or damaged value): it'd split the line.
                    out.append(NSAttributedString(string: r.text.replacingOccurrences(of: "\n", with: " "), attributes: a))
                }
            }
            if i < doc.blocks.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: style.attributes(line, [])))
            } else {
                trailing = line
            }
        }
        return (out, trailing)
    }

    /// What the editor's text says. `trailing` is the kind of an empty last line (it has no character to carry it).
    static func document(_ text: NSAttributedString, trailing: NoteLine) -> NoteDocument {
        let s = text.string as NSString
        var blocks: [NoteBlock] = []
        var start = 0
        let length = s.length
        if length == 0 {
            return NoteDocument(blocks: [NoteBlock(kind: trailing.kind, indent: trailing.indent, checked: trailing.checked)])
        }
        while start <= length {
            if start == length {
                // After a final newline: the empty last line.
                blocks.append(NoteBlock(kind: trailing.kind, indent: trailing.indent, checked: trailing.checked))
                break
            }
            var end = 0, contentsEnd = 0
            s.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let line = (text.attribute(.noteLine, at: start, effectiveRange: nil) as? NoteLine) ?? .paragraph
            var runs: [NoteRun] = []
            if contentsEnd > start {
                text.enumerateAttributes(in: NSRange(location: start, length: contentsEnd - start)) { attrs, range, _ in
                    if let a = attrs[.attachment] as? NoteImageAttachment {
                        for _ in 0..<range.length { runs.append(NoteRun(image: a.note)) }
                        return
                    }
                    if attrs[.attachment] != nil { return }   // a picture this note couldn't keep
                    let t = s.substring(with: range).replacingOccurrences(of: NoteRun.attachmentCharacter, with: "")
                    guard !t.isEmpty else { return }
                    let link: String? = switch attrs[.link] {
                    case let u as URL: u.absoluteString
                    case let str as String: str
                    default: nil
                    }
                    let run = NoteRun(t, marks: NoteMarks.of(attrs[.noteMarks]).set, link: link)
                    // Neighbours that look the same are one run.
                    if let last = runs.last, last.image == nil, last.marks == run.marks, last.link == run.link {
                        runs[runs.count - 1].text += t
                    } else {
                        runs.append(run)
                    }
                }
            }
            blocks.append(NoteBlock(kind: line.kind, indent: line.indent, checked: line.checked, runs: runs))
            if end == contentsEnd { break }   // the last line, without a newline
            start = end
        }
        return NoteDocument(blocks: blocks)
    }

    /// Restyles the lines `range` touches from their .noteLine and .noteMarks: one kind per line (the first
    /// character's: a joined line takes the upper one's), fonts and colours drawn again. Inside text storage editing.
    static func restyle(_ storage: NSTextStorage, in range: NSRange, style: NoteStyle) {
        let s = storage.string as NSString
        guard s.length > 0 else { return }
        let lines = s.paragraphRange(for: NSRange(location: min(range.location, s.length), length: min(range.length, s.length - min(range.location, s.length))))
        var start = lines.location
        while start < NSMaxRange(lines) {
            let p = s.paragraphRange(for: NSRange(location: start, length: 0))
            let line = (storage.attribute(.noteLine, at: p.location, effectiveRange: nil) as? NoteLine) ?? .paragraph
            storage.enumerateAttributes(in: p) { attrs, r, _ in
                let marks = NoteMarks.of(attrs[.noteMarks])
                var a = style.attributes(line, attrs[.attachment] != nil ? [] : marks)
                if attrs[.noteMarks] == nil { a[.noteMarks] = nil }
                storage.removeAttribute(.noteMarks, range: r)
                storage.removeAttribute(.underlineStyle, range: r)
                storage.removeAttribute(.strikethroughStyle, range: r)
                storage.removeAttribute(.backgroundColor, range: r)
                storage.addAttributes(a, range: r)
            }
            start = NSMaxRange(p)
        }
    }

    /// Text from elsewhere (another app's rich text, a file being imported) as the note's own: headings, lists,
    /// checkboxes, bold, italic, underline, strikethrough, code, links and pictures stay; fonts, colours and sizes don't.
    /// The first line takes `line`'s kind (a paste into a line), unless it's a whole document. A heading is a line
    /// HTML calls one or one in a font much larger than the text's usual size (RTF has no headings of its own).
    static func adopt(_ foreign: NSAttributedString, style: NoteStyle, line: NoteLine, wholeDocument: Bool = false,
                      storeImage: (NSTextAttachment) -> NoteImage?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let s = foreign.string as NSString
        let body = usualFontSize(foreign)
        var start = 0
        var first = true
        while start < s.length {
            var end = 0, contentsEnd = 0
            s.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let keepsLine = first && !wholeDocument
            var l = keepsLine ? line : NoteLine.paragraph
            let ps = foreign.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
            if let ps, let list = ps.textLists.last {
                let format = list.markerFormat
                let kind: NoteBlock.Kind = format == .box || format == .check ? .checkbox
                    : format.rawValue.contains("decimal") ? .numbered : .bullet
                l = NoteLine(kind, indent: max(0, ps.textLists.count - 1), checked: format == .check)
            } else if !keepsLine, contentsEnd > start, let kind = headingKind(ps, font: foreign.attribute(.font, at: start, effectiveRange: nil) as? NSFont, body: body) {
                l = NoteLine(kind)
            }
            // Checkboxes as text ("☐ Book the train"): Airc's HTML, Notes' and Bear's plain text.
            let text = s.substring(with: NSRange(location: start, length: contentsEnd - start))
            if let box = text.range(of: #"^\s*(?:(?:•|◦|▪|-|\d+[.)])?\t)?[☐☑☒✅]\x{FE0F}? ?"#, options: .regularExpression) {
                l = NoteLine(.checkbox, indent: l.kind.isList ? l.indent : 0, checked: !text[box].contains("☐"))
            }
            var lineStart = true
            let heading = l.kind == .heading1 || l.kind == .heading2 || l.kind == .heading3
            // A heading that's bold all through (Word's, Pages', HTML's) is just a heading; bold words in one are bold.
            let wholeLineBold = heading && contentsEnd > start && Self.isBoldThrough(foreign, NSRange(location: start, length: contentsEnd - start))
            if contentsEnd > start {
                foreign.enumerateAttributes(in: NSRange(location: start, length: contentsEnd - start)) { attrs, r, _ in
                    if let a = attrs[.attachment] as? NSTextAttachment {
                        if let img = storeImage(a) { out.append(NoteImageAttachment.string(img, attributes: style.attributes(l, []))) }
                        lineStart = false
                        return
                    }
                    var text = s.substring(with: r).replacingOccurrences(of: NoteRun.attachmentCharacter, with: "")
                    if lineStart {
                        // A list's marker that came along as text ("•\t", TextEdit's "\t1.\t" and "\t☐\t"), a checkbox's.
                        if l.kind.isList, ps?.textLists.isEmpty == false,
                           let m = text.range(of: #"^\t[^\t\n]{0,12}\t"#, options: .regularExpression) { text.removeSubrange(m) }
                        if l.kind.isList, let m = text.range(of: #"^\s*(•|◦|▪|-|\d+[.)])\t"#, options: .regularExpression) { text.removeSubrange(m) }
                        if l.kind == .checkbox, let m = text.range(of: #"^\s*[☐☑☒✅]\x{FE0F}? ?"#, options: .regularExpression) { text.removeSubrange(m) }
                    }
                    guard !text.isEmpty else { return }
                    lineStart = false
                    var marks: NoteMarks = []
                    if let f = attrs[.font] as? NSFont {
                        let traits = f.fontDescriptor.symbolicTraits
                        if Self.isBold(f), !wholeLineBold { marks.insert(.bold) }
                        if traits.contains(.italic) { marks.insert(.italic) }
                        if traits.contains(.monoSpace) { marks.insert(.code) }
                    }
                    if (attrs[.underlineStyle] as? Int ?? 0) != 0, attrs[.link] == nil { marks.insert(.underline) }
                    if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { marks.insert(.strikethrough) }
                    var a = style.attributes(l, marks)
                    if let link = attrs[.link] { a[.link] = link }
                    out.append(NSAttributedString(string: text, attributes: a))
                }
            }
            if end > contentsEnd { out.append(NSAttributedString(string: "\n", attributes: style.attributes(l, []))) }
            first = false
            start = end
        }
        return out
    }

    /// The size most of the text is in (by characters): what a heading is larger than.
    private static func usualFontSize(_ text: NSAttributedString) -> CGFloat {
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { v, r, _ in
            if let f = v as? NSFont { sizes[f.pointSize, default: 0] += r.length }
        }
        return sizes.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? NoteStyle.bodySize
    }

    /// A line's heading kind: HTML's h1–h6, or (RTF, Pages, Word) a size well above the text's: 1.55×, 1.22×, 1.08×.
    private static func headingKind(_ ps: NSParagraphStyle?, font: NSFont?, body: CGFloat) -> NoteBlock.Kind? {
        switch ps?.headerLevel ?? 0 {
        case 1: return .heading1
        case 2: return .heading2
        case 3...6: return .heading3
        default: break
        }
        guard let size = font?.pointSize, body > 0 else { return nil }
        let ratio = size / body
        return ratio >= 1.55 ? .heading1 : ratio >= 1.22 ? .heading2 : ratio >= 1.08 ? .heading3 : nil
    }

    /// Bold: the bold trait, or semibold and heavier (system fonts).
    static func isBold(_ f: NSFont) -> Bool {
        let weight = (f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        return f.fontDescriptor.symbolicTraits.contains(.bold) || weight >= NSFont.Weight.semibold.rawValue - 0.01
    }

    private static func isBoldThrough(_ text: NSAttributedString, _ range: NSRange) -> Bool {
        var bold = true, any = false
        let s = text.string as NSString
        text.enumerateAttribute(.font, in: range) { v, r, stop in
            guard !s.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            any = true
            if !((v as? NSFont).map(isBold) ?? false) { bold = false; stop.pointee = true }
        }
        return any && bold
    }
}

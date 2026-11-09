// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
@testable import AircKit
import XCTest

/// Note export and import (NoteFormats.swift): Markdown both ways, HTML out, the app New Note opens.
final class NoteFormatsTests: XCTestCase {
    private let picture = NoteImage(file: String(repeating: "ab", count: 32) + ".png", width: 640, height: 360)

    private func roundTrip(_ d: NoteDocument, file: StaticString = #filePath, line: UInt = #line) -> String {
        let md = NoteMarkdown.export(d) { "Note files/" + $0.file }
        let back = NoteMarkdown.parse(md) { path in
            path.hasPrefix("Note files/") ? NoteImage(file: String(path.dropFirst(11)), width: 640, height: 360) : nil
        }
        XCTAssertEqual(back, d, "Markdown:\n\(md)", file: file, line: line)
        return md
    }

    func testEveryLineKindAndMarkRoundTrips() {
        let d = NoteDocument(blocks: [
            NoteBlock(kind: .heading1, runs: [NoteRun("Lisbon plan")]),
            NoteBlock(runs: [NoteRun("Trams, "), NoteRun("bold", marks: [.bold]), NoteRun(", "), NoteRun("italic", marks: [.italic]),
                             NoteRun(", "), NoteRun("both", marks: [.bold, .italic]), NoteRun(", "), NoteRun("under", marks: [.underline]),
                             NoteRun(", "), NoteRun("gone", marks: [.strikethrough]), NoteRun(" and "), NoteRun("code()", marks: [.code])]),
            NoteBlock(runs: [NoteRun("See "), NoteRun("the guide", link: "https://trips.example/lisbon?a=1&b=(2)"),
                             NoteRun(" or "), NoteRun("this", marks: [.bold], link: "https://trips.example/x"), NoteRun(".")]),
            NoteBlock(kind: .heading2, runs: [NoteRun("Before we go")]),
            NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("Book the Sintra train")]),
            NoteBlock(kind: .checkbox, runs: [NoteRun("Tram 28 before nine")]),
            NoteBlock(kind: .checkbox, indent: 1, runs: [NoteRun("Tickets")]),
            NoteBlock(kind: .heading3, runs: [NoteRun("Food")]),
            NoteBlock(kind: .bullet, runs: [NoteRun("Pastéis")]),
            NoteBlock(kind: .bullet, indent: 1, runs: [NoteRun("Belém, "), NoteRun("the original", marks: [.italic])]),
            NoteBlock(kind: .numbered, indent: 2, runs: [NoteRun("first")]),
            NoteBlock(kind: .numbered, indent: 2, runs: [NoteRun("second")]),
            NoteBlock(kind: .bullet, runs: [NoteRun("Bacalhau")]),
            NoteBlock(kind: .numbered, runs: [NoteRun("One")]),
            NoteBlock(kind: .numbered, runs: [NoteRun("Two")]),
            NoteBlock(runs: [NoteRun(image: picture)]),
            NoteBlock(runs: [NoteRun("The end")]),
        ])
        let md = roundTrip(d)
        XCTAssertTrue(md.hasPrefix("# Lisbon plan\n\nTrams, **bold**, *italic*, ***both***, <u>under</u>, ~~gone~~ and `code()`\n"), md)
        XCTAssertTrue(md.contains("\n- [x] Book the Sintra train\n- [ ] Tram 28 before nine\n    - [ ] Tickets\n"), md)
        XCTAssertTrue(md.contains("\n        1. first\n        2. second\n- Bacalhau\n1. One\n2. Two\n"), md)
        XCTAssertTrue(md.contains("[**this**](<https://trips.example/x>)"), md)
        XCTAssertTrue(md.contains("\n\n![](<Note files/\(picture.file)>)\n\n"), md)
    }

    func testEmptyLinesAndEmptyItemsRoundTrip() {
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(kind: .heading1)]))
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(), NoteBlock(runs: [NoteRun("after one empty line")])]))
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(), NoteBlock(), NoteBlock(runs: [NoteRun("after two")])]))
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(runs: [NoteRun("a")]), NoteBlock(), NoteBlock(runs: [NoteRun("b")])]))
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(runs: [NoteRun("a")]), NoteBlock(), NoteBlock(), NoteBlock(), NoteBlock(runs: [NoteRun("b")])]))
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(runs: [NoteRun("a")]), NoteBlock()]))
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(runs: [NoteRun("a")]), NoteBlock(), NoteBlock()]))
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(kind: .bullet, runs: [NoteRun("x")]), NoteBlock(), NoteBlock(kind: .bullet, runs: [NoteRun("y")])]))
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(kind: .bullet), NoteBlock(kind: .checkbox), NoteBlock(kind: .numbered, indent: 1)]))
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(kind: .bullet, runs: [NoteRun("x")]), NoteBlock(runs: [NoteRun("para")])]))
    }

    func testTextThatLooksLikeMarkdownStaysText() {
        let tricky = ["# not a heading", "- not a bullet", "+1 for this", "1. not a list", "2) nor this", "> not a quote",
                      "**not bold**", "*not italic*", "_not either_", "snake_case_name", "a [bracket](not a link)", "`tick`",
                      "back\\slash", "<u>not underlined</u>", "~~not struck~~", "![not a picture](x.png)", "    four spaces",
                      "  - indented dash", "<https://not.example/autolink>", "50% * 2 = 100%"]
        _ = roundTrip(NoteDocument(blocks: tricky.map { NoteBlock(runs: [NoteRun($0)]) }))
        // In headings and list items too.
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(kind: .heading2, runs: [NoteRun("# **x**")]),
                                            NoteBlock(kind: .bullet, runs: [NoteRun("- [ ] not a box")]),
                                            NoteBlock(kind: .checkbox, runs: [NoteRun("[x] still unticked")])]))
    }

    func testNeighbouringMarksRoundTrip() {
        let pairs: [(Set<NoteRun.Mark>, Set<NoteRun.Mark>)] = [
            ([.italic], [.bold]), ([.bold], [.italic]), ([.bold, .italic], [.bold]), ([.bold], [.bold, .italic]),
            ([.italic], [.bold, .italic]), ([.bold, .italic], [.italic]), ([.strikethrough], [.bold]), ([.underline], [.italic]),
            ([.code], [.bold]), ([.bold, .code], [.italic]), ([], [.italic]), ([.underline, .strikethrough], [.underline]),
        ]
        for (a, b) in pairs {
            let d = NoteDocument(blocks: [NoteBlock(runs: [NoteRun("one", marks: a), NoteRun("two", marks: b), NoteRun("three")])])
            _ = roundTrip(d)
        }
        // Mark characters inside marked text.
        _ = roundTrip(NoteDocument(blocks: [NoteBlock(runs: [NoteRun("a*b", marks: [.bold]), NoteRun(" "), NoteRun("_x_", marks: [.italic]),
                                                              NoteRun(" "), NoteRun("`q`", marks: [.code])])]))
    }

    func testSpacesAtMarkedEndsStayOutsideTheMarkers() {
        let d = NoteDocument(blocks: [NoteBlock(runs: [NoteRun("a "), NoteRun("bold ", marks: [.bold]), NoteRun("b")])])
        let md = NoteMarkdown.export(d) { _ in nil }
        XCTAssertEqual(md, "a **bold** b\n")
        XCTAssertEqual(NoteMarkdown.parse(md) { _ in nil }.blocks[0].runs,
                       [NoteRun("a "), NoteRun("bold", marks: [.bold]), NoteRun(" b")])
    }

    func testMarkdownFromElsewhere() {
        let md = """
        Title
        =====
        A line with _italic_, __bold__, a [link](https://a.example "Its title") and <https://b.example/x>.
        * star item
          + nested plus item
            - [X] done, two-space nesting

        > A quote with **bold**
        ```swift
        let x = 1

        print(x)
        ```
        ![remote](https://c.example/p.png)
        ![](missing.png)
        """
        let d = NoteMarkdown.parse(md) { _ in nil }
        XCTAssertEqual(d.blocks.map(\.kind), [.paragraph, .paragraph, .paragraph, .bullet, .bullet, .checkbox, .paragraph,
                                              .paragraph, .paragraph, .paragraph, .paragraph, .paragraph])
        XCTAssertEqual(d.blocks[2].runs, [NoteRun("A line with "), NoteRun("italic", marks: [.italic]), NoteRun(", "),
                                          NoteRun("bold", marks: [.bold]), NoteRun(", a "), NoteRun("link", link: "https://a.example"),
                                          NoteRun(" and "), NoteRun("https://b.example/x", link: "https://b.example/x"), NoteRun(".")])
        XCTAssertEqual(d.blocks[3].indent, 0)
        XCTAssertEqual(d.blocks[4].indent, 1)
        XCTAssertEqual(d.blocks[5].indent, 2)
        XCTAssertTrue(d.blocks[5].checked)
        XCTAssertEqual(d.blocks[6].runs, [NoteRun("A quote with "), NoteRun("bold", marks: [.bold])])
        // Fenced code: its lines as code, an empty one kept.
        XCTAssertEqual(d.blocks[7].runs, [NoteRun("let x = 1", marks: [.code])])
        XCTAssertEqual(d.blocks[8].runs, [])
        XCTAssertEqual(d.blocks[9].runs, [NoteRun("print(x)", marks: [.code])])
        // A picture on the web stays a link; one that isn't there goes.
        XCTAssertEqual(d.blocks[10].runs, [NoteRun("remote", link: "https://c.example/p.png")])
        XCTAssertEqual(d.blocks[11].runs, [])
    }

    func testPicturesComeBackThroughTheResolver() {
        var asked: [String] = []
        let d = NoteMarkdown.parse("![](<My note files/Picture 1.png>) and ![x](pic%202.jpg)\n") { path in
            asked.append(path)
            return NoteImage(file: String(repeating: "cd", count: 32) + ".png", width: 1, height: 2)
        }
        XCTAssertEqual(asked, ["My note files/Picture 1.png", "pic%202.jpg"])
        XCTAssertEqual(d.blocks[0].runs.filter { $0.image != nil }.count, 2)
    }

    func testHTMLIsOneValidPage() {
        let d = NoteDocument(blocks: [
            NoteBlock(kind: .heading1, runs: [NoteRun("A <title> & more")]),
            NoteBlock(runs: [NoteRun("bold", marks: [.bold]), NoteRun(" "), NoteRun("link", link: "https://a.example/?q=\"x\"")]),
            NoteBlock(kind: .bullet, runs: [NoteRun("one")]),
            NoteBlock(kind: .bullet, indent: 2, runs: [NoteRun("deep")]),
            NoteBlock(kind: .numbered, indent: 1, runs: [NoteRun("n")]),
            NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("done")]),
            NoteBlock(kind: .checkbox, runs: [NoteRun("todo")]),
            NoteBlock(),
            NoteBlock(runs: [NoteRun(image: picture)]),
        ])
        let html = NoteHTML.export(d, title: "A <title>") { _ in "data:image/png;base64,AAAA" }
        XCTAssertTrue(html.contains("<title>A &lt;title&gt;</title>"))
        XCTAssertTrue(html.contains("<h1>A &lt;title&gt; &amp; more</h1>"))
        XCTAssertTrue(html.contains("<a href=\"https://a.example/?q=&quot;x&quot;\">link</a>"))
        XCTAssertTrue(html.contains("<li class=\"done\">☑ done"))
        XCTAssertTrue(html.contains("<li>☐ todo"))
        XCTAssertTrue(html.contains("<img src=\"data:image/png;base64,AAAA\" width=\"640\" height=\"360\" alt=\"\">"))
        // Every list and item that opens closes, in order.
        var stack: [String] = []
        let tags = try! NSRegularExpression(pattern: #"<(/?)(ul|ol|li)\b"#)
        for m in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let name = String(html[Range(m.range(at: 2), in: html)!])
            if html[Range(m.range(at: 1), in: html)!].isEmpty { stack.append(name) } else { XCTAssertEqual(stack.popLast(), name) }
        }
        XCTAssertEqual(stack, [])
    }

    func testTheNoteApp() throws {
        XCTAssertEqual(NoteApp.airc.route(online: true), .note(fallback: false))
        XCTAssertEqual(NoteApp.airc.route(online: false), .note(fallback: false))
        XCTAssertEqual(NoteApp.googleDocs.route(online: true), .open(URL(string: "https://doc.new")!))
        XCTAssertEqual(NoteApp.notion.route(online: false), .note(fallback: true))
        XCTAssertEqual(Set(NoteApp.allCases.compactMap(\.newDocumentURL?.scheme)), ["https"])
        // A choice a newer build wrote reads as Airc's own notes; a known one as itself.
        struct S: Codable { var app: NoteApp }
        XCTAssertEqual(try JSONDecoder().decode(S.self, from: Data(#"{"app":"evernote"}"#.utf8)).app, .airc)
        XCTAssertEqual(try JSONDecoder().decode(S.self, from: Data(#"{"app":"word"}"#.utf8)).app, .word)
        XCTAssertEqual(String(data: try JSONEncoder().encode(S(app: .googleDocs)), encoding: .utf8), #"{"app":"googleDocs"}"#)
    }
}

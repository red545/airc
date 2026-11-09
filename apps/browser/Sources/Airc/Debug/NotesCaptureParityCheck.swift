// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import CryptoKit

/// `--script notescapture`, then `--script notescapture-read` on the same data folder (P08a/Q04, both engines): a real
/// Capture of a loopback page (four colour quarters) copied with Capture's Copy into the run's own pasteboard, pasted
/// into a note with the editor's own Paste, and read back after a relaunch. No stand-in picture: when the engine gives
/// no picture (a window not drawn), it retries once and then reports FAIL-ENV with the evidence.
///   - the note keeps exactly the PNG Capture copied (its file named by the bytes' SHA-256), at its size on screen;
///   - a Capture Full Page pasted too: its full length kept;
///   - after the relaunch: the note as it was, both pictures' files there with the same bytes, the quarters' colours,
///     and the editor laying the Capture out at its size.
extension SnapshotRunner {
    private var notesCaptureExpected: URL { dir.appendingPathComponent("notescapture-expected.json") }

    private static let quartersPage = """
    <title>Quarters</title><style>html,body{margin:0;height:100%;overflow:hidden}div{position:fixed;width:50vw;height:50vh}
    #r{left:0;top:0;background:#e53935}#g{right:0;top:0;background:#43a047}#b{left:0;bottom:0;background:#1e88e5}
    #y{right:0;bottom:0;background:#fdd835}</style><div id=r></div><div id=g></div><div id=b></div><div id=y></div>
    """
    private static let tallPage = "<title>Tall</title><style>html,body{margin:0}div{height:600px}</style>"
        + "<div style='background:#e53935'></div><div style='background:#43a047'></div><div style='background:#1e88e5'></div>"

    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The colour at (fx, fy) of a PNG's pixels in sRGB.
    private static func colour(_ data: Data?, _ fx: Double, _ fy: Double) -> (Int, Int, Int)? {
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let x = CGFloat(img.width) * fx, y = CGFloat(img.height) * (1 - fy)
        ctx.draw(img, in: CGRect(x: -x, y: -y, width: CGFloat(img.width), height: CGFloat(img.height)))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    private static func near(_ a: (Int, Int, Int)?, _ b: (Int, Int, Int)) -> Bool {
        guard let a else { return false }
        return abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) <= 60
    }

    func notesCaptureScenario() {
        let board = NSPasteboard(name: NSPasteboard.Name("org.airc.test.notescapture.\(getpid())"))
        var server: LocalPageServer?
        var base = ""
        var pageTab = "", tallTab = "", noteTab = ""
        var copied = Data(), copiedFull = Data()
        var selected = CGSize.zero
        let store = { self.c.store }
        let active = { CaptureSession.active(in: self.c.window) }
        let tv = { self.c.shownNote?.textView }

        step { [self] done in
            CaptureSession.pasteboard = { board }
            CaptureSession.recordUse = { _ in }
            NoteTextView.pasteboard = { board }
            server = LocalPageServer(responses: ["/quarters.html": .init(body: Self.quartersPage), "/tall.html": .init(body: Self.tallPage)])
            server?.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }
        run { [self] in
            guard !base.isEmpty else { return check(false, "notes capture: a loopback server") }
            pageTab = (try? store().openTab(url: base + "/quarters.html", inSpace: c.currentSpaceID, title: "Quarters"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(pageTab, focus: false)
        }
        step { [self] done in
            waitUntil({ self.c.engineTab(for: pageTab).map { !$0.isLoading && $0.title == "Quarters" && !$0.view.isHiddenOrHasHiddenAncestor } == true },
                      timeout: 15) { done() }
        }
        wait(1.0)
        // A region over the four quarters, copied; once more if the engine's picture didn't come.
        for attempt in 1...2 {
            run { [self] in if copied.isEmpty { c.startCapture() } }
            step { [self] done in waitUntil({ !copied.isEmpty || active()?.picturesReady == true }, timeout: 8) { done() } }
            run { [self] in
                guard copied.isEmpty else { return }
                guard let s = active(), s.picturesReady, s.shots.contains(where: { $0.image != nil }) else {
                    let s = active(), p = c.engineTab(for: pageTab)
                    let evidence = "session \(s != nil), picturesReady \(s?.picturesReady ?? false), shots \(s?.shots.count ?? 0), "
                        + "page \(p.map { "loading \($0.isLoading), hidden \($0.view.isHiddenOrHasHiddenAncestor)" } ?? "none"), "
                        + "screen locked \(Self.screenLocked), window visible \(c.window.occlusionState.contains(.visible))"
                    s?.cancel()
                    if attempt == 2 { note("FAIL-ENV notes capture: the engine gave no picture of the page twice (\(evidence))") }
                    return
                }
                let o = s.overlay
                let a = CGPoint(x: (o.bounds.midX - 100).rounded(), y: (o.bounds.midY - 60).rounded())
                o.pressed(at: a)
                o.dragged(to: CGPoint(x: a.x + 200, y: a.y + 120))
                o.released(at: CGPoint(x: a.x + 200, y: a.y + 120))
                selected = o.selection?.size ?? .zero
                s.confirm()
                board.clearContents()
                o.bar.copyButton.action?()
                copied = board.data(forType: .png) ?? Data()
            }
        }
        var pasted: NoteImage?
        run { [self] in
            guard !copied.isEmpty else { return }
            check(selected == CGSize(width: 200, height: 120) && Self.near(Self.colour(copied, 0.25, 0.25), (229, 57, 53))
                  && Self.near(Self.colour(copied, 0.75, 0.75), (253, 216, 53)),
                  "notes capture: a real Capture of the page, 200 × 120 pt, its quarters' colours, on the run's own pasteboard")
            guard let t = try? store().createNote(inSpace: c.currentSpaceID, document: NoteDocument(blocks: [NoteBlock(kind: .heading1, runs: [NoteRun("Captured")])])) else {
                return check(false, "notes capture: a note")
            }
            noteTab = t.id
            c.show(noteTab)
            guard let t = tv() else { return check(false, "notes capture: the note's editor") }
            t.setSelectedRange(NSRange(location: (t.string as NSString).length, length: 0))
            t.insertNewline(nil)
            // The editor's own Paste (Edit › Paste, ⌘V), reading the run's pasteboard.
            t.paste(nil)
            pasted = store().note(forTab: noteTab)?.document.blocks.flatMap(\.runs).compactMap(\.image).first
            let file = pasted.flatMap { NoteImages.url($0.file) }
            let kept = file.flatMap { try? Data(contentsOf: $0) }
            check(pasted != nil && kept == copied && pasted?.file.hasPrefix(Self.sha(copied)) == true,
                  "notes capture: Paste keeps exactly the PNG Capture copied, named by its SHA-256 (\(pasted?.file.prefix(12) ?? "none")…)")
            check(pasted.map { CGSize(width: $0.width, height: $0.height) } == selected,
                  "notes capture: in the note it measures its size on screen (\(pasted.map { "\($0.width) × \($0.height)" } ?? "-") pt)")
        }
        // A Capture Full Page of a tall page, pasted too: its whole length kept.
        run { [self] in
            guard !copied.isEmpty else { return }
            tallTab = (try? store().openTab(url: base + "/tall.html", inSpace: c.currentSpaceID, title: "Tall"))?.id ?? ""
            c.show(tallTab, focus: false)
        }
        step { [self] done in waitUntil({ tallTab.isEmpty || self.c.engineTab(for: tallTab).map { !$0.isLoading && $0.title == "Tall" } == true }, timeout: 15) { done() } }
        wait(0.8)
        run { [self] in if !tallTab.isEmpty { c.startCapture(fullPage: true) } }
        step { [self] done in waitUntil({ tallTab.isEmpty || (active()?.picturesReady == true && active()?.phase != .capturing) }, timeout: 40) { done() } }
        var fullImage: NoteImage?
        run { [self] in
            guard !tallTab.isEmpty else { return }
            guard let s = active(), let p = s.fullPagePicture else {
                active()?.cancel()
                return note("FAIL-ENV notes capture: no full page picture (session \(active() != nil), window visible \(c.window.occlusionState.contains(.visible)))")
            }
            board.clearContents()
            s.overlay.bar.copyButton.action?()
            copiedFull = board.data(forType: .png) ?? Data()
            c.show(noteTab)
            guard let t = tv() else { return }
            t.setSelectedRange(NSRange(location: (t.string as NSString).length, length: 0))
            t.paste(nil)
            let images = store().note(forTab: noteTab)?.document.blocks.flatMap(\.runs).compactMap(\.image) ?? []
            fullImage = images.count == 2 ? images.last : nil
            let zoom = c.engineTab(for: tallTab)?.zoomFactor ?? 1
            check(fullImage.map { abs($0.height - 1800 * zoom) < 1 && abs($0.width - Double(p.pagePoints.width)) < 1 } == true
                  && fullImage.flatMap { NoteImages.url($0.file) }.flatMap { try? Data(contentsOf: $0) } == copiedFull,
                  "notes capture: a full page pasted keeps its whole length, \(fullImage.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "-") pt")
        }
        run { [self] in
            try? store().flush()
            let doc = store().note(forTab: noteTab)?.document
            let expected: [String: Any] = [
                "tab": noteTab, "doc": (doc.flatMap { try? JSONEncoder().encode($0) }).map { String(decoding: $0, as: UTF8.self) } ?? "",
                "capture": Self.sha(copied), "full": copiedFull.isEmpty ? "" : Self.sha(copiedFull),
                "size": [selected.width, selected.height],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: expected) { try? data.write(to: notesCaptureExpected) }
            note("notes capture: wrote notescapture-expected.json")
            NoteTextView.pasteboard = { .general }
            board.releaseGlobally()
            server?.stop()
        }
    }

    func notesCaptureReadScenario() {
        run { [self] in
            let e = (try? Data(contentsOf: notesCaptureExpected)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            guard let tab = e["tab"] as? String, !tab.isEmpty, let json = e["doc"] as? String,
                  let doc = try? JSONDecoder().decode(NoteDocument.self, from: Data(json.utf8)) else {
                return check(false, "notes capture read: notescapture-expected.json from --script notescapture")
            }
            let store = c.store
            check(store.note(forTab: tab)?.document == doc, "notes capture read: after a relaunch the note is as it was")
            let images = doc.blocks.flatMap(\.runs).compactMap(\.image)
            let shas = [e["capture"] as? String ?? "", e["full"] as? String ?? ""].filter { !$0.isEmpty }
            let files = images.map { img -> (NoteImage, Data?) in (img, NoteImages.url(img.file).flatMap { try? Data(contentsOf: $0) }) }
            check(!images.isEmpty && files.count == shas.count && zip(files, shas).allSatisfy { f, s in f.1.map(Self.sha) == s && f.0.file.hasPrefix(s) },
                  "notes capture read: each picture's file is there with the bytes Capture copied (\(files.count) of \(shas.count))")
            if let first = files.first?.1 {
                check(Self.near(Self.colour(first, 0.25, 0.25), (229, 57, 53)) && Self.near(Self.colour(first, 0.75, 0.25), (67, 160, 71))
                      && Self.near(Self.colour(first, 0.25, 0.75), (30, 136, 229)) && Self.near(Self.colour(first, 0.75, 0.75), (253, 216, 53)),
                      "notes capture read: the Capture's quarters are the page's colours")
            }
            c.show(tab)
            var laidOut: NSSize?
            if let t = c.shownNote?.textView, let lm = t.layoutManager, let storage = t.textStorage, let tc = t.textContainer {
                lm.ensureLayout(for: tc)
                storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                    guard value is NSTextAttachment else { return }
                    laidOut = lm.attachmentSize(forGlyphAt: lm.glyphIndexForCharacter(at: range.location))
                    stop.pointee = true
                }
            }
            let size = (e["size"] as? [Double]).map { CGSize(width: $0[0], height: $0[1]) }
            check(laidOut != nil && laidOut == size, "notes capture read: the editor shows the Capture at its size (\(laidOut.map { "\($0.width) × \($0.height)" } ?? "-") pt)")
        }
    }
}
#endif

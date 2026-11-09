// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AVFoundation
import AircKit
import AppKit
import CoreVideo

/// `--script library2` (both engines): LIB-1, Library › Media and the Library button's recent files, on loopback
/// downloads into a scratch folder of the run's data folder (never ~/Downloads): a PNG, an H.264 movie, a PDF and a text
/// file, a Capture saved to a scratch folder, then a CSV. Nothing opens in another app, in Finder or in Quick Look (the
/// hooks record it), and Delete moves to a scratch "Trash" folder, never the owner's Trash.
///   - Media lists exactly the image, the video and the Capture, newest first, each with a Quick Look picture;
///   - a click on a tile (a real one) shows Quick Look on it, a double-click opens it, ⌘-click shows it in Finder;
///   - Move to Trash takes a file out, Undo puts it back where it was;
///   - resting on the footer's Library button (its own enter and exit handlers: posted mouse moves never reach tracking
///     areas) brings the card after the dwell, above the button, listing the five newest files; it stays while the
///     pointer goes to it, hides after it leaves, a click on a row (a real one) opens the file;
///   - no card while a drag runs or with the Library open;
///   - a private window's download and Capture are never listed.
extension SnapshotRunner {
    func library2Scenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = chromium ? "chromium" : "webkit"
        var server: LocalPageServer?
        var base = ""
        var helper = ""
        var spaceID = ""
        let scratch = AppPaths.dataDirectory.appendingPathComponent("library2-downloads", isDirectory: true)
        let captures = AppPaths.dataDirectory.appendingPathComponent("library2-captures", isDirectory: true)
        let trash = AppPaths.dataDirectory.appendingPathComponent("library2-trash", isDirectory: true)
        var opened: [String] = [], revealed: [String] = [], looked: [(names: [String], index: Int)] = []
        var captureName = ""
        var privateCapture = ""
        var privateWindow: PrivateWindowController?
        let files = LibraryFiles.shared
        func center() -> DownloadCenter? { MediaLibrary.shared.downloads }
        func finished(_ path: String) -> Bool {
            center()?.items.contains { URL(string: $0.download.url)?.path == path && $0.download.state == .complete } == true
        }
        func names(_ list: [LibraryFile]) -> [String] { list.map(\.name) }
        func media(_ name: String) -> LibraryFile? { files.media.first { $0.name == name } }
        func refreshed(_ then: @escaping () -> Void) { files.refresh(then) }
        let hover = { self.c.recentFiles }

        // MARK: Setup: fixtures, the server, the hooks, a Space whose downloads go to the scratch folder
        var fixtures: [String: Data] = [:]
        step { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let made = LibraryFixtures.make()
                DispatchQueue.main.async { fixtures = made; done() }
            }
        }
        step { [self] done in
            check(fixtures["photo.png"] != nil && fixtures["clip.mov"] != nil && fixtures["paper.pdf"] != nil,
                  "library2 (\(tag)): fixtures (PNG \(fixtures["photo.png"]?.count ?? 0) B, movie \(fixtures["clip.mov"]?.count ?? 0) B, PDF \(fixtures["paper.pdf"]?.count ?? 0) B)")
            func file(_ name: String, _ type: String) -> LocalPageServer.Page {
                .init(headers: ["Content-Type": type, "Content-Disposition": "attachment; filename=\"\(name)\""], body: "", data: fixtures[name])
            }
            server = LocalPageServer(responses: [
                "/start": .init(body: "<!doctype html><title>Library fixture</title><style>body{margin:0;height:100vh;background:linear-gradient(135deg,#ff8a65,#7e57c2)}</style>"),
                "/photo.png": file("photo.png", "image/png"),
                "/clip.mov": file("clip.mov", "video/quicktime"),
                "/paper.pdf": file("paper.pdf", "application/pdf"),
                "/notes.txt": file("notes.txt", "text/plain"),
                "/data.csv": file("data.csv", "text/csv"),
                "/secret.png": file("secret.png", "image/png"),
            ])
            guard let server else { check(false, "library2: the loopback server starts"); return done() }
            server.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                self.check(!base.isEmpty, "library2 (\(tag)): the loopback server starts")
                done()
            }
        }
        step { [self] done in
            for d in [scratch, captures, trash] {
                try? FileManager.default.removeItem(at: d)
                try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            }
            DownloadCenter.interceptOpen = { opened.append($0.download.fileName); return true }
            DownloadCenter.reveal = { _ in }
            WebKitLibrary.directoryOverride = scratch
            WebKitLibrary.opener = { opened.append($0.lastPathComponent) }
            CaptureSession.downloadsDirectory = { captures }
            LibraryFiles.open = { opened.append($0.lastPathComponent) }
            LibraryFiles.reveal = { revealed += $0.map(\.lastPathComponent) }
            LibraryFiles.quickLook = { urls, i in looked.append((urls.map(\.lastPathComponent), i)) }
            LibraryFiles.trash = { url, answer in
                let to = trash.appendingPathComponent(url.lastPathComponent)
                answer((try? FileManager.default.moveItem(at: url, to: to)).map { to })
            }
            do {
                let first = c.store.selectedSpace
                var profileID = first.profileID
                if chromium {
                    // A profile of its own, whose folder gets the scratch download folder before it loads.
                    let p = try c.store.createProfile(name: "Library test")
                    let folder = Self.chromiumUserData.appendingPathComponent(p.engineDirectory, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let prefs = ["download": ["default_directory": scratch.path, "prompt_for_download": false, "directory_upgrade": true],
                                 "savefile": ["default_directory": scratch.path]]
                    try JSONSerialization.data(withJSONObject: prefs).write(to: folder.appendingPathComponent("Preferences"))
                    profileID = p.id
                }
                let space = try c.store.createSpace(name: "Library", icon: nil, theme: first.theme, profileID: profileID, after: first.id)
                spaceID = space.id
                helper = try c.store.openTab(url: base + "/start", inSpace: space.id).id
                c.profiles.whenLoaded(profileID, { [self] _ in
                    c.reloadAll(animated: false)
                    c.switchToSpace(space.id, animated: false)
                    c.show(helper, focus: false)
                    done()
                }, failed: { self.check(false, "library2: the test profile loads"); done() })
            } catch {
                check(false, "library2: setup (\(error))")
                done()
            }
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: helper)?.title.contains("Library fixture") == true }, timeout: 10) { done() } }

        // MARK: Downloads and a Capture
        func download(_ path: String) {
            run { [self] in c.engineTab(for: helper)?.load(URL(string: base + path)!) }
            step { [self] done in
                waitUntil({ finished(path) }, timeout: 10) {
                    let row = center()?.items.first { URL(string: $0.download.url)?.path == path }
                    let inScratch = row?.download.path?.hasPrefix(scratch.path) == true
                    self.check(finished(path) && inScratch, "library2 (\(tag)): \(path) downloads into the run's scratch folder"
                               + " (\(row.map { "\($0.download.state), \($0.download.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-")" } ?? "no row"))")
                    if let row, !inScratch, row.download.state == .inProgress { center()?.perform(.cancel, row) }
                    done()
                }
            }
            wait(0.15)
        }
        for p in ["/photo.png", "/clip.mov", "/paper.pdf", "/notes.txt"] { download(p) }
        // Back to the page for the Capture (a download leaves it on screen, but a slow engine may still be settling).
        run { [self] in c.engineTab(for: helper)?.load(URL(string: base + "/start")!) }
        step { [self] done in waitUntil({ self.c.engineTab(for: helper)?.isLoading == false && self.c.engineTab(for: helper)?.title.contains("Library fixture") == true }, timeout: 8) { done() } }
        wait(0.6)
        run { [self] in c.startCapture() }
        step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
        run { [self] in
            guard let s = CaptureSession.active(in: c.window) else { return check(false, "library2 (\(tag)): Capture starts") }
            s.toggleFullPage()
            s.confirm()
            s.save()
            let saved = (try? FileManager.default.contentsOfDirectory(atPath: captures.path)) ?? []
            captureName = saved.first ?? ""
            check(saved.count == 1 && captureName.hasPrefix("Capture "), "library2 (\(tag)): a Capture is saved to the scratch folder (\(captureName))")
        }
        wait(0.3)
        download("/data.csv")

        // MARK: Library › Media
        run { [self] in
            if c.library == nil { c.toggleLibrary() }
            c.library?.model.section = .media
        }
        wait(0.6)
        step { done in refreshed(done) }
        run { [self] in
            let got = names(files.media)
            check(got == [captureName, "clip.mov", "photo.png"],
                  "library2 (\(tag)): Media lists exactly the Capture, the video and the image, newest first (\(got))")
            check(files.media.map(\.kind) == [.image, .video, .image], "library2 (\(tag)): their kinds are image, video, image")
        }
        step { [self] done in
            waitUntil({ files.media.allSatisfy { LibraryThumbnails.shared.pictured.contains($0.path) } }, timeout: 8) {
                let missing = files.media.filter { !LibraryThumbnails.shared.pictured.contains($0.path) }.map(\.name)
                self.check(missing.isEmpty, "library2 (\(tag)): every tile has its Quick Look picture" + (missing.isEmpty ? "" : " (missing \(missing))"))
                done()
            }
        }
        wait(0.3)
        capture("library2-media")
        // A real click on the image's tile: Quick Look, on that file, with the grid's files as its items.
        step { [self] done in
            func attempt(_ n: Int) {
                looked.removeAll()
                clickLibraryAnchor("library.media.photo.png") {
                    self.waitUntil({ !looked.isEmpty }, timeout: 1.5) {
                        if looked.isEmpty, n == 0 {
                            self.note("library2: the click on the tile didn't arrive (\(TestAnchors.lastHit["library.media.photo.png"] ?? "-")); once more")
                            return attempt(1)
                        }
                        let l = looked.first
                        self.check(l.map { $0.names == [captureName, "clip.mov", "photo.png"] && $0.index == 2 } == true,
                                   "library2 (\(tag)): a click on a tile shows it in Quick Look (\(l.map { "\($0.names) at \($0.index)" } ?? "nothing"))")
                        done()
                    }
                }
            }
            attempt(0)
        }
        run { [self] in
            guard let clip = media("clip.mov") else { return check(false, "library2: the video is listed") }
            files.activate(clip, in: files.media, clickCount: 2, command: false, from: c.library)
            files.activate(clip, in: files.media, clickCount: 1, command: true, from: c.library)
            check(opened.last == "clip.mov" && revealed.last == "clip.mov",
                  "library2 (\(tag)): a double-click opens the file, ⌘-click shows it in Finder (opened \(opened.last ?? "-"), revealed \(revealed.last ?? "-"))")
            check(NSItemProvider(contentsOf: clip.url) != nil, "library2 (\(tag)): a tile drags out as its file")
        }
        // Move to Trash, Undo.
        run { [self] in
            guard let clip = media("clip.mov") else { return }
            files.moveToTrash(clip) { self.check(false, "library2 (\(tag)): Move to Trash: \($0)") }
        }
        step { done in self.waitUntil({ files.trashed != nil && media("clip.mov") == nil }, timeout: 3) { done() } }
        run { [self] in
            check(files.trashed?.file.name == "clip.mov" && media("clip.mov") == nil && names(files.media) == [captureName, "photo.png"]
                  && FileManager.default.fileExists(atPath: trash.appendingPathComponent("clip.mov").path),
                  "library2 (\(tag)): Move to Trash takes the video out of Media (\(names(files.media)))")
        }
        capture("library2-media-trashed")
        run { [self] in check(files.undoTrash(), "library2 (\(tag)): Undo puts the file back") }
        step { done in self.waitUntil({ media("clip.mov") != nil }, timeout: 3) { done() } }
        run { [self] in
            check(names(files.media) == [captureName, "clip.mov", "photo.png"] && files.trashed == nil
                  && FileManager.default.fileExists(atPath: scratch.appendingPathComponent("clip.mov").path),
                  "library2 (\(tag)): and it's listed again, where it was (\(names(files.media)))")
            c.toggleLibrary()
        }
        wait(0.6)

        // MARK: Recent files on the Library button
        let recent = { ["data.csv", captureName, "notes.txt", "paper.pdf", "clip.mov"] }
        var entered: CFTimeInterval = 0
        run { [self] in
            entered = CACurrentMediaTime()
            hoverLibraryButton(true)
        }
        wait(0.3)
        run { [self] in check(!hover().isShowing, "library2 (\(tag)): no card before the dwell (0.3 s)") }
        step { done in self.waitUntil({ hover().isShowing }, timeout: 2) { done() } }
        run { [self] in
            let after = CACurrentMediaTime() - entered
            let shown = names(hover().shownFiles)
            check(hover().isShowing && after >= RecentFilesHover.dwell - 0.02 && after < RecentFilesHover.dwell + 0.5,
                  "library2 (\(tag)): resting on the Library button brings the card after the dwell (\(String(format: "%.2f", after)) s)")
            check(shown == recent(), "library2 (\(tag)): it lists the five newest downloads and Captures (\(shown))")
            guard let card = hover().card else { return }
            let r = card.convert(card.cardRect, to: c.root)
            let b = c.sidebar.footer.libraryButton.convert(c.sidebar.footer.libraryButton.bounds, to: c.root)
            check(card.superview === c.root && r.maxY <= b.minY && r.maxY >= b.minY - 12 && abs(r.minX - b.minX) < 1 && c.root.bounds.contains(r),
                  "library2 (\(tag)): the card sits just above the button, from its left edge (card \(Self.rect(r)), button \(Self.rect(b)))")
            check(c.sidebar.footer.libraryButton.toolTip == nil, "library2 (\(tag)): the button's tooltip waits while the card is up")
        }
        wait(0.4)
        capture("library2-recent")
        // To the card: it stays; off it: it goes.
        run { [self] in
            hoverLibraryButton(false)
            hover().testCardHover(true)
        }
        wait(RecentFilesHover.grace + 0.2)
        run { [self] in
            check(hover().isShowing, "library2 (\(tag)): the card stays while the pointer goes from the button to it")
            hover().testCardHover(false)
        }
        wait(RecentFilesHover.grace + 0.2)
        run { [self] in
            check(!hover().isShowing && c.sidebar.footer.libraryButton.toolTip == SpaceBarView.libraryToolTip,
                  "library2 (\(tag)): and hides once it leaves the card, the tooltip back")
        }
        // A real click on a row opens its file.
        run { [self] in hoverLibraryButton(true) }
        step { done in self.waitUntil({ hover().isShowing }, timeout: 2) { done() } }
        wait(0.4)
        step { [self] done in
            func attempt(_ n: Int) {
                opened.removeAll()
                let name = "library.recent.notes.txt"
                guard let card = hover().card, let host = card.subviews.first, let w = host.window, let f = TestAnchors.frames[name] else {
                    check(false, "library2 (\(tag)): the card's rows are on screen")
                    return done()
                }
                let p = host.convert(NSPoint(x: f.midX + host.safeAreaInsets.left, y: f.midY + host.safeAreaInsets.top), to: nil)
                click(at: p, in: w) {
                    self.waitUntil({ !opened.isEmpty }, timeout: 1.5) {
                        if opened.isEmpty, n == 0, hover().isShowing {
                            self.note("library2: the click on the row didn't arrive; once more")
                            return attempt(1)
                        }
                        self.check(opened == ["notes.txt"] && !hover().isShowing,
                                   "library2 (\(tag)): a click on a row opens that file and closes the card (opened \(opened))")
                        done()
                    }
                }
            }
            attempt(0)
        }
        run { [self] in hoverLibraryButton(false) }
        wait(0.3)
        // Never during a drag, nor with the Library open.
        run { [self] in
            c.dragsInProgress += 1
            hoverLibraryButton(true)
        }
        wait(RecentFilesHover.dwell + 0.3)
        run { [self] in
            check(!hover().isShowing && hover().lastRefusal?.contains("drag") == true,
                  "library2 (\(tag)): no card while a drag runs (\(hover().lastRefusal ?? "shown"))")
            hoverLibraryButton(false)
            c.dragsInProgress -= 1
            c.toggleLibrary()
        }
        wait(0.6)
        run { [self] in hoverLibraryButton(true) }
        wait(RecentFilesHover.dwell + 0.3)
        run { [self] in
            check(!hover().isShowing && hover().lastRefusal == "the Library is open",
                  "library2 (\(tag)): no card with the Library open (\(hover().lastRefusal ?? "shown"))")
            hoverLibraryButton(false)
            c.toggleLibrary()
        }
        wait(0.6)

        // MARK: A private window's download and Capture stay out
        step { [self] done in
            guard let app else { return done() }
            // From the Library Space, so Chromium's private session inherits its scratch download folder.
            if c.currentSpaceID != spaceID { c.switchToSpace(spaceID, animated: false) }
            PrivateBrowsing.shared.open(app: app) { w in
                privateWindow = w
                _ = w?.openPage(URL(string: base + "/start"))
                done()
            }
        }
        step { done in self.waitUntil({ privateWindow?.shownPage?.isLoading == false && privateWindow?.shownPage?.title == "Library fixture" }, timeout: 10) { done() } }
        run { privateWindow?.shownPage?.load(URL(string: base + "/secret.png")!) }
        step { [self] done in
            waitUntil({ privateWindow?.downloads?.items.contains { $0.download.fileName == "secret.png" && $0.download.state == .complete } == true }, timeout: 10) {
                let row = privateWindow?.downloads?.items.first { $0.download.fileName == "secret.png" }
                self.check(row?.download.state == .complete && row?.download.path?.hasPrefix(scratch.path) == true,
                           "library2 (\(tag)): a private window downloads secret.png into the scratch folder (\(row.map { "\($0.download.state)" } ?? "no row"))")
                done()
            }
        }
        run { privateWindow?.shownPage?.load(URL(string: base + "/start")!) }
        step { done in self.waitUntil({ privateWindow?.shownPage?.isLoading == false && privateWindow?.shownPage?.title == "Library fixture" }, timeout: 8) { done() } }
        wait(0.6)
        run { [self] in
            _ = privateWindow?.perform(menuTitle: "Capture…")
            note("library2 private capture: session=\(CaptureSession.active(in: privateWindow?.window) != nil), visible=\(privateWindow?.window.isVisible ?? false), attached=\(privateWindow?.shownPage?.view.window === privateWindow?.window)")
        }
        step { done in self.waitUntil({ CaptureSession.active(in: privateWindow?.window)?.picturesReady == true }, timeout: 8) { done() } }
        run { [self] in
            guard let s = CaptureSession.active(in: privateWindow?.window) else { return check(false, "library2 (\(tag)): Capture starts in the private window") }
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: captures.path)) ?? [])
            s.toggleFullPage()
            s.confirm()
            s.save()
            privateCapture = Set((try? FileManager.default.contentsOfDirectory(atPath: captures.path)) ?? []).subtracting(before).first ?? ""
            check(!privateCapture.isEmpty, "library2 (\(tag)): the private window saves a Capture (\(privateCapture))")
        }
        step { done in refreshed(done) }
        run { [self] in
            let all = names(files.media) + names(files.recent)
            let fromDownloads = center()?.items.contains { $0.download.fileName == "secret.png" } == true
            check(!all.contains("secret.png") && !all.contains(privateCapture) && !fromDownloads && names(files.media) == [captureName, "clip.mov", "photo.png"],
                  "library2 (\(tag)): neither shows in Media or the recent files, nor in the main Downloads (media \(names(files.media)), recent \(names(files.recent)))")
            let recorded = (try? Data(contentsOf: LibraryFiles.recordsURL)).flatMap { try? JSONDecoder().decode(CaptureRecords.self, from: $0) }
            check(recorded?.entries.map { URL(fileURLWithPath: $0.path).lastPathComponent } == [captureName],
                  "library2 (\(tag)): Captures.json records only the main window's Capture (\(recorded?.entries.count ?? -1) entries)")
            check(privateWindow.map { !Self.contains(SpaceBarView.self, in: $0.window.contentView) } ?? false,
                  "library2 (\(tag)): a private window has no Library button to hover")
            privateWindow?.closeWindow()
        }
        wait(0.6)
        // A file deleted outside Airc drops out on the next refresh.
        run { try? FileManager.default.removeItem(at: scratch.appendingPathComponent("photo.png")) }
        step { done in refreshed(done) }
        run { [self] in
            check(names(files.media) == [captureName, "clip.mov"] && !names(files.recent).contains("photo.png"),
                  "library2 (\(tag)): a file deleted in Finder drops out (\(names(files.media)))")
            server?.stop()
            CaptureSession.downloadsDirectory = { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
            LibraryFiles.quickLook = nil
            note("library2: done")
        }
    }

    /// The Library button's own enter and exit handlers (what its tracking area calls).
    func hoverLibraryButton(_ inside: Bool) {
        guard let b = c.sidebar.footer.libraryButton as? GlyphButton,
              let e = NSEvent.enterExitEvent(with: inside ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                             context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else { return }
        if inside { b.mouseEntered(with: e) } else { b.mouseExited(with: e) }
    }

    /// A real click on a Library control (its hosting view keeps the titlebar's safe area: anchors start below it).
    func clickLibraryAnchor(_ name: String, _ done: @escaping () -> Void) {
        guard let host = c.library?.subviews.first(where: { !($0 is GlyphButton) }), let w = host.window, let f = TestAnchors.frames[name] else {
            note("FAIL click \(name): not on screen")
            return done()
        }
        let inset = host.safeAreaInsets
        let p = host.convert(NSPoint(x: f.midX + inset.left, y: f.midY + inset.top), to: nil)
        TestAnchors.lastHit[name] = String(format: "(%.0f, %.0f)", p.x, p.y)
        click(at: p, in: w, done)
    }

    static func contains<T: NSView>(_ type: T.Type, in view: NSView?) -> Bool {
        guard let view else { return false }
        return view is T || view.subviews.contains { contains(type, in: $0) }
    }

    static func rect(_ r: NSRect) -> String { String(format: "%.0f,%.0f %.0f×%.0f", r.minX, r.minY, r.width, r.height) }
}

/// The files the check (and the marketing shot) download: a PNG, an H.264 movie and a PDF made here, plus small text
/// files. Synthetic: gradients and shapes, nothing of anyone's.
enum LibraryFixtures {
    static func make() -> [String: Data] {
        var out: [String: Data] = [:]
        out["photo.png"] = png(width: 960, height: 640) { ctx, w, h in gradient(ctx, w, h, [0xFF8A65, 0xF06292, 0x7E57C2]) }
        out["secret.png"] = png(width: 320, height: 320) { ctx, w, h in gradient(ctx, w, h, [0x263238, 0x455A64]) }
        out["clip.mov"] = movie(width: 640, height: 360, frames: 24) { ctx, w, h, i in
            gradient(ctx, w, h, [0x00897B, 0x26C6DA])
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
            ctx.fillEllipse(in: CGRect(x: 60 + CGFloat(i) * 18, y: h / 2 - 50, width: 100, height: 100))
        }
        out["paper.pdf"] = pdf()
        out["notes.txt"] = Data("Notes\n".utf8)
        out["data.csv"] = Data("a,b\n1,2\n".utf8)
        return out
    }

    static func gradient(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ hexes: [Int]) {
        let colors = hexes.map { CGColor(srgbRed: CGFloat($0 >> 16 & 255) / 255, green: CGFloat($0 >> 8 & 255) / 255, blue: CGFloat($0 & 255) / 255, alpha: 1) }
        let locations = colors.indices.map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations) else { return }
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
    }

    static func png(width: Int, height: Int, _ draw: (CGContext, CGFloat, CGFloat) -> Void) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx, CGFloat(width), CGFloat(height))
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    static func pdf() -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        for i in 0..<12 { ctx.fill(CGRect(x: 60, y: 760 - CGFloat(i) * 40, width: CGFloat(300 + (i * 37) % 160), height: 10)) }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// An H.264 QuickTime movie, 24 fps (off the main thread: it waits for the writer).
    static func movie(width: Int, height: Int, frames: Int, _ draw: (CGContext, CGFloat, CGFloat, Int) -> Void) -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airc-library-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                         AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pb = buffer else { return nil }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                draw(ctx, CGFloat(width), CGFloat(height), i)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 24))
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 10) == .success, writer.status == .completed else { return nil }
        return try? Data(contentsOf: url)
    }
}
#endif

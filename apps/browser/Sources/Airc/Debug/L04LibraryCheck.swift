// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import Quartz

/// `--script l04` (both engines; run it on the dedicated build Mac's agent console, AIRC_UI_DEDICATED_SESSION=1): parity
/// row L04, Library › Media and the Library button's recent files against Arc's. Only synthetic files: a scratch folder in
/// the run's data folder stands in for the Desktop (`LibraryFolderSources.testDefaultURL`, the open panel answered by
/// `testPanel`), two loopback downloads go to a scratch folder, a Capture is a small PNG recorded as one, and "the Trash" is
/// a scratch folder. Nothing opens in Finder or another app (hooks record it); AirDrop and iMessage are recorded too.
///
/// Real input goes through the stable UI driver (~/arcfork/tools/airc-ui-driver, the owner's grants): clicks, keys and
/// drags are WindowServer events, never posted into the app. Each result says "real" or "hook". Without the driver's
/// grants a real-input case is FAIL-ENV, never PASS.
///   - folder access: the Desktop allowed (a bookmark kept), its pictures and videos join the grid; Stop Showing removes
///     them and the grant;
///   - the grid: newest first, in Arc's buckets ("Today", "Yesterday", then the month), on screen;
///   - filters: Images, Videos, Captures, and the chip's "Remove … Filter" (a real click);
///   - Quick Look: a real click on a tile shows the real Quick Look panel on it; Space (a real key) closes it and opens it
///     again on the selected tile;
///   - Delete (a real key) moves the selected tile to the Trash; ⌘Z (a real key) puts it back;
///   - drag out: a real drag of a tile, and of a hover row, into another window drops the file's URL;
///   - the hover: the five newest of downloads, Captures and folder media; the Library button's right-click "Show media
///     from:" switches each; a row shows in Finder, goes by AirDrop or iMessage, moves to the Trash and ⌘Z brings it back.
extension SnapshotRunner {
    func l04Scenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = chromium ? "chromium" : "webkit"
        let fm = FileManager.default
        let files = LibraryFiles.shared
        let sources = LibraryFolderSources.shared
        let hover = { self.c.recentFiles }
        let data = AppPaths.dataDirectory
        let desktop = data.appendingPathComponent("L04Desktop", isDirectory: true)
        let downloads = data.appendingPathComponent("L04Downloads", isDirectory: true)
        let trash = data.appendingPathComponent("L04Trash", isDirectory: true)
        let captureURL = data.appendingPathComponent("L04Captures/L04 Capture.png")
        var server: LocalPageServer?
        var base = ""
        var helper = ""
        var fixtures: [String: Data] = [:]
        var revealed: [String] = [], opened: [String] = [], shared: [String] = []
        var drop: L04DropWindow?
        func names(_ l: [LibraryFile]) -> [String] { l.map(\.name) }
        func media(_ n: String) -> LibraryFile? { files.media.first { $0.name == n } }
        func center() -> DownloadCenter? { MediaLibrary.shared.downloads }
        func finished(_ path: String) -> Bool {
            center()?.items.contains { URL(string: $0.download.url)?.path == path && $0.download.state == .complete } == true
        }

        // MARK: Setup
        step { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let made = LibraryFixtures.make()
                DispatchQueue.main.async { fixtures = made; done() }
            }
        }
        step { [self] done in
            for d in [desktop, downloads, trash, captureURL.deletingLastPathComponent()] {
                try? fm.removeItem(at: d)
                try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            }
            Self.p10Write(desktop.appendingPathComponent("trip.mov"), minutesAgo: 40 * 24 * 60, png: false)
            Self.p10Write(desktop.appendingPathComponent("sunset.png"), minutesAgo: 24 * 60 + 5)
            Self.p10Write(desktop.appendingPathComponent("pier.jpg"), minutesAgo: 5)
            try? Data("words".utf8).write(to: desktop.appendingPathComponent("readme.txt"))
            Self.p10Write(captureURL, minutesAgo: 0)
            LibraryFolderSources.testDefaultURL = { $0 == .desktop ? desktop : data.appendingPathComponent("L04-\($0.rawValue)") }
            LibraryFolderSources.testPanel = { _, suggested in suggested }
            sources.resetForTesting()
            sources.settings = LibrarySourceSettings()
            DownloadCenter.interceptOpen = { opened.append($0.download.fileName); return true }
            DownloadCenter.reveal = { _ in }
            WebKitLibrary.directoryOverride = downloads
            WebKitLibrary.opener = { opened.append($0.lastPathComponent) }
            LibraryFiles.open = { opened.append($0.lastPathComponent) }
            LibraryFiles.reveal = { revealed += $0.map(\.lastPathComponent) }
            LibraryFiles.quickLook = nil   // the real panel
            LibraryFiles.share = { service, url in shared.append("\(service.rawValue):\(url.lastPathComponent)") }
            LibraryFiles.trash = { url, answer in
                let to = trash.appendingPathComponent(url.lastPathComponent)
                answer((try? fm.moveItem(at: url, to: to)).map { to })
            }
            func file(_ name: String, _ type: String) -> LocalPageServer.Page {
                .init(headers: ["Content-Type": type, "Content-Disposition": "attachment; filename=\"\(name)\""], body: "", data: fixtures[name])
            }
            server = LocalPageServer(responses: [
                "/start": .init(body: "<!doctype html><title>L04 fixture</title><style>body{margin:0;height:100vh;background:#cfd8dc}</style>"),
                "/photo.png": file("photo.png", "image/png"),
                "/notes.txt": file("notes.txt", "text/plain"),
                "/edit": .init(body: "<!doctype html><title>L04 edit</title><textarea id=t style='width:90%;height:200px'></textarea>"),
            ])
            guard let server else { check(false, "l04 (\(tag)): the loopback server starts"); return done() }
            server.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                self.check(!base.isEmpty, "l04 (\(tag)): the loopback server starts")
                done()
            }
        }
        step { [self] done in
            do {
                let first = c.store.selectedSpace
                var profileID = first.profileID
                if chromium {
                    let p = try c.store.createProfile(name: "L04 test")
                    let folder = Self.chromiumUserData.appendingPathComponent(p.engineDirectory, isDirectory: true)
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    let prefs = ["download": ["default_directory": downloads.path, "prompt_for_download": false, "directory_upgrade": true],
                                 "savefile": ["default_directory": downloads.path]]
                    try JSONSerialization.data(withJSONObject: prefs).write(to: folder.appendingPathComponent("Preferences"))
                    profileID = p.id
                }
                let space = try c.store.createSpace(name: "Library", icon: nil, theme: first.theme, profileID: profileID, after: first.id)
                helper = try c.store.openTab(url: base + "/start", inSpace: space.id).id
                c.profiles.whenLoaded(profileID, { [self] _ in
                    c.reloadAll(animated: false)
                    c.switchToSpace(space.id, animated: false)
                    c.show(helper, focus: false)
                    done()
                }, failed: { self.check(false, "l04 (\(tag)): the test profile loads"); done() })
            } catch {
                check(false, "l04 (\(tag)): setup (\(error))")
                done()
            }
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: helper)?.title.contains("L04 fixture") == true }, timeout: 10) { done() } }

        // MARK: Folder access (the Desktop stand-in), then a Capture and two downloads
        run { [self] in
            check(sources.states[.desktop] ?? .notGranted == .notGranted, "l04 (\(tag)) folders: nothing is read before the folder is allowed")
            sources.requestAccess(.desktop, for: c.window)
        }
        step { done in self.waitUntil({ sources.files.count == 3 }, timeout: 4) { done() } }
        run { [self] in
            check(sources.settings.grant(.desktop) != nil && names(sources.files) == ["pier.jpg", "sunset.png", "trip.mov"],
                  "l04 (\(tag)) folders: Allow keeps a bookmark and the folder's pictures and videos show, not its text file (\(names(sources.files)))")
            files.recordCapture(captureURL, isPrivate: false)
        }
        wait(1.1)   // the downloads are newer than the Capture
        func download(_ path: String) {
            run { [self] in c.engineTab(for: helper)?.load(URL(string: base + path)!) }
            step { [self] done in
                waitUntil({ finished(path) }, timeout: 10) {
                    self.check(finished(path), "l04 (\(tag)): \(path) downloads into the scratch folder")
                    done()
                }
            }
            wait(1.1)
        }
        download("/photo.png")
        download("/notes.txt")
        run { [self] in c.engineTab(for: helper)?.load(URL(string: base + "/start")!) }
        wait(0.4)

        // MARK: The grid: contents, order, Arc's buckets
        let all = ["photo.png", "L04 Capture.png", "pier.jpg", "sunset.png", "trip.mov"]
        run { [self] in
            if c.library == nil { c.toggleLibrary() }
            c.library?.model.section = .media
        }
        wait(0.7)
        step { done in files.refresh(done) }
        wait(0.3)
        run { [self] in
            check(names(files.media) == all, "l04 (\(tag)) grid: downloads, the Capture and the folder's media in one grid, newest first (\(names(files.media)))")
            let titles = LibraryMedia.buckets(files.media).map(\.title)
            let onScreen = titles.filter { t in c.library.flatMap { TestAnchors.view("library.media.day.\(t)", in: $0) } != nil }
            check(titles.prefix(2) == ["Today", "Yesterday"] && titles.count == 3 && !["Today", "Yesterday", "Earlier This Week"].contains(titles[2])
                  && onScreen == titles,
                  "l04 (\(tag)) grid: Arc's sections, Today, Yesterday, then the month, on screen (\(titles), shown \(onScreen))")
        }
        capture("l04-media")

        // MARK: Filters
        let cases: [(LibraryMedia.Filter, [String])] = [(.images, ["photo.png", "L04 Capture.png", "pier.jpg", "sunset.png"]),
                                                       (.videos, ["trip.mov"]), (.captures, ["L04 Capture.png"])]
        for (f, want) in cases {
            run { files.filter = f }
            wait(0.4)
            run { [self] in
                let tiles = LibraryMediaView.rendered
                check(tiles == want && LibraryMedia.filtered(files.media, by: files.filter).map(\.name) == want,
                      "l04 (\(tag)) filter: \(f.title) shows only \(want) (tiles \(tiles))")
            }
        }
        run { files.filter = .images }
        wait(0.4)
        capture("l04-filter-images")
        realClick("library.media.removeFilter", tag: tag, what: "the filter chip's Remove Images Filter")
        wait(0.4)
        run { [self] in
            check(files.filter == nil, "l04 (\(tag)) filter [real click]: Remove Images Filter shows everything again (filter \(files.filter?.title ?? "none"))")
            files.filter = nil
        }
        wait(0.3)

        // MARK: Quick Look on a click and on Space; Delete and ⌘Z
        func panelFile() -> String? {
            guard QLPreviewPanel.sharedPreviewPanelExists(), let p = QLPreviewPanel.shared(), p.isVisible else { return nil }
            return (p.currentPreviewItem as? NSURL)?.lastPathComponent
        }
        realClick("library.media.pier.jpg", tag: tag, what: "a tile")
        step { done in self.waitUntil({ panelFile() == "pier.jpg" }, timeout: 3) { done() } }
        run { [self] in
            check(panelFile() == "pier.jpg" && files.selected?.name == "pier.jpg",
                  "l04 (\(tag)) Quick Look [real click]: a click on a tile shows it in Quick Look, and selects it (\(panelFile() ?? "no panel"))")
        }
        realKey("space", tag: tag)
        step { done in self.waitUntil({ panelFile() == nil }, timeout: 3) { done() } }
        run { [self] in
            check(panelFile() == nil, "l04 (\(tag)) Quick Look [real key]: Space closes it (\(panelFile() ?? "closed"))")
            // The window and the Library's host take the keys again.
            c.window.makeKeyAndOrderFront(nil)
            if let h = c.library { c.window.makeFirstResponder(h) }
        }
        wait(0.3)
        realKey("space", tag: tag)
        step { done in self.waitUntil({ panelFile() == "pier.jpg" }, timeout: 3) { done() } }
        run { [self] in
            check(panelFile() == "pier.jpg", "l04 (\(tag)) Quick Look [real key]: Space opens it again on the selected tile (\(panelFile() ?? "no panel"))")
            LibraryQuickLook.shared.close()
            c.window.makeKeyAndOrderFront(nil)
            if let h = c.library { c.window.makeFirstResponder(h) }
        }
        wait(0.4)
        realKey("delete", tag: tag)
        step { done in self.waitUntil({ media("pier.jpg") == nil && files.trashed != nil }, timeout: 3) { done() } }
        run { [self] in
            check(media("pier.jpg") == nil && fm.fileExists(atPath: trash.appendingPathComponent("pier.jpg").path) && files.trashed?.file.name == "pier.jpg",
                  "l04 (\(tag)) Delete [real key]: the selected tile goes to the Trash (\(names(files.media)))")
            check(c.window.firstResponder === c.library, "l04 (\(tag)) Delete: the Library keeps the keyboard (\(c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"))")
        }
        capture("l04-media-trashed")
        run { [self] in
            let r = c.window.firstResponder
            let tv = r as? NSTextView
            note("l04 (\(tag)) before ⌘Z in Media: responder \(r.map { String(describing: type(of: $0)) } ?? "nil"), field editor \(tv?.isFieldEditor ?? false), delegate \(tv?.delegate.map { String(describing: type(of: $0)) } ?? "-"), in \(tv?.superview?.superview.map { String(describing: type(of: $0)) } ?? "-")")
        }
        realKey("cmd+z", tag: tag)
        step { done in self.waitUntil({ media("pier.jpg") != nil }, timeout: 3) { done() } }
        run { [self] in
            check(names(files.media) == all && fm.fileExists(atPath: desktop.appendingPathComponent("pier.jpg").path) && files.trashed == nil,
                  "l04 (\(tag)) ⌘Z [real key]: puts it back where it was, in its place in the grid (\(names(files.media)); undo calls \(files.undoCalls), error \(files.lastUndoError ?? "none"), trashed \(files.trashed?.file.name ?? "none"), toast \(c.toast.shownText ?? "none"), responder \(c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"), key \(c.window.isKeyWindow)))")
        }

        // MARK: Drag a tile out to another window
        run { [self] in
            drop = L04DropWindow(beside: c.window)
            drop?.orderFront(nil)
        }
        wait(0.4)
        l04DragOut("library.media.sunset.png", drop: { drop }, tag: tag, what: "drag out [real drag]: a tile dragged to another window drops its file",
                   expect: { $0 == [desktop.appendingPathComponent("sunset.png").path] }, before: nil, host: nil)
        run { [self] in
            drop?.target.dropped.removeAll()
            c.toggleLibrary()
        }
        wait(0.7)

        // MARK: The Library button's recent files
        func showCard(_ then: @escaping () -> Void) {
            hoverLibraryButton(false)
            hover().hide()
            hoverLibraryButton(true)
            waitUntil({ hover().isShowing }, timeout: RecentFilesHover.dwell + 1.5) { then() }
        }
        step { done in showCard(done) }
        run { [self] in
            check(names(hover().shownFiles) == ["notes.txt", "photo.png", "L04 Capture.png", "pier.jpg", "sunset.png"],
                  "l04 (\(tag)) hover: the five newest of downloads, Captures and the folder's media (\(names(hover().shownFiles)))")
        }
        wait(0.3)
        capture("l04-recent")
        run { [self] in
            let menu = hover().sourcesMenu()
            check(hover().lastSourcesMenu == ["Show media from:", "✓Captures", "✓Downloads", "✓Media", "", "Open Library"] && !hover().isShowing,
                  "l04 (\(tag)) hover menu: the Library button's right-click is Arc's Show media from: (\(hover().lastSourcesMenu))")
            menu.performActionForItem(at: 3)   // Media off
        }
        step { done in showCard(done) }
        run { [self] in
            check(names(hover().shownFiles) == ["notes.txt", "photo.png", "L04 Capture.png"] && sources.settings.hover.media == false,
                  "l04 (\(tag)) hover menu: Media off leaves downloads and Captures (\(names(hover().shownFiles)))")
            hover().sourcesMenu().performActionForItem(at: 3)   // Media on
            hover().sourcesMenu().performActionForItem(at: 2)   // Downloads off
        }
        step { done in showCard(done) }
        run { [self] in
            check(names(hover().shownFiles) == ["L04 Capture.png", "pier.jpg", "sunset.png", "trip.mov"],
                  "l04 (\(tag)) hover menu: Downloads off leaves Captures and the folder's media (\(names(hover().shownFiles)))")
            hover().sourcesMenu().performActionForItem(at: 1)   // Captures off
            hover().sourcesMenu().performActionForItem(at: 3)   // Media off
            hoverLibraryButton(false)
            hover().hide()
            hoverLibraryButton(true)
        }
        wait(RecentFilesHover.dwell + 0.5)
        step { done in files.refresh(done) }
        run { [self] in
            check(!hover().isShowing && hover().lastRefusal == "no recent files", "l04 (\(tag)) hover menu: everything off, no card (\(hover().lastRefusal ?? "shown"))")
            var s = sources.settings
            s.hover = .init()
            sources.settings = s
        }
        step { done in showCard(done) }
        run { [self] in
            guard let f = hover().shownFiles.first(where: { $0.name == "photo.png" }) else { return check(false, "l04 (\(tag)) hover: photo.png listed") }
            hover().testPerform(.showInFinder, f)
            check(revealed.last == "photo.png" && !hover().isShowing, "l04 (\(tag)) hover row [hook]: Show in Finder (\(revealed.last ?? "-"))")
        }
        step { done in showCard(done) }
        run { [self] in
            guard let f = hover().shownFiles.first(where: { $0.name == "photo.png" }) else { return }
            hover().testPerform(.airDrop, f)
            check(shared.last == "\(NSSharingService.Name.sendViaAirDrop.rawValue):photo.png", "l04 (\(tag)) hover row [hook]: AirDrop sends the file (\(shared.last ?? "-"))")
        }
        step { done in showCard(done) }
        run { [self] in
            guard let f = hover().shownFiles.first(where: { $0.name == "photo.png" }) else { return }
            hover().testPerform(.iMessage, f)
            check(shared.last == "\(NSSharingService.Name.composeMessage.rawValue):photo.png", "l04 (\(tag)) hover row [hook]: Send via iMessage (\(shared.last ?? "-"))")
        }
        step { done in showCard(done) }
        run { [self] in
            guard let f = hover().shownFiles.first(where: { $0.name == "notes.txt" }) else { return check(false, "l04 (\(tag)) hover: notes.txt listed") }
            hover().testPerform(.trash, f)
        }
        step { done in self.waitUntil({ hover().shownFiles.first?.name == "photo.png" }, timeout: 3) { done() } }
        run { [self] in
            check(hover().shownFiles.first?.name == "photo.png" && fm.fileExists(atPath: trash.appendingPathComponent("notes.txt").path)
                  && c.toast.shownText == "Moved “notes.txt” to the Trash. ⌘Z to undo." && c.toast.actionButton?.title == "Undo",
                  "l04 (\(tag)) hover row [hook]: Move to Trash takes it off the card, with ⌘Z in the toast (\(c.toast.shownText ?? "no toast"))")
            hoverLibraryButton(false)
            hover().hide()
            c.window.makeKeyAndOrderFront(nil)
            c.window.makeFirstResponder(nil)
        }
        realKey("cmd+z", tag: tag)
        step { done in self.waitUntil({ fm.fileExists(atPath: downloads.appendingPathComponent("notes.txt").path) }, timeout: 3) { done() } }
        step { done in files.refresh(done) }
        run { [self] in
            check(fm.fileExists(atPath: downloads.appendingPathComponent("notes.txt").path) && files.recent.first?.name == "notes.txt",
                  "l04 (\(tag)) hover ⌘Z [real key]: the file comes back, first on the card again (\(names(files.recent)); undo calls \(files.undoCalls), error \(files.lastUndoError ?? "none"), trashed \(files.trashed?.file.name ?? "none"), toast \(c.toast.shownText ?? "none"), responder \(c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"), key \(c.window.isKeyWindow)))")
        }

        // ⌘Z while typing in a page after a hover trash: the page's text undoes, the file stays in the Trash; the toast's
        // Undo (a real click) puts it back.
        func pageValue(_ then: @escaping (String?) -> Void) {
            guard let tab = c.engineTab(for: helper) else { return then(nil) }
            tab.evaluate("document.getElementById('t') ? document.getElementById('t').value : null") { v in
                DispatchQueue.main.async { then(v as? String) }
            }
        }
        var typed: String?
        run { [self] in c.engineTab(for: helper)?.load(URL(string: base + "/edit")!) }
        step { [self] done in waitUntil({ self.c.engineTab(for: helper)?.title == "L04 edit" && self.c.engineTab(for: helper)?.isLoading == false }, timeout: 8) { done() } }
        step { done in showCard(done) }
        run { [self] in
            guard let f = hover().shownFiles.first(where: { $0.name == "notes.txt" }) else { return check(false, "l04 (\(tag)) typing: notes.txt listed") }
            hover().testPerform(.trash, f)
        }
        step { [self] done in waitUntil({ self.c.toast.actionButton != nil && files.trashed?.file.name == "notes.txt" }, timeout: 3) { done() } }
        run { [self] in
            hoverLibraryButton(false)
            hover().hide()
            c.window.makeKeyAndOrderFront(nil)
            c.show(helper, focus: true)
            c.engineTab(for: helper)?.evaluate("document.getElementById('t').focus()", completion: nil)
        }
        wait(0.4)
        realKey("a", tag: tag)
        realKey("b", tag: tag)
        wait(0.3)
        step { done in pageValue { typed = $0; done() } }
        realKey("cmd+z", tag: tag)
        wait(0.8)
        step { [self] done in
            pageValue { after in
                self.check(typed == "ab" && after != nil && after != "ab"
                           && fm.fileExists(atPath: trash.appendingPathComponent("notes.txt").path) && files.trashed?.file.name == "notes.txt",
                           "l04 (\(tag)) typing ⌘Z [real keys]: in a page's text area ⌘Z undoes the typing and the file stays in the Trash (typed \(typed ?? "nil"), after ⌘Z \(after ?? "nil"), trashed \(files.trashed?.file.name ?? "none"), toast \(self.c.toast.shownText ?? "none"))")
                done()
            }
        }
        step { [self] done in
            guard let b = c.toast.actionButton, let w = b.window, !c.toast.isHidden, let main = NSScreen.screens.first else {
                check(false, "l04 (\(tag)) toast Undo: the toast and its Undo are still up (\(c.toast.shownText ?? "no toast"))")
                return done()
            }
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            let mid = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
            let hit = w.contentView?.superview?.hitTest(mid) ?? w.contentView?.hitTest(mid)
            note("l04 (\(tag)) toast Undo: the button's centre hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
            l04Drive(["--click", "\(r.midX.rounded())", "\((main.frame.maxY - r.midY).rounded())"]) { ok, text in
                if !ok { self.note("FAIL-ENV l04 (\(tag)) [real click] the toast's Undo: the driver refused (\(text))") }
                done()
            }
        }
        step { done in self.waitUntil({ fm.fileExists(atPath: downloads.appendingPathComponent("notes.txt").path) }, timeout: 3) { done() } }
        run { [self] in
            check(fm.fileExists(atPath: downloads.appendingPathComponent("notes.txt").path) && files.trashed == nil && c.toast.isHidden,
                  "l04 (\(tag)) toast Undo [real click]: puts the file back and the toast goes (trashed \(files.trashed?.file.name ?? "none"))")
            c.engineTab(for: helper)?.load(URL(string: base + "/start")!)
        }
        wait(0.5)

        // A real drag of a row to the other window (in front again: the browser window came forward for ⌘Z).
        run { drop?.orderFront(nil) }
        l04DragOut("library.recent.photo.png", drop: { drop }, tag: tag, what: "hover drag out [real drag]: a row dragged to another window drops its file",
                   expect: { $0.count == 1 && ($0.first as NSString?)?.lastPathComponent == "photo.png" && ($0.first.map { $0.hasPrefix(downloads.path) } ?? false) },
                   before: { done in showCard { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done) } }, host: { hover().card })
        run { [self] in
            hoverLibraryButton(false)
            hover().hide()
            drop?.close()
            drop = nil
        }

        // MARK: Folder removed
        run { sources.forget(.desktop) }
        step { done in self.waitUntil({ media("sunset.png") == nil }, timeout: 3) { done() } }
        step { done in files.refresh(done) }
        run { [self] in
            check(sources.settings.grant(.desktop) == nil && names(files.media) == ["photo.png", "L04 Capture.png"]
                  && !names(files.recent).contains("pier.jpg") && fm.fileExists(atPath: desktop.appendingPathComponent("pier.jpg").path),
                  "l04 (\(tag)) folders: Stop Showing drops the grant and its files from the grid and the card, the files stay (\(names(files.media)))")
            LibraryFolderSources.testPanel = nil
            LibraryFolderSources.testDefaultURL = nil
            LibraryFiles.share = nil
            server?.stop()
        }
    }

    // MARK: Real input through the stable UI driver

    /// The driver, in the account's real home (the stable service the owner granted), never the test profile's.
    static var l04Driver: String {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + "/arcfork/tools/airc-ui-driver/airc-ui-driver"
    }

    /// Runs the driver off the main thread (the app keeps handling the events it posts); `done` on the main thread.
    func l04Drive(_ args: [String], _ done: @escaping (Bool, String) -> Void) {
        let path = Self.l04Driver
        DispatchQueue.global(qos: .userInitiated).async {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                return DispatchQueue.main.async { done(false, "no driver at the stable path") }
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CFFIXED_USER_HOME")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            do { try p.run() } catch { return DispatchQueue.main.async { done(false, "\(error)") } }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
            p.waitUntilExit()
            killer.cancel()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { done(p.terminationStatus == 0, text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    /// Quartz global coordinates (top left of the main display) of an anchor's centre.
    private func l04Point(_ name: String, in host: NSView) -> CGPoint? {
        guard let v = TestAnchors.view(name, in: host), let w = v.window else { return nil }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        guard let main = NSScreen.screens.first else { return nil }
        return CGPoint(x: r.midX.rounded(), y: (main.frame.maxY - r.midY).rounded())
    }

    func realClick(_ anchor: String, tag: String, what: String) {
        step { [self] done in
            let host: NSView = (c.library as NSView?) ?? c.root
            guard let p = l04Point(anchor, in: host) else {
                check(false, "l04 (\(tag)) [real click]: \(what) is on screen (\(anchor))")
                return done()
            }
            l04Drive(["--click", "\(p.x)", "\(p.y)"]) { ok, text in
                if !ok { self.note("FAIL-ENV l04 (\(tag)) [real click] \(what): the driver refused (\(text))") }
                done()
            }
        }
    }

    /// Plain keys go to the app's process; a ⌘ shortcut goes through the HID event stream (as a person's would), and
    /// only when Airc is the frontmost app with its window key: otherwise FAIL-ENV.
    func realKey(_ combo: String, tag: String) {
        step { [self] done in
            // The driver presses key positions; the build Mac's layout isn't US (Austrian: ANSI Z types "y"). A letter
            // goes as the key that types it in the current layout, so ⌘Z is the key macOS reads as ⌘Z.
            var parts = combo.split(separator: "+").map(String.init)
            if let last = parts.last, last.count == 1, last.first?.isLetter == true {
                guard let k = UIDriverClient.keys(typing: last)?.first, !k.contains("+") else {
                    note("FAIL-ENV l04 (\(tag)) [real key] \(combo): no key types “\(last)” in \(UIDriverClient.layoutName)")
                    return done()
                }
                parts[parts.count - 1] = k
            }
            let args = ["--key", parts.joined(separator: "+"), "--pid", "\(getpid())"]
            l04Drive(args) { ok, text in
                if !ok { self.note("FAIL-ENV l04 (\(tag)) [real key] \(combo): the driver refused (\(text))") }
                done()
            }
        }
    }

    /// A real drag to the drop window, tried twice. A drag the drop window saw arrive (entered) that never dropped,
    /// twice, is the driver's gesture (it lets go about 0.1 s after reaching the target): FAIL-ENV with that evidence.
    func l04DragOut(_ anchor: String, drop: @escaping () -> L04DropWindow?, tag: String, what: String,
                    expect: @escaping ([String]) -> Bool, before: ((@escaping () -> Void) -> Void)?, host: (() -> NSView?)?) {
        for attempt in 1...2 {
            step { [self] done in
                guard attempt == 1 || drop()?.target.dropped.isEmpty == true else { return done() }
                drop()?.orderFront(nil)
                if let before { before(done) } else { done() }
            }
            step { [self] done in
                guard attempt == 1 || drop()?.target.dropped.isEmpty == true else { return done() }
                note("l04 (\(tag)) \(what): attempt \(attempt)")
                done()
            }
            realDrag(anchor, to: drop, tag: tag, what: what, host: host, only: { attempt == 1 || drop()?.target.dropped.isEmpty == true })
            step { done in self.waitUntil({ drop()?.target.dropped.isEmpty == false }, timeout: 3) { done() } }
        }
        run { [self] in
            let t = drop()?.target
            let got = t?.dropped ?? []
            let evidence = "dropped \(got.map { ($0 as NSString).lastPathComponent }), drags started \(LibraryMediaView.dragsStarted), entered \(t?.entered ?? 0), performed \(t?.performed ?? 0), types \(t?.types ?? [])"
            if got.isEmpty, (t?.entered ?? 0) > 0, (t?.performed ?? 0) == 0 {
                note("FAIL-ENV l04 (\(tag)) \(what): the drag reached the drop window but the driver's gesture ended before a drop, twice (\(evidence))")
            } else {
                check(expect(got), "l04 (\(tag)) \(what) (\(evidence))")
            }
        }
    }

    func realDrag(_ anchor: String, to target: @escaping () -> L04DropWindow?, tag: String, what: String, host: (() -> NSView?)? = nil,
                  only: @escaping () -> Bool = { true }) {
        step { [self] done in
            guard only() else { return done() }
            let h: NSView = host?() ?? (c.library as NSView?) ?? c.root
            guard let from = l04Point(anchor, in: h), let w = target(), let main = NSScreen.screens.first else {
                check(false, "l04 (\(tag)) [real drag]: \(what) and the drop window are on screen (\(anchor))")
                return done()
            }
            let f = w.frame
            let to = CGPoint(x: f.midX.rounded(), y: (main.frame.maxY - f.midY).rounded())
            l04Drive(["--drag", "\(from.x)", "\(from.y)", "\(to.x)", "\(to.y)"]) { ok, text in
                if !ok { self.note("FAIL-ENV l04 (\(tag)) [real drag] \(what): the driver refused (\(text))") }
                done()
            }
        }
    }
}

/// "Another app" for the drag-out cases: a plain window of the check's own, at the normal level beside the browser
/// window's page, that takes file URLs and writes down what it got. Never above other apps' windows.
final class L04DropWindow: NSWindow {
    final class Target: NSView {
        var dropped: [String] = []
        var types: [String] = []
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.35).cgColor
            registerForDraggedTypes([.fileURL])
        }
        required init?(coder: NSCoder) { fatalError() }
        var entered = 0
        var performed = 0
        var mask: UInt = 0
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { entered += 1; return .copy }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            performed += 1
            mask = sender.draggingSourceOperationMask.rawValue
            let pb = sender.draggingPasteboard
            types = pb.types?.map(\.rawValue) ?? []
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            dropped += urls.map(\.path)
            return !urls.isEmpty
        }
    }

    let target = Target(frame: NSRect(x: 0, y: 0, width: 240, height: 240))

    init(beside w: NSWindow) {
        let f = w.frame
        let rect = NSRect(x: f.maxX - 300, y: f.midY - 120, width: 240, height: 240)
        super.init(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        title = "L04 drop target"
        isReleasedWhenClosed = false
        contentView = target
    }
}
#endif

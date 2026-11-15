// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script paritytidydl` (tidydl, audit A04, docs/user/ai.md › Tidy downloads), both engines: Arc's Tidy Downloads,
/// Settings → AI → Rename automatically. Synthetic downloads (a PDF, a PNG, a CSV and a ZIP) from a loopback page
/// server go to a scratch folder in the run's data folder (never ~/Downloads); the namer is a stub
/// (`ScriptedFileNameModel`: fixed names), so nothing depends on Apple Intelligence on the build Mac. Without Apple
/// Intelligence the switch stays off. Off, a download gets a suggestion and keeps its name; on, the PDF, the PNG and the
/// CSV are renamed by themselves, keep their extension, show "Renamed to “…”" with Undo, a taken name gets a number,
/// and the Downloads list shows the old name; Undo puts the original name back; a ZIP isn't renamed; a file open in
/// another process or just written counts as busy; a private window's download is never renamed. Last it notes whether
/// the real on-device model is there and, if so, names the PDF with it (never renaming anything).
extension SnapshotRunner {
    @MainActor func parityTidyDownloadsScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = "paritytidydl (\(chromium ? "chromium" : "webkit"))"
        let ai = AIFeatures.shared
        let fake = ScriptedFileNameModel()
        fake.answers["IMG_2041"] = "Lisbon itinerary"
        fake.answers["image"] = "Lisbon viewpoint"
        fake.answers["export-"] = "Quarterly sales"
        let scratch = AppPaths.dataDirectory.appendingPathComponent("paritytidydl-files", isDirectory: true)
        var server: LocalPageServer?
        var port: UInt16 = 0
        var trip: String?
        var privateWindow: PrivateWindowController?
        var autoLog: [(String, String)] = []
        var undoneKey = "", undoneOriginal = ""
        func center() -> DownloadCenter? { MediaLibrary.shared.downloads }
        func page() -> EngineTab? { trip.flatMap { c.engineTab(for: $0) } }
        func fm() -> FileManager { FileManager.default }
        func exists(_ name: String) -> Bool { fm().fileExists(atPath: scratch.appendingPathComponent(name).path) }
        func finished(_ path: String) -> [DownloadCenter.Item] {
            center()?.items.filter { URL(string: $0.download.url)?.path == path && $0.download.state == .complete } ?? []
        }
        func toast() -> ToastView? { center().flatMap { TidyDownloadsFeature.toastController($0) }?.toast }
        /// The page (loaded again first: Chromium blocks a page's second download without a gesture) asks for `path`.
        func download(_ path: String, from pagePath: String = "/trip.html", title: String = "Lisbon") {
            run { [self] in if let u = URL(string: "http://127.0.0.1:\(port)\(pagePath)") { page()?.load(u) } }
            step { [self] done in waitUntil({ page().map { !$0.isLoading && $0.title.hasPrefix(title) } ?? false }, timeout: 10) { done() } }
            wait(0.3)
            run { page()?.evaluate("location.href = '\(path)'; true", completion: nil) }
        }

        run { [self] in note("\(tag): environment at the start: \(aiEnvironment.line)") }
        step { [self] done in
            try? fm().removeItem(at: scratch)
            try? fm().createDirectory(at: scratch, withIntermediateDirectories: true)
            DownloadCenter.finishedLinger = 1
            DownloadCenter.interceptOpen = { _ in true }
            DownloadCenter.reveal = { _ in }
            WebKitLibrary.directoryOverride = scratch
            WebKitLibrary.opener = { _ in }
            TidyDownloadsFeature.autoLog = { autoLog.append(($0, $1)) }
            ai.testOverride = (.notEnabled, nil)
            ai.testModels = .init(downloads: fake)
            func file(_ name: String, _ type: String, _ data: Data) -> LocalPageServer.Page {
                LocalPageServer.Page(headers: ["Content-Type": type, "Content-Disposition": "attachment; filename=\"\(name)\""], body: "", data: data)
            }
            let style = "<style>body{font:17px/1.5 -apple-system,sans-serif;max-width:680px;margin:48px auto;color:#222}</style>"
            server = LocalPageServer(responses: [
                "/trip.html": LocalPageServer.Page(body: """
                    <!doctype html><meta charset="utf-8"><title>Lisbon in three days – Example Travel</title>\(style)
                    <h1>Lisbon in three days</h1><p>Your itinerary, a photo from the viewpoint and the maps.</p>
                    """),
                "/report.html": LocalPageServer.Page(body: """
                    <!doctype html><meta charset="utf-8"><title>Quarterly sales report – Example Corp</title>\(style)
                    <h1>Quarterly sales</h1><p>Download the figures as CSV.</p>
                    """),
                "/dl/pdf": file("IMG_2041 (1).pdf", "application/pdf", Self.itineraryPDF()),
                "/dl/png": file("image.png", "image/png", Self.tidyPNG()),
                "/dl/csv": file("export-20261107.csv", "text/csv", Data("Region,Quarterly sales\nNorth,120\nSouth,95\n".utf8)),
                "/dl/zip": file("IMG_2041.zip", "application/zip", Self.tidyZip()),
            ])
            server?.start { [self] p in
                guard let p else { aiCheck(false, "\(tag): the loopback page server starts"); return finish() }
                port = p
                do {
                    let first = c.store.selectedSpace
                    var profileID = first.profileID
                    if chromium {
                        // A profile of its own, whose folder gets the scratch download folder before it loads.
                        let profile = try c.store.createProfile(name: "Tidy downloads test")
                        let folder = Self.chromiumUserData.appendingPathComponent(profile.engineDirectory, isDirectory: true)
                        try fm().createDirectory(at: folder, withIntermediateDirectories: true)
                        let prefs = ["download": ["default_directory": scratch.path, "prompt_for_download": false, "directory_upgrade": true],
                                     "savefile": ["default_directory": scratch.path]]
                        try JSONSerialization.data(withJSONObject: prefs).write(to: folder.appendingPathComponent("Preferences"))
                        profileID = profile.id
                    }
                    let space = try c.store.createSpace(name: "Trips", icon: nil, theme: first.theme, profileID: profileID, after: first.id)
                    trip = try c.store.openTab(url: "http://127.0.0.1:\(p)/trip.html", inSpace: space.id).id
                    c.profiles.whenLoaded(profileID, { [self] _ in
                        c.reloadAll(animated: false)
                        c.switchToSpace(space.id, animated: false)
                        if let trip { c.show(trip, focus: false) }
                        done()
                    }, failed: { [self] in aiCheck(false, "\(tag): the test profile loads"); done() })
                } catch {
                    aiCheck(false, "\(tag): setup (\(error))")
                    done()
                }
            }
        }
        step { [self] done in waitUntil({ page().map { !$0.isLoading && $0.title.hasPrefix("Lisbon") } ?? false }, timeout: 12) { done() } }

        // 1. The switch: off by default, and unavailable without Apple Intelligence.
        run { [self] in
            guard let s = app?.settings else { return aiCheck(false, "\(tag): settings") }
            aiCheck(!s.values.tidyDownloadsAuto, "\(tag): Rename automatically is off by default")
            ai.setTidyDownloads(true, settings: s)
            ai.setTidyDownloadsAuto(true, settings: s)
            aiCheck(!s.values.tidyDownloads && !s.values.tidyDownloadsAuto,
                    "\(tag): without Apple Intelligence neither switch turns on (\(ai.availability.detail))")
            ai.testOverride = (.available, nil)
            ai.setTidyDownloads(true, settings: s)
            aiCheck(s.values.tidyDownloads && !s.values.tidyDownloadsAuto, "\(tag): Tidy downloads on, Rename automatically still off")
        }

        // 2. Off: the PDF gets a suggestion and keeps its name.
        download("/dl/pdf")
        step { [self] done in waitUntil({ finished("/dl/pdf").first.flatMap(TidyDownloadsFeature.suggestion) != nil }, timeout: 20) { done() } }
        wait(3)
        run { [self] in
            let item = finished("/dl/pdf").first
            aiCheck(item.flatMap(TidyDownloadsFeature.suggestion) == "Lisbon itinerary.pdf" && !exists("Lisbon itinerary.pdf")
                    && fm().fileExists(atPath: item?.download.path ?? "/nonexistent") && toast()?.shownText == nil && autoLog.isEmpty,
                    "\(tag): Rename automatically off: \"\(item?.download.fileName ?? "?")\" gets a suggestion, keeps its name, no toast")
            if let s = app?.settings { ai.setTidyDownloadsAuto(true, settings: s) }
            aiCheck(app?.settings.values.tidyDownloadsAuto == true, "\(tag): Settings → AI turns Rename automatically on")
        }
        wait(2)
        run { [self] in
            aiCheck(!exists("Lisbon itinerary.pdf") && finished("/dl/pdf").first.flatMap(TidyDownloadsFeature.suggestion) != nil,
                    "\(tag): turning it on doesn't rename a download that finished before")
        }

        // 3. On: the PNG, the CSV and the PDF are renamed by themselves, with the toast.
        download("/dl/png")
        step { [self] done in waitUntil({ exists("Lisbon viewpoint.png") }, timeout: 20) { done() } }
        wait(0.4)   // the list publishes at most ten times a second
        run { [self] in
            let item = finished("/dl/png").first
            aiCheck(exists("Lisbon viewpoint.png") && !exists("image.png") && item?.download.fileName == "Lisbon viewpoint.png",
                    "\(tag): on, \"image.png\" becomes \"\(item?.download.fileName ?? "?")\" by itself, in the same folder")
            aiCheck(toast()?.shownText == "Renamed to “Lisbon viewpoint.png”" && toast()?.actionButton?.title == "Undo"
                    && center().flatMap { TidyDownloadsFeature.toastController($0) } === c,
                    "\(tag): the window shows “\(toast()?.shownText ?? "no toast")” with \(toast()?.actionButton?.title ?? "no action")")
            note("\(tag): the PNG's rename attempts: \(autoLog.map(\.1).joined(separator: ", "))")
        }
        capture("paritytidydl-toast")
        download("/dl/csv", from: "/report.html", title: "Quarterly")
        step { [self] done in waitUntil({ exists("Quarterly sales.csv") }, timeout: 20) { done() } }
        wait(0.4)   // the list publishes at most ten times a second
        run { [self] in
            aiCheck(exists("Quarterly sales.csv") && !exists("export-20261107.csv") && toast()?.shownText == "Renamed to “Quarterly sales.csv”",
                    "\(tag): \"export-20261107.csv\" becomes \"Quarterly sales.csv\" (the extension kept), “\(toast()?.shownText ?? "-")”")
        }
        download("/dl/pdf")
        step { [self] done in waitUntil({ exists("Lisbon itinerary.pdf") }, timeout: 20) { done() } }
        wait(0.4)   // the list publishes at most ten times a second
        run { [self] in
            let item = finished("/dl/pdf").first { $0.download.fileName == "Lisbon itinerary.pdf" }
            aiCheck(item != nil && item.flatMap(TidyDownloadsFeature.originalName)?.hasPrefix("IMG_2041") == true,
                    "\(tag): the PDF becomes \"Lisbon itinerary.pdf\" and the list remembers it was \"\(item.flatMap(TidyDownloadsFeature.originalName) ?? "-")\"")
        }
        // 4. A taken name gets a number; Undo puts the original name back.
        download("/dl/pdf")
        step { [self] done in waitUntil({ exists("Lisbon itinerary 2.pdf") }, timeout: 20) { done() } }
        wait(0.4)   // the list publishes at most ten times a second
        run { [self] in
            let item = finished("/dl/pdf").first { $0.download.fileName == "Lisbon itinerary 2.pdf" }
            undoneKey = item?.id ?? ""
            undoneOriginal = item.flatMap(TidyDownloadsFeature.originalName) ?? ""
            aiCheck(item != nil && toast()?.shownText == "Renamed to “Lisbon itinerary 2.pdf”",
                    "\(tag): with \"Lisbon itinerary.pdf\" taken, the next PDF becomes \"Lisbon itinerary 2.pdf\" (“\(toast()?.shownText ?? "-")”)")
            toast()?.actionButton?.performClick(nil)
        }
        wait(0.5)
        run { [self] in
            let item = center()?.item(undoneKey)
            aiCheck(!undoneOriginal.isEmpty && exists(undoneOriginal) && !exists("Lisbon itinerary 2.pdf")
                    && item?.download.fileName == undoneOriginal && item.flatMap(TidyDownloadsFeature.originalName) == nil
                    && TidyDownloadsFeature.record.entries[undoneKey] == nil && toast()?.shownText == "Download name reverted",
                    "\(tag): Undo puts back \"\(undoneOriginal)\" (list: \(item?.download.fileName ?? "-"), “\(toast()?.shownText ?? "-")”)")
            if let item, let c0 = center() { c0.open(item) }
            aiCheck(item.flatMap { center()?.file($0)?.lastPathComponent } == undoneOriginal,
                    "\(tag): after Undo, Open uses the original file (\(item.flatMap { center()?.file($0)?.lastPathComponent } ?? "-"))")
        }
        wait(2)
        run { [self] in
            aiCheck(exists(undoneOriginal) && !exists("Lisbon itinerary 2.pdf"), "\(tag): an undone file isn't renamed again")
        }

        // 5. Archives keep their name.
        download("/dl/zip")
        step { [self] done in waitUntil({ finished("/dl/zip").first.flatMap(TidyDownloadsFeature.suggestion) != nil }, timeout: 20) { done() } }
        wait(2)
        run { [self] in
            let item = finished("/dl/zip").first
            aiCheck(item?.download.fileName.hasPrefix("IMG_2041") == true && !exists("Lisbon itinerary.zip")
                    && autoLog.contains { $0.0 == item?.id && $0.1 == "skipped type" },
                    "\(tag): a ZIP keeps its name (\(item?.download.fileName ?? "?")); its suggestion stays for a click")
            // 6. Busy files: open in another process, or just written.
            let held = scratch.appendingPathComponent("held.txt")
            try? Data("held".utf8).write(to: held)
            aiCheck(TidyDownloadsFeature.fileBusy(held, quietPeriod: 1) == "being written", "\(tag): a file written a moment ago counts as being written")
            try? fm().setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: held.path)
            aiCheck(TidyDownloadsFeature.fileBusy(held, quietPeriod: 1) == nil, "\(tag): a quiet file nobody has open can be renamed")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["10"]
            p.standardInput = try? FileHandle(forReadingFrom: held)
            if (try? p.run()) != nil {
                usleep(300_000)
                let busy = TidyDownloadsFeature.fileBusy(held, quietPeriod: 1)
                aiCheck(busy == "open in another app", "\(tag): a file another process has open is left alone (\(busy ?? "free"))")
                p.terminate()
                p.waitUntilExit()
            } else {
                aiCheck(false, "\(tag): a helper process holds the file open")
            }
            try? fm().removeItem(at: held)
            c.showLibrary(.downloads)
        }
        wait(1)
        capture("paritytidydl-library")

        // 7. A private window's download is never renamed.
        run { [self] in
            if c.library != nil { c.toggleLibrary() }
            guard let app else { return }
            PrivateBrowsing.shared.open(app: app) { w in privateWindow = w }
        }
        step { [self] done in waitUntil({ privateWindow != nil }, timeout: 8) { done() } }
        run { privateWindow?.openPage(URL(string: "http://127.0.0.1:\(port)/trip.html")) }
        step { [self] done in waitUntil({ privateWindow?.shownPage.map { !$0.isLoading && $0.title.hasPrefix("Lisbon") } ?? false }, timeout: 10) { done() } }
        run { [self] in
            note("\(tag): \(fake.asked.count) requests before the private download")
            privateWindow?.shownPage?.evaluate("location.href = '/dl/png'; true", completion: nil)
        }
        wait(5)
        run { [self] in
            let asked = fake.asked.count, renamed = autoLog.filter { $0.1 == "renamed" }.count
            aiCheck(asked == 6 && renamed == 4 && (center()?.items.filter { URL(string: $0.download.url)?.path == "/dl/png" }.count ?? 0) == 1
                    && !exists("Lisbon viewpoint 2.png"),
                    "\(tag): a private window's download stays out of the list, the model and the renames (\(asked) requests, \(renamed) renames)")
            privateWindow?.closeWindow()
            // Off again: the next download keeps its name.
            if let s = app?.settings { ai.setTidyDownloadsAuto(false, settings: s) }
        }
        download("/dl/png")
        step { [self] done in waitUntil({ finished("/dl/png").count == 2 && finished("/dl/png").contains { TidyDownloadsFeature.suggestion(for: $0) != nil } }, timeout: 20) { done() } }
        wait(2)
        run { [self] in
            aiCheck(!exists("Lisbon viewpoint 2.png") && autoLog.filter { $0.1 == "renamed" }.count == 4,
                    "\(tag): turned off again, the next download keeps its name (\(finished("/dl/png").map(\.download.fileName).joined(separator: ", ")))")
        }

        // 8. The real on-device model: noted; when it's there, it names the PDF (nothing is renamed with it).
        step { [self] done in
            ai.testOverride = nil
            ai.testModels = nil
            guard let model = AppleIntelligence.fileNameModel() else {
                note("\(tag): real model ran: no (\(AppleIntelligence.availability.label)); every rename above used the stub namer")
                return done()
            }
            let pdf = scratch.appendingPathComponent("real-model-check.pdf")
            try? Self.itineraryPDF().write(to: pdf)
            let r = TidyDownloadPrompt.request(fileName: "IMG_2041 (1).pdf", pageTitle: "Lisbon in three days – Example Travel",
                                               pageURL: "https://travel.example/lisbon", fileText: TidyDownloadsFeature.fileText(pdf, mime: "application/pdf"))
            Task { @MainActor in
                let start = CACurrentMediaTime()
                let outcome = await AIDeadline.run(timeout: 20) { try await model.fileName(for: r) }
                let took = CACurrentMediaTime() - start
                if case .value(let answer) = outcome {
                    let shown = TidyDownloadRules.accept(answer, original: r.fileName, sources: [r.pageTitle, r.pageURL, r.fileText].joined(separator: " "))
                    self.note("\(tag): real model ran: yes, \"\(answer)\" → \(shown ?? "dropped") (" + String(format: "%.2f s)", took))
                } else {
                    self.note("\(tag): real model ran: yes, no name (\(outcome))")
                }
                try? FileManager.default.removeItem(at: pdf)
                done()
            }
        }
        run { [self] in
            note("\(tag): environment at the end: \(aiEnvironment.line)")
            if let s = app?.settings { ai.setTidyDownloads(false, settings: s) }
            server?.stop()
            DownloadCenter.interceptOpen = nil
            TidyDownloadsFeature.autoLog = { _, _ in }
        }
    }

    /// A small PNG (a 64 × 40 blue rectangle).
    static func tidyPNG() -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 40).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// An empty ZIP archive (its end-of-central-directory record only).
    static func tidyZip() -> Data {
        Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
    }
}
#endif

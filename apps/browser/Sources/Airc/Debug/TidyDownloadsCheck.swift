// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script tidydownloads` (docs/user/ai.md, Tidy Downloads), both engines, on a loopback travel page whose download
/// is a PDF called "IMG_2041 (1).pdf", with a fake namer (`ScriptedFileNameModel`). Downloads go to a scratch folder in
/// the run's data folder (never ~/Downloads); nothing opens in another app or in Finder. Off by default (a download
/// gets no suggestion); without Apple Intelligence the switch stays off; on, the finished PDF gets "Lisbon
/// itinerary.pdf", made from the page's title and address and the PDF's own text (PDFKit), shown in Library ›
/// Downloads with Rename; a clean name gets none; Rename moves the file in its folder, keeps ".pdf", and the list,
/// Open and Show in Finder follow it; a taken name gets a number; a private window's download never reaches the
/// model; off clears the suggestions and only `ai.tidy_downloads` on, off and used is recorded. Last, with Apple
/// Intelligence on, a timed real on-device suggestion for the same PDF (SKIP otherwise).
extension SnapshotRunner {
    @MainActor func tidyDownloadsScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = "tidydownloads (\(chromium ? "chromium" : "webkit"))"
        let ai = AIFeatures.shared
        let fake = ScriptedFileNameModel()
        fake.answers["IMG_2041"] = "Lisbon itinerary"
        fake.answers["scan0001"] = "Lisbon scan"
        let scratch = AppPaths.dataDirectory.appendingPathComponent("tidydownloads-files", isDirectory: true)
        var server: LocalPageServer?
        var port: UInt16 = 0
        var trip: String?
        var opened: [String] = []
        var revealed: [URL] = []
        var privateWindow: PrivateWindowController?
        var renamedID = ""
        var tripProfileID = "", firstProfileID = ""
        var logged: [String] = []
        func center() -> DownloadCenter? { MediaLibrary.shared.downloads }
        func page() -> EngineTab? { trip.flatMap { c.engineTab(for: $0) } }
        func finished(_ path: String) -> [DownloadCenter.Item] {
            center()?.items.filter { URL(string: $0.download.url)?.path == path && $0.download.state == .complete } ?? []
        }
        /// The page asks for `path` (a renderer navigation: the download's referrer is the page). The page is loaded
        /// again first, as the medialib check does: Chromium blocks a page's second download without a gesture.
        func download(_ path: String) {
            run { [self] in if let u = URL(string: "http://127.0.0.1:\(port)/trip.html") { page()?.load(u) } }
            step { [self] done in waitUntil({ page().map { !$0.isLoading && $0.title.hasPrefix("Lisbon") } ?? false }, timeout: 10) { done() } }
            wait(0.3)
            run { page()?.evaluate("location.href = '\(path)'; true", completion: nil) }
        }

        run { [self] in note("\(tag): environment at the start: \(aiEnvironment.line)") }
        step { [self] done in
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            DownloadCenter.finishedLinger = 1
            DownloadCenter.interceptOpen = { opened.append($0.download.fileName); return true }
            DownloadCenter.reveal = { revealed += $0 }
            WebKitLibrary.directoryOverride = scratch
            WebKitLibrary.opener = { opened.append($0.lastPathComponent) }
            ai.testOverride = (.notEnabled, nil)
            ai.testModels = .init(downloads: fake)
            let pdf = Self.itineraryPDF()
            func file(_ name: String, _ type: String, _ data: Data) -> LocalPageServer.Page {
                LocalPageServer.Page(headers: ["Content-Type": type, "Content-Disposition": "attachment; filename=\"\(name)\""], body: "", data: data)
            }
            let tripPage = """
                <!doctype html><meta charset="utf-8"><title>Lisbon in three days – Example Travel</title>
                <style>body{font:17px/1.5 -apple-system,sans-serif;max-width:680px;margin:48px auto;color:#222}</style>
                <h1>Lisbon in three days</h1><p>Download your itinerary and packing list below.</p>
                """
            server = LocalPageServer(responses: [
                "/trip.html": LocalPageServer.Page(body: tripPage),
                "/dl/first": file("scan0001.pdf", "application/pdf", pdf),
                "/dl/itinerary": file("IMG_2041 (1).pdf", "application/pdf", pdf),
                "/dl/notes": file("Lisbon packing list.txt", "text/plain", Data("Sun cream, walking shoes, a light jacket.".utf8)),
            ])
            server?.start { [self] p in
                guard let p else { aiCheck(false, "\(tag): the loopback page server starts"); return finish() }
                port = p
                do {
                    // Chromium: a profile of its own, whose folder gets the scratch download folder before it loads.
                    let first = c.store.selectedSpace
                    var profileID = first.profileID
                    firstProfileID = first.profileID
                    if chromium {
                        let profile = try c.store.createProfile(name: "Downloads test")
                        let folder = Self.chromiumUserData.appendingPathComponent(profile.engineDirectory, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let prefs = ["download": ["default_directory": scratch.path, "prompt_for_download": false, "directory_upgrade": true],
                                     "savefile": ["default_directory": scratch.path]]
                        try JSONSerialization.data(withJSONObject: prefs).write(to: folder.appendingPathComponent("Preferences"))
                        profileID = profile.id
                    }
                    tripProfileID = profileID
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

        // 1. Off by default: a finished download gets no suggestion.
        run { [self] in
            aiCheck(center() != nil && app?.settings.values.tidyDownloads == false, "\(tag): Tidy downloads is off by default (downloads: \(center() != nil))")
        }
        download("/dl/first")
        step { [self] done in waitUntil({ !finished("/dl/first").isEmpty }, timeout: 15) { done() } }
        wait(1)
        run { [self] in
            let first = finished("/dl/first").first
            aiCheck(first?.download.path?.hasPrefix(scratch.path) == true, "\(tag): downloads go to the run's scratch folder (\(first?.download.fileName ?? "none"))")
            aiCheck(fake.asked.isEmpty && first.flatMap(TidyDownloadsFeature.suggestion) == nil,
                  "\(tag): off, a finished download gets no suggestion and nothing is asked")
            // 2. Without Apple Intelligence the switch stays off; with it, on.
            if let s = app?.settings { ai.setTidyDownloads(true, settings: s) }
            aiCheck(app?.settings.values.tidyDownloads == false, "\(tag): without Apple Intelligence the switch stays off")
            ai.testOverride = (.available, nil)
            if let s = app?.settings { ai.setTidyDownloads(true, settings: s) }
            aiCheck(app?.settings.values.tidyDownloads == true && ai.lastToggleEvent == .featureUsed(.aiTidyDownloads(.on)),
                  "\(tag): with Apple Intelligence, Settings → AI turns Tidy downloads on")
        }
        download("/dl/itinerary")

        // 3. The PDF gets a suggestion from the page and its own text.
        step { [self] done in
            waitUntil({ finished("/dl/itinerary").first.flatMap(TidyDownloadsFeature.suggestion) != nil }, timeout: 20) { done() }
        }
        run { [self] in
            let item = finished("/dl/itinerary").first
            let r = fake.asked.first
            aiCheck(item.flatMap(TidyDownloadsFeature.suggestion) == "Lisbon itinerary.pdf",
                  "\(tag): the finished \"\(item?.download.fileName ?? "?")\" gets the suggestion \"\(item.flatMap(TidyDownloadsFeature.suggestion) ?? "none")\"")
            aiCheck(fake.asked.count == 1 && r?.fileName == item?.download.fileName && r?.pageTitle == "Lisbon in three days - Example Travel"
                  && r?.pageURL == "127.0.0.1/trip.html" && r?.fileText.contains("Your Lisbon itinerary") == true,
                  "\(tag): made from the page's title and address and the PDF's text (\"\(r?.pageTitle ?? "")\", \"\(r?.pageURL ?? "")\", "
                  + "\(r?.fileText.count ?? 0) characters of the PDF)")
            aiCheck(FileManager.default.fileExists(atPath: item?.download.path ?? "/nonexistent"),
                  "\(tag): nothing is renamed before Rename (\(item?.download.fileName ?? "?") is still there)")
            renamedID = item?.id ?? ""
            // The title comes from the download's own profile's page only (the AI-2 review's H1): asked as another
            // profile (on Chromium the first Space's, whose history has no such page), the trip page's title isn't used.
            if let app {
                let address = "http://127.0.0.1:\(port)/trip.html"
                let own = TidyDownloadsFeature.pageTitle(address, profileID: tripProfileID, app: app)
                let other = TidyDownloadsFeature.pageTitle(address, profileID: chromium ? firstProfileID : "another-profile", app: app)
                aiCheck(own == "Lisbon in three days – Example Travel" && other.isEmpty,
                        "\(tag): a download's page title comes from its own profile's pages only (\"\(own)\"; another profile: \"\(other)\")")
            }
        }
        download("/dl/notes")
        step { [self] done in waitUntil({ !finished("/dl/notes").isEmpty }, timeout: 15) { done() } }
        wait(1)
        run { [self] in
            aiCheck(fake.asked.count == 1 && finished("/dl/notes").first.flatMap(TidyDownloadsFeature.suggestion) == nil,
                  "\(tag): a file with a clean name (\(finished("/dl/notes").first?.download.fileName ?? "?")) gets no suggestion")
            c.showLibrary(.downloads)
        }
        wait(1)
        capture("tidydownloads-library")

        // 4. Rename: the file moves in its folder, keeps .pdf, and the list, Open and Show in Finder follow.
        run { [self] in
            guard let c0 = center(), let item = c0.item(renamedID) else { return aiCheck(false, "\(tag): the download is in the list") }
            let old = item.download.path ?? ""
            aiCheck(TidyDownloadsFeature.rename(item, center: c0), "\(tag): Rename is applied")
            let new = scratch.appendingPathComponent("Lisbon itinerary.pdf")
            aiCheck(FileManager.default.fileExists(atPath: new.path) && !FileManager.default.fileExists(atPath: old)
                  && c0.file(item)?.standardizedFileURL == new.standardizedFileURL && TidyDownloadsFeature.suggestion(for: item) == nil,
                  "\(tag): the file is now \"\(new.lastPathComponent)\" in the same folder (the old name is gone)")
            aiCheck(FileManager.default.fileExists(atPath: TidyDownloadsFeature.fileURL.path) && TidyDownloadsFeature.record.entries[renamedID]?.name == "Lisbon itinerary.pdf",
                  "\(tag): the rename is kept in TidyDownloads.json")
            aiCheck(ai.events.contains(.featureUsed(.aiTidyDownloads(.used))), "\(tag): Rename records feature.used ai.tidy_downloads used")
        }
        wait(0.5)
        run { [self] in
            guard let c0 = center(), let item = c0.item(renamedID) else { return }
            aiCheck(item.download.fileName == "Lisbon itinerary.pdf", "\(tag): the Downloads list shows \"\(item.download.fileName)\"")
            c0.open(item)
            c0.showInFinder(item)
            aiCheck(opened.last == "Lisbon itinerary.pdf" && revealed.last?.lastPathComponent == "Lisbon itinerary.pdf",
                  "\(tag): Open and Show in Finder use the new name (\(opened.last ?? "-"), \(revealed.last?.lastPathComponent ?? "-"))")
        }
        download("/dl/itinerary")
        capture("tidydownloads-renamed")

        // 5. A name that's taken gets a number.
        step { [self] done in
            waitUntil({ finished("/dl/itinerary").contains { $0.id != renamedID && TidyDownloadsFeature.suggestion(for: $0) != nil } }, timeout: 20) { done() }
        }
        run { [self] in
            guard let c0 = center(), let item = finished("/dl/itinerary").first(where: { $0.id != renamedID }) else {
                return aiCheck(false, "\(tag): the second download gets a suggestion")
            }
            // First a move that fails (the folder read-only): the log says so without a name or a path (the AI-2
            // review's H3; the new name is made from the page and the file).
            TidyDownloadsFeature.log = { logged.append($0) }
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.path)
            let failed = !TidyDownloadsFeature.rename(item, center: c0)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path)
            TidyDownloadsFeature.log = { NSLog("%@", $0) }
            let line = logged.joined(separator: "\n")
            let leaks = ["Lisbon", "itinerary", "IMG_2041", scratch.path, scratch.lastPathComponent, "/"].filter { line.contains($0) }
            aiCheck(failed && logged.count == 1 && line.hasPrefix("Airc: Tidy Downloads couldn't rename a file (NSCocoaErrorDomain ") && leaks.isEmpty
                    && TidyDownloadsFeature.suggestion(for: item) != nil,
                    "\(tag): a rename that fails logs no file name or path (\"\(line)\"\(leaks.isEmpty ? "" : ", leaks: \(leaks)")); the suggestion stays")
            aiCheck(TidyDownloadsFeature.rename(item, center: c0)
                  && FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Lisbon itinerary 2.pdf").path),
                  "\(tag): with \"Lisbon itinerary.pdf\" taken, the next one becomes \"Lisbon itinerary 2.pdf\"")
            guard let app else { return }
            PrivateBrowsing.shared.open(app: app) { w in privateWindow = w }
        }

        // 6. A private window's download never reaches the model.
        step { [self] done in waitUntil({ privateWindow != nil }, timeout: 8) { done() } }
        run { privateWindow?.openPage(URL(string: "http://127.0.0.1:\(port)/trip.html")) }
        step { [self] done in waitUntil({ privateWindow?.shownPage.map { !$0.isLoading && $0.title.hasPrefix("Lisbon") } ?? false }, timeout: 10) { done() } }
        run { privateWindow?.shownPage?.evaluate("location.href = '/dl/itinerary'; true", completion: nil) }
        wait(4)
        run { [self] in
            let asked = fake.asked.count
            aiCheck(asked == 2 && (center()?.items.filter { URL(string: $0.download.url)?.path == "/dl/itinerary" }.count ?? 0) == 2,
                  "\(tag): a private window's download stays out of the list and away from the model (\(asked) requests in all)")
            privateWindow?.closeWindow()
            // 6b. Clear Data and Delete Profile: the profile's renames and suggestions go (AIFeatures.forget, which both call).
            let renamedBefore = TidyDownloadsFeature.record.entries.keys.filter { $0.hasPrefix(tripProfileID + "/") }.count
            ai.forget(profileID: tripProfileID)
            aiCheck(renamedBefore == 2 && TidyDownloadsFeature.record.entries.keys.allSatisfy { !$0.hasPrefix(tripProfileID + "/") }
                    && !FileManager.default.fileExists(atPath: TidyDownloadsFeature.fileURL.path)
                    && ai.downloads.suggestions.keys.allSatisfy { !$0.hasPrefix(tripProfileID + "/") },
                    "\(tag): Clear Data and Delete Profile forget the profile's renames (\(renamedBefore) of them, TidyDownloads.json gone) and suggestions")
            // 7. Off: suggestions go.
            if let s = app?.settings { ai.setTidyDownloads(false, settings: s) }
            aiCheck(app?.settings.values.tidyDownloads == false && ai.downloads.suggestions.isEmpty && TidyDownloadsFeature.Model.shared.suggestions.isEmpty,
                  "\(tag): off, every suggestion goes")
            checkAIEvents(tag, ai.events, expect: ["ai.tidy_downloads:on", "ai.tidy_downloads:used", "ai.tidy_downloads:off"])
        }

        // 8. The real on-device model, when this Mac has Apple Intelligence on: the same PDF, timed.
        step { [self] done in
            ai.testOverride = nil
            ai.testModels = nil
            guard let model = AppleIntelligence.fileNameModel() else {
                skip("\(tag): real on-device run: this Mac's model is unavailable (\(AppleIntelligence.availability.label))")
                return done()
            }
            let pdf = scratch.appendingPathComponent("real-model-check.pdf")
            try? Self.itineraryPDF().write(to: pdf)
            let text = TidyDownloadsFeature.fileText(pdf, mime: "application/pdf")
            let r = TidyDownloadPrompt.request(fileName: "IMG_2041 (1).pdf", pageTitle: "Lisbon in three days – Example Travel",
                                               pageURL: "https://travel.example/lisbon", fileText: text)
            Task { @MainActor in
                let start = CACurrentMediaTime()
                let outcome = await AIDeadline.run(timeout: 20) { try await model.fileName(for: r) }
                let took = CACurrentMediaTime() - start
                if case .value(let answer) = outcome {
                    let shown = TidyDownloadRules.accept(answer, original: r.fileName, sources: [r.pageTitle, r.pageURL, r.fileText].joined(separator: " "))
                    self.check(shown != nil, "\(tag): the real on-device model named the PDF \"\(answer)\" → \(shown ?? "dropped") ("
                               + String(format: "%.2f s)", took))
                } else {
                    self.check(false, "\(tag): the real on-device model named the PDF (\(outcome))")
                }
                try? FileManager.default.removeItem(at: pdf)
                done()
            }
        }
        run { [self] in
            note("\(tag): environment at the end: \(aiEnvironment.line)")
            server?.stop()
            DownloadCenter.interceptOpen = nil
        }
    }

    /// A one-page PDF with real text ("Your Lisbon itinerary…"), drawn with Core Text so PDFKit can read it back.
    static func itineraryPDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return Data()
        }
        ctx.beginPDFPage(nil)
        let text = NSAttributedString(string: "Your Lisbon itinerary\n\nDay one: Alfama, the castle and the viewpoints.\nDay two: Belém, the monastery and the river.\nDay three: Sintra by train.",
                                      attributes: [.font: NSFont.systemFont(ofSize: 18)])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0),
                                             CGPath(rect: box.insetBy(dx: 60, dy: 80), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
#endif

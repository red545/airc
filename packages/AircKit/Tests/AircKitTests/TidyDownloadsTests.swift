// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import AircKit

/// A model that names files from a table (by file name), records its requests, and can hang ignoring cancellation.
final class FakeFileNameModel: TidyDownloadModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [TidyDownloadRequest] = []
    var answers: [String: String] = [:]
    var hang: Set<String> = []

    var asked: [TidyDownloadRequest] { lock.withLock { _asked } }

    func fileName(for r: TidyDownloadRequest) async throws -> String {
        lock.withLock { _asked.append(r) }
        if hang.contains(r.fileName) {
            let end = Date().addingTimeInterval(5)
            while Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        return answers[r.fileName] ?? "Something invented entirely"
    }
}

final class TidyDownloadRulesTests: XCTestCase {
    func testWhichNamesGetASuggestion() {
        for n in ["IMG_2041 (1).pdf", "document.pdf", "download", "file (3).pdf", "a8f3e9c1d2b4.pdf", "DSC01234.JPG",
                  "3f2504e0-4f89-11d3-9a0c-0305e82c3301.pdf", "Screenshot 2026-11-07 at 10.15.32.png", "report_final_v2.pdf",
                  "scan0001.pdf", "untitled.txt", "export-20261107.csv", "IMG2041.heic"] {
            XCTAssertTrue(TidyDownloadRules.needsTidy(n), n)
        }
        for n in ["Lisbon itinerary.pdf", "Invoice 8834.pdf", "2026-Q3-results.pdf", "lisbonTrip.pdf", "README.md",
                  "Quarterly report.pdf", "airc-0.1.2.dmg"] {
            XCTAssertFalse(TidyDownloadRules.needsTidy(n), n)
        }
    }

    func testTheExtensionIsSplitOff() {
        XCTAssertEqual(TidyDownloadRules.split("IMG_2041 (1).pdf").ext, "pdf")
        XCTAssertEqual(TidyDownloadRules.split("IMG_2041 (1).pdf").base, "IMG_2041 (1)")
        XCTAssertEqual(TidyDownloadRules.split("archive.tar.gz").ext, "tar.gz")
        XCTAssertEqual(TidyDownloadRules.split("archive.tar.gz").base, "archive")
        XCTAssertEqual(TidyDownloadRules.split("README").ext, "")
        XCTAssertEqual(TidyDownloadRules.split("notes.final version").ext, "", "a space isn't an extension")
        XCTAssertEqual(TidyDownloadRules.split(".hidden").ext, "")
    }

    func testIllegalCharactersAndLengths() {
        XCTAssertEqual(TidyDownloadRules.sanitize("a/b:c\\d*e?f\"g<h>i|j"), "a b c d e f g h i j")
        XCTAssertEqual(TidyDownloadRules.sanitize("..hidden name.  "), "hidden name", "no hidden files, no trailing dots")
        XCTAssertEqual(TidyDownloadRules.sanitize("- dash first"), "dash first")
        XCTAssertEqual(TidyDownloadRules.sanitize("tab\tand\nnew\u{0}line\u{202E}x"), "tab and new line x")
        let long = TidyDownloadRules.sanitize(String(repeating: "Lisbon itinerary ", count: 10))
        XCTAssertLessThanOrEqual(long.count, TidyDownloadRules.maxLength)
        XCTAssertTrue(long.hasSuffix("itinerary") || long.hasSuffix("Lisbon"), "cut at a word end: \(long)")
        let wide = TidyDownloadRules.sanitize(String(repeating: "東京", count: 200))
        XCTAssertLessThanOrEqual(wide.utf8.count, TidyDownloadRules.maxBytes)
    }

    func testAnswersKeepTheOriginalExtension() {
        let sources = "Lisbon in three days - Example Travel travel.example/lisbon Your Lisbon itinerary Day one Alfama"
        let orig = "IMG_2041 (1).pdf"
        XCTAssertEqual(TidyDownloadRules.accept("Lisbon itinerary", original: orig, sources: sources), "Lisbon itinerary.pdf")
        XCTAssertEqual(TidyDownloadRules.accept("\"Lisbon itinerary.PDF\"", original: orig, sources: sources), "Lisbon itinerary.pdf")
        XCTAssertEqual(TidyDownloadRules.accept("File name: Lisbon itinerary.docx", original: orig, sources: sources), "Lisbon itinerary.pdf",
                       "the file stays a PDF whatever the model wrote")
        XCTAssertEqual(TidyDownloadRules.accept("Lisbon: itinerary / day one", original: orig, sources: sources), "Lisbon itinerary day one.pdf",
                       "no slash or colon in a file name")
        XCTAssertEqual(TidyDownloadRules.accept("Lisbon itinerary", original: "IMG_2041", sources: sources), "Lisbon itinerary", "no extension, none added")
        XCTAssertEqual(TidyDownloadRules.accept("Lisbon itinerary", original: "data.tar.gz", sources: sources), "Lisbon itinerary.tar.gz")
    }

    func testAnswersThatAreDropped() {
        let sources = "Lisbon in three days travel.example/lisbon Your Lisbon itinerary"
        let orig = "IMG_2041 (1).pdf"
        for bad in ["", "  ", "x", "IMG_2041 (1)", "Paris weekend getaway brochure", "https://travel.example/lisbon",
                    "someone@example.com itinerary", "Lisbon itinerary with many many more words than allowed here",
                    "2041", ".pdf"] {
            XCTAssertNil(TidyDownloadRules.accept(bad, original: orig, sources: sources), bad)
        }
    }

    func testANameThatIsTakenGetsANumber() {
        let taken: Set<String> = ["Lisbon itinerary.pdf", "Lisbon itinerary 2.pdf"]
        XCTAssertEqual(TidyDownloadRules.unique("Lisbon itinerary.pdf") { taken.contains($0) }, "Lisbon itinerary 3.pdf")
        XCTAssertEqual(TidyDownloadRules.unique("Other.pdf") { taken.contains($0) }, "Other.pdf")
        XCTAssertEqual(TidyDownloadRules.unique("README") { $0 == "README" }, "README 2")
    }

    func testTheRequestHoldsNoQueryOrEmailAddresses() {
        let r = TidyDownloadPrompt.request(fileName: "IMG_2041 (1).pdf", pageTitle: "Trips (3) - someone@example.com - Example Travel",
                                           pageURL: "https://www.travel.example/trips/lisbon?token=secret#x",
                                           fileText: String(repeating: "Your Lisbon itinerary.\n\n", count: 200))
        XCTAssertEqual(r.pageTitle, "Trips - Example Travel")
        XCTAssertEqual(r.pageURL, "travel.example/trips/lisbon")
        XCTAssertLessThanOrEqual(r.fileText.count, TidyDownloadPrompt.fileTextLength)
        XCTAssertFalse(r.fileText.contains("\n"))
        let p = TidyDownloadPrompt.prompt(for: r)
        for leak in ["token", "secret", "someone", "@", "(3)"] { XCTAssertFalse(p.contains(leak), leak) }
        XCTAssertTrue(p.hasPrefix("Current name: IMG_2041 (1).pdf\n"))
    }

    func testRenamesRoundTrip() throws {
        var r = TidyDownloadRenames()
        r.set("p1/abc", path: "/tmp/Lisbon itinerary.pdf", name: "Lisbon itinerary.pdf", from: "IMG_2041 (1).pdf")
        let back = try JSONDecoder().decode(TidyDownloadRenames.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.entries["p1/abc"]?.from, "IMG_2041 (1).pdf")
    }
}

@MainActor
final class TidyDownloadsTests: XCTestCase {
    func center(_ model: FakeFileNameModel?) -> TidyDownloads {
        var o = TidyDownloads.Options()
        o.timeout = 0.3
        let t = TidyDownloads(options: o)
        t.model = model
        t.isEnabled = true
        return t
    }

    /// Until the queue (started by the offers, or by the test) is through.
    func settle(_ t: TidyDownloads) async {
        await t.runQueue()
        let end = Date().addingTimeInterval(2)
        while t.isBusy, Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func request(_ name: String) -> TidyDownloadRequest {
        TidyDownloadPrompt.request(fileName: name, pageTitle: "Lisbon in three days - Example Travel",
                                   pageURL: "https://travel.example/lisbon", fileText: "Your Lisbon itinerary. Day one: Alfama.")
    }

    func testOffByDefaultAndWithoutAModelNothingIsAsked() async {
        let model = FakeFileNameModel()
        let off = TidyDownloads()
        off.model = model
        XCTAssertFalse(off.isEnabled)
        XCTAssertFalse(off.offer(key: "a", request: request("IMG_1.pdf")))
        let none = center(nil)
        XCTAssertFalse(none.offer(key: "a", request: request("IMG_1.pdf")))
        await off.runQueue()
        XCTAssertTrue(model.asked.isEmpty)
    }

    func testASuggestionArrivesOncePerDownload() async {
        let model = FakeFileNameModel()
        model.answers["IMG_2041 (1).pdf"] = "Lisbon itinerary"
        let t = center(model)
        var changed: [String] = []
        t.onChange = { changed.append($0) }
        XCTAssertTrue(t.offer(key: "p/1", request: request("IMG_2041 (1).pdf")))
        XCTAssertFalse(t.offer(key: "p/1", request: request("IMG_2041 (1).pdf")), "once a session")
        XCTAssertFalse(t.offer(key: "p/2", request: request("Lisbon itinerary.pdf")), "a clean name is left alone")
        await settle(t)
        XCTAssertEqual(t.suggestion(for: "p/1"), "Lisbon itinerary.pdf")
        XCTAssertEqual(changed, ["p/1"])
        XCTAssertEqual(model.asked.count, 1)
        // An answer made up of words from nowhere isn't suggested.
        XCTAssertTrue(t.offer(key: "p/3", request: request("document.pdf")))
        await settle(t)
        XCTAssertNil(t.suggestion(for: "p/3"))
        XCTAssertEqual(t.stats.kept, 1)
        t.dismiss("p/1")
        XCTAssertNil(t.suggestion(for: "p/1"))
        XCTAssertEqual(changed, ["p/1", "p/1"])
    }

    func testWhatWasAskedIsKeptByKeyOnlyAndOffClearsIt() async {
        let model = FakeFileNameModel()
        model.answers["IMG_2041 (1).pdf"] = "Lisbon itinerary"
        let t = center(model)
        let r = TidyDownloadPrompt.request(fileName: "IMG_2041 (1).pdf", pageTitle: "Lab results – Clinic portal",
                                           pageURL: "https://clinic.example/results", fileText: "CONFIDENTIAL: blood test results")
        t.offer(key: "p/1", request: r)
        await settle(t)
        XCTAssertEqual(t.asked, ["p/1"], "keys only: no name, title or text of the file")
        t.isEnabled = false
        XCTAssertTrue(t.asked.isEmpty)
        // A huge file text is cut before anything else is done with it.
        let big = TidyDownloadPrompt.request(fileName: "a.pdf", pageTitle: nil, pageURL: nil, fileText: String(repeating: "word  \n ", count: 500_000))
        XCTAssertLessThanOrEqual(big.fileText.count, TidyDownloadPrompt.fileTextLength)
    }

    func testOffStopsTheCallUnderWay() async throws {
        let model = FakeFileNameModel()
        model.hang = ["scan0001.pdf"]
        var o = TidyDownloads.Options()
        o.timeout = 5
        let t = TidyDownloads(options: o)
        t.model = model
        t.isEnabled = true
        t.offer(key: "p/1", request: request("scan0001.pdf"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(t.isBusy)
        t.isEnabled = false
        await eventually(2) { !t.isBusy }
        XCTAssertFalse(t.isBusy, "the call is cancelled, not waited for until its 5-second timeout")
    }

    func testForgettingAProfileDropsItsSuggestionsAndItsCallUnderWay() async throws {
        let model = FakeFileNameModel()
        model.hang = ["scan0001.pdf"]
        model.answers["IMG_2.pdf"] = "Lisbon itinerary"
        model.answers["IMG_3.pdf"] = "Lisbon itinerary"
        var o = TidyDownloads.Options()
        o.timeout = 5
        let t = TidyDownloads(options: o)
        t.model = model
        t.isEnabled = true
        t.offer(key: "work/9", request: request("IMG_3.pdf"))
        await settle(t)
        XCTAssertEqual(t.suggestion(for: "work/9"), "Lisbon itinerary.pdf")
        let before = t.generation(ofProfile: "home")
        t.offer(key: "home/1", request: request("scan0001.pdf"))
        t.offer(key: "home/2", request: request("IMG_2.pdf"))
        try await Task.sleep(nanoseconds: 150_000_000)
        var changed: [String] = []
        t.onChange = { changed.append($0) }
        t.forget(profileID: "home")
        await eventually(2) { !t.isBusy }
        XCTAssertFalse(t.isBusy, "its call under way stops (not at its 5-second timeout), its queued one goes")
        XCTAssertNil(t.suggestion(for: "home/1"))
        XCTAssertNil(t.suggestion(for: "home/2"))
        XCTAssertEqual(t.suggestion(for: "work/9"), "Lisbon itinerary.pdf", "another profile's stays")
        XCTAssertTrue(changed.isEmpty)
        // A download read before the purge isn't offered after it.
        XCTAssertFalse(t.offer(key: "home/3", request: request("IMG_4.pdf"), profileGeneration: before))
        XCTAssertTrue(t.offer(key: "home/3", request: request("IMG_4.pdf"), profileGeneration: t.generation(ofProfile: "home")))
        var renames = TidyDownloadRenames()
        renames.set("home/1", path: "/tmp/a.pdf", name: "a.pdf", from: "IMG_1.pdf")
        renames.set("work/9", path: "/tmp/b.pdf", name: "b.pdf", from: "IMG_3.pdf")
        renames.remove(profileID: "home")
        XCTAssertEqual(Array(renames.entries.keys), ["work/9"])
    }

    func testTwoProfilesOnOneAddressKeepTheirOwnPageTitles() {
        // A work and a personal mailbox at one address: a download is named from its own profile's page only.
        let url = "https://mail.example/inbox"
        let pages = [TidyDownloadSources.OpenPage(profileID: "work", url: URL(string: url), title: "Inbox – Restructuring plan (confidential)"),
                     TidyDownloadSources.OpenPage(profileID: "home", url: URL(string: url + "#top"), title: "Inbox – Appointment with Dr. Example")]
        let history = ["home": "Home history title"]
        func title(_ profile: String) -> String {
            TidyDownloadSources.pageTitle(for: url, profileID: profile, openPages: pages) { _ in history[profile] }
        }
        XCTAssertEqual(title("work"), "Inbox – Restructuring plan (confidential)")
        XCTAssertEqual(title("home"), "Inbox – Appointment with Dr. Example")
        XCTAssertEqual(title("third"), "", "neither of the others' titles")
        let homeOnlyInHistory = [pages[0]]
        XCTAssertEqual(TidyDownloadSources.pageTitle(for: url, profileID: "home", openPages: homeOnlyInHistory) { _ in history["home"] },
                       "Home history title", "its own history, never the open page of another profile")
        XCTAssertEqual(TidyDownloadSources.pageTitle(for: "", profileID: "work", openPages: pages) { _ in "x" }, "")
    }

    func testAFailedRenameLogsNoFileName() throws {
        // A real failed move, with a name made from a page and a file's content.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = "Diagnosis Jane Example HIV test"
        let source = folder.appendingPathComponent("IMG_2041 (1).pdf"), destination = folder.appendingPathComponent(secret + ".pdf")
        var failure: Error?
        do { try FileManager.default.moveItem(at: source, to: destination) } catch { failure = error }
        let error = try XCTUnwrap(failure, "the source doesn't exist")
        let line = TidyDownloadRules.renameFailureLog(error)
        XCTAssertTrue(("\(error)" + error.localizedDescription).contains("IMG_2041") || "\((error as NSError).userInfo)".contains(secret),
                      "the error itself names the files (that's why it isn't logged)")
        for leak in [secret, "Diagnosis", "IMG_2041", folder.path, folder.lastPathComponent] { XCTAssertFalse(line.contains(leak), leak) }
        XCTAssertEqual(line, "Airc: Tidy Downloads couldn't rename a file (\(NSCocoaErrorDomain) \((error as NSError).code))")
        XCTAssertEqual(TidyDownloadRules.renameFailureLog(NSError(domain: "com.example.\(secret)", code: 7)),
                       "Airc: Tidy Downloads couldn't rename a file (other 7)", "an unknown domain isn't named either")
    }

    func testAStuckModelTimesOutAndOffClearsSuggestions() async {
        let model = FakeFileNameModel()
        model.hang = ["scan0001.pdf"]
        model.answers["IMG_2.pdf"] = "Lisbon itinerary"
        let t = center(model)
        t.offer(key: "a", request: request("scan0001.pdf"))
        t.offer(key: "b", request: request("IMG_2.pdf"))
        let start = Date()
        await settle(t)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(t.stats.timeouts, 1)
        XCTAssertNil(t.suggestion(for: "a"))
        XCTAssertEqual(t.suggestion(for: "b"), "Lisbon itinerary.pdf", "the next one still runs")
        t.isEnabled = false
        XCTAssertTrue(t.suggestions.isEmpty)
        XCTAssertFalse(t.offer(key: "c", request: request("IMG_3.pdf")))
    }
}

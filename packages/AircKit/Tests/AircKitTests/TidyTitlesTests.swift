// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import AircKit

/// A model that answers from a table, records what it was asked, and can be slow (ignoring cancellation) or fail.
final class FakeTitleModel: TidyTitleModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [TidyTitleRequest] = []
    var answers: [String: String]
    /// Titles (as asked) that take this long; the fake doesn't stop when cancelled, as a stuck model wouldn't.
    var slow: [String: TimeInterval] = [:]
    var declines: Set<String> = []
    var fails: Set<String> = []

    init(_ answers: [String: String] = [:]) { self.answers = answers }

    var asked: [TidyTitleRequest] { lock.withLock { _asked } }

    func shortTitle(for request: TidyTitleRequest) async throws -> String {
        lock.withLock { _asked.append(request) }
        if let s = slow[request.title] {
            let end = Date().addingTimeInterval(s)
            while Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        if declines.contains(request.title) { throw TidyTitleDeclined() }
        if fails.contains(request.title) { throw URLError(.timedOut) }
        return answers[request.title] ?? "Something Else Entirely Here Today"
    }
}

final class TidyTitleRulesTests: XCTestCase {
    func testWhichTitlesNeedTidying() {
        for t in ["Inbox (3) - someone@example.com - Gmail", "(12) Home / X", "Pull requests · example-org/repo · GitHub",
                  "Weekly sync | Calendar | Example Corp - Outlook", "general | 3 new items | Example Workspace",
                  "A very long page title that just keeps going on"] {
            XCTAssertTrue(TidyTitleRules.needsTidy(t), t)
        }
        for t in ["", "  ", "GitHub", "Figma", "Q3 Planning Doc", "Weekly sync", "127.0.0.1:8080", "example.com/a/b",
                  "about:blank"] {
            XCTAssertFalse(TidyTitleRules.needsTidy(t), t)
        }
    }

    func testPrepareTakesOutCountsAndEmailAddresses() {
        XCTAssertEqual(TidyTitleRules.prepare("Inbox (3) - someone@example.com - Gmail"), "Inbox - Gmail")
        XCTAssertEqual(TidyTitleRules.prepare("(12) Home / X"), "Home - X")
        XCTAssertEqual(TidyTitleRules.prepare("general | 3 new items | Example Workspace"), "general - Example Workspace")
        XCTAssertEqual(TidyTitleRules.prepare("Pull requests · example-org/repo · GitHub"), "Pull requests - example-org/repo - GitHub")
        XCTAssertEqual(TidyTitleRules.prepare("Plain title"), "Plain title")
    }

    func testThePromptHoldsOnlyTheCleanTitleAndTheHost() {
        let r = TidyTitlePrompt.request(title: "Inbox (3) - someone@example.com - Gmail",
                                        url: "https://www.mail.example.com/mail/u/0/?token=secret#inbox")
        XCTAssertEqual(r, TidyTitleRequest(title: "Inbox - Gmail", host: "mail.example.com"))
        let p = TidyTitlePrompt.prompt(for: r)
        XCTAssertEqual(p, "Title: Inbox - Gmail\nSite: mail.example.com")
        for leak in ["someone", "@", "token", "secret", "/mail/", "(3)", "#inbox"] { XCTAssertFalse(p.contains(leak), leak) }
        XCTAssertTrue(TidyTitlePrompt.instructions.contains("at most four words"))
        // A long title is cut before the model sees it.
        let long = TidyTitlePrompt.request(title: String(repeating: "word ", count: 100), url: "https://a.example/")
        XCTAssertLessThanOrEqual(long.title.count, TidyTitleRules.promptLength)
    }

    func testAcceptedAnswers() {
        let title = "Inbox (3) - someone@example.com - Gmail", host = "mail.google.com"
        XCTAssertEqual(TidyTitleRules.accept("Gmail Inbox", title: title, host: host), "Gmail Inbox")
        XCTAssertEqual(TidyTitleRules.accept("  \"Gmail Inbox.\"  \nmore", title: title, host: host), "Gmail Inbox")
        XCTAssertEqual(TidyTitleRules.accept("Title: Gmail  Inbox", title: title, host: host), "Gmail Inbox")
        XCTAssertEqual(TidyTitleRules.accept("“Inbox”", title: title, host: host), "Inbox")
        // Up to five words ("about four"); never cut.
        XCTAssertEqual(TidyTitleRules.accept("Inbox of Gmail for someone", title: title, host: host), "Inbox of Gmail for someone")
        XCTAssertNil(TidyTitleRules.accept("Inbox of Gmail for someone today", title: title, host: host))
        XCTAssertNil(TidyTitleRules.accept("", title: title, host: host))
        XCTAssertNil(TidyTitleRules.accept("  \" \"  ", title: title, host: host))
        XCTAssertNil(TidyTitleRules.accept("someone@example.com", title: title, host: host))
        XCTAssertNil(TidyTitleRules.accept("Inbox (3)", title: title, host: host))
        XCTAssertNil(TidyTitleRules.accept("<b>Inbox</b>", title: title, host: host))
        XCTAssertNil(TidyTitleRules.accept("{\"name\": \"Inbox\"}", title: title, host: host))
        XCTAssertNil(TidyTitleRules.accept(String(repeating: "x", count: 41), title: title, host: host))
        // Unchanged is no name; invented words aren't either.
        XCTAssertNil(TidyTitleRules.accept("(12) Home / X", title: "(12) Home / X", host: "x.com"))
        XCTAssertNil(TidyTitleRules.accept("Banana Smoothie Recipes", title: title, host: host))
        XCTAssertEqual(TidyTitleRules.accept("Mail Inbox", title: title, host: host), "Mail Inbox")
        XCTAssertEqual(TidyTitleRules.accept("X Home", title: "(12) Home / X", host: "x.com"), "X Home")
    }

    func testFingerprintIgnoresCountsAndNumbers() {
        let a = TidyTitleRules.fingerprint("Inbox (3) - someone@example.com - Gmail")
        XCTAssertEqual(a, TidyTitleRules.fingerprint("Inbox (12) - someone@example.com - Gmail"))
        XCTAssertEqual(a, "inbox gmail")
        XCTAssertNotEqual(a, TidyTitleRules.fingerprint("Starred - someone@example.com - Gmail"))
    }

    func testCacheIsBoundedLeastRecentlyUsedFirst() {
        var c = TidyTitleCache(limit: 8)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for i in 0..<8 { c.set(url: "u\(i)", fingerprint: "f", name: "n\(i)", now: t0.addingTimeInterval(Double(i))) }
        c.touch("u0", now: t0.addingTimeInterval(100))
        c.set(url: "u8", fingerprint: "f", name: "n8", now: t0.addingTimeInterval(101))
        XCTAssertEqual(c.entries.count, 7)
        XCTAssertNotNil(c.entries["u0"])
        XCTAssertNotNil(c.entries["u8"])
        XCTAssertNil(c.entries["u1"])
        XCTAssertNil(c.entries["u2"])
    }
}

@MainActor
final class Flag {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

@MainActor
final class TidyTitlesTests: XCTestCase {
    let gmail = "https://mail.google.com/mail/u/0/#inbox"
    let gmailTitle = "Inbox (3) - someone@example.com - Gmail"

    func center(_ model: FakeTitleModel?, file: URL? = nil, enabled: Bool = true) -> TidyTitles {
        var o = TidyTitles.Options()
        o.debounce = 60   // tests run the queue themselves
        o.timeout = 0.3
        o.saveDelay = 60
        let t = TidyTitles(fileURL: file, options: o)
        t.model = model
        t.isEnabled = enabled
        return t
    }

    func testOffByDefaultAndWithoutAModelNothingIsAsked() async {
        let fake = FakeTitleModel(["Inbox - Gmail": "Gmail Inbox"])
        let off = TidyTitles(fileURL: nil)
        off.model = fake
        XCTAssertFalse(off.isEnabled)
        XCTAssertNil(off.name(for: gmailTitle, url: gmail))
        await off.runPending()
        let noModel = center(nil)
        XCTAssertNil(noModel.name(for: gmailTitle, url: gmail))
        await noModel.runPending()
        XCTAssertTrue(fake.asked.isEmpty)
        XCTAssertTrue(off.queue.isEmpty && noModel.queue.isEmpty)
    }

    func testANameArrivesAndIsCachedPerURL() async {
        let fake = FakeTitleModel(["Inbox - Gmail": "Gmail Inbox"])
        let t = center(fake)
        var changes: [Set<String>] = []
        t.onChange = { changes.append($0) }
        XCTAssertNil(t.name(for: gmailTitle, url: gmail))
        XCTAssertNil(t.name(for: gmailTitle, url: gmail))   // asked once, however often the row draws
        XCTAssertEqual(t.queue, [gmail])
        await t.runPending()
        XCTAssertEqual(fake.asked, [TidyTitleRequest(title: "Inbox - Gmail", host: "mail.google.com")])
        XCTAssertEqual(changes, [[gmail]])
        XCTAssertEqual(t.name(for: gmailTitle, url: gmail), "Gmail Inbox")
        // A new count is the same page: no new request.
        XCTAssertEqual(t.name(for: "Inbox (4) - someone@example.com - Gmail", url: gmail), "Gmail Inbox")
        // Short, clean titles are never asked about.
        XCTAssertNil(t.name(for: "GitHub", url: "https://github.com/"))
        // A different title at the same address is.
        XCTAssertNil(t.name(for: "Starred - someone@example.com - Gmail", url: gmail))
        XCTAssertEqual(t.queue, [gmail])
        await t.runPending()
        XCTAssertEqual(fake.asked.count, 2)
        XCTAssertEqual(t.stats.requests, 2)
        XCTAssertEqual(t.stats.named, 1)
        XCTAssertEqual(t.stats.kept, 1)   // "Something Else Entirely Here Today" isn't from the title
        XCTAssertNil(t.name(for: "Starred - someone@example.com - Gmail", url: gmail))
        XCTAssertTrue(t.queue.isEmpty, "a title the model had nothing for isn't asked again")
    }

    func testHandRenamedTabsAndPrivateWindowsAreNeverSent() async {
        let fake = FakeTitleModel(["Inbox - Gmail": "Gmail Inbox"])
        let t = center(fake)
        XCTAssertNil(t.name(for: gmailTitle, url: gmail, customName: "Mail"))
        XCTAssertNil(t.name(for: gmailTitle, url: gmail, isPrivate: true))
        await t.runPending()
        XCTAssertTrue(fake.asked.isEmpty)
        // Even with a name cached for the page, the renamed tab and the private window show their own.
        _ = t.name(for: gmailTitle, url: gmail)
        await t.runPending()
        XCTAssertEqual(t.name(for: gmailTitle, url: gmail), "Gmail Inbox")
        XCTAssertNil(t.name(for: gmailTitle, url: gmail, customName: "Mail"))
        XCTAssertNil(t.name(for: gmailTitle, url: gmail, isPrivate: true))
        XCTAssertEqual(fake.asked.count, 1)
        // A blank custom name is no name.
        XCTAssertEqual(t.name(for: gmailTitle, url: gmail, customName: " "), "Gmail Inbox")
    }

    func testAStuckModelTimesOutAndHoldsNothingUp() async {
        let fake = FakeTitleModel(["Slow - Example": "Slow Example", "Inbox - Gmail": "Gmail Inbox"])
        fake.slow["Slow - Example"] = 1.2
        let t = center(fake)
        var clock = Date(timeIntervalSince1970: 10_000)
        t.now = { clock }
        _ = t.name(for: "Slow (2) - Example", url: "https://slow.example/")
        _ = t.name(for: gmailTitle, url: gmail)
        let start = Date()
        await t.runPending()
        let took = Date().timeIntervalSince(start)
        XCTAssertLessThan(took, 0.9, "the queue waited \(took) s for a model past its 0.3 s timeout")
        XCTAssertEqual(t.stats.timeouts, 1)
        XCTAssertNil(t.name(for: "Slow (2) - Example", url: "https://slow.example/"), "a late answer is never shown")
        // Nothing more goes to the model until the stuck call lets go.
        XCTAssertEqual(fake.asked.count, 1)
        await t.runPending()
        XCTAssertEqual(fake.asked.count, 1)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await t.runPending()
        XCTAssertEqual(t.name(for: gmailTitle, url: gmail), "Gmail Inbox")
        // The page that timed out is asked again only after `retryAfter`.
        _ = t.name(for: "Slow (2) - Example", url: "https://slow.example/")
        XCTAssertFalse(t.queue.contains("https://slow.example/"))
        clock = clock.addingTimeInterval(t.options.retryAfter + 1)
        _ = t.name(for: "Slow (2) - Example", url: "https://slow.example/")
        XCTAssertTrue(t.queue.contains("https://slow.example/"))
    }

    func testDeclinedAndFailedRequests() async {
        let fake = FakeTitleModel()
        fake.declines = ["Declined - Example"]
        fake.fails = ["Failed - Example"]
        let t = center(fake)
        _ = t.name(for: "Declined (1) - Example", url: "https://a.example/")
        _ = t.name(for: "Failed (1) - Example", url: "https://b.example/")
        await t.runPending()
        XCTAssertEqual(t.stats.kept, 1)
        XCTAssertEqual(t.stats.failures, 1)
        XCTAssertNil(t.name(for: "Declined (1) - Example", url: "https://a.example/"))
        XCTAssertNil(t.name(for: "Failed (1) - Example", url: "https://b.example/"))
        XCTAssertTrue(t.queue.isEmpty, "neither is asked again right away")
    }

    func testTheQueueWaitsWhileThePersonIsBusyAndRunsInBatches() async {
        let fake = FakeTitleModel()
        let t = center(fake)
        let busy = Flag(true)
        t.isBusy = { busy.value }
        for i in 0..<10 { _ = t.name(for: "Page \(i) - Example Site", url: "https://example.com/\(i)") }
        await t.runPending()
        XCTAssertTrue(fake.asked.isEmpty, "typing or scrolling: nothing runs")
        XCTAssertEqual(t.queue.count, 10)
        busy.value = false
        t.options.batchLimit = 4
        await t.runPending()
        XCTAssertEqual(fake.asked.count, 4)
        XCTAssertEqual(t.queue.count, 6)
        await t.runPending()
        XCTAssertEqual(fake.asked.count, 8)
        await t.runPending()
        XCTAssertEqual(fake.asked.count, 10)
        XCTAssertEqual(Set(fake.asked.map(\.title)).count, 10)
    }

    func testTheDebounceRunsTheQueueByItself() async {
        let fake = FakeTitleModel(["Inbox - Gmail": "Gmail Inbox"])
        let t = center(fake)
        t.options.debounce = 0.05
        var changed = false
        t.onChange = { _ in changed = true }
        _ = t.name(for: gmailTitle, url: gmail)
        for _ in 0..<100 where !changed { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(changed)
        XCTAssertEqual(t.name(for: gmailTitle, url: gmail), "Gmail Inbox")
    }

    func testTurningOffDropsTheQueueAndForgetDeletesTheFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("TidyTitles.json")
        let fake = FakeTitleModel(["Inbox - Gmail": "Gmail Inbox"])
        let t = center(fake, file: file)
        _ = t.name(for: gmailTitle, url: gmail)
        await t.runPending()
        t.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("Gmail Inbox"))
        XCTAssertFalse(saved.contains("someone@example.com"), "the file keeps the name and a fingerprint, never the title")

        // The next launch reads it: no new request.
        let fake2 = FakeTitleModel()
        let t2 = center(fake2, file: file)
        XCTAssertEqual(t2.name(for: gmailTitle, url: gmail), "Gmail Inbox")
        XCTAssertTrue(fake2.asked.isEmpty)

        _ = t2.name(for: "Other (1) - Example", url: "https://other.example/")
        XCTAssertFalse(t2.queue.isEmpty)
        t2.isEnabled = false
        XCTAssertTrue(t2.queue.isEmpty)
        XCTAssertNil(t2.name(for: gmailTitle, url: gmail), "off: every row shows its page's own title")
        t2.forget()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        t2.isEnabled = true
        XCTAssertNil(t2.name(for: gmailTitle, url: gmail))
        XCTAssertEqual(t2.queue, [gmail])
    }

    func testAnAnswerFromBeforeTurningOffIsDropped() async {
        let fake = FakeTitleModel(["Inbox - Gmail": "Gmail Inbox"])
        fake.slow["Inbox - Gmail"] = 0.1
        let t = center(fake)
        _ = t.name(for: gmailTitle, url: gmail)
        let run = Task { await t.runPending() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        t.isEnabled = false
        await run.value
        t.isEnabled = true
        XCTAssertNil(t.name(for: gmailTitle, url: gmail))
        XCTAssertTrue(t.cache.entries.isEmpty)
    }
}

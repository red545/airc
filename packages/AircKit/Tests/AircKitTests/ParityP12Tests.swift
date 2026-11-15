// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// P12 (S15): GitHub Live Folders against a synthetic GitHub (`FakeGitHub`, no network): pull requests created,
/// updated, merged and closed; pagination and ETags; filters; sign-in, an expired token, the rate limit, offline;
/// a folder deleted while its request is out; the person's own tabs; Keep in Folder; Stop Updating; undo; relaunch.
final class ParityP12Tests: XCTestCase {
    let repo = "acme/rocket"
    var gh: FakeGitHub!
    var store: SpacesStore!
    var book: LiveFolderBook!
    var space: String!

    override func setUpWithError() throws {
        gh = FakeGitHub(pageSize: 2)
        store = try SpacesStore(path: nil)
        space = store.selectedSpace.id
        book = LiveFolderBook(store: store)
    }

    var client: GitHubClient { GitHubClient(http: gh) }

    /// Fetches and applies once, as LiveFolderCenter does.
    @discardableResult
    func refresh(_ folder: String, token: String? = nil, protected: Set<String> = []) async -> LiveApplyOutcome {
        let d = try! XCTUnwrap(book.definition(folder))
        let r = await client.fetch(d.query, token: token, pages: d.pages)
        return book.apply(r, to: folder, protected: protected)
    }

    func titles(_ folder: String) -> [String] {
        store.children(of: .pinned(spaceID: space), parent: folder).map(\.displayTitle)
    }

    // MARK: Lifecycle

    func testCreatedUpdatedMergedClosedPullRequests() async throws {
        gh.open(repo, 1, "Add launch checklist")
        gh.open(repo, 2, "Fix telemetry")
        let folder = try book.create(query: GitHubPullQuery(repository: repo), inSpace: space)
        XCTAssertEqual(folder.title, "rocket", "a repository's folder is named after it")
        var out = await refresh(folder.id)
        XCTAssertEqual(out.added.count, 2)
        XCTAssertEqual(titles(folder.id), ["Fix telemetry", "Add launch checklist"], "most recently updated first")
        let rows = store.children(of: .pinned(spaceID: space), parent: folder.id)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .tab && $0.sourceID?.hasPrefix("live:github:acme/rocket#") == true })
        XCTAssertEqual(rows.first?.savedURL, "https://github.com/acme/rocket/pull/2")
        XCTAssertEqual(rows.first?.faviconURL, "https://github.com/favicon.ico")

        gh.open(repo, 3, "Draft: new engine")
        gh.retitle(repo, 1, "Add the launch checklist")
        out = await refresh(folder.id)
        XCTAssertEqual(out.added.count, 1)
        XCTAssertEqual(out.updated.count, 1)
        XCTAssertEqual(titles(folder.id).first, "Draft: new engine", "a new pull request goes to the top")
        XCTAssertTrue(titles(folder.id).contains("Add the launch checklist"))

        gh.merge(repo, 1)
        gh.close(repo, 2)
        out = await refresh(folder.id)
        XCTAssertEqual(out.retired.count, 2, "merged and closed pull requests leave the folder")
        XCTAssertEqual(titles(folder.id), ["Draft: new engine"])
        XCTAssertEqual(book.definition(folder.id)?.status, .ok)
    }

    func testPaginationReadsEveryPageAndAPartialListNeverRetires() async throws {
        for n in 1...5 { gh.open(repo, n, "PR \(n)") }
        let folder = try book.create(query: GitHubPullQuery(repository: repo), inSpace: space)
        await refresh(folder.id)
        XCTAssertEqual(titles(folder.id).count, 5, "three pages of two")
        XCTAssertEqual(gh.requestCount, 3)

        gh.merge(repo, 1)
        gh.failPage(2)
        let out = await refresh(folder.id)
        XCTAssertEqual(out.retired, [], "a failed second page retires nothing")
        XCTAssertEqual(titles(folder.id).count, 5)
        if case .failed = book.definition(folder.id)?.status {} else { XCTFail("the failure is shown") }
    }

    func testETagsMakeAnUnchangedListFree() async throws {
        gh.open(repo, 1, "One")
        let folder = try book.create(query: GitHubPullQuery(repository: repo), inSpace: space)
        await refresh(folder.id)
        let before = gh.conditionalHits
        let out = await refresh(folder.id)
        XCTAssertEqual(gh.conditionalHits, before + 1, "the second ask sends If-None-Match and gets 304")
        XCTAssertEqual(out, LiveApplyOutcome(), "nothing changes")
        XCTAssertEqual(titles(folder.id), ["One"])
    }

    // MARK: The person's rows

    func testOwnTabsKeptRowsAndDismissedRowsAreNeverTouched() async throws {
        gh.open(repo, 1, "One")
        gh.open(repo, 2, "Two")
        gh.open(repo, 3, "Three")
        let folder = try book.create(query: GitHubPullQuery(repository: repo), inSpace: space)
        await refresh(folder.id)
        // The person's own tab in the folder.
        let mine = Item(kind: .tab, container: .pinned(spaceID: space), parentID: folder.id, order: 99,
                        savedURL: "https://example.com/notes", title: "My notes")
        try store.perform(nil) { store.put(mine) }
        let rows = store.children(of: .pinned(spaceID: space), parent: folder.id)
        let one = try XCTUnwrap(rows.first { $0.title == "One" })
        let two = try XCTUnwrap(rows.first { $0.title == "Two" })
        try book.keep(one.id)                  // Keep in Folder
        try store.deleteItem(two.id)           // the person removes a row
        try store.renameItem(rows.first { $0.title == "Three" }!.id, to: "Ship it")
        gh.retitle(repo, 3, "Three (rebased)")
        await refresh(folder.id)
        XCTAssertFalse(titles(folder.id).contains("Two"), "a removed row isn't added back while its PR is open")
        XCTAssertTrue(titles(folder.id).contains("Ship it"), "a renamed row keeps the person's name")

        gh.merge(repo, 1)
        gh.close(repo, 3)
        await refresh(folder.id)
        XCTAssertEqual(Set(titles(folder.id)), ["One", "My notes"], "kept and own tabs stay when their PRs end")
        XCTAssertNotNil(store.item(mine.id))
    }

    func testOnScreenRowRetiresOnlyAfterItLeavesTheScreen() async throws {
        gh.open(repo, 1, "One")
        let folder = try book.create(query: GitHubPullQuery(repository: repo), inSpace: space)
        await refresh(folder.id)
        let row = try XCTUnwrap(store.children(of: .pinned(spaceID: space), parent: folder.id).first)
        let tab = try store.openItem(row.id, inSpace: space)
        gh.merge(repo, 1)
        var out = await refresh(folder.id, protected: [tab.id])
        XCTAssertEqual(out.deferred, [row.id])
        XCTAssertNotNil(store.item(row.id))
        out = await refresh(folder.id)
        XCTAssertEqual(out.retired, [row.id])
        XCTAssertEqual(out.retiredTabIDs, [tab.id], "its page is closed by the app")
        XCTAssertNil(store.tab(tab.id))
    }

    func testStopUpdatingMakesAnOrdinaryFolder() async throws {
        gh.open(repo, 1, "One")
        let folder = try book.create(query: GitHubPullQuery(repository: repo), inSpace: space)
        await refresh(folder.id)
        try book.stopUpdating(folder.id)
        XCTAssertFalse(book.isLive(folder.id))
        XCTAssertTrue(store.children(of: .pinned(spaceID: space), parent: folder.id).allSatisfy { $0.sourceID == nil })
        gh.merge(repo, 1)
        let r = await client.fetch(GitHubPullQuery(repository: repo), token: nil, pages: [:])
        XCTAssertTrue(book.apply(r, to: folder.id).discarded)
        XCTAssertEqual(titles(folder.id), ["One"])
    }

    // MARK: Filters

    func testFiltersOnARepositoryList() async throws {
        gh.open(repo, 1, "Docs", author: "ada", labels: ["docs"])
        gh.open(repo, 2, "WIP", author: "ada", draft: true, labels: ["docs"])
        gh.open(repo, 3, "Perf", author: "bob", labels: ["perf", "docs"])
        let q = GitHubPullQuery(repository: "https://github.com/acme/rocket.git", author: "@ada", labels: ["Docs"], includeDrafts: false)
        XCTAssertEqual(q.repository, repo)
        let folder = try book.create(query: q, inSpace: space)
        await refresh(folder.id)
        XCTAssertEqual(titles(folder.id), ["Docs"])
        var wider = q
        wider.includeDrafts = true
        wider.author = nil
        book.setQuery(wider, ofFolder: folder.id)
        await refresh(folder.id)
        XCTAssertEqual(Set(titles(folder.id)), ["Docs", "WIP", "Perf"])
        wider.labels = ["perf"]
        book.setQuery(wider, ofFolder: folder.id)
        await refresh(folder.id)
        XCTAssertEqual(titles(folder.id), ["Perf"], "rows that stop matching leave")
    }

    func testSignedInSearchesYoursAndReviewRequests() async throws {
        gh.addToken("tok-ada", login: "ada")
        gh.open(repo, 1, "Mine", author: "ada")
        gh.open(repo, 2, "Review me", author: "bob", reviewers: ["ada"])
        gh.open("acme/other", 3, "Not mine", author: "bob")
        gh.open("acme/other", 4, "Mine draft", author: "ada", draft: true)
        let folder = try book.create(query: .yours, inSpace: space)
        XCTAssertEqual(folder.title, "Pull Requests", "Arc's name for its GitHub folder")
        await refresh(folder.id, token: "tok-ada")
        XCTAssertEqual(Set(titles(folder.id)), ["Mine", "Review me", "Mine draft"])
        XCTAssertTrue(gh.requests.contains { $0.contains("author%3A%40me") || $0.contains("author:@me") })
        book.setQuery(GitHubPullQuery(reviewRequested: true), ofFolder: folder.id)
        await refresh(folder.id, token: "tok-ada")
        XCTAssertEqual(titles(folder.id), ["Review me"])
        book.setQuery(GitHubPullQuery(createdByMe: true, includeDrafts: false), ofFolder: folder.id)
        await refresh(folder.id, token: "tok-ada")
        XCTAssertEqual(titles(folder.id), ["Mine"])
    }

    // MARK: Failures

    func testSignedOutAndAnExpiredTokenKeepTheRows() async throws {
        let folder = try book.create(query: .yours, inSpace: space)
        await refresh(folder.id)
        XCTAssertEqual(book.definition(folder.id)?.status, .signedOut, "your PRs need a GitHub account")
        XCTAssertEqual(gh.requestCount, 0, "nothing is asked without one")
        XCTAssertEqual(LiveFolderStatus.signedOut.message, "Not signed in to GitHub")

        gh.addToken("tok", login: "ada")
        gh.open(repo, 1, "Mine", author: "ada")
        await refresh(folder.id, token: "tok")
        XCTAssertEqual(titles(folder.id), ["Mine"])
        gh.revokeToken("tok")
        await refresh(folder.id, token: "tok")
        XCTAssertEqual(book.definition(folder.id)?.status, .signedOut, "401: the token expired")
        XCTAssertEqual(titles(folder.id), ["Mine"], "the last list stays")
        let d = try XCTUnwrap(book.definition(folder.id))
        XCTAssertFalse(LiveFolderSchedule.isDue(d, trigger: .timer, now: Date()), "no retries until a sign-in")
        XCTAssertTrue(LiveFolderSchedule.isDue(d, trigger: .manual, now: Date()))
    }

    func testRateLimitBacksOffUntilGitHubsReset() async throws {
        gh.open(repo, 1, "One")
        let reset = Date(timeIntervalSince1970: 1_900_000_000)
        gh.setRateLimit(remaining: 0, resetAt: reset)
        let t = Date(timeIntervalSince1970: 1_899_999_000)
        book.now = { t }
        let folder = try book.create(query: GitHubPullQuery(repository: repo), inSpace: space)
        await refresh(folder.id)
        let d = try XCTUnwrap(book.definition(folder.id))
        XCTAssertEqual(d.status, .rateLimited(until: reset))
        XCTAssertEqual(d.status.message, "GitHub rate limit exceeded")
        XCTAssertGreaterThanOrEqual(d.nextAllowed ?? .distantPast, reset)
        XCTAssertFalse(LiveFolderSchedule.isDue(d, trigger: .timer, now: t.addingTimeInterval(600)))
        XCTAssertFalse(LiveFolderSchedule.isDue(d, trigger: .manual, now: t.addingTimeInterval(600)), "not even by hand before the reset")
        XCTAssertTrue(LiveFolderSchedule.isDue(d, trigger: .timer, now: reset.addingTimeInterval(2)))
        gh.setRateLimit(remaining: 60, resetAt: reset)
        await refresh(folder.id)
        XCTAssertEqual(titles(folder.id), ["One"])
        XCTAssertEqual(book.definition(folder.id)?.failures, 0)
    }

    func testOfflineKeepsTheCacheAndBacksOff() async throws {
        gh.open(repo, 1, "One")
        let folder = try book.create(query: GitHubPullQuery(repository: repo), inSpace: space)
        await refresh(folder.id)
        gh.setOffline(true)
        await refresh(folder.id)
        await refresh(folder.id)
        let d = try XCTUnwrap(book.definition(folder.id))
        XCTAssertEqual(d.status, .offline)
        XCTAssertEqual(d.failures, 2)
        XCTAssertEqual(d.cache.map(\.title), ["One"], "the offline cache")
        XCTAssertEqual(titles(folder.id), ["One"])
        XCTAssertEqual(LiveFolderSchedule.backoff(1), 60)
        XCTAssertEqual(LiveFolderSchedule.backoff(3), 240)
        XCTAssertEqual(LiveFolderSchedule.backoff(20), LiveFolderSchedule.maxBackoff)
        gh.setOffline(false)
        await refresh(folder.id)
        XCTAssertEqual(book.definition(folder.id)?.status, .ok)
    }

    func testUnknownRepositoryAndPrivateWithoutSignIn() async throws {
        let folder = try book.create(query: GitHubPullQuery(repository: "private/secret"), inSpace: space)
        await refresh(folder.id)
        XCTAssertEqual(book.definition(folder.id)?.status, .notFound)
    }

    // MARK: Deletion, undo and relaunch

    func testDeleteWhileARequestIsInFlightIsSafeAndUndoKeepsItLive() async throws {
        gh.open(repo, 1, "One")
        let folder = try book.create(query: GitHubPullQuery(repository: repo), inSpace: space)
        gh.setDelay(0.3)
        let q = try XCTUnwrap(book.definition(folder.id)).query
        let pending = Task { [client] in await client.fetch(q, token: nil, pages: [:]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        try store.deleteItem(folder.id)       // deleted while the request is out
        let result = await pending.value
        let out = book.apply(result, to: folder.id)
        XCTAssertTrue(out.discarded, "the answer for a deleted folder is dropped")
        XCTAssertTrue(store.state.items.values.allSatisfy { $0.parentID != folder.id }, "no orphan rows")

        // A cancelled request (the app cancels on delete) is dropped too.
        let cancelled = Task { [client] in await client.fetch(q, token: nil, pages: [:]) }
        cancelled.cancel()
        let c = await cancelled.value
        XCTAssertEqual(c, .cancelled)

        _ = try store.undo()
        XCTAssertTrue(book.isLive(folder.id), "⌘Z brings back a live folder")
        gh.setDelay(0)
        await refresh(folder.id)
        XCTAssertEqual(titles(folder.id), ["One"])
    }

    func testDefinitionsSurviveRelaunchAndPruneForgetsDeletedFolders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sqlite").path
        store = try SpacesStore(path: path)
        space = store.selectedSpace.id
        book = LiveFolderBook(store: store)
        gh.open(repo, 1, "One")
        let keep = try book.create(query: GitHubPullQuery(repository: repo, labels: ["x"], includeDrafts: false), inSpace: space)
        let gone = try book.create(query: GitHubPullQuery(repository: repo), inSpace: space)
        await refresh(gone.id)
        try store.deleteItem(gone.id)
        try store.flush()

        let again = try SpacesStore(path: path)
        let book2 = LiveFolderBook(store: again)
        XCTAssertEqual(book2.definition(keep.id)?.query, GitHubPullQuery(repository: repo, labels: ["x"], includeDrafts: false))
        XCTAssertEqual(book2.prune(), [gone.id])
        XCTAssertEqual(book2.activeFolderIDs, [keep.id])
        let ops = try again.operations().count
        book2.setQuery(GitHubPullQuery(repository: repo), ofFolder: keep.id)
        XCTAssertEqual(try again.operations().count, ops, "definitions aren't in the op log, so they never sync")
    }

    func testProfileOfAFolderIsItsSpaces() throws {
        let work = try store.createProfile(name: "Work")
        let other = try store.createSpace(name: "Work", profileID: work.id)
        let a = try book.create(query: .yours, inSpace: space)
        let b = try book.create(query: .yours, inSpace: other.id)
        XCTAssertEqual(book.profileID(ofFolder: a.id), store.defaultProfile.id)
        XCTAssertEqual(book.profileID(ofFolder: b.id), work.id, "each profile signs in to GitHub on its own")
    }

    // MARK: Sign-in

    func testDeviceFlow() async throws {
        let web = GitHubEndpoint(api: URL(string: "https://api.github.com")!, web: URL(string: "https://github.com")!)
        gh.setDeviceFlow(pendingPolls: 2, token: "tok-device", login: "ada")
        let flow = GitHubDeviceFlow(http: gh, endpoint: web, clientID: "Iv1.test")
        let code = try await flow.start()
        XCTAssertEqual(code.userCode, "WDJB-MJHT")
        let token = try await flow.token(for: code, sleep: { _ in })
        XCTAssertEqual(token, "tok-device")
        let viewer = await GitHubClient(http: gh).viewer(token: token)
        XCTAssertEqual(try viewer.get(), "ada")

        do {
            _ = try await GitHubDeviceFlow(http: gh, endpoint: web, clientID: "").start()
            XCTFail("no client ID")
        } catch let e as GitHubDeviceFlow.Failure { XCTAssertEqual(e, .notConfigured) }

        gh.setDeviceFlow(pendingPolls: 0, token: "x", login: "x", denied: true)
        do {
            _ = try await flow.token(for: code, sleep: { _ in })
            XCTFail("denied")
        } catch let e as GitHubDeviceFlow.Failure { XCTAssertEqual(e, .denied) }
    }

    // MARK: The real GitHub (by hand only)

    /// The manual smoke: `AIRC_P12_REAL_SMOKE=1 swift test --filter ParityP12Tests/testRealPublicRepositorySmoke`.
    /// Reads swiftlang/swift's open pull requests from api.github.com without an account (read-only, one page and one
    /// conditional repeat), applies them to a scratch folder and prints what it saw. Skipped in the suite: no network.
    func testRealPublicRepositorySmoke() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIRC_P12_REAL_SMOKE"] == "1", "manual smoke only")
        var real = GitHubClient(http: URLSessionLiveHTTP())
        real.maxPages = 1
        let folder = try book.create(query: GitHubPullQuery(repository: "swiftlang/swift"), inSpace: space)
        let d = try XCTUnwrap(book.definition(folder.id))
        let r = await real.fetch(d.query, token: nil, pages: [:])
        let out = book.apply(r, to: folder.id)
        let status = book.definition(folder.id)?.status
        print("P12 smoke: status \(String(describing: status)), \(out.added.count) rows; first: \(titles(folder.id).prefix(3))")
        if case .rateLimited = status { throw XCTSkip("GitHub's unauthenticated limit is used up on this network") }
        XCTAssertEqual(status, .ok)
        XCTAssertGreaterThan(out.added.count, 0, "swiftlang/swift has open pull requests")
        XCTAssertTrue(store.children(of: .pinned(spaceID: space), parent: folder.id)
            .allSatisfy { $0.savedURL?.hasPrefix("https://github.com/swiftlang/swift/pull/") == true })
        let again = await real.fetch(d.query, token: nil, pages: book.definition(folder.id)?.pages ?? [:])
        if case .success(let pulls, let pages, _) = again {
            print("P12 smoke: repeat with If-None-Match: \(pulls.count) pulls, etag \(pages.values.first?.etag ?? "none")")
        }
    }

    // MARK: Parsing

    func testParsingAndLinks() {
        XCTAssertEqual(GitHubClient.nextLink(#"<https://api.github.com/x?page=2>; rel="next", <https://api.github.com/x?page=5>; rel="last""#),
                       "https://api.github.com/x?page=2")
        XCTAssertNil(GitHubClient.nextLink(#"<https://api.github.com/x?page=1>; rel="prev""#))
        let search = #"{"items":[{"number":7,"title":"T","html_url":"https://github.com/a/b/pull/7","repository_url":"https://api.github.com/repos/a/b","pull_request":{"merged_at":null},"state":"open","draft":true,"user":{"login":"u"},"labels":[{"name":"bug"}]},{"number":8,"title":"An issue","html_url":"https://github.com/a/b/issues/8","state":"open"}]}"#
        let pulls = GitHubClient.parse(Data(search.utf8), fromSearch: true)
        XCTAssertEqual(pulls?.count, 1, "issues aren't pull requests")
        XCTAssertEqual(pulls?.first?.repository, "a/b")
        XCTAssertEqual(pulls?.first?.isDraft, true)
        XCTAssertEqual(pulls?.first?.labels, ["bug"])
        XCTAssertNil(GitHubClient.parse(Data("{}".utf8), fromSearch: false))
        XCTAssertNil(GitHubPullQuery.normalizedRepository("not a repo"))
        XCTAssertNil(GitHubPullQuery.normalizedRepository("a/../b"))
        XCTAssertEqual(GitHubPullQuery.normalizedRepository("github.com/swiftlang/swift/pulls"), "swiftlang/swift")
    }
}

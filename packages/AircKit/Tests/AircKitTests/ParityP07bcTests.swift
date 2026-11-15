// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// P07b (A07): ChatGPT, Perplexity or Claude from the Command Bar, as a web address in the profile. P07c (A08): Instant
/// Links' resolver with a fake results page and a fake model: how many, which addresses may open, the first organic
/// results, the model's picks, timeouts, cancellation and the fallback to a normal search.
final class ParityP07bcTests: XCTestCase {
    // MARK: P07b

    func testProviderAddressesAndEncoding() {
        XCTAssertEqual(AskAIProvider.chatGPT.url(for: "what is a monad?")?.absoluteString,
                       "https://chatgpt.com/?q=what%20is%20a%20monad%3F")
        XCTAssertEqual(AskAIProvider.claude.url(for: "c++ & 50% #1")?.absoluteString,
                       "https://claude.ai/new?q=c%2B%2B%20%26%2050%25%20%231")
        XCTAssertEqual(AskAIProvider.perplexity.url(for: "東京 天気")?.absoluteString,
                       "https://www.perplexity.ai/search?q=%E6%9D%B1%E4%BA%AC%20%E5%A4%A9%E6%B0%97")
        // Whitespace runs and new lines become one space; nothing to ask, no address.
        XCTAssertEqual(AskAIProvider.chatGPT.url(for: "  two\n\n words\t ")?.absoluteString, "https://chatgpt.com/?q=two%20words")
        XCTAssertNil(AskAIProvider.chatGPT.url(for: "   "))
        // A literal "+" is the question's, never a space.
        XCTAssertEqual(AskAIProvider.chatGPT.url(for: "1+1")?.absoluteString, "https://chatgpt.com/?q=1%2B1")
        // A long question is cut.
        let long = String(repeating: "a", count: AskAIProvider.maxPromptLength + 500)
        XCTAssertEqual(AskAIProvider.chatGPT.url(for: long)?.absoluteString.count,
                       "https://chatgpt.com/?q=".count + AskAIProvider.maxPromptLength)
        // Every provider's page is https on its own host.
        for p in AskAIProvider.allCases {
            let u = p.url(for: "x")
            XCTAssertEqual(u?.scheme, "https")
            XCTAssertTrue(SiteSearchTemplate.isValid(p.template), p.name)
            XCTAssertEqual(p.siteSearch.name, p.name)
        }
    }

    func testProviderKeywords() {
        XCTAssertTrue(AskAIProvider.chatGPT.matches("gpt"))
        XCTAssertTrue(AskAIProvider.chatGPT.matches("GPT"))
        XCTAssertTrue(AskAIProvider.chatGPT.matches("ChatGPT"))
        XCTAssertTrue(AskAIProvider.chatGPT.matches("chat"))
        XCTAssertFalse(AskAIProvider.chatGPT.matches("ch"))
        XCTAssertFalse(AskAIProvider.chatGPT.matches("gpt 4"))
        XCTAssertTrue(AskAIProvider.perplexity.matches("pplx"))
        XCTAssertTrue(AskAIProvider.perplexity.matches("perp"))
        XCTAssertTrue(AskAIProvider.claude.matches("Claude"))
        XCTAssertFalse(AskAIProvider.claude.matches("cla"))
        XCTAssertFalse(AskAIProvider.claude.matches(""))
    }

    func testAskRowOnlyForQuestions() {
        XCTAssertTrue(AskAIProvider.suggestsAsking("why is the sky blue"))
        XCTAssertTrue(AskAIProvider.suggestsAsking("monads?"))
        XCTAssertFalse(AskAIProvider.suggestsAsking("weather"))
        XCTAssertFalse(AskAIProvider.suggestsAsking("github.com/apple/swift"))
        XCTAssertFalse(AskAIProvider.suggestsAsking("/new split view"))
        XCTAssertFalse(AskAIProvider.suggestsAsking("   "))
    }

    func testSettingsArePerProfileAndOffByDefault() throws {
        var s = AskAISettings()
        XCTAssertNil(s.provider(for: "a"))
        s.set(.chatGPT, for: "a")
        s.set(.claude, for: "b")
        XCTAssertEqual(s.provider(for: "a"), .chatGPT)
        XCTAssertEqual(s.provider(for: "b"), .claude)
        XCTAssertNil(s.provider(for: "c"))
        s.set(nil, for: "b")
        XCTAssertNil(s.provider(for: "b"))
        // Round trip, and a provider from a newer build reads as off (the rest stays).
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(AskAISettings.self, from: data), s)
        let newer = try JSONDecoder().decode(AskAISettings.self, from: Data(#"{"profiles":{"a":"chatgpt","b":"future"}}"#.utf8))
        XCTAssertEqual(newer.provider(for: "a"), .chatGPT)
        XCTAssertNil(newer.provider(for: "b"))
        s.prune(keeping: ["z"])
        XCTAssertNil(s.provider(for: "a"))
    }

    // MARK: P07c: how many, which addresses

    func testCountsAreLimited() {
        XCTAssertEqual(InstantLinks.count(in: "pizza near the river"), 1)
        XCTAssertEqual(InstantLinks.count(in: "top 3 pizza places in Lisbon"), 3)
        XCTAssertEqual(InstantLinks.count(in: "best five hiking trails"), 5)
        XCTAssertEqual(InstantLinks.count(in: "Open 2 swift tutorials"), 2)
        XCTAssertEqual(InstantLinks.count(in: "4 best espresso machines"), 4)
        XCTAssertEqual(InstantLinks.count(in: "top 10 films"), InstantLinks.maxLinks)
        XCTAssertEqual(InstantLinks.count(in: "top 0 films"), 1)
        // A year or a model number isn't a count.
        XCTAssertEqual(InstantLinks.count(in: "best 2024 laptops"), 1)
        XCTAssertEqual(InstantLinks.count(in: "iphone 15 best price"), 1)
    }

    func testUnsafeAddressesNeverOpen() {
        for bad in ["javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,<b>x</b>", "file:///etc/hosts",
                    "blob:https://example.com/1", "about:blank", "chrome://settings", "airc://x", "ftp://example.com/f",
                    "https://user:pw@example.com/", "https://", "", "   ",
                    "https://www.google.com/url?q=javascript:alert(1)",
                    "https://duckduckgo.com/l/?uddg=data%3Atext%2Fhtml%2Cx",
                    "https://example.com/" + String(repeating: "a", count: 2100)] {
            XCTAssertNil(InstantLinks.safeURL(bad), bad)
        }
        XCTAssertEqual(InstantLinks.safeURL("https://example.com/a?b=1#c")?.absoluteString, "https://example.com/a?b=1#c")
        XCTAssertEqual(InstantLinks.safeURL("http://127.0.0.1:8080/x")?.absoluteString, "http://127.0.0.1:8080/x")
    }

    func testSearchEngineRedirectsAreFollowed() {
        XCTAssertEqual(InstantLinks.safeURL("https://www.google.com/url?q=https://example.org/page&sa=U")?.absoluteString,
                       "https://example.org/page")
        // Google's newer form (seen on a real results page): an empty q, the target in url.
        XCTAssertEqual(InstantLinks.safeURL("https://www.google.com/url?esrc=s&q=&rct=j&sa=U&url=https://developer.apple.com/videos/&ved=x")?.absoluteString,
                       "https://developer.apple.com/videos/")
        XCTAssertEqual(InstantLinks.safeURL("https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fp%3Fx%3D1&rut=abc")?.absoluteString,
                       "https://example.org/p?x=1")
        let b64 = Data("https://example.org/bing".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(InstantLinks.safeURL("https://www.bing.com/ck/a?!&&p=1&u=a1\(b64)&ntb=1")?.absoluteString, "https://example.org/bing")
    }

    func testCandidatesLeaveOutTheEngineAdsAndRepeats() {
        let search = DefaultSearch.engine(.google)
        let url = SearchEngine.google.searchURL(for: "lisbon trams")
        let links = [
            InstantLinksPageLink(title: "Images", href: "https://www.google.com/search?q=lisbon+trams&tbm=isch", isResult: false),
            InstantLinksPageLink(title: "Sign in", href: "https://accounts.google.com/ServiceLogin", isResult: false),
            InstantLinksPageLink(title: "Ad: Tram tours", href: "https://www.googleadservices.com/pagead/aclk?x=1", isResult: true),
            InstantLinksPageLink(title: "  Lisbon   trams\n– Guide ", href: "https://www.google.com/url?q=https://example.org/trams", isResult: true),
            InstantLinksPageLink(title: "Lisbon trams (again)", href: "https://example.org/trams#top", isResult: true),
            InstantLinksPageLink(title: "Evil", href: "javascript:alert(1)", isResult: true),
            InstantLinksPageLink(title: "Tram 28", href: "https://en.wikipedia.org/wiki/Lisbon_tram_28", isResult: true),
            InstantLinksPageLink(title: "", href: "https://visitlisboa.com/trams", isResult: false),
        ]
        let c = InstantLinks.candidates(links, searchURL: url, search: search)
        XCTAssertEqual(c.map(\.href), ["https://example.org/trams", "https://en.wikipedia.org/wiki/Lisbon_tram_28", "https://visitlisboa.com/trams"])
        XCTAssertEqual(c.first?.title, "Lisbon trams – Guide")
        XCTAssertEqual(c.last?.title, "visitlisboa.com")   // no title: its host
    }

    func testASiteDefaultKeepsTheSitesOwnPages() {
        let site = SiteSearch(name: "Shop", keyword: "shop", template: "https://shop.example/search?k=%s")
        let url = site.url(for: "socks")!
        let links = [
            InstantLinksPageLink(title: "Search again", href: "https://shop.example/search?k=wool", isResult: false),
            InstantLinksPageLink(title: "Wool socks", href: "https://shop.example/p/wool-socks", isResult: false),
            InstantLinksPageLink(title: "Elsewhere", href: "https://other.example/socks", isResult: false),
        ]
        let c = InstantLinks.candidates(links, searchURL: url, search: .site(site))
        XCTAssertEqual(c.map(\.href), ["https://shop.example/p/wool-socks"])
    }

    func testASearchEngineAsASiteDefaultIsReadAsAnEngine() {
        // DuckDuckGo's HTML results page made the default (P07d): its results are other sites, through its redirect.
        let ddg = SiteSearch(name: "DuckDuckGo HTML", keyword: "ddgh", template: "https://html.duckduckgo.com/html/?q=%s")
        let url = ddg.url(for: "swift")!
        let links = [
            InstantLinksPageLink(title: "Swift.org", href: "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2F&rut=x", isResult: true),
            InstantLinksPageLink(title: "Ad", href: "https://duckduckgo.com/y.js?ad_domain=x.example&u3=1", isResult: true),
            InstantLinksPageLink(title: "Next page", href: "https://html.duckduckgo.com/html/?q=swift&s=30", isResult: false),
        ]
        XCTAssertEqual(InstantLinks.candidates(links, searchURL: url, search: .site(ddg)).map(\.href), ["https://www.swift.org/"])
    }

    func testGoogleRedirectsOpenWithTheSiteGooglePrinted() {
        let url = SearchEngine.google.searchURL(for: "swift evolution")
        let goto = "https://www.google.com/goto?url=CAESqAEBxCJF1token"
        let links = [
            // A result: its title in a heading, Google's redirect, the site printed under it.
            InstantLinksPageLink(title: "GitHub - swiftlang/swift-evolution", href: goto, isResult: true,
                                 displaySite: "https://github.com › swiftlang › swift-evolution"),
            // The same redirect again (its snippet link): once.
            InstantLinksPageLink(title: "Swift Evolution on GitHub", href: goto, isResult: false, displaySite: "github.com"),
            // No site printed, not a result, an empty token, plain http, another host's /goto: never through the redirect.
            InstantLinksPageLink(title: "No site", href: "https://www.google.com/goto?url=CAESother", isResult: true),
            InstantLinksPageLink(title: "Translate this page", href: "https://www.google.com/goto?url=CAESx2", isResult: false, displaySite: "x.example"),
            InstantLinksPageLink(title: "Empty", href: "https://www.google.com/goto?url=", isResult: true, displaySite: "y.example"),
            InstantLinksPageLink(title: "Plain http", href: "http://www.google.com/goto?url=CAESz", isResult: true, displaySite: "z.example"),
            InstantLinksPageLink(title: "Not a site", href: "https://www.google.de/goto?url=CAESq", isResult: true, displaySite: "Videos"),
            InstantLinksPageLink(title: "Apple Developer", href: "https://www.google.de/goto?url=CAESw", isResult: true,
                                 displaySite: "developer.apple.com › videos"),
        ]
        let c = InstantLinks.candidates(links, searchURL: url, search: .engine(.google))
        XCTAssertEqual(c.map(\.title), ["GitHub - swiftlang/swift-evolution", "Apple Developer"])
        let picked = InstantLinks.firstResults(c, count: 2)
        XCTAssertEqual(picked.map(\.url.absoluteString), [goto, "https://www.google.de/goto?url=CAESw"])
        XCTAssertEqual(picked.map(\.host), ["github.com", "developer.apple.com"])
        XCTAssertEqual(picked.first?.displaySite, "https://github.com › swiftlang › swift-evolution")
        XCTAssertTrue(picked.allSatisfy(\.isRedirect))
        // A direct link is never shown as a redirect.
        XCTAssertFalse(InstantLink(title: "x", url: URL(string: "https://a.example/")!).isRedirect)
    }

    func testDisplayedSites() {
        XCTAssertEqual(InstantLinks.displayDomain("https://github.com › swiftlang"), "github.com")
        XCTAssertEqual(InstantLinks.displayDomain("www.lisbon.net › tram"), "lisbon.net")
        XCTAssertEqual(InstantLinks.displayDomain("en.wikipedia.org/wiki/Lisbon"), "en.wikipedia.org")
        XCTAssertNil(InstantLinks.displayDomain("Videos"))
        XCTAssertNil(InstantLinks.displayDomain(""))
        XCTAssertNil(InstantLinks.displayDomain("1:16:14"))
        XCTAssertNil(InstantLinks.displayDomain("javascript:alert(1)"))
    }

    func testFirstResultsPreferDifferentSites() {
        let r = ["https://a.example/1", "https://a.example/2", "https://b.example/1", "https://c.example/1"].map {
            InstantLinksPageLink(title: $0, href: $0, isResult: true)
        }
        XCTAssertEqual(InstantLinks.firstResults(r, count: 1).map(\.url.absoluteString), ["https://a.example/1"])
        XCTAssertEqual(InstantLinks.firstResults(r, count: 3).map(\.url.absoluteString),
                       ["https://a.example/1", "https://b.example/1", "https://c.example/1"])
        XCTAssertEqual(InstantLinks.firstResults(r, count: 5).count, 4)
    }

    func testModelPicksAreChecked() {
        let o = (1...4).map { InstantLinksPageLink(title: "t\($0)", href: "https://e\($0).example/", isResult: false) }
        XCTAssertEqual(InstantLinks.picks([3, 3, 0, 9, -1, 1, 2], from: o, count: 2).map(\.title), ["t3", "t1"])
        XCTAssertTrue(InstantLinks.picks([], from: o, count: 2).isEmpty)
    }

    func testScriptValueParses() {
        let v: [String: Any] = ["links": [["A", "https://a.example/", 1, "a.example › x"], ["B", "https://b.example/"], ["C", "https://c.example/", 0, ""], ["bad"], 3]]
        XCTAssertEqual(InstantLinksPageLink.parse(script: v),
                       [InstantLinksPageLink(title: "A", href: "https://a.example/", isResult: true, displaySite: "a.example › x"),
                        InstantLinksPageLink(title: "B", href: "https://b.example/", isResult: false),
                        InstantLinksPageLink(title: "C", href: "https://c.example/", isResult: false)])
        XCTAssertNil(InstantLinksPageLink.parse(script: nil))
        XCTAssertNil(InstantLinksPageLink.parse(script: ["x": 1]))
    }

    // MARK: P07c: the resolver

    private struct FakeFetcher: InstantLinksFetcher {
        var links: [InstantLinksPageLink] = []
        var delay: TimeInterval = 0
        var fails = false
        let asked = Box<[URL]>([])
        func links(on searchURL: URL) async throws -> [InstantLinksPageLink] {
            asked.value.append(searchURL)
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }   // ignores cancellation
            if fails { throw URLError(.cannotConnectToHost) }
            return links
        }
    }

    private struct FakeModel: InstantLinksModel {
        var answer: [Int] = []
        var delay: TimeInterval = 0
        var declines = false
        let asked = Box<[InstantLinksChoiceRequest]>([])
        func choose(_ request: InstantLinksChoiceRequest) async throws -> [Int] {
            asked.value.append(request)
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            if declines { throw AIRequestDeclined(.refusal) }
            return answer
        }
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T {
            get { lock.withLock { v } }
            set { lock.withLock { v = newValue } }
        }
    }

    private let shop = SiteSearch(name: "Loop", keyword: "lp", template: "http://127.0.0.1:9/find?q=%s")
    private var organic: [InstantLinksPageLink] {
        [InstantLinksPageLink(title: "Home", href: "http://127.0.0.1:9/", isResult: false),
         InstantLinksPageLink(title: "Tram 28 guide", href: "http://127.0.0.1:9/a", isResult: true),
         InstantLinksPageLink(title: "Bad", href: "javascript:alert(1)", isResult: true),
         InstantLinksPageLink(title: "Tram 15 guide", href: "http://127.0.0.1:9/b", isResult: true),
         InstantLinksPageLink(title: "Tram 12 guide", href: "http://127.0.0.1:9/c", isResult: true)]
    }

    private func options(fetch: TimeInterval = 2, model: TimeInterval = 1) -> InstantLinksResolver.Options {
        var o = InstantLinksResolver.Options()
        o.fetchTimeout = fetch
        o.modelTimeout = model
        return o
    }

    func testFirstOrganicResultWithoutTheModel() async {
        let fetcher = FakeFetcher(links: organic)
        let model = FakeModel(answer: [1])
        let r = InstantLinksResolver(fetcher: fetcher, model: model, options: options())
        let out = await r.resolve("tram 28 & more", search: .site(shop))
        guard case .open(let plan) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(plan.links.map(\.url.absoluteString), ["http://127.0.0.1:9/a"])
        XCTAssertEqual(plan.picker, .firstResults)
        XCTAssertEqual(plan.requested, 1)
        // The search went to the profile's default (the site), encoded as its site search encodes it.
        XCTAssertEqual(fetcher.asked.value.map(\.absoluteString), ["http://127.0.0.1:9/find?q=tram+28+%26+more"])
        XCTAssertTrue(model.asked.value.isEmpty, "the model isn't asked when the page marks its results")
    }

    func testTopThreeOpensThreeAndNeverMoreThanFive() async {
        let r = InstantLinksResolver(fetcher: FakeFetcher(links: organic), model: nil, options: options())
        guard case .open(let plan) = await r.resolve("top 3 tram guides", search: .site(shop)) else { return XCTFail() }
        XCTAssertEqual(plan.links.map(\.title), ["Tram 28 guide", "Tram 15 guide", "Tram 12 guide"])
        let many = (1...9).map { InstantLinksPageLink(title: "R\($0)", href: "https://r\($0).example/", isResult: true) }
        let r2 = InstantLinksResolver(fetcher: FakeFetcher(links: many), model: nil, options: options())
        guard case .open(let plan2) = await r2.resolve("top 9 results", search: .engine(.duckDuckGo)) else { return XCTFail() }
        XCTAssertEqual(plan2.links.count, InstantLinks.maxLinks)
        XCTAssertEqual(plan2.requested, InstantLinks.maxLinks)
    }

    func testTheModelPicksWhenThePageMarksNoResults() async {
        let plain = organic.map { InstantLinksPageLink(title: $0.title, href: $0.href, isResult: false) }
        let model = FakeModel(answer: [3, 2])
        let r = InstantLinksResolver(fetcher: FakeFetcher(links: plain), model: model, options: options())
        guard case .open(let plan) = await r.resolve("best two tram guides", search: .site(shop)) else { return XCTFail() }
        XCTAssertEqual(plan.picker, .model)
        XCTAssertEqual(plan.links.map(\.title), ["Tram 15 guide", "Tram 28 guide"])
        // It saw titles and hosts only, numbered, never the unsafe link.
        let asked = model.asked.value.first
        XCTAssertEqual(asked?.count, 2)
        XCTAssertEqual(asked?.options.map(\.title), ["Home", "Tram 28 guide", "Tram 15 guide", "Tram 12 guide"])
        XCTAssertEqual(asked?.options.first?.host, "127.0.0.1")
        XCTAssertTrue(InstantLinksPrompt.prompt(for: asked!).contains("2. Tram 28 guide (127.0.0.1)"))
    }

    func testFallbacksAreANormalSearch() async {
        let search = DefaultSearch.site(shop)
        let want = shop.url(for: "trams")
        let plain = organic.map { InstantLinksPageLink(title: $0.title, href: $0.href, isResult: false) }
        func outcome(_ f: FakeFetcher, _ m: FakeModel?, fetch: TimeInterval = 2, model: TimeInterval = 1) async -> InstantLinksOutcome {
            await InstantLinksResolver(fetcher: f, model: m, options: options(fetch: fetch, model: model)).resolve("trams", search: search)
        }
        var r = await outcome(FakeFetcher(fails: true), nil)
        XCTAssertEqual(r, .search(want, .failed))
        r = await outcome(FakeFetcher(links: []), nil)
        XCTAssertEqual(r, .search(want, .noResults))
        r = await outcome(FakeFetcher(links: [InstantLinksPageLink(title: "x", href: "data:text/html,x", isResult: true)]), nil)
        XCTAssertEqual(r, .search(want, .noResults))
        r = await outcome(FakeFetcher(links: plain), nil)
        XCTAssertEqual(r, .search(want, .noResults), "no marked results and no model")
        r = await outcome(FakeFetcher(links: plain), FakeModel(declines: true))
        XCTAssertEqual(r, .search(want, .declined))
        r = await outcome(FakeFetcher(links: plain), FakeModel(answer: [42]))
        XCTAssertEqual(r, .search(want, .declined))
        // An address or nothing isn't a query.
        let none = await InstantLinksResolver(fetcher: FakeFetcher(), model: nil).resolve("example.com/x", search: search)
        XCTAssertEqual(none, .search(nil, .notAQuery))
        let empty = await InstantLinksResolver(fetcher: FakeFetcher(), model: nil).resolve("  ", search: search)
        XCTAssertEqual(empty, .search(nil, .notAQuery))
    }

    func testTimeoutsFallBackInTime() async {
        let want = shop.url(for: "trams")
        let start = Date()
        // A results page that never answers in time (and ignores cancellation).
        let slow = await InstantLinksResolver(fetcher: FakeFetcher(links: organic, delay: 5), model: nil,
                                              options: options(fetch: 0.3)).resolve("trams", search: .site(shop))
        XCTAssertEqual(slow, .search(want, .timeout))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let plain = organic.map { InstantLinksPageLink(title: $0.title, href: $0.href, isResult: false) }
        let start2 = Date()
        let stuck = await InstantLinksResolver(fetcher: FakeFetcher(links: plain), model: FakeModel(answer: [1], delay: 5),
                                               options: options(model: 0.3)).resolve("trams", search: .site(shop))
        XCTAssertEqual(stuck, .search(want, .timeout))
        XCTAssertLessThan(Date().timeIntervalSince(start2), 2)
    }

    func testCancellationOpensNothing() async {
        let r = InstantLinksResolver(fetcher: FakeFetcher(links: organic, delay: 3), model: nil, options: options(fetch: 10))
        let shop = self.shop
        let task = Task { await r.resolve("trams", search: .site(shop)) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let start = Date()
        task.cancel()
        let out = await task.value
        XCTAssertEqual(out, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}

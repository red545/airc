// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// DuckDuckGo-style bangs in the Command Bar (docs/user/command-bar.md): "!yt cats" or "cats !yt" searches YouTube for
/// "cats". A bang is a word that starts with "!", anywhere in what's typed. It names a site search: the profile's own
/// (Settings → Site Search, its shortcut: "!gdocs", "!lb"), else one of Airc's built-in bangs (`builtIn`). Everything
/// is resolved here, on the Mac: nothing asks DuckDuckGo. A bang neither knows is left in the text, so a profile that
/// searches DuckDuckGo still gets DuckDuckGo's own bangs from its normal search.
public enum SiteSearchBang {
    /// What a bang in the text asks for.
    public struct Match: Equatable, Sendable {
        /// The bang's word without "!", lowercased ("yt").
        public let keyword: String
        /// The rest of the text, trimmed, the bang's word taken out ("cats" for "cats !yt").
        public let query: String
        /// The site it searches.
        public let site: SiteSearch

        /// The site's search page for the query; nil while there's no query yet ("!yt" alone).
        public var url: URL? {
            guard let u = site.url(for: query) else { return nil }
            // Test builds' loopback stand-in (SearchEngineStandIn), for Airc's own sites only (built-in bangs, seeded
            // site searches): a check sees which site was asked, and nothing leaves the Mac. Sites someone added keep
            // their own addresses.
            guard SearchEngineStandIn.origin != nil,
                  SiteSearchBang.isBuiltIn(site) || site.id.hasPrefix("default.") else { return u }
            return URL(string: SearchEngineStandIn.route(u.absoluteString))
        }
    }

    public static let idPrefix = "bang."

    /// One of `builtIn`'s sites (not the profile's own).
    public static func isBuiltIn(_ s: SiteSearch) -> Bool { s.id.hasPrefix(idPrefix) }

    /// The bang in `text`, if one names a site: the first word "!<keyword>" whose keyword is one of `own`'s shortcuts
    /// (ignoring case) or a built-in bang. Not a word that only contains "!" ("example.com/#!/x", "wow!"), not "!" or
    /// "!!" alone, and not a word whose next character isn't a letter or digit ("!?"). Costs a byte scan when there's
    /// no "!" in the text, the one thing every keystroke without a bang pays.
    public static func match(_ text: String, own: SiteSearchIndex?) -> Match? {
        guard text.utf8.contains(0x21) else { return nil }
        var i = text.startIndex
        while i < text.endIndex {
            // The next word: from a non-space to the next space.
            guard let start = text[i...].firstIndex(where: { !$0.isWhitespace }) else { break }
            let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            i = end
            guard text[start] == "!" else { continue }
            let word = text[text.index(after: start)..<end]
            guard let first = word.first, first.isLetter || first.isNumber, !word.contains("!") else { continue }
            let keyword = word.lowercased()
            guard let site = own?.site(forKeyword: keyword) ?? builtIn[keyword] else { continue }
            let before = text[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
            let after = text[end...].trimmingCharacters(in: .whitespacesAndNewlines)
            let query = before.isEmpty ? after : after.isEmpty ? before : before + " " + after
            return Match(keyword: keyword, query: query, site: site)
        }
        return nil
    }

    /// Whether `text` has a word that looks like a bang ("!yt", "!nosuchbang"), known or not: the Command Bar doesn't
    /// complete such text inline.
    public static func hasBangWord(_ text: String) -> Bool {
        guard text.utf8.contains(0x21) else { return false }
        var previous: Character = " "
        for (n, ch) in zip(text, text.dropFirst()) {
            if n == "!", previous.isWhitespace, ch.isLetter || ch.isNumber { return true }
            previous = n
        }
        return false
    }

    /// Airc's built-in bangs: the common DuckDuckGo ones (their shortcuts), keyed by shortcut. Several shortcuts can
    /// name one site ("w" and "wiki"). Made once; each keystroke only looks one up.
    public static let builtIn: [String: SiteSearch] = {
        var table: [String: SiteSearch] = [:]
        for (keywords, name, template) in entries {
            let s = SiteSearch(id: idPrefix + keywords[0], name: name, keyword: keywords[0], template: template)
            for k in keywords where table[k] == nil { table[k] = s }
        }
        return table
    }()

    /// Every built-in site once, in the table's order (Settings and the tests list them).
    public static var builtInSites: [SiteSearch] {
        entries.map { e in builtIn[e.0[0]]! }
    }

    /// Google Translate translates into the Mac's first language ("de" for German), English where it has none.
    static var translateTarget: String {
        let code = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        return code.isEmpty ? "en" : code
    }

    private static let entries: [([String], String, String)] = [
        (["g", "google"], "Google", "https://www.google.com/search?q=%s"),
        (["gm", "maps", "gmaps"], "Google Maps", "https://www.google.com/maps/search/%s"),
        (["gt", "translate"], "Google Translate", "https://translate.google.com/?sl=auto&tl=\(translateTarget)&text=%s&op=translate"),
        (["gi", "gimages"], "Google Images", "https://www.google.com/search?tbm=isch&q=%s"),
        (["gn", "gnews"], "Google News", "https://news.google.com/search?q=%s"),
        (["yt", "youtube"], "YouTube", "https://www.youtube.com/results?search_query=%s"),
        (["w", "wiki", "wikipedia"], "Wikipedia", "https://en.wikipedia.org/wiki/Special:Search?search=%s"),
        (["a", "amazon", "amz"], "Amazon", "https://www.amazon.com/s?k=%s"),
        (["gh", "github"], "GitHub", "https://github.com/search?q=%s"),
        (["so", "stackoverflow"], "Stack Overflow", "https://stackoverflow.com/search?q=%s"),
        (["r", "reddit"], "Reddit", "https://www.reddit.com/search/?q=%s"),
        (["imdb"], "IMDb", "https://www.imdb.com/find/?q=%s"),
        (["x", "twitter", "tw"], "X", "https://x.com/search?q=%s"),
        (["ddg", "duckduckgo"], "DuckDuckGo", "https://duckduckgo.com/?q=%s"),
        (["b", "bing"], "Bing", "https://www.bing.com/search?q=%s"),
        (["npm"], "npm", "https://www.npmjs.com/search?q=%s"),
        (["mdn"], "MDN Web Docs", "https://developer.mozilla.org/en-US/search?q=%s"),
        (["hn", "hackernews"], "Hacker News", "https://hn.algolia.com/?q=%s"),
        (["wa", "wolfram", "wolframalpha"], "WolframAlpha", "https://www.wolframalpha.com/input?i=%s"),
        (["ebay"], "eBay", "https://www.ebay.com/sch/i.html?_nkw=%s"),
        (["sp", "spotify"], "Spotify", "https://open.spotify.com/search/%s"),
        (["applemaps", "amaps"], "Apple Maps", "https://maps.apple.com/?q=%s"),
        (["applemusic", "itunes"], "Apple Music", "https://music.apple.com/us/search?term=%s"),
        (["li", "linkedin"], "LinkedIn", "https://www.linkedin.com/search/results/all/?keywords=%s"),
        (["gdrive", "drive"], "Google Drive", "https://drive.google.com/drive/search?q=%s"),
        (["gs", "scholar"], "Google Scholar", "https://scholar.google.com/scholar?q=%s"),
        (["pypi"], "PyPI", "https://pypi.org/search/?q=%s"),
        (["crates"], "crates.io", "https://crates.io/search?q=%s"),
        (["brave"], "Brave Search", "https://search.brave.com/search?q=%s"),
        (["kagi"], "Kagi", "https://kagi.com/search?q=%s"),
        (["ecosia"], "Ecosia", "https://www.ecosia.org/search?q=%s"),
        (["pplx", "perplexity"], "Perplexity", "https://www.perplexity.ai/search?q=%s"),
        (["etsy"], "Etsy", "https://www.etsy.com/search?q=%s"),
        (["pin", "pinterest"], "Pinterest", "https://www.pinterest.com/search/pins/?q=%s"),
        (["twitch"], "Twitch", "https://www.twitch.tv/search?term=%s"),
    ]
}

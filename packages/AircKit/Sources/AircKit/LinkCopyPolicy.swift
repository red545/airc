// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Arc's link copying (C05, C06): Copy URL and Copy Link hand over a clean link, without the tracking parameters that
/// campaigns, ad clicks and share buttons add ("Copied a clean link without trackers"); every parameter a page needs to
/// show the same thing stays, in its order, with its own encoding, and so does the fragment.
public enum LinkCopyPolicy {
    /// The link without trackers, and whether any were there. A link with nothing to remove comes back unchanged,
    /// character for character.
    public static func cleaned(_ url: String) -> (url: String, removedTrackers: Bool) {
        guard var c = URLComponents(string: url), let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let items = c.percentEncodedQueryItems, !items.isEmpty else { return (url, false) }
        let host = (c.host ?? "").lowercased()
        let kept = items.filter { !isTracker($0.name, host: host, path: c.path) }
        guard kept.count < items.count, let out = { () -> String? in
            c.percentEncodedQueryItems = kept.isEmpty ? nil : kept
            return c.string
        }() else { return (url, false) }
        return (out, true)
    }

    public static func clean(_ url: String) -> String { cleaned(url).url }

    /// Whether `name` only tracks, on any site or on `host`'s own.
    static func isTracker(_ name: String, host: String, path: String) -> Bool {
        let n = name.lowercased()
        if trackers.contains(n) || trackerPrefixes.contains(where: n.hasPrefix) { return true }
        for rule in siteRules where rule.matches(host, path) {
            if rule.names.contains(n) || rule.prefixes.contains(where: n.hasPrefix) { return true }
        }
        return false
    }

    /// Click and campaign identifiers that every site gets the same way (ads, newsletters, analytics linkers).
    static let trackers: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "gad_source", "gad_campaignid", "msclkid", "yclid",
        "ysclid", "twclid", "ttclid", "li_fat_id", "igshid", "igsh", "epik", "irclickid", "rb_clickid", "s_kwcid", "ef_id",
        "wickedid", "srsltid", "_gl", "_openstat", "_bta_tid", "_bta_c", "mc_cid", "mc_eid", "mkt_tok", "ml_subscriber",
        "ml_subscriber_hash", "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv", "__s", "_hsenc", "_hsmi", "__hstc",
        "__hssc", "__hsfp", "hsctatracking", "pk_campaign", "pk_kwd", "pk_keyword", "pk_source", "pk_medium",
        "pk_content", "pk_cid", "sb_referer_host",
    ]

    static let trackerPrefixes = ["utm_", "mtm_", "matomo_", "piwik_", "hsa_", "stm_", "oft_"]

    /// What a site's own share buttons and result lists add.
    struct SiteRule {
        /// Registrable names ("youtube.com"); a name ending in "." is any country's ("amazon." matches amazon.co.uk).
        let hosts: [String]
        var path: String? = nil
        var names: Set<String> = []
        var prefixes: [String] = []

        func matches(_ host: String, _ p: String) -> Bool {
            if let path, !p.hasPrefix(path) { return false }
            let labels = host.split(separator: ".").map(String.init)
            return hosts.contains { h in
                if h.hasSuffix(".") { return labels.dropLast().contains(String(h.dropLast())) }
                return host == h || host.hasSuffix("." + h)
            }
        }
    }

    static let siteRules: [SiteRule] = [
        SiteRule(hosts: ["youtube.com", "youtu.be"], names: ["si", "feature", "pp"]),
        SiteRule(hosts: ["x.com", "twitter.com"], names: ["s", "t", "ref_src", "ref_url"]),
        SiteRule(hosts: ["spotify.com"], names: ["si"]),
        SiteRule(hosts: ["amazon."], names: ["_encoding", "content-id", "crid", "sprefix", "ref_", "linkcode", "linkid",
                                            "ascsubtag", "qid", "sr", "dib", "dib_tag"], prefixes: ["pd_rd_", "pf_rd_"]),
        SiteRule(hosts: ["ebay."], names: ["_trkparms", "_trksid", "_from", "hash", "_skw", "itmmeta", "itmprp", "mkcid",
                                          "mkevt", "mkrid", "campid", "toolid", "customid"]),
        SiteRule(hosts: ["linkedin.com"], names: ["trk", "trackingid", "lipi", "midtoken", "midsig", "trkemail"]),
        SiteRule(hosts: ["reddit.com"], names: ["share_id", "rdt"]),
        SiteRule(hosts: ["tiktok.com"], names: ["_r", "_t", "is_from_webapp", "sender_device", "sender_web_id"]),
        SiteRule(hosts: ["facebook.com"], names: ["mibextid", "rdid", "sfnsn"]),
        SiteRule(hosts: ["google."], path: "/search", names: ["ved", "ei", "sca_esv", "sca_upv", "sxsrf", "gs_lcrp", "gs_lp",
                                                            "sourceid", "rlz", "iflsig", "uact", "sclient", "oq", "aqs",
                                                            "bih", "biw", "dpr", "prmd", "fbs"]),
    ]

    /// A link that opens the page scrolled to `selection`, highlighted (a text fragment, `#:~:text=`; Arc's "share a link
    /// directly to this text"). The page's own fragment gives way; trackers go. Nil when there are no words or the page
    /// isn't a website.
    ///
    /// The fragment has to find the text again in any browser, so it follows how browsers match one: a single
    /// `text=` term matches only inside one block (paragraph, list item, cell), and a range (`start,end`) needs only
    /// its start to begin a word and its end to end one. So:
    /// - a short passage on one line goes as it is (whitespace collapsed);
    /// - a long one, or one across several lines or blocks, goes as a range: its first and its last words (from the
    ///   first and the last line);
    /// - a run without spaces (Chinese, Japanese, a long code word) is cut by characters, never in the middle of one.
    public static func textFragmentURL(_ url: String, selection: String) -> String? {
        let lines = selection.split(whereSeparator: \.isNewline).map(Self.words).filter { !$0.isEmpty }
        guard let first = lines.first, let last = lines.last, var c = URLComponents(string: clean(url)),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        let text: String
        if lines.count == 1, first.count <= exactWords, first.joined(separator: " ").count <= exactCharacters {
            text = fragmentTerm(first.joined(separator: " "))
        } else {
            let start = edge(first, fromStart: true), end = edge(last, fromStart: false)
            text = fragmentTerm(start) + "," + fragmentTerm(end)
        }
        c.percentEncodedFragment = ":~:text=" + text
        return c.string
    }

    /// Up to this many words (and characters) on one line go whole.
    static let exactWords = 8, exactCharacters = 120
    /// A range's start or end: up to this many words, within this many characters.
    static let edgeWords = 4, edgeCharacters = 48

    static func words(_ s: Substring) -> [String] {
        s.split(whereSeparator: { (c: Character) in c.isWhitespace || c.isNewline }).map(String.init)
    }

    /// A range's start (its first words) or end (its last words); a first or last word too long for that is cut by
    /// characters, from its outer side.
    static func edge(_ words: [String], fromStart: Bool) -> String {
        let ordered = fromStart ? words : words.reversed()
        var picked: [String] = []
        var length = 0
        for w in ordered.prefix(edgeWords) {
            let extra = (picked.isEmpty ? 0 : 1) + w.count
            if !picked.isEmpty, length + extra > edgeCharacters { break }
            picked.append(w)
            length += extra
        }
        if picked.count == 1, let w = picked.first, w.count > edgeCharacters {
            let keep = edgeCharacters / 2
            return fromStart ? String(w.prefix(keep)) : String(w.suffix(keep))
        }
        return (fromStart ? picked : picked.reversed()).joined(separator: " ")
    }

    /// One term of a `text=` directive, percent-encoded. The directive's own characters (- , &) are escaped inside it.
    static func fragmentTerm(_ s: String) -> String {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "-,&#%")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// The toast after copying `count` links (Arc's wording): clean ones say so.
    public static func toast(count: Int, removedTrackers: Bool, single: String) -> String {
        if removedTrackers { return count == 1 ? "Copied a clean link without trackers" : "Copied clean links without trackers" }
        return count == 1 ? single : "Copied \(count) Links"
    }
}

/// Arc's quote links (C06): its labels, and the pages that get a plain link instead.
///
/// Arc 1.171's own strings: the button "Copy Quote Link" (on the offer after ⌘C), the toast "Copied Link" with the
/// sublabel "With Quote" and a filled quote bubble. A page where a link to the text can't work gets the page's clean link
/// and the plain "Copied Link".
public enum QuoteLink {
    public static let copyTitle = "Copy Quote Link"
    public static let copiedToast = "Copied Link"
    public static let withQuote = "With Quote"
    public static let symbol = "quote.bubble.fill"

    /// Why a page gets a plain link.
    public enum OptOut: String, Sendable {
        /// Not a website (chrome:, about:, file:, data:, a note…): nobody else can open it.
        case notWebsite
        /// A PDF: browsers show it in a viewer that text fragments don't reach.
        case pdf
        /// A private window: a quote of what was read there would outlive it.
        case privateWindow
        /// The site sends `Document-Policy: force-load-at-top`: it always opens at the top, so the link would never
        /// scroll to the text.
        case forceLoadAtTop
        /// The page didn't say in time what it is (a viewer page that runs no script, a busy page): no promise of a
        /// link that finds the text.
        case unreadable
    }

    /// What is known about a page. `contentType` and `documentPolicy` are nil while unknown.
    public struct Page: Equatable, Sendable {
        public var url: String
        public var contentType: String?
        public var documentPolicy: String?
        public var isPrivate: Bool
        /// The page was asked and didn't answer.
        public var unreadable: Bool

        public init(url: String, contentType: String? = nil, documentPolicy: String? = nil, isPrivate: Bool = false,
                    unreadable: Bool = false) {
            self.url = url
            self.contentType = contentType
            self.documentPolicy = documentPolicy
            self.isPrivate = isPrivate
            self.unreadable = unreadable
        }
    }

    /// Why `page` gets a plain link, or nil when a quote link works there.
    public static func optOut(_ page: Page) -> OptOut? {
        if page.isPrivate { return .privateWindow }
        guard let u = URLComponents(string: page.url), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
              !(u.host ?? "").isEmpty else { return .notWebsite }
        if let type = page.contentType?.lowercased() {
            if type.hasPrefix("application/pdf") || type.hasPrefix("application/x-pdf") { return .pdf }
        } else if u.path.lowercased().hasSuffix(".pdf") {
            return .pdf
        }
        if let policy = page.documentPolicy, forcesLoadAtTop(policy) { return .forceLoadAtTop }
        return page.unreadable ? .unreadable : nil
    }

    /// Whether a `Document-Policy` header (a structured-header dictionary; several headers joined with commas) turns
    /// `force-load-at-top` on: `force-load-at-top` or `force-load-at-top=?1`, with or without parameters.
    public static func forcesLoadAtTop(_ documentPolicy: String) -> Bool {
        for member in documentPolicy.split(separator: ",") {
            let item = member.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.first?.lowercased() == "force-load-at-top" else { continue }
            return parts.count == 1 || parts[1] == "?1"
        }
        return false
    }

    /// What a quote copy writes: the link to `selection` (`withQuote`), or the page's clean link when the page opts out
    /// or there are no words. Nil when there's nothing to copy at all.
    public static func copy(_ page: Page, selection: String) -> (link: String, withQuote: Bool)? {
        if optOut(page) == nil, let link = LinkCopyPolicy.textFragmentURL(page.url, selection: selection) { return (link, true) }
        guard !page.url.isEmpty else { return nil }
        return (LinkCopyPolicy.clean(page.url), false)
    }
}

/// An answer that arrives later than the request (Copy URL as Quote asks the page for its selection): only the latest
/// request may write, once, and only while what it was asked about is still what the person sees and nothing else was
/// copied meanwhile. A later copy, another tab, a Peek opening or closing, or a navigation make it come to nothing.
public final class LatestAnswerGate<Context: Equatable> {
    public struct Ticket {
        let generation: Int
        public let context: Context
        let changeCount: Int
    }

    private var generation = 0

    public init() {}

    /// A new request; any earlier one can no longer write.
    public func begin(_ context: Context, changeCount: Int) -> Ticket {
        generation += 1
        return Ticket(generation: generation, context: context, changeCount: changeCount)
    }

    /// Something else was copied, or the context changed: the pending answer is dropped.
    public func cancel() { generation += 1 }

    /// Whether `ticket`'s answer may be written now (true at most once per ticket).
    public func finish(_ ticket: Ticket, now: Context, changeCount: Int) -> Bool {
        guard ticket.generation == generation, ticket.context == now, ticket.changeCount == changeCount else { return false }
        generation += 1
        return true
    }
}

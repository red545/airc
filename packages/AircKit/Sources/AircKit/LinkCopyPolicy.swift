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
    /// directly to this text"). A long passage is found by its first and last words. The page's own fragment gives way;
    /// trackers go. Nil when there are no words or the page isn't a website.
    public static func textFragmentURL(_ url: String, selection: String) -> String? {
        let words = selection.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !words.isEmpty, var c = URLComponents(string: clean(url)),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        func encoded(_ w: ArraySlice<String>) -> String {
            // The directive's own characters (- , &) are escaped inside its terms.
            var allowed = CharacterSet.urlFragmentAllowed
            allowed.remove(charactersIn: "-,&#%")
            return w.joined(separator: " ").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        let text = words.count <= 8 ? encoded(words[...]) : encoded(words.prefix(4)) + "," + encoded(words.suffix(4))
        c.percentEncodedFragment = ":~:text=" + text
        return c.string
    }

    /// The toast after copying `count` links (Arc's wording): clean ones say so.
    public static func toast(count: Int, removedTrackers: Bool, single: String) -> String {
        if removedTrackers { return count == 1 ? "Copied a clean link without trackers" : "Copied clean links without trackers" }
        return count == 1 ? single : "Copied \(count) Links"
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

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Airc's Boost gallery (BST-3): starter Boosts for popular sites, built into the app. Arc's gallery (arc.net/boosts)
/// was a website of community Boosts with a screenshot and "Get Boost"; Airc has no server for Boosts, so its gallery
/// is this list, reviewed like any shared Boost before it's installed, and the community shares files and links.
/// Style only: no gallery Boost has JavaScript. Each entry is an ordinary Boost file (BoostFile, validated by the
/// tests), with Airc as the author, a fixed id and a revision, so a later Airc with a better version can offer it as
/// an update.
public enum BoostGallery {
    public struct Entry: Sendable, Identifiable {
        public var file: BoostFile
        /// The page the gallery opens after installing it, to show it working.
        public var page: URL
        public var id: String { file.id ?? file.site }
    }

    /// The gallery's author line.
    public static let author = "Airc"

    public static let entries: [Entry] = [
        entry("81ff8dfb-9215-4abd-8e9f-11d5c8fd16b4", "Bookish Wikipedia", "wikipedia.org",
              "A warm paper tint, Charter and roomier lines: Wikipedia like a good book.",
              page: "https://en.wikipedia.org/wiki/Typography",
              colors: BoostColors(hue: 0.09, tint: 0.34, brightness: 1, contrast: 1.02),
              font: BoostFont(family: .charter, size: 1),
              css: """
                  .mw-parser-output { line-height: 1.7 !important; }
                  .mw-parser-output p, .mw-parser-output li { font-size: 1.04em !important; }
                  """),
        entry("c332e331-d497-462d-95c9-449d289ecc33", "Night Wikipedia", "wikipedia.org",
              "Every article dark, photos left as they are.",
              page: "https://en.wikipedia.org/wiki/Night_sky",
              colors: BoostColors(brightness: 0.95, contrast: 0.92, invert: true)),
        entry("3c34698c-abe6-467b-bd1d-827a1161c88e", "Comfortable Hacker News", "ycombinator.com",
              "Larger text, a readable column and some air between comments.",
              page: "https://news.ycombinator.com/",
              colors: BoostColors(hue: 0.07, tint: 0.18),
              font: BoostFont(family: .system, size: 2),
              css: """
                  #hnmain { width: min(980px, 96%) !important; }
                  .commtext { line-height: 1.5 !important; }
                  .comment-tree .comtr td.default { padding-bottom: 6px !important; }
                  """),
        entry("bf57ce30-e9c9-4721-8d6d-df2b94312061", "Focus YouTube", "youtube.com",
              "No Shorts shelves and no suggestions beside or after a video: just what you came for.",
              page: "https://www.youtube.com/",
              css: """
                  ytd-reel-shelf-renderer, ytd-rich-shelf-renderer[is-shorts], ytd-rich-section-renderer:has(ytd-rich-shelf-renderer[is-shorts]) { display: none !important; }
                  ytd-guide-entry-renderer:has(a[title="Shorts"]), ytd-mini-guide-entry-renderer[aria-label="Shorts"] { display: none !important; }
                  #secondary #related, .ytp-endscreen-content, .ytp-ce-element { display: none !important; }
                  """),
        entry("0b9ad270-aec8-48a7-9fd7-f5e65e285fc3", "Wide GitHub", "github.com",
              "Code and READMEs use the whole window, with easier reading.",
              page: "https://github.com/",
              css: """
                  .container-xl, .container-lg, .container-md { max-width: none !important; }
                  .markdown-body { font-size: 15px !important; line-height: 1.65 !important; }
                  """),
        entry("8002e481-3f0b-4837-b15a-771c74887ced", "MDN Reader", "mozilla.org",
              "MDN's docs in Georgia with a cool tint; code stays monospaced.",
              page: "https://developer.mozilla.org/en-US/docs/Web/CSS",
              colors: BoostColors(hue: 0.58, tint: 0.16),
              font: BoostFont(family: .georgia, size: 0),
              css: """
                  .main-page-content { line-height: 1.7 !important; }
                  """),
        entry("b8478821-a0e4-4333-9147-09ff65d0d933", "Calm News", "nytimes.com",
              "Softer colors, Georgia throughout and no ad slots.",
              page: "https://www.nytimes.com/",
              colors: BoostColors(hue: 0.1, tint: 0.2, saturation: 0.65),
              font: BoostFont(family: .georgia, size: 0),
              css: """
                  [data-testid="StandardAd"], [id^="dfp-ad"], .ad, #top-wrapper { display: none !important; }
                  """),
        entry("43dfef58-62f1-4306-9553-d39b63209814", "Are.na in Serif", "are.na",
              "Are.na's blocks and channels set in Charter.",
              page: "https://www.are.na/explore",
              font: BoostFont(family: .charter, size: 0)),
        entry("48cfa5a8-b1e0-4241-b407-041b93768b6e", "Terminal Hacker News", "ycombinator.com",
              "A green screen tint, Menlo and capitals, for the nostalgic.",
              page: "https://news.ycombinator.com/",
              colors: BoostColors(hue: 0.33, tint: 0.22),
              font: BoostFont(family: .menlo, size: 1, textCase: .uppercase)),
    ]

    public static func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    private static func entry(_ id: String, _ name: String, _ site: String, _ about: String, page: String,
                              colors: BoostColors = BoostColors(), font: BoostFont = BoostFont(), css: String = "") -> Entry {
        var file = BoostFile(boost: Boost(domain: site, colors: colors, font: font, css: css,
                                          created: Date(timeIntervalSince1970: 1_793_923_200)), name: name)
        file.id = id
        file.revision = 1
        file.author = author
        file.about = about
        return Entry(file: file, page: URL(string: page)!)
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Arc Max's "ChatGPT in the Command Bar" (P07b, docs/user/command-bar.md): type "gpt" (or "chatgpt"), press Tab, type a
/// question, press Return, and it opens on the chat site in a new tab of the Space's profile, with the question filled
/// in. Arc's later builds did exactly this with chatgpt.com (a "ChatGPT Site Search"); Airc also offers Perplexity and
/// Claude. It is a web address, nothing more: no account, no API key, no model of Airc's, and the question is kept
/// only where any typed address is (the profile's history; never for a private window).
public enum AskAIProvider: String, Codable, CaseIterable, Sendable {
    case chatGPT = "chatgpt"
    case perplexity
    case claude

    public var name: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .perplexity: "Perplexity"
        case .claude: "Claude"
        }
    }

    /// The chat page with `%s` where the question goes.
    public var template: String {
        switch self {
        case .chatGPT: "https://chatgpt.com/?q=%s"
        case .perplexity: "https://www.perplexity.ai/search?q=%s"
        case .claude: "https://claude.ai/new?q=%s"
        }
    }

    /// What starts it with Tab (folded: case and accents don't matter). Arc's was "gpt"/"ChatGPT".
    public var keywords: [String] {
        switch self {
        case .chatGPT: ["gpt", "chatgpt"]
        case .perplexity: ["pplx", "perplexity"]
        case .claude: ["claude"]
        }
    }

    /// A question longer than this is cut (an address that long is refused by some servers).
    public static let maxPromptLength = 2000

    /// The chat page asking `prompt` (trimmed, whitespace runs as one space, cut to `maxPromptLength`), encoded as a
    /// query value with spaces as %20 (every site decodes that the same way). Nil for an empty prompt.
    public func url(for prompt: String) -> URL? { Self.url(for: prompt, template: template) }

    /// `prompt` in another `%s` template, encoded as `url(for:)` encodes it (the scripted checks' loopback chat page).
    public static func url(for prompt: String, template: String) -> URL? {
        let words = prompt.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        let cut = String(words.prefix(Self.maxPromptLength))
        let encoded = SiteSearchTemplate.escape(cut, inQuery: true).replacingOccurrences(of: "+", with: "%20")
        return URL(string: template.replacingOccurrences(of: SiteSearchTemplate.placeholder, with: encoded))
    }

    /// The provider as a site search: its pill, its icon and its placeholder use Site Search's.
    public var siteSearch: SiteSearch {
        SiteSearch(id: "ask." + rawValue, name: name, keyword: keywords[0], template: template)
    }

    /// Whether what's typed names this provider: one of its keywords, or at least four letters of its name ("chat",
    /// "perp", "clau"), ignoring case, accents and spaces.
    public func matches(_ typed: String) -> Bool {
        let t = SiteSearch.fold(typed)
        guard !t.isEmpty else { return false }
        if keywords.contains(where: { SiteSearch.fold($0) == t }) { return true }
        return t.count >= 4 && SiteSearch.fold(name).hasPrefix(t)
    }

    /// Whether the plain bar offers "Ask ChatGPT" for what's typed (Arc's "Ask GPT What You Typed" row):
    /// `looksLikePrompt`.
    public static func suggestsAsking(_ typed: String) -> Bool { looksLikePrompt(typed) }

    /// Whether what's typed reads as a prompt for a chat site rather than a search or an address (askai): a question
    /// ("?", "？", "¿"), two words or more starting with a question or instruction word ("how do I…", "explain…",
    /// "wie…", "pourquoi…"), five words or more, or a long phrase in a script written without spaces ("東京の天気を教えて").
    /// Never a web address or an address followed by words ("github.com swift"), a command ("/…") or a bang ("!yt cats").
    /// One pass over the text; the only copy is a short first word's lowercase (every keystroke asks).
    public static func looksLikePrompt(_ typed: String) -> Bool {
        var words = 0, inWord = false, question = false, headQuestion = false, unspaced = 0
        var head: Substring = ""
        var headStart = typed.startIndex
        var i = typed.startIndex
        while i < typed.endIndex {
            let ch = typed[i]
            if ch.isWhitespace || ch.isNewline {
                if inWord, words == 1 { head = typed[headStart..<i] }
                inWord = false
            } else {
                if !inWord {
                    if words == 0 {
                        headStart = i
                        // A command.
                        if ch == "/" { return false }
                    }
                    // A bang ("!yt", "!g"), anywhere: the bang's site search runs instead.
                    if ch == "!" {
                        let n = typed.index(after: i)
                        if n < typed.endIndex, typed[n].isLetter { return false }
                    }
                    words += 1
                    inWord = true
                }
                switch ch {
                case "?", "\u{FF1F}", "\u{00BF}", "\u{061F}":
                    if words == 1 { headQuestion = true } else { question = true }
                default:
                    if let u = ch.unicodeScalars.first, isUnspacedScript(u) { unspaced += 1 }
                }
            }
            i = typed.index(after: i)
        }
        guard words > 0 else { return false }
        if inWord, words == 1 { head = typed[headStart...] }
        // An address, or an address then words: open or search it, don't ask about it ("example.com docs"). An
        // address in a question of several words is asked about ("is example.com down?").
        // A "?" inside the address ("example.com/?q=…") isn't a question.
        if head.contains(".") || head.contains(":"), words == 1 || !question,
           URLRules.normalizeInput(String(head)) != nil { return false }
        if question || headQuestion || unspaced >= 6 || words >= 5 { return true }
        return words >= 2 && head.count <= 12 && promptStarters.contains(head.lowercased())
    }

    /// First words that make even a short phrase a prompt (English, German, French, Spanish, Italian, Portuguese).
    static let promptStarters: Set<String> = [
        "what", "what's", "whats", "why", "how", "who", "whom", "whose", "when", "where", "which", "is", "are", "was",
        "were", "can", "could", "should", "would", "will", "do", "does", "did", "explain", "write", "summarize",
        "summarise", "translate", "compare", "describe", "define", "draft", "rewrite", "help", "tell", "give",
        "suggest", "brainstorm", "generate", "debug", "calculate",
        "wie", "warum", "wieso", "weshalb", "wer", "wo", "wann", "welche", "welcher", "welches", "kann", "erkläre",
        "erklär", "schreib", "schreibe", "übersetze", "fasse", "vergleiche",
        "pourquoi", "comment", "qui", "quand", "où", "quel", "quelle", "explique", "écris", "traduis",
        "qué", "cómo", "quién", "cuándo", "dónde", "cuál", "explica", "escribe", "traduce",
        "perché", "chi", "quando", "dove", "spiega", "scrivi", "traduci", "porque", "quem", "onde",
    ]

    /// Han, kana, Thai, Lao, Khmer, Myanmar: scripts written without spaces between words.
    private static func isUnspacedScript(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF,
             0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF: true
        default: false
        }
    }

    /// The chat site's hosts (and their subdomains): a pinned tab, Favorite or history page there shows you use it.
    public var hosts: [String] {
        switch self {
        case .chatGPT: Self.chatGPTHosts
        case .perplexity: Self.perplexityHosts
        case .claude: Self.claudeHosts
        }
    }
    private static let chatGPTHosts = ["chatgpt.com", "chat.openai.com"]
    private static let perplexityHosts = ["perplexity.ai"]
    private static let claudeHosts = ["claude.ai"]

    /// Whether `url` (http or https) is on this chat site: a bytewise look at its host (ASCII case folded), no parsing
    /// and no copies, as it runs over a whole history.
    public func owns(_ url: String) -> Bool {
        var u = url.utf8[...]
        if u.starts(with: "https://".utf8) { u = u.dropFirst(8) } else if u.starts(with: "http://".utf8) { u = u.dropFirst(7) } else { return false }
        let host = u[..<(u.firstIndex { $0 == 0x2F || $0 == 0x3F || $0 == 0x23 || $0 == 0x3A } ?? u.endIndex)]
        return hosts.contains { Self.host(host, isOrIsUnder: $0) }
    }

    private static func host(_ host: Substring.UTF8View, isOrIsUnder h: String) -> Bool {
        let n = h.utf8.count
        guard let start = host.index(host.endIndex, offsetBy: -n, limitedBy: host.startIndex) else { return false }
        if start > host.startIndex, host[host.index(before: start)] != 0x2E { return false }
        var i = start
        for b in h.utf8 {
            var c = host[i]
            if c >= 0x41 && c <= 0x5A { c += 32 }
            guard c == b else { return false }
            i = host.index(after: i)
        }
        return true
    }

    /// History older than this doesn't count as using a chat site.
    public static let recentUse: TimeInterval = 90 * 86_400

    /// Settings → AI's "Automatic" (askai): the chat site you keep as a pinned tab or Favorite (the most recently
    /// visited one if several), else the one you visited most recently in the last 90 days, else none (off, as Arc
    /// Max's ChatGPT in the Command Bar was until chosen).
    public static func automatic(pinned: [String], history: some Sequence<HistoryEntry>, now: Date) -> AskAIProvider? {
        var kept = Set<AskAIProvider>()
        for url in pinned { for p in allCases where p.owns(url) { kept.insert(p) } }
        var last: [AskAIProvider: Date] = [:]
        let since = now.addingTimeInterval(-recentUse)
        for e in history where e.lastVisit >= since {
            for p in allCases where p.owns(e.url) && e.lastVisit > last[p] ?? .distantPast { last[p] = e.lastVisit }
        }
        func latest(_ among: [AskAIProvider]) -> AskAIProvider? {
            among.max { a, b in
                let (da, db) = (last[a] ?? .distantPast, last[b] ?? .distantPast)
                return da != db ? da < db : a.order > b.order
            }
        }
        return kept.isEmpty ? latest(Array(last.keys)) : latest(Array(kept))
    }

    /// `automatic` over the history index's published snapshot (immutable: safe to read off the main thread).
    public static func automatic(pinned: [String], snapshot: HistorySnapshot, now: Date) -> AskAIProvider? {
        automatic(pinned: pinned, history: snapshot.rows.lazy.map(\.entry), now: now)
    }

    /// Ties go to the first: ChatGPT, then Claude, then Perplexity.
    private var order: Int {
        switch self {
        case .chatGPT: 0
        case .claude: 1
        case .perplexity: 2
        }
    }
}

/// A profile's choice for asking from the Command Bar: Automatic (`AskAIProvider.automatic`), off, or a chat site.
public enum AskAIChoice: Hashable, Sendable {
    case automatic
    case off
    case provider(AskAIProvider)
}

/// Each profile's choice (Settings → AI → Ask AI, also in Site Search): Automatic until chosen (askai; before it, off
/// until chosen, as Arc Max's "ChatGPT in the Command Bar" was), off, or a chat site. A private window follows the
/// profile it was opened from. Off is a list of its own, so builds before askai still read those profiles as off.
public struct AskAISettings: Codable, Equatable, Sendable {
    /// Profile ID → provider, for profiles that picked one.
    public private(set) var profiles: [String: AskAIProvider] = [:]
    /// Profiles that turned it off.
    public private(set) var off: Set<String> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A provider a newer build added reads as off, not as an unreadable file.
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .profiles)) ?? [:]
        profiles = raw.compactMapValues(AskAIProvider.init(rawValue:))
        off = Set(raw.keys.filter { profiles[$0] == nil }).union((try? c.decodeIfPresent(Set<String>.self, forKey: .off)) ?? [])
    }

    /// The provider the profile picked; nil for Automatic or off.
    public func provider(for profileID: String) -> AskAIProvider? { profiles[profileID] }

    public func choice(for profileID: String) -> AskAIChoice {
        if let p = profiles[profileID] { return .provider(p) }
        return off.contains(profileID) ? .off : .automatic
    }

    /// The provider asked: the pick, none when off, else `automatic()` (called only for Automatic).
    public func resolved(for profileID: String, automatic: () -> AskAIProvider?) -> AskAIProvider? {
        switch choice(for: profileID) {
        case .provider(let p): p
        case .off: nil
        case .automatic: automatic()
        }
    }

    public mutating func set(_ choice: AskAIChoice, for profileID: String) {
        switch choice {
        case .automatic: profiles[profileID] = nil; off.remove(profileID)
        case .off: profiles[profileID] = nil; off.insert(profileID)
        case .provider(let p): profiles[profileID] = p; off.remove(profileID)
        }
    }

    /// A provider, or nil: off.
    public mutating func set(_ provider: AskAIProvider?, for profileID: String) {
        set(provider.map(AskAIChoice.provider) ?? .off, for: profileID)
    }

    /// Drops the choices of profiles that no longer exist.
    public mutating func prune(keeping profileIDs: Set<String>) {
        profiles = profiles.filter { profileIDs.contains($0.key) }
        off = off.intersection(profileIDs)
    }
}

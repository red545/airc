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

    /// Whether the plain bar offers "Ask ChatGPT" for what's typed (Arc's "Ask GPT What You Typed" row): a question ("?")
    /// or three words or more, never an address or a command ("/…").
    public static func suggestsAsking(_ typed: String) -> Bool {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("/"), URLRules.normalizeInput(t) == nil else { return false }
        return t.contains("?") || t.split(whereSeparator: \.isWhitespace).count >= 3
    }
}

/// Each profile's choice (Settings → AI → Ask from the Command Bar): a provider, or none. Off until chosen, as Arc Max's
/// "ChatGPT in the Command Bar" was off until you opted in. A private window follows the profile it was opened from.
public struct AskAISettings: Codable, Equatable, Sendable {
    /// Profile ID → provider, for profiles that turned it on.
    public private(set) var profiles: [String: AskAIProvider] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A provider a newer build added reads as off, not as an unreadable file.
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .profiles)) ?? [:]
        profiles = raw.compactMapValues(AskAIProvider.init(rawValue:))
    }

    public func provider(for profileID: String) -> AskAIProvider? { profiles[profileID] }

    public mutating func set(_ provider: AskAIProvider?, for profileID: String) { profiles[profileID] = provider }

    /// Drops the choices of profiles that no longer exist.
    public mutating func prune(keeping profileIDs: Set<String>) {
        profiles = profiles.filter { profileIDs.contains($0.key) }
    }
}

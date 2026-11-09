// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import NaturalLanguage

// What Ask on Page, link previews and Tidy Downloads share (docs/user/ai.md): a page's visible text as the page script
// reads it, a cautious token count for the on-device model's context window, sentence splitting, text folding for
// matching, and one model call with a strict timeout. Nothing here sends anything anywhere.

/// The model won't do this request: a guardrail, a refusal, a language it doesn't support, or a prompt too big for its
/// context window. Any other error is a failure.
public struct AIRequestDeclined: Error, Equatable, Sendable {
    public enum Reason: String, Sendable { case guardrail, refusal, language, contextTooLarge }
    public var reason: Reason
    public init(_ reason: Reason) { self.reason = reason }
}

/// One block of a page's visible text (a paragraph, a heading, a list item, a table cell), in reading order. `index` is
/// its place in the page script's list: a quote's jump finds the block again by it and its text.
public struct PageTextBlock: Equatable, Sendable {
    public var index: Int
    public var text: String
    public var isHeading: Bool

    public init(index: Int, text: String, isHeading: Bool = false) {
        self.index = index
        self.text = text
        self.isHeading = isHeading
    }
}

/// A page's visible text, as the app's page reader returns it (apps/browser AI/PageReader.swift).
public struct PageText: Equatable, Sendable {
    public var title: String
    public var url: String
    public var blocks: [PageTextBlock]
    /// Characters of visible text on the page, counted past what was read (at least `characters`).
    public var totalCharacters: Int
    /// The page has more text than the reader took.
    public var truncated: Bool

    public init(title: String, url: String, blocks: [PageTextBlock], totalCharacters: Int? = nil, truncated: Bool = false) {
        self.title = title
        self.url = url
        self.blocks = blocks
        let read = blocks.reduce(0) { $0 + $1.text.count }
        self.totalCharacters = max(read, totalCharacters ?? read)
        self.truncated = truncated
    }

    /// The page reader's answer: `{"title", "url", "total", "truncated", "blocks": [[text, 1 for a heading], …]}`.
    /// Blocks without text are skipped; nil when it isn't the reader's shape.
    public init?(script value: Any?) {
        guard let d = value as? [String: Any], let rows = d["blocks"] as? [Any] else { return nil }
        var blocks: [PageTextBlock] = []
        for (i, row) in rows.enumerated() {
            guard let r = row as? [Any], let text = r.first as? String, !text.isEmpty else { continue }
            let heading = (r.count > 1 ? (r[1] as? NSNumber)?.intValue : nil) == 1
            blocks.append(PageTextBlock(index: i, text: text, isHeading: heading))
        }
        self.init(title: d["title"] as? String ?? "", url: d["url"] as? String ?? "", blocks: blocks,
                  totalCharacters: (d["total"] as? NSNumber)?.intValue, truncated: (d["truncated"] as? NSNumber)?.boolValue ?? false)
    }

    public var characters: Int { blocks.reduce(0) { $0 + $1.text.count } }
    public var words: Int { blocks.reduce(0) { $0 + AIText.words($1.text).count } }
    /// About how many words the whole page has (the "too large" note).
    public var estimatedWords: Int {
        let c = characters
        return c == 0 ? 0 : Int((Double(words) * Double(totalCharacters) / Double(c)).rounded())
    }

    public var host: String {
        var h = URLComponents(string: url)?.host?.lowercased() ?? ""
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }
}

/// Token counts for Apple's on-device model, cautious: about one token per three bytes of UTF-8 (English runs nearer
/// four characters a token; Chinese or Japanese about one a character, three bytes each), never fewer than one a word.
/// The app checks the real count where macOS can (26.4 and later) and plans with this.
public enum AITokens {
    public static func estimate<S: StringProtocol>(_ s: S) -> Int {
        let bytes = s.utf8.count
        // Words counted where they start (no substrings made: planning a long page estimates many times).
        var words = 0, space = true
        for u in s.unicodeScalars {
            let white = u.properties.isWhitespace
            if space, !white { words += 1 }
            space = white
        }
        return max((bytes + 2) / 3, words)
    }
}

public enum AIText {
    public static func words(_ s: String) -> [Substring] { s.split(whereSeparator: \.isWhitespace) }

    /// Whitespace runs (newlines too) as one space, trimmed.
    public static func collapse(_ s: String) -> String { words(s).joined(separator: " ") }

    /// The longest start of `s` that `AITokens.estimate` counts at most `maxTokens`, in whole characters (an emoji, or
    /// a letter with its accents, is never cut).
    public static func prefix(_ s: String, maxTokens: Int) -> String {
        guard AITokens.estimate(s) > maxTokens else { return s }
        return String(s[..<prefixEnd(Substring(s), maxTokens: maxTokens)])
    }

    /// Where the longest start of `s` within `maxTokens` ends (a character boundary; `s.startIndex` when not even its
    /// first character fits). The count only grows as the start does, and a start within the budget has at most three
    /// bytes a token, so it's a binary search over that many characters.
    static func prefixEnd(_ s: Substring, maxTokens: Int) -> String.Index {
        guard maxTokens > 0 else { return s.startIndex }
        var ends: [String.Index] = []
        var i = s.startIndex
        while ends.count < 3 * maxTokens, i < s.endIndex {
            i = s.index(after: i)
            ends.append(i)
        }
        var lo = 0, hi = ends.count   // `lo` characters fit; more than `hi` don't
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if AITokens.estimate(s[..<ends[mid - 1]]) <= maxTokens { lo = mid } else { hi = mid - 1 }
        }
        return lo == 0 ? s.startIndex : ends[lo - 1]
    }

    /// `word` (no spaces in it) in pieces of at most `maxTokens` each: whole characters wherever one fits, else (a
    /// single character of hundreds of combining marks) its Unicode scalars. Never a piece over the budget.
    static func pieces(of word: String, maxTokens: Int) -> [String] {
        let budget = max(2, maxTokens)
        var out: [String] = []
        var rest = Substring(word)
        while !rest.isEmpty {
            if rest.utf8.count <= 3 * budget, AITokens.estimate(rest) <= budget {
                out.append(String(rest))
                break
            }
            let end = prefixEnd(rest, maxTokens: budget)
            if end > rest.startIndex {
                out.append(String(rest[..<end]))
                rest = rest[end...]
                continue
            }
            // Not one whole character fits: as many of its scalars as do (at least one; a scalar is at most 4 bytes).
            var bytes = 0, n = 0
            for u in rest.unicodeScalars {
                let b = String(u).utf8.count
                if n > 0, bytes + b > 3 * budget { break }
                bytes += b
                n += 1
            }
            let scalars = rest.unicodeScalars
            out.append(String(String.UnicodeScalarView(scalars.prefix(n))))
            rest = Substring(String(String.UnicodeScalarView(scalars.dropFirst(n))))
        }
        return out
    }

    /// The sentences of `s` (NaturalLanguage's tokenizer: abbreviations, numbers and quotes handled), as ranges in it.
    public static func sentences(_ s: String) -> [Range<String.Index>] {
        guard !s.isEmpty else { return [] }
        let t = NLTokenizer(unit: .sentence)
        t.string = s
        var out: [Range<String.Index>] = []
        t.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in
            var r = r
            while r.lowerBound < r.upperBound, s[s.index(before: r.upperBound)].isWhitespace { r = r.lowerBound..<s.index(before: r.upperBound) }
            if r.lowerBound < r.upperBound { out.append(r) }
            return true
        }
        return out
    }

    /// Case, accents and character widths folded, curly quotes and dashes made plain: for comparing words.
    public static func fold(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        for (a, b) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("–", "-"), ("—", "-"), ("…", "...")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    /// The folded words of `s` that carry meaning: letters or digits, at least `minLength` long, not a common word.
    public static func keywords(_ s: String, minLength: Int = 3) -> [String] {
        fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= minLength && !stopwords.contains($0) }
    }

    /// Common English and German words a question or a file name shares with every page.
    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "your", "with", "this", "that", "from", "they", "was", "were",
        "what", "when", "where", "which", "who", "whom", "why", "how", "does", "did", "has", "have", "had", "can", "could",
        "should", "would", "will", "about", "into", "than", "then", "there", "their", "them", "these", "those", "its",
        "it's", "page", "say", "says", "said", "tell", "me", "any", "all", "our", "out", "who's", "what's", "is", "of",
        "der", "die", "das", "und", "ist", "ein", "eine", "mit", "von", "den", "dem", "des", "wie", "wer", "wo",
        "warum", "nicht", "auf", "für", "sich", "auch",
    ]
}

/// One model call with a strict timeout: whichever comes first, its answer or the timeout, wins. A model that ignores
/// cancellation can't hold the caller past `timeout`; its late answer is dropped. The caller's cancellation (a card
/// closed, a preview no longer wanted, a feature turned off) reaches the work at once and ends the wait with
/// `.cancelled`.
public enum AIDeadline {
    public enum Outcome<T: Sendable>: Sendable {
        case value(T)
        case declined(AIRequestDeclined.Reason)
        case failed
        case timeout
        case cancelled
    }

    /// The one outcome that ends a wait: the work's, the timer's or the caller's cancellation, whichever is first.
    final class Claim<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome<T>, Never>?
        private var outcome: Outcome<T>?
        private var job: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        /// False when the wait is over already (the caller was cancelled first); the continuation is resumed.
        func install(_ c: CheckedContinuation<Outcome<T>, Never>) -> Bool {
            lock.lock()
            if let o = outcome {
                lock.unlock()
                c.resume(returning: o)
                return false
            }
            continuation = c
            lock.unlock()
            return true
        }

        func set(job: Task<Void, Never>? = nil, timer: Task<Void, Never>? = nil) {
            lock.lock()
            let over = outcome != nil
            if let job { self.job = job }
            if let timer { self.timer = timer }
            lock.unlock()
            if over { job?.cancel(); timer?.cancel() }
        }

        func finish(_ o: Outcome<T>) {
            lock.lock()
            guard outcome == nil else { lock.unlock(); return }
            outcome = o
            let c = continuation, j = job, t = timer
            continuation = nil
            lock.unlock()
            t?.cancel()
            // Timed out or no longer wanted: the work is told to stop (a model that listens stops at once).
            j?.cancel()
            c?.resume(returning: o)
        }
    }

    public static func run<T: Sendable>(timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async -> Outcome<T> {
        let claim = Claim<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Outcome<T>, Never>) in
                guard claim.install(done) else { return }
                claim.set(job: Task.detached {
                    let outcome: Outcome<T>
                    do {
                        outcome = .value(try await work())
                    } catch let d as AIRequestDeclined {
                        outcome = .declined(d.reason)
                    } catch {
                        outcome = .failed
                    }
                    claim.finish(outcome)
                })
                claim.set(timer: Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9))
                    guard !Task.isCancelled else { return }
                    claim.finish(.timeout)
                })
            }
        } onCancel: {
            claim.finish(.cancelled)
        }
    }
}

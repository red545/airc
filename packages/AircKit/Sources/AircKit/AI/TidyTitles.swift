// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

// Tidy Titles (Arc Max's auto-renamed tabs, docs/user/ai.md): a long or noisy page title in the sidebar gets a short
// name from a language model on this Mac ("Inbox (3) - someone@example.com - Gmail" becomes "Gmail Inbox"). The app's
// model is Apple's on-device Foundation Models (apps/browser/Sources/Airc/AI); everything here works with any
// `TidyTitleModel`, so the tests use a fake. Nothing here sends anything anywhere.

/// What the model is asked about one page: its title with counts and email addresses taken out
/// (`TidyTitleRules.prepare`), and its host. Never the address's path or query.
public struct TidyTitleRequest: Hashable, Sendable {
    public var title: String
    public var host: String

    public init(title: String, host: String) {
        self.title = title
        self.host = host
    }
}

/// A language model that names tabs. A call may take a while and may ignore cancellation: `TidyTitles` keeps its own
/// timeout.
public protocol TidyTitleModel: Sendable {
    func shortTitle(for request: TidyTitleRequest) async throws -> String
}

/// The model won't name this page (a guardrail, a refusal, a language it doesn't support): the page keeps its title
/// and isn't asked about again until its title changes. Any other error is retried later.
public struct TidyTitleDeclined: Error, Sendable {
    public init() {}
}

/// The instructions and the prompt. The app asks for guided generation: an answer with one `name` field.
public enum TidyTitlePrompt {
    public static let instructions = """
        You name browser tabs. You get a web page's title and its site. Reply with a short, clean name for the tab: \
        what the page is, the way a person would say it, in at most four words. Keep the site's or app's name when it \
        helps, like "Gmail Inbox" or "GitHub Pull Requests". Leave out counts, email addresses, account names, \
        separators and taglines. Use only words from the title or the site's name, in the title's language.
        """

    public static func prompt(for request: TidyTitleRequest) -> String {
        "Title: \(request.title)\nSite: \(request.host)"
    }

    /// The request for a page: the prepared title (cut to `TidyTitleRules.promptLength`) and the host without "www.".
    public static func request(title: String, url: String) -> TidyTitleRequest {
        var host = URLComponents(string: url)?.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return TidyTitleRequest(title: String(TidyTitleRules.prepare(title).prefix(TidyTitleRules.promptLength)), host: host)
    }
}

/// Which titles get tidied, what the model sees, and which answers are shown.
public enum TidyTitleRules {
    /// The prompt asks for at most this many words.
    public static let maxWords = 4
    /// An answer may run one word over ("about four"); a longer one is dropped, never cut.
    public static let acceptedWords = 5
    public static let maxLength = 40
    /// A title this long is tidied even without separators or counts.
    public static let longTitle = 32
    /// The model sees at most this much of a title.
    public static let promptLength = 160

    static let separators = [" - ", " – ", " — ", " | ", " · ", " • ", " / ", " :: ", " » ", " › "]

    private static let email = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    /// "(3)", "(12+)", "[2]": unread counts (Arc's own tidyTitles rules strip these from 52 sites' titles).
    private static let count = try! NSRegularExpression(pattern: #"[(\[]\d+\+?[)\]]"#)
    /// Slack's "| 3 new items" and the like.
    private static let newItems = try! NSRegularExpression(
        pattern: #"\b\d+\+? (new |unread )?(items?|messages?|notifications?)\b"#, options: [.caseInsensitive])
    /// Separators between two parts of a title: dashes, bars, dots or slashes with spaces around them (several in a
    /// row once an email address between them is out).
    private static let divider = try! NSRegularExpression(pattern: #"(\s+[-–—|·•/:»›]+)+\s+"#)
    private static let dividerCharacters = CharacterSet(charactersIn: "-–—|·•/:»›").union(.whitespacesAndNewlines)

    /// Whether a title is long or noisy enough to ask the model about. Short, clean titles ("GitHub") and addresses
    /// (a page without a title shows its host) stay as they are, without a model call.
    public static func needsTidy(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !looksLikeAddress(t) else { return false }
        if matches(email, t) || matches(count, t) || matches(newItems, t) { return true }
        if separators.contains(where: { t.contains($0) }) { return true }
        return words(t).count > maxWords || t.count >= longTitle
    }

    /// The title the model sees: email addresses, counts and "3 new items" taken out, the parts joined with " - ".
    public static func prepare(_ title: String) -> String {
        var s = title
        for r in [email, count, newItems] { s = replace(r, in: s, with: " ") }
        let parts = replace(divider, in: " " + s + " ", with: "\u{1F}").split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: dividerCharacters) }.filter { !$0.isEmpty }
        return parts.joined(separator: " - ")
    }

    /// The model's answer cleaned up to show in the sidebar, or nil to keep the page's own title: empty, too long,
    /// holding an email address or a count, markup, the title unchanged, or mostly words that aren't in the title or
    /// the site's name.
    public static func accept(_ answer: String, title: String, host: String) -> String? {
        var s = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        s = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["title:", "name:", "tab:", "tab name:"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        let wrap = CharacterSet(charactersIn: "\"'“”‘’`«»").union(.whitespaces)
        s = s.trimmingCharacters(in: wrap)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!-–—|·•/").union(.whitespaces))
        s = s.trimmingCharacters(in: wrap)
        s = words(s).joined(separator: " ")
        guard !s.isEmpty, s.count <= maxLength, words(s).count <= acceptedWords else { return nil }
        guard !matches(email, s), !matches(count, s), !s.contains(where: { "<>{}[]\\@".contains($0) }) else { return nil }
        guard s.caseInsensitiveCompare(trimmed(title)) != .orderedSame else { return nil }
        let source = fold(title + " " + host)
        let significant = words(s).map(fold).map { $0.filter(\.isLetter) }.filter { $0.count >= 3 }
        let found = significant.filter { source.contains($0) }.count
        guard significant.isEmpty || found * 2 >= significant.count else { return nil }
        return s
    }

    /// What two titles of one page have in common once counts and numbers are out: a name stays while only those
    /// change ("Inbox (3)" and "Inbox (4)").
    public static func fingerprint(_ title: String) -> String {
        let s = replace(email, in: title, with: " ").lowercased()
        return s.unicodeScalars.map { CharacterSet.letters.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    static func looksLikeAddress(_ t: String) -> Bool {
        !t.contains(where: \.isWhitespace) && (t.contains(".") || t.contains("/") || t.contains(":"))
    }

    static func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }
    private static func trimmed<S: StringProtocol>(_ s: S) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func replace(_ r: NSRegularExpression, in s: String, with t: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }
}

/// Short names by page address, each with the fingerprint of the title it was made from. Bounded: past `limit`, the
/// least recently used go. The app keeps it in TidyTitles.json in its data folder (never synced or sent).
public struct TidyTitleCache: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// `TidyTitleRules.fingerprint` of the title the name was made from.
        public var fingerprint: String
        /// The short name; nil when the model had nothing better (that title isn't asked about again).
        public var name: String?
        public var used: Date
    }

    public private(set) var entries: [String: Entry] = [:]
    public var limit: Int

    public init(limit: Int = 1000) { self.limit = max(1, limit) }

    /// The entry for this page, if it was made from this title (or one that differs only in counts).
    public func entry(url: String, title: String) -> Entry? {
        entries[url].flatMap { $0.fingerprint == TidyTitleRules.fingerprint(title) ? $0 : nil }
    }

    public mutating func set(url: String, fingerprint: String, name: String?, now: Date = Date()) {
        entries[url] = Entry(fingerprint: fingerprint, name: name, used: now)
        guard entries.count > limit else { return }
        // Down to seven eighths of the limit, so the sort is paid once per `limit / 8` inserts.
        let keep = limit - limit / 8
        for (url, _) in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(entries.count - keep) {
            entries[url] = nil
        }
    }

    public mutating func touch(_ url: String, now: Date = Date()) { entries[url]?.used = now }
    public mutating func remove(profileID: String, url: String? = nil) {
        entries = entries.filter { key, _ in
            // Old unscoped entries cannot be assigned safely to a surviving profile.
            guard key.contains("\n") else { return false }
            return url.map { key != profileID + "\n" + $0 } ?? !key.hasPrefix(profileID + "\n")
        }
    }
    public mutating func removeAll() { entries.removeAll() }
}

/// Tidy Titles for the app: what a sidebar row shows, and the queue of pages waiting for a name. Requests wait for a
/// quiet moment (`debounce` after the last one, and not while `isBusy`), then go to the model one at a time, at most
/// `batchLimit` per burst, each cut off after `timeout`. Off (the default) or without a model it does nothing and
/// costs nothing.
@MainActor
public final class TidyTitles {
    public struct Options: Sendable {
        /// Quiet time after the last request before the queue runs.
        public var debounce: TimeInterval = 1.5
        /// One request's limit; the model's answer after it is thrown away.
        public var timeout: TimeInterval = 4
        public var batchLimit = 6
        /// A page that timed out or failed is asked again after this long.
        public var retryAfter: TimeInterval = 600
        /// While the person types or scrolls, the queue checks again after this long.
        public var busyRetry: TimeInterval = 1
        /// After a timeout, while the model still hasn't answered, the queue checks again after this long.
        public var stallRetry: TimeInterval = 15
        public var cacheLimit = 1000
        /// How long after the last change the cache file is written.
        public var saveDelay: TimeInterval = 2

        public init() {}
    }

    public struct Stats: Equatable, Sendable {
        /// Model calls, names shown, answers dropped or declined (the title stays), timeouts and other errors.
        public var requests = 0, named = 0, kept = 0, timeouts = 0, failures = 0
        public init() {}
    }

    public var options: Options
    /// The on-device model, when it can run (a test's fake in scripted runs); nil hides the feature.
    public var model: (any TidyTitleModel)? {
        didSet { epoch += 1; memo.removeAll(); if model == nil { clearQueue() } }
    }
    /// Settings → AI → "Tidy tab titles".
    public var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            epoch += 1
            memo.removeAll()
            if isEnabled { load() } else { clearQueue() }
        }
    }
    /// The person is typing or scrolling: the queue waits.
    public var isBusy: @MainActor () -> Bool = { false }
    /// New names (or names dropped) for these page addresses: their rows show them.
    public var onChange: (@MainActor (Set<String>) -> Void)?
    public var now: @MainActor () -> Date = { Date() }
    public let fileURL: URL?
    public private(set) var stats = Stats()
    public private(set) var cache: TidyTitleCache
    /// Addresses waiting for the model, oldest first.
    public private(set) var queue: [String] = []

    public var isActive: Bool { isEnabled && model != nil }

    private struct Pending {
        let request: TidyTitleRequest
        let title: String
        let fingerprint: String
    }
    private var pending: [String: Pending] = [:]
    private var retryAt: [String: Date] = [:]
    private var memo: [String: (title: String, name: String?)] = [:]
    private var runTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var running = false
    private var loaded = false
    /// A call that timed out and hasn't returned yet: nothing more goes to the model until it does.
    private var stalled: Call?
    /// Bumped when the feature turns off, the model changes or the cache is forgotten: answers from before are dropped.
    private var epoch = 0

    public init(fileURL: URL?, options: Options = Options()) {
        self.fileURL = fileURL
        self.options = options
        cache = TidyTitleCache(limit: options.cacheLimit)
    }

    /// The short name a sidebar row shows for a page, or nil for its own title. A tab the person renamed
    /// (`customName`) and every page of a private window keep theirs and are never sent to the model. A title that
    /// needs a name and has none yet is queued; `onChange` says when it arrives.
    public func name(for title: String, url: String, customName: String? = nil, isPrivate: Bool = false, profileID: String = "") -> String? {
        let url = profileID.isEmpty ? url : profileID + "\n" + url
        guard isActive, !isPrivate, !url.isEmpty else { return nil }
        if let customName, !customName.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        if let m = memo[url], m.title == title { return m.name }
        var result: String?
        if TidyTitleRules.needsTidy(title) {
            let fp = TidyTitleRules.fingerprint(title)
            if let e = cache.entries[url], e.fingerprint == fp {
                result = e.name
                cache.touch(url, now: now())
            } else {
                enqueue(url: url, title: title, fingerprint: fp)
                return nil   // not memoised: the next call after the answer reads the cache
            }
        }
        if memo.count >= 4096 { memo.removeAll() }
        memo[url] = (title, result)
        return result
    }

    /// Runs the queue now (the debounce timer calls it; tests too).
    public func runPending() async {
        guard !running else { return }
        guard isActive, let model else { return clearQueue() }
        if let stalled, !stalled.isFinished { return schedule(after: options.stallRetry) }
        stalled = nil
        if isBusy() { return schedule(after: options.busyRetry) }
        running = true
        let epoch = self.epoch
        var changed = Set<String>()
        var done = 0
        while done < options.batchLimit, let url = queue.first {
            if done > 0, isBusy() { break }
            queue.removeFirst()
            guard let p = pending.removeValue(forKey: url) else { continue }
            done += 1
            stats.requests += 1
            let outcome = await Self.ask(model, p.request, timeout: options.timeout)
            guard epoch == self.epoch else { break }
            switch outcome {
            case .answer(let text):
                let name = TidyTitleRules.accept(text, title: p.title, host: p.request.host)
                if name == nil { stats.kept += 1 } else { stats.named += 1 }
                cache.set(url: url, fingerprint: p.fingerprint, name: name, now: now())
                changed.insert(url)
            case .declined:
                stats.kept += 1
                cache.set(url: url, fingerprint: p.fingerprint, name: nil, now: now())
            case .failed:
                stats.failures += 1
                retryAt[url + "\n" + p.fingerprint] = now().addingTimeInterval(options.retryAfter)
            case .timeout(let call):
                stats.timeouts += 1
                retryAt[url + "\n" + p.fingerprint] = now().addingTimeInterval(options.retryAfter)
                stalled = call
            }
            if stalled != nil { break }
        }
        running = false
        guard epoch == self.epoch else { return }
        if !changed.isEmpty {
            for url in changed { memo[url] = nil }
            scheduleSave()
            onChange?(Set(changed.map { $0.components(separatedBy: "\n").last ?? $0 }))
        }
        if !queue.isEmpty { schedule(after: options.debounce) }
    }

    /// Forgets every name and deletes the file (turning the feature off does this).
    public func forget() {
        epoch += 1
        clearQueue()
        cache.removeAll()
        memo.removeAll()
        retryAt.removeAll()
        saveTask?.cancel()
        saveTask = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Delete Profile, Clear Data and removal of a history URL also forget queued work and late model answers.
    public func forget(profileID: String, url: String? = nil) {
        load()
        epoch += 1
        clearQueue()
        memo.removeAll()
        retryAt.removeAll()
        cache.remove(profileID: profileID, url: url)
        save()
    }

    /// Writes the cache file now (quit, tests).
    public func save() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL, loaded else { return }
        if cache.entries.isEmpty { try? FileManager.default.removeItem(at: fileURL); return }
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: Queue

    private func enqueue(url: String, title: String, fingerprint: String) {
        if pending[url]?.fingerprint == fingerprint { return }
        if let until = retryAt[url + "\n" + fingerprint], until > now() { return }
        if retryAt.count >= 1024 { retryAt = retryAt.filter { $0.value > now() } }
        if pending[url] == nil { queue.append(url) }
        pending[url] = Pending(request: TidyTitlePrompt.request(title: title, url: url.components(separatedBy: "\n").last ?? url), title: title, fingerprint: fingerprint)
        if !running { schedule(after: options.debounce) }
    }

    private func clearQueue() {
        runTask?.cancel()
        runTask = nil
        pending.removeAll()
        queue.removeAll()
    }

    private func schedule(after delay: TimeInterval) {
        runTask?.cancel()
        runTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1e9))
            guard !Task.isCancelled else { return }
            await self?.runPending()
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              var c = try? JSONDecoder().decode(TidyTitleCache.self, from: data) else { return }
        c.limit = options.cacheLimit
        cache = c
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTask?.cancel()
        let delay = options.saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    // MARK: One call, with a strict timeout

    public enum Outcome: Sendable {
        case answer(String), declined, failed, timeout(Call)
    }

    /// One model call: whichever comes first, its answer or the timeout, wins. A model that ignores cancellation
    /// can't hold the queue past `timeout`; `isFinished` says when it has let go.
    public final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        private var finished = false
        private var timer: Task<Void, Never>?

        public var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }

        func finish() {
            lock.lock()
            finished = true
            let t = timer
            lock.unlock()
            t?.cancel()
        }

        func setTimer(_ t: Task<Void, Never>) {
            lock.lock()
            let done = finished
            timer = t
            lock.unlock()
            if done { t.cancel() }
        }
    }

    /// One request to `model`, cut off after `timeout` (the queue's calls; the app's real-model smoke run).
    nonisolated public static func ask(_ model: any TidyTitleModel, _ request: TidyTitleRequest, timeout: TimeInterval) async -> Outcome {
        let call = Call()
        return await withCheckedContinuation { (done: CheckedContinuation<Outcome, Never>) in
            let work = Task.detached {
                let outcome: Outcome
                do {
                    outcome = .answer(try await model.shortTitle(for: request))
                } catch is TidyTitleDeclined {
                    outcome = .declined
                } catch {
                    outcome = .failed
                }
                call.finish()
                if call.claim() { done.resume(returning: outcome) }
            }
            call.setTimer(Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9))
                guard !Task.isCancelled, call.claim() else { return }
                work.cancel()
                done.resume(returning: .timeout(call))
            })
        }
    }
}

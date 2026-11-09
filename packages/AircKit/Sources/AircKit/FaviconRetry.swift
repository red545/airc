// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// When a favicon that failed may be asked of the network again (the app's FaviconCache). A failed or empty fetch is
/// never final. A round of tries that fails puts the icon on a backoff, per icon URL and profile: 1 min, then 5 min,
/// 30 min, then a day for every later round. The next round waits for a trigger after that (the row coming on screen,
/// the page loading, the network coming back), never for a timer, so an idle browser asks nothing.
public struct FaviconBackoff {
    public struct Key: Hashable, Sendable {
        public var url: String
        /// The profile whose rows asked ("" when the caller has none: the engine's own page loads).
        public var profile: String

        public init(url: String, profile: String?) {
            self.url = url
            self.profile = profile ?? ""
        }
    }

    /// Why a fetch failed.
    public enum Failure: String, Sendable {
        /// No answer, a timeout, 408, 425, 429, 5xx or an empty answer: tried again within the round, and soon after.
        case transient
        /// 4xx or bytes that aren't an image: the site has no icon there for now. Starts one step up the ladder.
        case missing
    }

    /// What asks for a new round.
    public enum Trigger: String, Sendable {
        /// A row showing the icon came on screen or was configured again: only once its backoff is over.
        case shown
        /// The icon's page loaded: an icon that failed for a passing reason is asked again at once (at most once per
        /// `pageLoadFloor`); a missing one waits out its backoff.
        case pageLoaded
        /// The network came back: transient failures are forgotten (records made offline too).
        case networkRestored
    }

    public struct Policy: Sendable, Equatable {
        /// The wait after the first, second, … failed round; the last one repeats.
        public var ladder: [TimeInterval]
        /// Within a round, a transient failure is tried again after each of these (a server busy for a moment). A few
        /// one-shot waits right after a failure, then the round ends; nothing runs while the browser is idle.
        public var roundRetries: [TimeInterval]
        /// A page load asks a transiently failed icon again at once, but not sooner than this after its last failure.
        public var pageLoadFloor: TimeInterval
        /// A record nobody asked about for this long after it came due is forgotten (its ladder starts over).
        public var forgetAfter: TimeInterval
        /// How many failed icons are remembered at most (the least recently failed go first).
        public var limit: Int

        public init(ladder: [TimeInterval], roundRetries: [TimeInterval], pageLoadFloor: TimeInterval,
                    forgetAfter: TimeInterval, limit: Int) {
            self.ladder = ladder.isEmpty ? [60] : ladder
            self.roundRetries = roundRetries
            self.pageLoadFloor = pageLoadFloor
            self.forgetAfter = forgetAfter
            self.limit = max(1, limit)
        }

        public static let standard = Policy(ladder: [60, 300, 1800, 86_400], roundRetries: [4, 16, 40], pageLoadFloor: 30,
                                            forgetAfter: 2 * 86_400, limit: 4000)

        /// The wait before another try within a round, after `attempts` tries failed with `failure` (nil: the round is
        /// over). Missing icons aren't tried again within a round.
        public func roundRetry(afterAttempts attempts: Int, _ failure: Failure) -> TimeInterval? {
            guard failure == .transient, attempts >= 1, attempts <= roundRetries.count else { return nil }
            return roundRetries[attempts - 1]
        }

        /// The wait after the `rounds`-th failed round.
        public func wait(afterRounds rounds: Int, _ failure: Failure) -> TimeInterval {
            let step = max(0, rounds - 1) + (failure == .missing ? 1 : 0)
            return ladder[min(step, ladder.count - 1)]
        }
    }

    public struct Record: Equatable, Sendable {
        /// Failed rounds while online (failures offline don't climb the ladder).
        public var rounds: Int
        public var failure: Failure
        public var failedAt: Date
        /// No new round on `.shown` before this.
        public var due: Date
        /// The last round failed while the network was down.
        public var offline: Bool
    }

    public var policy: Policy
    private var records: [Key: Record] = [:]

    public init(policy: Policy = .standard) { self.policy = policy }

    public var count: Int { records.count }
    public func record(_ key: Key) -> Record? { records[key] }

    /// Whether a new round for `key` may start now.
    public mutating func mayStart(_ key: Key, trigger: Trigger, now: Date = Date()) -> Bool {
        guard let r = records[key] else { return true }
        if now >= r.due.addingTimeInterval(policy.forgetAfter) {
            records[key] = nil
            return true
        }
        switch trigger {
        case .shown: return now >= r.due
        case .pageLoaded:
            if r.failure == .missing { return now >= r.due }
            return now >= r.due || now.timeIntervalSince(r.failedAt) >= policy.pageLoadFloor
        case .networkRestored: return r.failure == .transient || r.offline || now >= r.due
        }
    }

    /// A round for `key` failed. `online`: the network path was up (offline failures don't climb the ladder).
    public mutating func failed(_ key: Key, _ failure: Failure, online: Bool = true, now: Date = Date()) {
        var r = records[key] ?? Record(rounds: 0, failure: failure, failedAt: now, due: now, offline: false)
        if online { r.rounds += 1 }
        r.failure = failure
        r.failedAt = now
        r.offline = !online
        r.due = now.addingTimeInterval(policy.wait(afterRounds: max(1, r.rounds), failure))
        records[key] = r
        if records.count > policy.limit { trim(now: now) }
    }

    /// The icon arrived for `key`: its failures are forgotten.
    public mutating func succeeded(_ key: Key) { records[key] = nil }

    /// The network came back: every transient failure, and every failure made offline, is forgotten, so the next
    /// trigger starts a round. Missing icons keep their backoff.
    public mutating func networkRestored() {
        records = records.filter { $0.value.failure == .missing && !$0.value.offline }
    }

    public mutating func removeAll() { records = [:] }

    /// Drops records long past due, then the least recently failed down to seven eighths of the limit.
    private mutating func trim(now: Date) {
        records = records.filter { now < $0.value.due.addingTimeInterval(policy.forgetAfter) }
        let keep = policy.limit - policy.limit / 8
        guard records.count > keep else { return }
        for (key, _) in records.sorted(by: { $0.value.failedAt < $1.value.failedAt }).prefix(records.count - keep) {
            records[key] = nil
        }
    }
}

/// At most `limit` jobs at once, each key once (FaviconCache's network fetches, deduplicated per icon URL); the rest
/// wait in the order they asked.
public struct FetchGate<Key: Hashable> {
    public enum Admission: Equatable { case start, queued, duplicate }

    public let limit: Int
    public private(set) var running: Set<Key> = []
    private var queue: [Key] = []
    private var queued: Set<Key> = []
    /// The most jobs that ran at once.
    public private(set) var peak = 0

    public init(limit: Int) { self.limit = max(1, limit) }

    public var waiting: Int { queue.count }

    public mutating func request(_ key: Key) -> Admission {
        if running.contains(key) || queued.contains(key) { return .duplicate }
        guard running.count < limit else {
            queue.append(key)
            queued.insert(key)
            return .queued
        }
        running.insert(key)
        peak = max(peak, running.count)
        return .start
    }

    /// `key` is done (or was dropped): the next job to start, if one waits and a place is free.
    public mutating func finish(_ key: Key) -> Key? {
        running.remove(key)
        if queued.remove(key) != nil { queue.removeAll { $0 == key } }
        guard running.count < limit, !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        queued.remove(next)
        running.insert(next)
        peak = max(peak, running.count)
        return next
    }

    public mutating func removeAll() {
        running = []
        queue = []
        queued = []
    }
}

extension FaviconBackoff {
    /// How a fetch went: nil when it brought an icon, else why it failed. `status` nil: no answer at all (no network,
    /// a timeout, a refused connection).
    public static func failure(status: Int?, bytes: Int, decoded: Bool) -> Failure? {
        guard let status else { return .transient }
        if status < 400 {
            if decoded { return nil }
            return bytes == 0 ? .transient : .missing
        }
        return [408, 425, 429].contains(status) || status >= 500 ? .transient : .missing
    }
}

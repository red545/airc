// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Airc's product analytics client (docs/user/telemetry.md): typed events (TelemetryEvent) go into a bounded queue that
/// survives relaunches and is sent to PostHog's batch API in batches: 30 s after the first pending event, at once when
/// 20 are waiting, and best-effort at quit. Failed batches are retried with exponential backoff and jitter; events older
/// than 24 h are dropped. The caller's thread only hands the event to a private queue; everything else runs there, and
/// nothing is scheduled while no event is waiting (MEM-6: idle CPU stays at zero).
public final class Telemetry: @unchecked Sendable {
    /// The app's client. Tests make their own with a fake transport and scheduler.
    public static let shared = Telemetry()

    public struct Policy: Sendable {
        public var flushDelay: TimeInterval = 30
        public var batchSize = 20
        public var maxQueued = 1000
        public var maxAge: TimeInterval = 24 * 3600
        public var retryBase: TimeInterval = 15
        public var retryMax: TimeInterval = 30 * 60
        /// A burst of events is written to disk once, this long after the first.
        public var persistDelay: TimeInterval = 2
        /// What "See what Airc sends" shows.
        public var recentLimit = 100

        public init() {}
    }

    public struct Configuration: Sendable {
        public var resolution: TelemetryResolution
        public var context: TelemetryContext
        /// `<data dir>/Telemetry` (install.json, queue.json); nil keeps the install ID and the queue in memory.
        public var directory: URL?

        public init(resolution: TelemetryResolution, context: TelemetryContext, directory: URL?) {
            self.resolution = resolution
            self.context = context
            self.directory = directory
        }
    }

    /// The client's state, for Settings and tests.
    public struct Status: Sendable, Equatable {
        public var state: TelemetryResolution.State
        public var installID: String?
        public var pending: Int
        public var sending: Bool
        public var failures: Int
        public var retryAt: Date?
        /// When the next flush is armed, if one is.
        public var flushDue: Date?
        public var delivered: Int
        public var dropped: Int
    }

    public let policy: Policy
    private let queue = DispatchQueue(label: "org.airc.telemetry", qos: .utility)
    private let transport: TelemetryTransport
    private let scheduler: TelemetryScheduler
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double

    // Everything below is touched on `queue` only.
    private var resolution = TelemetryResolution.unavailable
    private var context: TelemetryContext?
    private var directory: URL?
    private var install: TelemetryInstall?
    private var queueLoaded = false
    private var pending: [TelemetryRecord] = []
    private var recent: [TelemetryRecord] = []
    private var inFlight = false
    private var failures = 0
    private var retryAt: Date?
    private var flushTimer: TelemetryTimer?
    private var flushDue: Date?
    private var flushToken = 0
    private var persistTimer: TelemetryTimer?
    private var persistToken = 0
    /// Bumped when the queue is thrown away (turned off, ID reset), so a send that was in flight changes nothing.
    private var generation = 0
    private var delivered = 0
    private var dropped = 0
    private var observers: [Int: @Sendable ([TelemetryRecord]) -> Void] = [:]
    private var nextObserver = 0
    private var idleWaiters: [@Sendable () -> Void] = []

    public init(transport: TelemetryTransport = URLSessionTelemetryTransport(), scheduler: TelemetryScheduler? = nil,
                policy: Policy = Policy(), now: @escaping @Sendable () -> Date = { Date() },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.transport = transport
        self.scheduler = scheduler ?? DispatchTelemetryScheduler(queue: DispatchQueue.global(qos: .utility))
        self.policy = policy
        self.now = now
        self.random = random
    }

    // MARK: Recording

    /// Records `event`. Cheap on any thread: the event is handed to the telemetry queue, nothing else.
    public func record(_ event: TelemetryEvent) {
        let at = now()
        queue.async { self.append(name: event.name, properties: event.properties, at: at) }
    }

    /// Records a crash report as PostHog's `$exception` (docs/user/telemetry.md, "Crash reports"): the same switch,
    /// queue and "See what Airc sends" as every other event, and like them never sent from a scripted run.
    public func record(_ crash: CrashReport, smoke: Bool = false) {
        let at = now()
        let properties = crash.properties(smoke: smoke)
        queue.async { self.append(name: "$exception", properties: properties, at: at) }
    }

    /// Applies a configuration: at launch, and whenever Settings → Privacy changes. Turning telemetry off (or a build
    /// without a key) throws away whatever was queued.
    public func start(_ configuration: Configuration) {
        queue.async { self.apply(configuration) }
    }

    /// Settings → Privacy → "Reset": a new install ID; queued and shown events of the old one are thrown away.
    public func resetInstallID() {
        queue.async {
            self.discardQueue()
            guard self.resolution.records else { return }
            let t = self.now()
            self.install = self.directory.map { TelemetryInstall.make($0.appendingPathComponent("install.json"), now: t) }
                ?? TelemetryInstall(created: t)
            self.notifyObservers()
        }
    }

    public var status: Status {
        queue.sync {
            Status(state: resolution.state, installID: install?.id, pending: pending.count, sending: inFlight, failures: failures,
                   retryAt: retryAt, flushDue: flushDue, delivered: delivered, dropped: dropped)
        }
    }

    /// The last `policy.recentLimit` events, oldest first, now and after every new one (on the main queue), for "See what
    /// Airc sends". Returns a token for `removeObserver`.
    @discardableResult
    public func observeRecent(_ block: @escaping @Sendable ([TelemetryRecord]) -> Void) -> Int {
        let (token, current) = queue.sync { () -> (Int, [TelemetryRecord]) in
            nextObserver += 1
            observers[nextObserver] = block
            return (nextObserver, recent)
        }
        DispatchQueue.main.async { block(current) }
        return token
    }

    public func removeObserver(_ token: Int) {
        queue.async { self.observers[token] = nil }
    }

    /// At quit: writes the queue to disk, then sends what is waiting for at most `timeout` seconds (blocking the
    /// caller). Whatever doesn't go out now goes at the next launch.
    public func flushForQuit(timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.persistNow()
            guard self.resolution.sends, !self.pending.isEmpty else {
                done.signal()
                return
            }
            self.idleWaiters.append { _ = done.signal() }
            if !self.inFlight { self.flush() }
            if !self.inFlight { self.signalIdle() }
        }
        _ = done.wait(timeout: .now() + timeout)
        queue.sync { self.persistNow() }
    }

    /// Waits until the telemetry queue has run what was handed to it (tests).
    func drain() { queue.sync {} }

    // MARK: Queue

    private func apply(_ c: Configuration) {
        let before = resolution.state
        resolution = c.resolution
        context = c.context
        directory = c.directory
        guard resolution.records else {
            discardQueue()
            install = nil
            return
        }
        if install == nil || before == .unavailable {
            install = c.directory.map { TelemetryInstall.load($0.appendingPathComponent("install.json"), now: now()).install }
                ?? TelemetryInstall(created: now())
        }
        guard resolution.sends else {
            // Record-only (scripted runs): nothing is kept on disk, so a later real launch never sends it.
            pending = []
            return
        }
        if !queueLoaded {
            queueLoaded = true
            pending = loadQueue() + pending
            trim()
        }
        if !pending.isEmpty { arm(after: policy.flushDelay) }
    }

    private func append(name: String, properties own: [String: TelemetryValue], at: Date) {
        guard resolution.records, let install, let context else { return }
        var properties = context.superProperties(installAgeDays: install.ageInDays(at: at))
        for (k, v) in own { properties[k] = v }
        let r = TelemetryRecord(uuid: UUID().uuidString.lowercased(), event: name, distinctID: install.id, timestamp: at,
                                properties: properties)
        recent.append(r)
        if recent.count > policy.recentLimit { recent.removeFirst(recent.count - policy.recentLimit) }
        notifyObservers()
        guard resolution.sends else { return }
        pending.append(r)
        trim()
        schedulePersist()
        if pending.count >= policy.batchSize { flush() } else { arm(after: policy.flushDelay) }
    }

    /// The oldest go first past `maxQueued`.
    private func trim() {
        if pending.count > policy.maxQueued {
            dropped += pending.count - policy.maxQueued
            pending.removeFirst(pending.count - policy.maxQueued)
        }
    }

    private func discardQueue() {
        generation += 1
        pending = []
        recent = []
        inFlight = false
        failures = 0
        retryAt = nil
        flushTimer?.cancel()
        flushTimer = nil
        flushDue = nil
        persistTimer?.cancel()
        persistTimer = nil
        if let url = queueFile ?? directory?.appendingPathComponent("queue.json") { try? FileManager.default.removeItem(at: url) }
        notifyObservers()
        signalIdle()
    }

    // MARK: Sending

    /// A one-shot flush `delay` from now, unless an earlier one is already armed.
    private func arm(after delay: TimeInterval) {
        let due = now().addingTimeInterval(max(0, delay))
        if flushTimer != nil, let flushDue, flushDue <= due { return }
        flushTimer?.cancel()
        flushToken += 1
        let token = flushToken
        flushDue = due
        flushTimer = scheduler.schedule(after: max(0, delay)) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.flushToken == token else { return }
                self.flushTimer = nil
                self.flushDue = nil
                self.flush()
            }
        }
    }

    private func flush() {
        guard resolution.sends, let endpoint = resolution.endpoint, !inFlight else { return }
        let cutoff = now().addingTimeInterval(-policy.maxAge)
        let before = pending.count
        pending.removeAll { $0.timestamp < cutoff }
        if pending.count != before {
            dropped += before - pending.count
            schedulePersist()
        }
        guard !pending.isEmpty else { return becameIdle() }
        if let retryAt, retryAt > now() { return arm(after: retryAt.timeIntervalSince(now())) }
        let batch = Array(pending.prefix(policy.batchSize))
        guard let body = try? PostHogBatch.body(apiKey: resolution.apiKey, records: batch) else {
            pending.removeFirst(batch.count)
            dropped += batch.count
            return flush()
        }
        inFlight = true
        let gen = generation
        transport.send(body, to: endpoint) { [weak self] result in
            guard let self else { return }
            self.queue.async { self.finished(result, uuids: Set(batch.map(\.uuid)), generation: gen) }
        }
    }

    private func finished(_ result: TelemetrySendResult, uuids: Set<String>, generation gen: Int) {
        guard gen == generation else { return }
        inFlight = false
        switch result {
        case .delivered:
            pending.removeAll { uuids.contains($0.uuid) }
            delivered += uuids.count
            failures = 0
            retryAt = nil
            schedulePersist()
            // A backlog (after being offline, or from the last launch) goes out batch after batch.
            flush()
        case .rejected:
            // The endpoint refuses this batch (a bad key, a malformed or oversized body): drop it, but still back off,
            // so a bad key can't drain the queue in a tight loop.
            pending.removeAll { uuids.contains($0.uuid) }
            dropped += uuids.count
            backOff()
            schedulePersist()
            if pending.isEmpty { becameIdle() }
        case .failed:
            backOff()
            signalIdle()
        }
    }

    private func backOff() {
        failures += 1
        let delay = retryDelay(failures: failures)
        retryAt = now().addingTimeInterval(delay)
        if !pending.isEmpty { arm(after: delay) }
    }

    /// Exponential (15 s, 30 s, 1 min … up to 30 min) with jitter: somewhere in the upper half of the ceiling.
    func retryDelay(failures: Int) -> TimeInterval {
        let ceiling = min(policy.retryMax, policy.retryBase * pow(2, Double(max(0, failures - 1))))
        return ceiling / 2 + ceiling / 2 * random()
    }

    /// Nothing waits: no timer stays armed.
    private func becameIdle() {
        flushTimer?.cancel()
        flushTimer = nil
        flushDue = nil
        signalIdle()
    }

    private func signalIdle() {
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0() }
    }

    private func notifyObservers() {
        guard !observers.isEmpty else { return }
        let r = recent
        for o in observers.values { DispatchQueue.main.async { o(r) } }
    }

    // MARK: Disk

    private var queueFile: URL? { resolution.sends ? directory?.appendingPathComponent("queue.json") : nil }

    private struct QueueFile: Codable {
        var version = 1
        var events: [TelemetryRecord]
    }

    private func loadQueue() -> [TelemetryRecord] {
        guard let url = queueFile, let data = try? Data(contentsOf: url),
              let file = try? TelemetryRecord.decoder.decode(QueueFile.self, from: data), file.version == 1 else { return [] }
        let cutoff = now().addingTimeInterval(-policy.maxAge)
        return file.events.filter { $0.timestamp >= cutoff }
    }

    private func schedulePersist() {
        guard queueFile != nil, persistTimer == nil else { return }
        persistToken += 1
        let token = persistToken
        persistTimer = scheduler.schedule(after: policy.persistDelay) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.persistToken == token else { return }
                self.persistNow()
            }
        }
    }

    private func persistNow() {
        persistTimer?.cancel()
        persistTimer = nil
        persistToken += 1
        guard let url = queueFile else { return }
        if pending.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? TelemetryRecord.encoder.encode(QueueFile(events: pending)).write(to: url, options: .atomic)
    }
}

// MARK: - Records and the PostHog batch

/// One event as Airc queues it, shows it in "See what Airc sends" and sends it: the fields of a PostHog batch event.
public struct TelemetryRecord: Codable, Sendable, Equatable, Identifiable {
    public var uuid: String
    public var event: String
    public var distinctID: String
    public var timestamp: Date
    public var properties: [String: TelemetryValue]

    public var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid, event, distinctID = "distinct_id", timestamp, properties
    }

    /// Pretty JSON with sorted keys, exactly as the event appears in the batch.
    public var json: String {
        let e = Self.encoder
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// PostHog's batch capture API: `POST <host>/batch/` with the project key and the events.
public enum PostHogBatch {
    struct Body: Codable {
        var api_key: String
        var historical_migration = false
        var batch: [TelemetryRecord]
    }

    public static func body(apiKey: String, records: [TelemetryRecord]) throws -> Data {
        try TelemetryRecord.encoder.encode(Body(api_key: apiKey, batch: records))
    }
}

// MARK: - Transport and scheduling

public enum TelemetrySendResult: Sendable, Equatable {
    case delivered
    /// The endpoint refused the batch itself (400, 401, 403, 413): retrying can't help.
    case rejected(status: Int)
    /// Offline, a timeout, a 5xx or a 429: try again later.
    case failed
}

public protocol TelemetryTransport: Sendable {
    func send(_ body: Data, to url: URL, completion: @escaping @Sendable (TelemetrySendResult) -> Void)
}

/// POSTs batches with an ephemeral session: no cookies, no cache, no credentials. The session is made at the first
/// send (on the telemetry queue), not at launch.
public final class URLSessionTelemetryTransport: TelemetryTransport, @unchecked Sendable {
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var made: URLSession?

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    private var session: URLSession {
        lock.withLock {
            if let made { return made }
            let c = URLSessionConfiguration.ephemeral
            c.httpCookieStorage = nil
            c.httpShouldSetCookies = false
            c.urlCache = nil
            c.urlCredentialStorage = nil
            c.timeoutIntervalForRequest = timeout
            c.timeoutIntervalForResource = timeout * 2
            let s = URLSession(configuration: c)
            made = s
            return s
        }
    }

    public func send(_ body: Data, to url: URL, completion: @escaping @Sendable (TelemetrySendResult) -> Void) {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        session.dataTask(with: r) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil, (200..<300).contains(status) { return completion(.delivered) }
            completion([400, 401, 403, 413].contains(status) ? .rejected(status: status) : .failed)
        }.resume()
    }
}

public protocol TelemetryTimer: Sendable {
    func cancel()
}

/// One-shot timers. Nothing repeats.
public protocol TelemetryScheduler: Sendable {
    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> TelemetryTimer
}

public struct DispatchTelemetryScheduler: TelemetryScheduler {
    let queue: DispatchQueue

    public init(queue: DispatchQueue) { self.queue = queue }

    public func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> TelemetryTimer {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return DispatchTimer(item: item)
    }

    private final class DispatchTimer: TelemetryTimer, @unchecked Sendable {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}

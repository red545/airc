// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Network
import XCTest
@testable import AircKit

/// Delivery: batching, the one-shot flush, backoff, the 24 h limit, the bounded queue on disk, turning it off, scripted
/// runs, the quit flush. Everything goes to a fake transport; nothing leaves the Mac (the HTTP test talks to loopback).
final class TelemetryDeliveryTests: XCTestCase {
    func testNothingIsScheduledWhileIdle() {
        let h = TelemetryHarness()
        h.startSending()
        XCTAssertEqual(h.scheduler.armed, [], "no timer before the first event")
        h.client.record(.featureUsed(.find))
        h.settle()
        XCTAssertEqual(h.scheduler.armed, [30])
        h.scheduler.fireAll(h.client)
        XCTAssertEqual(h.transport.events.count, 1)
        XCTAssertEqual(h.scheduler.armed, [], "nothing scheduled once the queue is empty")
        XCTAssertNil(h.client.status.flushDue)
    }

    func testEventsWaitForOneFlushThirtySecondsAfterTheFirst() {
        let h = TelemetryHarness()
        h.startSending()
        for _ in 0..<5 { h.client.record(.featureUsed(.peekOpen)) }
        h.settle()
        XCTAssertEqual(h.scheduler.armed, [30], "one flush, armed by the first event")
        XCTAssertTrue(h.transport.bodies.isEmpty)
        h.scheduler.fireAll(h.client)
        XCTAssertEqual(h.transport.bodies.count, 1)
        XCTAssertEqual(h.transport.events.count, 5)
        XCTAssertEqual(h.client.status.pending, 0)
    }

    func testTwentyEventsGoAtOnce() {
        let h = TelemetryHarness()
        h.startSending()
        for _ in 0..<20 { h.client.record(.featureUsed(.commandBar(.newTab))) }
        h.settle()
        XCTAssertEqual(h.transport.bodies.count, 1)
        XCTAssertEqual(h.transport.events.count, 20)
        XCTAssertEqual(h.scheduler.armed, [], "the 30 s flush is cancelled once the queue is empty")
        for _ in 0..<45 { h.client.record(.featureUsed(.find)) }
        h.settle()
        h.scheduler.fireAll(h.client)
        XCTAssertEqual(h.transport.bodies.map { h.transport.events(in: $0).count }, [20, 20, 20, 5])
    }

    func testFailedBatchIsRetriedWithBackoffAndJitter() {
        let h = TelemetryHarness(random: 0.5)
        h.transport.result = .failed
        h.startSending()
        h.client.record(.featureUsed(.spaceCreate))
        h.settle()
        h.scheduler.fireNext(h.client)
        XCTAssertEqual(h.client.status.failures, 1)
        XCTAssertEqual(h.scheduler.armed, [11.25], "15 s ceiling, jittered into its upper half")
        h.scheduler.fireNext(h.client)
        XCTAssertEqual(h.scheduler.armed, [22.5])
        h.scheduler.fireNext(h.client)
        XCTAssertEqual(h.scheduler.armed, [45])
        XCTAssertEqual(h.transport.bodies.count, 3)
        XCTAssertEqual(Set(h.transport.events.map { $0["uuid"] as! String }).count, 1, "the same event, same UUID: PostHog dedupes")
        h.transport.result = .delivered
        h.scheduler.fireNext(h.client)
        XCTAssertEqual(h.client.status.pending, 0)
        XCTAssertEqual(h.client.status.failures, 0)
        XCTAssertNil(h.client.status.retryAt)
        XCTAssertEqual(h.scheduler.armed, [])
    }

    func testRetryDelayStaysWithinItsCeiling() {
        let low = TelemetryHarness(random: 0).client, high = TelemetryHarness(random: 0.999).client
        XCTAssertEqual(low.retryDelay(failures: 1), 7.5)
        XCTAssertEqual(low.retryDelay(failures: 40), 900)
        XCTAssertLessThan(high.retryDelay(failures: 40), 1800)
        XCTAssertGreaterThan(high.retryDelay(failures: 4), 119)
    }

    func testRejectedBatchIsDroppedButStillBacksOff() {
        let h = TelemetryHarness()
        h.transport.result = .rejected(status: 401)
        h.startSending()
        h.client.record(.featureUsed(.find))
        h.settle()
        h.scheduler.fireAll(h.client)
        let s = h.client.status
        XCTAssertEqual(s.pending, 0)
        XCTAssertEqual(s.dropped, 1)
        XCTAssertNotNil(s.retryAt, "a bad key can't drain the queue in a tight loop")
        XCTAssertEqual(h.transport.bodies.count, 1)
    }

    func testEventsOlderThanADayAreDropped() {
        let h = TelemetryHarness()
        h.transport.result = .failed
        h.startSending()
        h.client.record(.featureUsed(.find))
        h.settle()
        h.scheduler.fireNext(h.client)
        XCTAssertEqual(h.client.status.pending, 1)
        h.clock.advance(25 * 3600)
        h.scheduler.fireNext(h.client)
        XCTAssertEqual(h.client.status.pending, 0)
        XCTAssertEqual(h.client.status.dropped, 1)
        XCTAssertEqual(h.transport.bodies.count, 1, "the expired event isn't sent again")
        XCTAssertEqual(h.scheduler.armed, [])
    }

    func testQueueSurvivesARelaunch() throws {
        let dir = TelemetryHarness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = TelemetryHarness(directory: dir)
        first.transport.result = .failed
        first.startSending()
        for _ in 0..<3 { first.client.record(.featureUsed(.themeChanged)) }
        first.settle()
        first.client.flushForQuit(timeout: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("queue.json").path))
        let sentFirst = Set(first.transport.events.map { $0["uuid"] as! String })
        let installID = first.client.status.installID

        let second = TelemetryHarness(directory: dir)
        second.startSending()
        XCTAssertEqual(second.client.status.pending, 3)
        XCTAssertEqual(second.client.status.installID, installID, "the install ID is kept in the data folder")
        XCTAssertEqual(second.scheduler.armed, [30], "a backlog from the last launch is flushed soon after launch")
        second.scheduler.fireAll(second.client)
        XCTAssertEqual(Set(second.transport.events.map { $0["uuid"] as! String }), sentFirst)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("queue.json").path), "empty: no file")
    }

    func testQueueIsBoundedAndDropsTheOldest() {
        let h = TelemetryHarness()
        h.transport.hold = true   // the first batch stays in flight, the rest wait
        h.startSending()
        for _ in 0..<1010 { h.client.record(.featureUsed(.find)) }
        h.client.record(.featureUsed(.telemetrySmoke))
        h.settle()
        XCTAssertEqual(h.client.status.pending, 1000)
        XCTAssertEqual(h.client.status.dropped, 11)
        h.transport.hold = false
        h.transport.release(.delivered)
        h.settle()
        h.scheduler.fireAll(h.client)
        XCTAssertEqual(h.transport.events.last?["properties"].flatMap { ($0 as? [String: Any])?["feature"] as? String }, "telemetry.smoke")
        XCTAssertEqual(h.client.status.pending, 0)
    }

    func testTurningItOffThrowsTheQueueAway() {
        let dir = TelemetryHarness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = TelemetryHarness(directory: dir)
        h.transport.hold = true
        h.startSending()
        for _ in 0..<3 { h.client.record(.featureUsed(.find)) }
        h.settle()
        h.scheduler.fire(delay: 2, h.client)
        let file = dir.appendingPathComponent("queue.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "written 2 s after the burst")
        h.scheduler.fire(delay: 30, h.client)
        XCTAssertTrue(h.client.status.sending, "a batch is in flight")
        h.start(userEnabled: false)
        XCTAssertEqual(h.client.status.pending, 0)
        XCTAssertEqual(h.client.status.state, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(h.scheduler.armed, [])
        h.client.record(.featureUsed(.find))
        h.settle()
        XCTAssertEqual(h.client.status.pending, 0)
        XCTAssertEqual(h.recent().count, 0, "nothing recorded while off")
        h.transport.release(.delivered)
        h.settle()
        XCTAssertEqual(h.client.status.delivered, 0, "a send that was in flight changes nothing")
    }

    func testScriptedRunsRecordButNeverSend() {
        let dir = TelemetryHarness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = TelemetryHarness(directory: dir)
        h.start(automated: true)
        XCTAssertEqual(h.client.status.state, .recordOnly)
        h.client.record(.featureUsed(.find))
        h.client.record(.onboardingFinished(imported: false))
        h.settle()
        h.scheduler.fireAll(h.client)
        XCTAssertEqual(h.transport.bodies.count, 0)
        XCTAssertEqual(h.client.status.pending, 0)
        XCTAssertEqual(h.recent().map(\.event), ["feature.used", "onboarding.finished"], "still shown in See what Airc sends")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("queue.json").path))
    }

    func testNoKeyMeansNothingAtAll() {
        let dir = TelemetryHarness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = TelemetryHarness(directory: dir)
        h.start(key: "")
        h.client.record(.featureUsed(.find))
        h.settle()
        XCTAssertEqual(h.client.status.state, .unavailable)
        XCTAssertNil(h.client.status.installID)
        XCTAssertEqual(h.recent().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("install.json").path), "no ID is even made")
    }

    func testResetGivesANewInstallIDAndDropsTheQueue() {
        let h = TelemetryHarness()
        h.startSending()
        h.client.record(.featureUsed(.find))
        h.settle()
        let old = h.client.status.installID
        h.client.resetInstallID()
        h.settle()
        XCTAssertNotNil(old)
        XCTAssertNotEqual(h.client.status.installID, old)
        XCTAssertEqual(h.client.status.pending, 0)
        XCTAssertEqual(h.recent().count, 0)
        h.client.record(.featureUsed(.find))
        h.settle()
        h.scheduler.fireAll(h.client)
        XCTAssertEqual(h.transport.events.map { $0["distinct_id"] as! String }, [h.client.status.installID!])
        XCTAssertEqual(h.transport.events.first.flatMap { ($0["properties"] as? [String: Any])?["install_age_days"] as? String }, "0")
    }

    func testFlushForQuitSendsWhatIsWaiting() {
        let h = TelemetryHarness()
        h.startSending()
        for _ in 0..<3 { h.client.record(.featureUsed(.find)) }
        h.client.flushForQuit(timeout: 2)
        XCTAssertEqual(h.transport.events.count, 3)
        XCTAssertEqual(h.client.status.pending, 0)
    }

    func testFlushForQuitGivesUpAfterItsTimeout() {
        let h = TelemetryHarness()
        h.transport.hold = true
        h.startSending()
        h.client.record(.featureUsed(.find))
        let t0 = Date()
        h.client.flushForQuit(timeout: 0.3)
        let waited = Date().timeIntervalSince(t0)
        XCTAssertGreaterThan(waited, 0.25)
        XCTAssertLessThan(waited, 1.5)
        XCTAssertEqual(h.client.status.pending, 1, "kept for the next launch")
    }

    func testSeeWhatAircSendsKeepsTheLastHundred() {
        let h = TelemetryHarness()
        h.startSending()
        for _ in 0..<129 { h.client.record(.featureUsed(.find)) }
        h.client.record(.featureUsed(.telemetrySmoke))
        h.settle()
        let r = h.recent()
        XCTAssertEqual(r.count, 100)
        XCTAssertEqual(r.last?.properties["feature"], .string("telemetry.smoke"))
        XCTAssertTrue(r.last?.json.contains("\"distinct_id\"") ?? false)
    }
}

/// The real transport against a loopback HTTP server: the request PostHog would get, and how statuses are read.
final class TelemetryHTTPTests: XCTestCase {
    func testPostsTheBatchToTheBatchEndpoint() throws {
        let server = try LoopbackServer(status: 200)
        let port = try XCTUnwrap(server.start())
        let client = Telemetry(transport: URLSessionTelemetryTransport(timeout: 5), scheduler: ManualScheduler())
        client.start(.init(resolution: .resolve(host: "http://127.0.0.1:\(port)", key: "phc_mock", environment: [:],
                                                defaultsValue: nil, userEnabled: true, automated: true),
                           context: TelemetryHarness.context, directory: nil))
        client.record(.featureUsed(.telemetrySmoke))
        client.flushForQuit(timeout: 5)
        server.stop()
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(request.head.hasPrefix("POST /batch/ HTTP/1.1"), request.head)
        XCTAssertTrue(request.head.lowercased().contains("content-type: application/json"))
        XCTAssertFalse(request.head.lowercased().contains("cookie"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["api_key"] as? String, "phc_mock")
        let events = try XCTUnwrap(body["batch"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["event"] as? String, "feature.used")
        XCTAssertEqual(client.status.delivered, 1)
    }

    func testStatusCodes() throws {
        for (status, expected) in [(200, TelemetrySendResult.delivered), (401, .rejected(status: 401)), (413, .rejected(status: 413)),
                                   (429, .failed), (503, .failed)] {
            let server = try LoopbackServer(status: status)
            let port = try XCTUnwrap(server.start())
            let done = expectation(description: "\(status)")
            let got = LockedBox<TelemetrySendResult?>(nil)
            URLSessionTelemetryTransport(timeout: 5).send(Data("{}".utf8), to: URL(string: "http://127.0.0.1:\(port)/batch/")!) { r in
                got.mutate { $0 = r }
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            server.stop()
            XCTAssertEqual(got.value, expected, "HTTP \(status)")
        }
    }
}

// MARK: - Test doubles

final class TelemetryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var d = Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date { lock.withLock { d } }
    func advance(_ s: TimeInterval) { lock.withLock { d = d.addingTimeInterval(s) } }
}

/// Records every batch; answers with `result`, or holds the answer (`hold`) until `release`.
final class FakeTransport: TelemetryTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [Data] = []
    private var _held: [@Sendable (TelemetrySendResult) -> Void] = []
    private var _result = TelemetrySendResult.delivered
    private var _hold = false

    var result: TelemetrySendResult {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }

    var bodies: [Data] { lock.withLock { _bodies } }
    var events: [[String: Any]] { bodies.flatMap(events(in:)) }

    func events(in body: Data) -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["batch"] as? [[String: Any]] ?? []
    }

    func send(_ body: Data, to url: URL, completion: @escaping @Sendable (TelemetrySendResult) -> Void) {
        let (hold, result) = lock.withLock { () -> (Bool, TelemetrySendResult) in
            _bodies.append(body)
            if _hold { _held.append(completion) }
            return (_hold, _result)
        }
        if !hold { completion(result) }
    }

    func release(_ r: TelemetrySendResult) {
        let held = lock.withLock { () -> [@Sendable (TelemetrySendResult) -> Void] in
            defer { _held = [] }
            return _held
        }
        held.forEach { $0(r) }
    }
}

/// One-shot timers that fire only when a test says so.
final class ManualScheduler: TelemetryScheduler, @unchecked Sendable {
    final class Timer: TelemetryTimer, @unchecked Sendable {
        let delay: TimeInterval
        let work: @Sendable () -> Void
        private let lock = NSLock()
        private var _cancelled = false
        var cancelled: Bool { lock.withLock { _cancelled } }
        init(delay: TimeInterval, work: @escaping @Sendable () -> Void) {
            self.delay = delay
            self.work = work
        }
        func cancel() { lock.withLock { _cancelled = true } }
    }

    private let lock = NSLock()
    private var timers: [Timer] = []
    /// Moves the test clock to when a fired timer was due.
    var advance: (@Sendable (TimeInterval) -> Void)?

    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> TelemetryTimer {
        let t = Timer(delay: seconds, work: work)
        lock.withLock { timers.append(t) }
        return t
    }

    private var live: [Timer] { lock.withLock { timers.filter { !$0.cancelled } } }
    /// The delays of the timers still armed.
    var armed: [TimeInterval] { live.map(\.delay).sorted() }

    private func take(_ t: [Timer]) { lock.withLock { timers.removeAll { x in t.contains { $0 === x } } } }

    /// Fires the earliest armed timer.
    func fireNext(_ client: Telemetry) {
        guard let t = live.min(by: { $0.delay < $1.delay }) else { return }
        take([t])
        advance?(t.delay)
        t.work()
        settle(client)
    }

    func fire(delay: TimeInterval, _ client: Telemetry) {
        let due = live.filter { $0.delay == delay }
        take(due)
        advance?(delay)
        due.forEach { $0.work() }
        settle(client)
    }

    /// Fires every armed timer, and the ones they arm, up to a bound (a failing transport re-arms forever).
    func fireAll(_ client: Telemetry) {
        for _ in 0..<50 {
            let due = live
            guard !due.isEmpty else { return }
            take(due)
            advance?(due.map(\.delay).max() ?? 0)
            due.forEach { $0.work() }
            settle(client)
        }
    }

    private func settle(_ client: Telemetry) { for _ in 0..<30 { client.drain() } }
}

final class TelemetryHarness {
    let clock: TelemetryTestClock
    let transport: FakeTransport
    let scheduler: ManualScheduler
    let directory: URL?
    let client: Telemetry

    static let context = TelemetryContext(appVersion: "0.1.0", build: "202611061230", channel: .dev, engine: .chromium,
                                          osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 2),
                                          arch: "arm64", preferredLanguage: "en-GB")

    init(directory: URL? = nil, random: Double = 0.5) {
        let clock = TelemetryTestClock(), transport = FakeTransport(), scheduler = ManualScheduler()
        self.clock = clock
        self.transport = transport
        self.scheduler = scheduler
        scheduler.advance = { clock.advance($0) }
        self.directory = directory
        client = Telemetry(transport: transport, scheduler: scheduler, now: { clock.date }, random: { random })
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("airc-telemetry-\(UUID().uuidString)")
    }

    func startSending() { start() }

    func start(key: String = "phc_test", userEnabled: Bool = true, automated: Bool = false) {
        client.start(.init(resolution: .resolve(host: "https://eu.i.posthog.com", key: key, environment: [:], defaultsValue: nil,
                                                userEnabled: userEnabled, automated: automated),
                           context: Self.context, directory: directory))
        settle()
    }

    /// Runs the client's queue until the async hops (send → completion → next batch) have settled.
    func settle() { for _ in 0..<30 { client.drain() } }

    /// What "See what Airc sends" would show now.
    func recent() -> [TelemetryRecord] {
        let box = LockedBox<[TelemetryRecord]>([])
        let got = XCTestExpectation(description: "recent")
        let token = client.observeRecent { r in
            box.mutate { $0 = r }
            got.fulfill()
        }
        _ = XCTWaiter.wait(for: [got], timeout: 5)
        client.removeObserver(token)
        return box.value
    }
}

/// A loopback-only HTTP server that answers every request with `status` and keeps what it got.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let status: Int
    private let queue = DispatchQueue(label: "airc.test.loopback")
    private let lock = NSLock()
    private var got: [(head: String, body: Data)] = []

    var requests: [(head: String, body: Data)] { lock.withLock { got } }

    init(status: Int) throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        p.acceptLocalOnly = true
        listener = try NWListener(using: p)
        self.status = status
    }

    func start() -> UInt16? {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [self] c in
            c.start(queue: queue)
            receive(c, Data())
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        return listener.port?.rawValue
    }

    func stop() { listener.cancel() }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { c.cancel() } else { receive(c, buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            let body = Data(buffer[end.upperBound...])
            if body.count < length, !complete, error == nil { return receive(c, buffer) }
            lock.withLock { got.append((head, body)) }
            let reply = "HTTP/1.1 \(status) Status\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
            c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

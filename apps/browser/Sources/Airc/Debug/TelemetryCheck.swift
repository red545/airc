// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import Network

/// `--script telemetry` (docs/user/telemetry.md): delivery to a mock PostHog on this Mac. Build with a loopback host,
/// which a scripted run may send to (and only to):
///
///     AIRC_TELEMETRY_HOST=http://127.0.0.1:18573 AIRC_TELEMETRY_KEY=phc_mock scripts/build-app.sh --no-test
///
/// The scenario listens on the Info.plist host's port, drives a few features through their real dispatch points,
/// shows Settings → Privacy and "See what Airc sends" (30-privacy.png, 31-privacy-events.png), sends at once with the
/// quit flush and checks the batch the mock got against PostHog's batch format (written to telemetry-batch.json). Then
/// "Share anonymous usage data" off: nothing queued, nothing recorded. A build without a key checks that nothing is
/// recorded at all.
extension SnapshotRunner {
    func telemetryScenario() {
        let info = Bundle.main.infoDictionary ?? [:]
        let host = info["AircTelemetryHost"] as? String
        let endpoint = host.flatMap(TelemetryResolution.batchEndpoint)
        guard info["AircTelemetryKey"] as? String != nil, let endpoint, TelemetryResolution.isLoopback(endpoint),
              let port = endpoint.port.flatMap({ UInt16(exactly: $0) }) else {
            run { [self] in
                let s = Telemetry.shared.status
                check(AppTelemetry.shared.resolution.state == .unavailable || AppTelemetry.shared.resolution.state == .recordOnly,
                      "telemetry: without a loopback host a scripted run never sends (\(AppTelemetry.shared.resolution.state))")
                note("SKIP telemetry delivery: build with AIRC_TELEMETRY_HOST=http://127.0.0.1:<port> AIRC_TELEMETRY_KEY=phc_mock (state \(s.state))")
            }
            return
        }
        let mock = MockPostHog(port: port)
        step { [self] done in
            mock.start { ok in
                self.check(ok, "telemetry: the mock PostHog listens on 127.0.0.1:\(port)")
                done()
            }
        }
        run { [self] in
            check(AppTelemetry.shared.resolution.state == .sending, "telemetry: a scripted run sends to a loopback host only (\(AppTelemetry.shared.resolution.state))")
            let sentinel = AppPaths.dataDirectory.appendingPathComponent("Telemetry/running")
            check(FileManager.default.fileExists(atPath: sentinel.path), "telemetry: the running sentinel is there while Airc runs")
        }
        // Features through their dispatch points.
        run { [self] in c.openCommandBar(mode: .newTab) }
        wait(0.3)
        run { [self] in c.closeCommandBar() }
        wait(0.2)
        run { [self] in c.openCommandBar(mode: .editURL) }
        wait(0.3)
        run { [self] in c.closeCommandBar() }
        run { [self] in
            if let l = c.app?.openLittleArc(url: nil) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { l.window.close() } }
        }
        wait(0.8)
        // Settings → Privacy, then "See what Airc sends".
        run { [self] in c.app?.showSettings(page: .privacy) }
        wait(0.8)
        step { [self] done in
            guard let w = c.app?.settingsWindow?.window else { return done() }
            captureWindow(w, name: "30-privacy", rounded: 0, done)
        }
        run { TelemetrySheetState.shared.showingEvents = true }
        step { [self] done in
            waitUntil({ self.c.app?.settingsWindow?.window.attachedSheet != nil }, timeout: 3) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let sheet = self.c.app?.settingsWindow?.window.attachedSheet else {
                        self.check(false, "telemetry: See what Airc sends opens as a sheet")
                        return done()
                    }
                    self.check(true, "telemetry: See what Airc sends opens as a sheet")
                    self.captureWindow(sheet, name: "31-privacy-events", rounded: 0, done)
                }
            }
        }
        run { TelemetrySheetState.shared.showingEvents = false }
        wait(0.4)
        // Send now (the quit flush), then read what the mock got.
        step { [self] done in
            Telemetry.shared.flushForQuit(timeout: 3)
            waitUntil({ !mock.batches.isEmpty }, timeout: 3) { done() }
        }
        run { [self] in
            let batches = mock.batches
            check(!batches.isEmpty && batches.allSatisfy { $0.head.hasPrefix("POST /batch/ HTTP/1.1") }, "telemetry: batches POST to /batch/ (\(batches.count))")
            let bodies = batches.compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
            check(bodies.count == batches.count && bodies.allSatisfy { $0["api_key"] as? String == "phc_mock" && $0["batch"] is [[String: Any]] },
                  "telemetry: each body is {api_key, batch} JSON")
            let events = bodies.flatMap { $0["batch"] as? [[String: Any]] ?? [] }
            let wellFormed = events.allSatisfy { e in
                Set(e.keys) == ["uuid", "event", "distinct_id", "timestamp", "properties"]
                    && UUID(uuidString: e["uuid"] as? String ?? "") != nil && UUID(uuidString: e["distinct_id"] as? String ?? "") != nil
                    && (e["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } != nil
            }
            check(!events.isEmpty && wellFormed, "telemetry: \(events.count) events, each with uuid, event, distinct_id, timestamp, properties")
            let props = events.compactMap { $0["properties"] as? [String: Any] }
            check(props.allSatisfy { $0["$process_person_profile"] as? Bool == false && $0["$geoip_disable"] as? Bool == true
                && $0["$lib"] as? String == "airc-macos" }, "telemetry: anonymous events, no GeoIP, $lib airc-macos")
            let names = events.map { e -> String in
                let f = (e["properties"] as? [String: Any])?["feature"] as? String
                return [e["event"] as? String, f, (e["properties"] as? [String: Any])?["variant"] as? String].compactMap { $0 }.joined(separator: " ")
            }
            note("telemetry: sent " + names.joined(separator: ", "))
            check(names.contains { $0.hasPrefix("app.launched") }, "telemetry: app.launched was sent")
            check(names.contains("feature.used command_bar.open new_tab") && names.contains("feature.used command_bar.open edit_url"),
                  "telemetry: ⌘T and ⌘L count as command_bar.open new_tab / edit_url")
            check(names.contains("feature.used little_arc.open shortcut"), "telemetry: ⌥⌘N counts as little_arc.open shortcut")
            // Nothing that looks like a URL, a path, a host, an address or an email in any value.
            let leaks = props.flatMap { $0.values.compactMap { $0 as? String } }.filter {
                $0.contains("/") || $0.contains("@") || $0.contains("http") || $0.contains("127.0.0.1") || $0.contains(NSUserName())
            }
            check(leaks.isEmpty, "telemetry: no value looks like a URL, path, host or account (\(leaks.prefix(3)))")
            if let body = batches.first?.body, let obj = try? JSONSerialization.jsonObject(with: body),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try? pretty.write(to: dir.appendingPathComponent("telemetry-batch.json"))
                note("wrote telemetry-batch.json")
            }
            let s = Telemetry.shared.status
            check(s.pending == 0 && s.flushDue == nil, "telemetry: once sent, nothing is queued and no flush is armed (pending \(s.pending))")
        }
        // Off: the queue goes, nothing more is recorded or sent.
        run { [self] in
            AppTelemetry.shared.setUserEnabled(false)
            Telemetry.shared.record(.featureUsed(.telemetrySmoke))
        }
        wait(0.5)
        step { [self] done in
            let s = Telemetry.shared.status
            let queue = AppPaths.dataDirectory.appendingPathComponent("Telemetry/queue.json")
            let sentinel = AppPaths.dataDirectory.appendingPathComponent("Telemetry/running")
            check(s.state == .off && s.pending == 0 && !FileManager.default.fileExists(atPath: queue.path)
                  && !FileManager.default.fileExists(atPath: sentinel.path),
                  "telemetry: turned off, nothing is queued and no files stay but the ID (\(s.state), pending \(s.pending))")
            let before = mock.batches.count
            Telemetry.shared.flushForQuit(timeout: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.check(mock.batches.count == before, "telemetry: nothing is sent while off")
                AppTelemetry.shared.setUserEnabled(true)
                mock.stop()
                done()
            }
        }
    }
}

/// A loopback-only stand-in for PostHog's capture API: answers every request with `{"status": 1}` and keeps it.
final class MockPostHog {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "airc.test.mock-posthog")
    private let lock = NSLock()
    private var got: [(head: String, body: Data)] = []

    var batches: [(head: String, body: Data)] { lock.withLock { got } }

    init(port: UInt16) { self.port = port }

    /// Calls `ready` on the main queue.
    func start(_ ready: @escaping (Bool) -> Void) {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        p.acceptLocalOnly = true
        p.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: p) else { return ready(false) }
        listener = l
        var answered = false
        l.stateUpdateHandler = { state in
            let ok: Bool
            switch state {
            case .ready: ok = true
            case .failed, .cancelled: ok = false
            default: return
            }
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                ready(ok)
            }
        }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            self.receive(c, Data())
        }
        l.start(queue: queue)
    }

    func stop() { listener?.cancel() }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return c.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { c.cancel() } else { self.receive(c, buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            let body = Data(buffer[end.upperBound...])
            if body.count < length, !complete, error == nil { return self.receive(c, buffer) }
            self.lock.withLock { self.got.append((head, body)) }
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{\"status\": 1}"
            c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import MachO

/// The deliberate crash's site: a frame the relaunch must find in the crash report, by name (dladdr in this binary).
@_cdecl("airc_test_crash_site") @inline(never) @_optimize(none)
func aircTestCrashSite(_ kind: Int32) {
    switch kind {
    case 1: TestCrashSwitch.target.pointee = 42   // SIGSEGV: page zero is never mapped
    case 2: abort()                                // SIGABRT, raised (the handler raises it again)
    default: fatalError("test crash")              // SIGTRAP (brk), like Chromium's CHECK
    }
}

/// `--test-crash=segv|abort|trap|segv-thread` (test builds only; scripts/tests/crash-visibility.sh): crashes the app on
/// purpose a second after the launch's crash-report look (AppCrashReports), so the next launch's look has a mark from
/// before the crash. Never in a public build: this type is one of check-release.py's test markers.
enum TestCrashSwitch {
    nonisolated(unsafe) static var target = UnsafeMutablePointer<Int>(bitPattern: 0x10)!
    private static let kind = CommandLine.arguments.first { $0.hasPrefix("--test-crash=") }.map { String($0.dropFirst(13)) }
    private static var fired = false

    /// The launch's look is done (main queue).
    static func armed() {
        guard let kind, !fired else { return }
        fired = true
        let code: Int32 = kind.hasPrefix("segv") ? 1 : kind == "abort" ? 2 : 3
        print("[test-crash] \(kind) in 1 s; signal handlers ours: \(CrashLog.handlers)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if kind == "segv-thread" {
                Thread { aircTestCrashSite(code) }.start()
            } else {
                aircTestCrashSite(code)
            }
        }
    }
}

/// `--script crashvis` (scripts/tests/crash-visibility.sh), the launch after a `--test-crash` one on the same data
/// folder. The signal record the crash left (CrashRecords/record.1) becomes exactly one `$exception`, through the
/// launch's own look (it waits a minute after the crash for macOS's .ips) or, with AIRC_CRASHVIS_NOW=1, at once; built
/// with a loopback telemetry host, the in-app mock PostHog receives it. Its frames hold the crash site
/// (`airc_test_crash_site`, found by name in this very binary) with this binary's UUID, and nothing of the Mac: no
/// path, no user name. `AIRC_CRASHVIS_EXPECT=none`: a later launch, after macOS's .ips of the same crash was put in
/// this home's DiagnosticReports, sends nothing (the .ips is the same crash). `AIRC_CRASHVIS_SOURCE=ips`: that .ips was
/// there from the start, and the one event is macOS's (the record of the same crash, a minute later, adds nothing).
/// AIRC_CRASHVIS_SIGNAL names the signal.
/// `AIRC_CRASHVIS_RENDERER=1` (Chromium): a tab's renderer ends itself (chrome://kill, SIGTERM: no crash report), which
/// counts as one `process.gone` with the process type and signal only.
extension SnapshotRunner {
    func crashVisibilityScenario() {
        let env = ProcessInfo.processInfo.environment
        let expectNone = env["AIRC_CRASHVIS_EXPECT"] == "none"
        let signal = env["AIRC_CRASHVIS_SIGNAL"] ?? "SIGSEGV"
        let source = env["AIRC_CRASHVIS_SOURCE"] ?? "signal"
        var crashTime: Date?
        let resolution = AppTelemetry.shared.resolution
        let mock: MockPostHog? = {
            guard resolution.sends, let port = resolution.endpoint?.port.flatMap({ UInt16(exactly: $0) }) else { return nil }
            return MockPostHog(port: port)
        }()
        CrashCheckRecent.shared.start()
        if let mock {
            step { done in mock.start { _ in done() } }
        }
        run { [self] in
            let h = CrashLog.handlers
            check(h.installed, "crashvis: our signal handlers are installed (on top of \(h.chained) earlier one(s), \(h.images) binaries listed)")
            if app?.engine.name.hasPrefix("Chromium") == true {
                check(h.chained > 0, "crashvis: on Chromium they hand on to the engine's own handlers (\(h.chained))")
            }
            check(resolution.records, "crashvis: telemetry records in this run (\(resolution.state))")
            check(!resolution.sends || resolution.endpoint.map(TelemetryResolution.isLoopback) == true,
                  "crashvis: a scripted run sends to a loopback host only")
            let record = CrashLog.recordsDirectory.appendingPathComponent("record.1")
            let data = (try? Data(contentsOf: record)) ?? Data()
            let parsed = CrashReport.parseSignalRecord(data)
            check(parsed != nil, "crashvis: the crash left a signal record (record.1, \(data.count) bytes)")
            crashTime = parsed?.crashTime
            if let parsed {
                note("crashvis: record: \(parsed.signal ?? "?") code \(parsed.signalCode.map(String.init) ?? "?"), \(parsed.frames.count) frames, \(parsed.images.count) binaries, build \(parsed.appBuild ?? "?")")
                check(parsed.signal == signal, "crashvis: the record has the signal (\(parsed.signal ?? "none"), expected \(signal))")
            }
            try? data.write(to: dir.appendingPathComponent("crash-record.txt"))
        }
        if env["AIRC_CRASHVIS_NOW"] == "1" {
            step { done in AppCrashReports.shared.lookAtRecordsForCheck { _ in done() } }
        }
        step { [self] done in
            // The launch's look runs 10 s after launch; a record younger than a minute waits for its .ips until then.
            let timeout: Double = expectNone ? 20 : 100
            waitUntil({ !self.crashvisExceptions().isEmpty }, timeout: timeout) {
                AppCrashReports.shared.drain()
                done()
            }
        }
        if source == "ips" {
            // The record waits a minute after the crash for its .ips; only after that look is "exactly one" proven.
            step { [self] done in
                let until = (crashTime ?? Date()).addingTimeInterval(CrashReportLog.recordSettle + 8)
                note("crashvis: waiting \(max(0, Int(until.timeIntervalSinceNow))) s for the record's own look")
                waitUntil({ Date() > until }, timeout: 120) {
                    AppCrashReports.shared.drain()
                    done()
                }
            }
        }
        run { [self] in
            let events = crashvisExceptions()
            if expectNone {
                check(events.isEmpty, "crashvis: macOS's .ips of the same crash adds no second event (\(events.count))")
                return
            }
            check(events.count == 1, "crashvis: the crash is exactly one $exception (\(events.count))")
            guard let event = events.first else { return }
            let json = event.json
            try? json.write(to: dir.appendingPathComponent("crashvis-event.json"), atomically: true, encoding: .utf8)
            note("wrote crashvis-event.json")
            check(event.properties["crash_source"] == .string(source), "crashvis: crash_source is \(source) (\(String(describing: event.properties["crash_source"])))")
            check(event.properties["signal"] == .string(signal), "crashvis: the event's signal is \(signal)")
            let site = Self.crashSiteFrames(json)
            check(site.uuidMatches, "crashvis: the app's frames carry this binary's UUID (\(site.uuid))")
            check(site.named > 0, "crashvis: a frame is the crash site, airc_test_crash_site (\(site.named) of \(site.frames) frames)")
            let planted = [NSUserName(), NSHomeDirectory(), AppPaths.dataDirectory.path, "/Users/", "/private/", "file://"]
            let leaks = planted.filter { !$0.isEmpty && json.contains($0) }
            check(leaks.isEmpty, "crashvis: no path or user name in the event (\(leaks))")
        }
        if env["AIRC_CRASHVIS_RENDERER"] == "1" {
            rendererGoneSteps()
        }
        if let mock {
            step { [self] done in
                Telemetry.shared.flushForQuit(timeout: 3)
                waitUntil({ !mock.batches.isEmpty || expectNone }, timeout: 5) {
                    let events = mock.batches.flatMap { b -> [[String: Any]] in
                        ((try? JSONSerialization.jsonObject(with: b.body)) as? [String: Any])?["batch"] as? [[String: Any]] ?? []
                    }
                    let exceptions = events.filter { $0["event"] as? String == "$exception" }
                    self.check(exceptions.count == (expectNone ? 0 : 1),
                               "crashvis: the mock PostHog got \(expectNone ? "no" : "one") $exception (\(exceptions.count), \(events.count) events)")
                    mock.stop()
                    done()
                }
            }
        } else {
            run { [self] in note("crashvis: no loopback telemetry host in this build: checked See what Airc sends only") }
        }
    }

    private func rendererGoneSteps() {
        guard app?.engine.name.hasPrefix("Chromium") == true else {
            return run { [self] in note("crashvis: renderer step skipped (Chromium only)") }
        }
        var tabID = ""
        step { [self] done in
            guard let t = try? c.store.openTab(url: "data:text/html,<title>Renderer</title>", inSpace: c.currentSpaceID,
                                               title: "Renderer") else { return done() }
            tabID = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
            waitUntil({ self.c.engineTab(for: tabID)?.title == "Renderer" }, timeout: 8) { done() }
        }
        run { [self] in c.engineTab(for: tabID)?.load(URL(string: "chrome://kill")!) }
        step { [self] done in
            let gone = { CrashCheckRecent.shared.records.filter { $0.event == "process.gone" } }
            waitUntil({ !gone().isEmpty }, timeout: 8) {
                let events = gone()
                self.check(events.count == 1, "crashvis: the renderer's end is one process.gone (\(events.count))")
                let p = events.first?.properties ?? [:]
                self.check(p["process"] == .string("renderer") && p["exit_signal"] == .string("SIGTERM"),
                           "crashvis: process.gone says renderer and SIGTERM (\(String(describing: p["process"])), \(String(describing: p["exit_signal"])))")
                if let json = events.first?.json {
                    try? json.write(to: self.dir.appendingPathComponent("process-gone-event.json"), atomically: true, encoding: .utf8)
                }
                done()
            }
        }
    }

    private func crashvisExceptions() -> [TelemetryRecord] {
        CrashCheckRecent.shared.records.filter { $0.event == "$exception" }
    }

    /// The event's frames in this binary (by the crashed run's load address), and how many of them dladdr names
    /// `airc_test_crash_site` here; whether their debug image is this binary's UUID.
    static func crashSiteFrames(_ json: String) -> (frames: Int, named: Int, uuid: String, uuidMatches: Bool) {
        guard let event = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let props = event["properties"] as? [String: Any],
              let list = props["$exception_list"] as? [[String: Any]],
              let frames = (list.first?["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]],
              let images = props["$debug_images"] as? [[String: Any]] else { return (0, 0, "", false) }
        var info = Dl_info()
        let site: @convention(c) (Int32) -> Void = aircTestCrashSite
        guard dladdr(unsafeBitCast(site, to: UnsafeRawPointer.self), &info) != 0, let base = info.dli_fbase else { return (frames.count, 0, "", false) }
        let uuid = Self.uuid(of: base)
        // "Airc", or a renamed test copy (scripts/tests/crash-visibility.sh).
        let exe = Bundle.main.executableURL?.lastPathComponent ?? "Airc"
        let mine = images.first { $0["code_file"] as? String == exe }
        var named = 0
        for f in frames where f["module"] as? String == exe {
            guard let a = (f["instruction_addr"] as? String).flatMap(hex), let b = (f["image_addr"] as? String).flatMap(hex), a > b else { continue }
            // A return address points after its call: look up the instruction before it, as symbolication does.
            let here = UnsafeRawPointer(base).advanced(by: Int(a - b) - 1)
            var s = Dl_info()
            // Swift calls the function itself, not its @_cdecl thunk: either name is the crash site.
            if dladdr(here, &s) != 0, let name = s.dli_sname.map({ String(cString: $0) }),
               name == "airc_test_crash_site" || name.contains("17aircTestCrashSite") { named += 1 }
        }
        return (frames.count, named, uuid, mine?["debug_id"] as? String == uuid)
    }

    private static func hex(_ s: String) -> UInt64? { s.hasPrefix("0x") ? UInt64(s.dropFirst(2), radix: 16) : nil }

    private static func uuid(of base: UnsafeRawPointer) -> String {
        let header = base.assumingMemoryBound(to: mach_header_64.self)
        var cursor = base.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let lc = cursor.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmd == LC_UUID { return UUID(uuid: cursor.assumingMemoryBound(to: uuid_command.self).pointee.uuid).uuidString }
            cursor = cursor.advanced(by: Int(lc.cmdsize))
        }
        return ""
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import MachO
import MetricKit

/// A function with a known address in this binary: the synthetic crash's top frame, which symbolication must resolve
/// back to this name (REPORT: the smoke event).
@_cdecl("airc_crash_check_marker") @inline(never)
func aircCrashCheckMarker() -> Int { 42 }

/// `--script crashreports` (docs/user/telemetry.md, "Crash reports"): a synthetic `.ips` crash of this very binary (its
/// real UUID and load address, a real function's offset) and a synthetic MetricKit hang each become one `$exception`
/// event, buffered like any event, in "See what Airc sends" (33-crash-report.png), with nothing of what the fixtures
/// plant (paths, the user name, thread names, crash messages). Never the owner's DiagnosticReports. A scripted run only
/// records: built with a loopback telemetry host (see TelemetryCheck.swift) the events also go to the mock PostHog.
/// `AIRC_CRASH_SMOKE=1` also records the crash once more marked `"smoke": true` and writes it to crash-smoke-event.json,
/// for the one manual smoke event (never sent from here).
extension SnapshotRunner {
    func crashReportsScenario() {
        let folder = AppPaths.dataDirectory.appendingPathComponent("CrashFixture", isDirectory: true)
        let resolution = AppTelemetry.shared.resolution
        let mock: MockPostHog? = {
            guard resolution.sends, let port = resolution.endpoint?.port.flatMap({ UInt16(exactly: $0) }) else { return nil }
            return MockPostHog(port: port)
        }()
        var before = 0
        var uuid = ""
        CrashCheckRecent.shared.start()
        if let mock {
            step { done in mock.start { _ in done() } }
        }
        run { [self] in
            check(resolution.records, "crash reports: telemetry records in this run (\(resolution.state))")
            check(!resolution.sends || resolution.endpoint.map(TelemetryResolution.isLoopback) == true,
                  "crash reports: a scripted run sends to a loopback host only")
            note("crash reports: MetricKit has delivered \(MXMetricManager.shared.pastDiagnosticPayloads.count) diagnostic payload(s) to \(Bundle.main.bundleIdentifier ?? "?")")
            before = Telemetry.shared.status.pending
            do {
                let (ips, exe) = try Self.syntheticIPS()
                uuid = exe
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try ips.write(to: folder.appendingPathComponent("Airc-2026-11-06-120000.ips"))
                try ips.write(to: folder.appendingPathComponent("Arc-2026-11-06-120000.ips"))   // another app's name: skipped
            } catch {
                check(false, "crash reports: wrote the synthetic .ips (\(error))")
            }
        }
        step { [self] done in
            AppCrashReports.shared.collectForCheck(from: folder) { n in
                self.check(n == 1, "crash reports: the synthetic .ips is one crash (\(n))")
                done()
            }
        }
        run { AppCrashReports.shared.receive([Self.syntheticMetricKitHang()]) }
        step { [self] done in
            waitUntil({ Telemetry.shared.status.pending - before >= (resolution.sends ? 2 : 0) && self.recentExceptions().count >= 2 },
                      timeout: 3) { done() }
        }
        run { [self] in
            let events = recentExceptions()
            check(events.count == 2, "crash reports: two $exception events, a crash and a hang (\(events.count))")
            let pending = Telemetry.shared.status.pending - before
            if resolution.sends {
                check(pending == 2, "crash reports: both are buffered in the queue (\(pending))")
            } else {
                check(pending == 0, "crash reports: record-only, nothing queued to send (\(pending))")
            }
            guard let crash = events.first(where: { $0.properties["crash_kind"] == .string("crash") }) else {
                return check(false, "crash reports: the crash is among them")
            }
            let json = crash.json
            try? json.write(to: dir.appendingPathComponent("crash-report-event.json"), atomically: true, encoding: .utf8)
            note("wrote crash-report-event.json")
            check(json.contains("\"debug_id\" : \"\(uuid)\""), "crash reports: the binary's UUID is the debug image (\(uuid))")
            check(json.contains("\"function\" : \"airc_crash_check_marker\""), "crash reports: the marker frame is there")
            let planted = [NSUserName(), NSHomeDirectory(), "secret.example", "hunter2", "libspy", "Injected", "queue-name"]
            let leaks = events.flatMap { e in planted.filter { e.json.contains($0) } }
            check(leaks.isEmpty, "crash reports: no path, user name, thread name, crash message or other binary (\(leaks))")
        }
        // "See what Airc sends" shows them.
        run { [self] in c.app?.showSettings(page: .privacy) }
        wait(0.8)
        run { TelemetrySheetState.shared.showingEvents = true }
        step { [self] done in
            waitUntil({ self.c.app?.settingsWindow?.window.attachedSheet != nil }, timeout: 3) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let sheet = self.c.app?.settingsWindow?.window.attachedSheet else {
                        self.check(false, "crash reports: See what Airc sends opens")
                        return done()
                    }
                    self.check(true, "crash reports: See what Airc sends opens")
                    self.captureWindow(sheet, name: "33-crash-report", rounded: 0, done)
                }
            }
        }
        run { TelemetrySheetState.shared.showingEvents = false }
        wait(0.4)
        if let mock {
            step { [self] done in
                Telemetry.shared.flushForQuit(timeout: 3)
                waitUntil({ !mock.batches.isEmpty }, timeout: 3) {
                    let events = mock.batches.flatMap { b -> [[String: Any]] in
                        ((try? JSONSerialization.jsonObject(with: b.body)) as? [String: Any])?["batch"] as? [[String: Any]] ?? []
                    }
                    let exceptions = events.filter { $0["event"] as? String == "$exception" }
                    self.check(exceptions.count == 2, "crash reports: the mock PostHog got both $exception events (\(exceptions.count))")
                    mock.stop()
                    done()
                }
            }
        }
        if ProcessInfo.processInfo.environment["AIRC_CRASH_SMOKE"] == "1" {
            step { [self] done in
                AppCrashReports.shared.drain()
                var log = CrashReportLog(since: .distantPast)
                guard let report = log.scan(folder, bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path, now: Date()).first else {
                    check(false, "crash reports: smoke report")
                    return done()
                }
                Telemetry.shared.record(report, smoke: true)
                waitUntil({ self.recentExceptions().contains { $0.properties["smoke"] == .bool(true) } }, timeout: 3) {
                    if let smoke = self.recentExceptions().first(where: { $0.properties["smoke"] == .bool(true) }) {
                        try? smoke.json.write(to: self.dir.appendingPathComponent("crash-smoke-event.json"), atomically: true, encoding: .utf8)
                        self.note("wrote crash-smoke-event.json (not sent)")
                    }
                    done()
                }
            }
        }
    }

    /// The `$exception` events "See what Airc sends" holds, newest first (as of its last update on the main queue).
    private func recentExceptions() -> [TelemetryRecord] {
        CrashCheckRecent.shared.records.filter { $0.event == "$exception" }.reversed()
    }

    // MARK: Fixtures

    /// The marker function's entry point (this binary isn't arm64e: no pointer signature to strip).
    private static var markerAddress: UnsafeRawPointer {
        let f: @convention(c) () -> Int = aircCrashCheckMarker
        return unsafeBitCast(f, to: UnsafeRawPointer.self)
    }

    /// The loaded image holding `address`: its path, load address, UUID and __TEXT size.
    private static func image(containing address: UnsafeRawPointer) -> (path: String, base: UInt64, uuid: String, size: UInt64)? {
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let base = info.dli_fbase, let name = info.dli_fname else { return nil }
        let header = base.assumingMemoryBound(to: mach_header_64.self)
        var cursor = UnsafeRawPointer(base).advanced(by: MemoryLayout<mach_header_64>.size)
        var uuid: String?
        var size: UInt64 = 0
        for _ in 0..<header.pointee.ncmds {
            let lc = cursor.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmd == LC_UUID {
                let u = cursor.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                uuid = UUID(uuid: u).uuidString
            } else if lc.cmd == LC_SEGMENT_64 {
                let seg = cursor.assumingMemoryBound(to: segment_command_64.self).pointee
                if withUnsafeBytes(of: seg.segname, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) == "__TEXT" {
                    size = seg.vmsize
                }
            }
            cursor = cursor.advanced(by: Int(lc.cmdsize))
        }
        guard let uuid else { return nil }
        return (String(cString: name), UInt64(UInt(bitPattern: base)), uuid, size)
    }

    /// An .ips like macOS writes for a crash of this process: the marker function on top, then -[NSApplication run] in
    /// AppKit, then an injected library's frame; with a thread name, a queue name, a crash message and the environment
    /// that must all stay behind. Returns the file and the executable's UUID.
    static func syntheticIPS() throws -> (Data, String) {
        let marker = markerAddress
        let appKit = unsafeBitCast(class_getMethodImplementation(NSApplication.self, #selector(NSApplication.run)), to: UnsafeRawPointer.self)
        guard let exe = image(containing: marker), let kit = image(containing: appKit) else {
            throw NSError(domain: "crashreports", code: 1, userInfo: [NSLocalizedDescriptionKey: "can't find the marker or AppKit"])
        }
        // Inside the function, as a real crash site is (symbolication looks up the address before a frame's).
        let markerOffset = UInt64(UInt(bitPattern: marker)) - exe.base + 4
        let kitOffset = UInt64(UInt(bitPattern: appKit)) - kit.base
        let home = NSHomeDirectory()
        // As macOS writes it: the real path, inside the bundle.
        let exePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/Contents/MacOS/Airc"
        let header: [String: Any] = ["app_name": "Airc", "bug_type": "309", "os_version": "macOS 26.6.2 (25G83)", "name": "Airc",
                                     "timestamp": "2026-11-06 12:00:00.00 +0100", "incident_id": UUID().uuidString]
        let body: [String: Any] = [
            "pid": 99_999, "procName": "Airc", "procPath": exePath,
            "bundleInfo": ["CFBundleShortVersionString": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
                           "CFBundleVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""],
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "rawCodes": [1, 0x1234_5678],
                          "subtype": "KERN_INVALID_ADDRESS at 0x12345678 https://secret.example"],
            "termination": ["namespace": "SIGNAL", "code": 11, "indicator": "Segmentation fault: 11"],
            "asi": ["libsystem_c.dylib": ["https://secret.example/page?token=hunter2"]],
            "environment": ["HOME": home, "USER": NSUserName()],
            "faultingThread": 0,
            "threads": [["id": 1, "triggered": true, "name": "https://secret.example/page?token=hunter2", "queue": "queue-name",
                         "frames": [
                            ["imageOffset": markerOffset, "symbol": "airc_crash_check_marker", "imageIndex": 0],
                            ["imageOffset": kitOffset, "symbol": "-[NSApplication run]", "imageIndex": 1],
                            ["imageOffset": 0x10, "symbol": "spy_hook", "imageIndex": 2],
                         ]]],
            "usedImages": [
                ["source": "P", "arch": "arm64", "base": exe.base, "size": exe.size, "uuid": exe.uuid, "path": exePath, "name": "Airc"],
                ["source": "S", "arch": "arm64e", "base": kit.base, "size": kit.size, "uuid": kit.uuid, "path": kit.path, "name": "AppKit"],
                ["source": "P", "arch": "arm64", "base": 0x3_0000_0000, "size": 0x1000, "uuid": UUID().uuidString,
                 "path": home + "/Library/Injected/libspy.dylib", "name": "libspy.dylib"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: header) + Data("\n".utf8)
            + JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])
        return (data, exe.uuid)
    }

    /// A MetricKit payload holding one 3 s hang on the marker function.
    static func syntheticMetricKitHang() -> Data {
        let exe = image(containing: markerAddress)
        let address = UInt64(UInt(bitPattern: markerAddress))
        let payload: [String: Any] = ["hangDiagnostics": [[
            "diagnosticMetaData": ["appVersion": "0.1.0", "osVersion": "macOS 26.6.2 (25G83)", "hangDuration": "3 sec"],
            "callStackTree": ["callStackPerThread": true, "callStacks": [["threadAttributed": true, "callStackRootFrames": [[
                "binaryUUID": exe?.uuid ?? "", "binaryName": "Airc", "address": address,
                "offsetIntoBinaryTextSegment": address - (exe?.base ?? 0), "sampleCount": 1,
            ]]]]],
        ]]]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}
/// What "See what Airc sends" would show, kept up to date for the check.
final class CrashCheckRecent {
    static let shared = CrashCheckRecent()
    private(set) var records: [TelemetryRecord] = []
    private var token: Int?

    func start() {
        guard token == nil else { return }
        token = Telemetry.shared.observeRecent { [weak self] r in self?.records = r }
    }
}
#endif

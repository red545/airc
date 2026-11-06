// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// Crash reports (docs/user/telemetry.md, "Crash reports"): an `.ips` file or a MetricKit payload becomes one
/// `$exception` whose every key and value is allowlisted, with no path, user name, thread name, crash message or
/// page data in it. The fixtures are synthetic, laced with the things that must never leave the Mac.
final class CrashReportTests: XCTestCase {
    typealias Rule = TelemetryEventTests.Rule

    static let bundle = "/Users/jane.doe/Applications/Airc.app"
    /// Strings planted in the fixtures. None may reach an event.
    static let secrets = ["jane", "/Users", "bank.example", "https", "hunter2", "Secret page", "account?id", "spy", "Evil",
                          "deadbeef", "HOME", "x29", "sleepWake", "crashReporterKey", "queue-name"]

    static let hex = #"^0x[0-9a-f]{1,16}$"#
    static let paddedHex = #"^0x[0-9a-f]{16}$"#
    static let uuid = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#

    /// The `$exception` event's own top-level properties.
    static let rules: (required: [String: Rule], optional: [String: Rule]) = (
        ["$exception_list": .format(".*"), "$debug_images": .format(".*"),   // checked structurally below
         "$exception_level": .oneOf(["fatal", "error", "warning"]),
         "$exception_source": .oneOf(["macos.diagnostic_report", "macos.metrickit", "airc.signal_handler"]),
         "crash_kind": TelemetryEventTests.values(CrashReport.Kind.self),
         "crash_process": TelemetryEventTests.values(CrashReport.Process.self),
         "crash_source": .oneOf(["ips", "metrickit", "signal"])],
        ["exception_type": .format(CrashReport.exceptionTypeFormat), "signal": .format(CrashReport.signalFormat),
         "signal_code": .format(#"^[0-9]{1,10}$"#),
         "mach_code": .format(hex), "termination_namespace": .format(CrashReport.namespaceFormat),
         "termination_code": .format(hex), "crash_app_version": .format(CrashReport.versionFormat),
         "crash_build": .format(CrashReport.buildFormat), "crash_os_version": .format(#"^[0-9]{1,3}\.[0-9]{1,3}$"#),
         "hang_duration_s": .oneOf(Set(CrashReport.hangDuration.labels)), "smoke": .bool]
    )

    // MARK: Fixtures

    static func ips(procName: String = "Airc", procPath: String? = nil, bugType: String = "309", pid: Int = 4242,
                    exceptionBacktrace: Bool = false) -> Data {
        let header: [String: Any] = [
            "app_name": procName, "timestamp": "2026-11-06 12:00:00.00 +0100", "app_version": "0.1.0",
            "slice_uuid": "11111111-2222-3333-4444-555555555555", "build_version": "202611061200", "platform": 1,
            "bundleID": "org.airc.Airc", "share_with_app_devs": 0, "is_first_party": 0, "bug_type": bugType,
            "os_version": "macOS 26.6.2 (25G83)", "roots_installed": 0, "name": procName,
            "incident_id": "9F9F9F9F-0000-0000-0000-000000000000",
        ]
        let frames: [[String: Any]] = [
            ["imageOffset": 0x9a3c, "symbol": "__pthread_kill", "symbolLocation": 8, "imageIndex": 2],
            ["imageOffset": 0x1234, "symbol": "spy_hook_for_jane", "imageIndex": 3],
            ["imageOffset": 0x5c_0000, "symbol": "content::RenderFrameHostImpl::DidCommitNavigation()", "imageIndex": 1],
            ["imageOffset": 0x5c_0100, "symbol": "load /Users/jane.doe/Secret page.html", "imageIndex": 1],
            ["imageOffset": 0x44, "imageIndex": 4],
            ["imageOffset": 0x2_3456, "symbol": "Airc.AppDelegate.applicationDidFinishLaunching(_:)", "imageIndex": 0],
            ["imageOffset": 0x1_0000, "symbol": "main", "imageIndex": 0],
        ]
        let images: [[String: Any]] = [
            ["source": "P", "arch": "arm64", "base": 0x1_0000_0000, "size": 0x40_0000,
             "uuid": "c0ffee00-1234-5678-9abc-def012345678", "path": bundle + "/Contents/MacOS/Airc", "name": "Airc",
             "CFBundleIdentifier": "org.airc.Airc", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "202611061200"],
            ["source": "P", "arch": "arm64", "base": 0x1_1000_0000, "size": 0xf00_0000,
             "uuid": "4c4c4480-5555-3144-a1fe-efd110699e75",
             "path": bundle + "/Contents/Frameworks/Airc Framework.framework/Versions/A/Airc Framework", "name": "Airc Framework"],
            ["source": "P", "arch": "arm64e", "base": 0x1_8f00_0000, "size": 0x3_c000,
             "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "path": "/usr/lib/system/libsystem_kernel.dylib",
             "name": "libsystem_kernel.dylib"],
            ["source": "P", "arch": "arm64", "base": 0x1_0500_0000, "size": 0x1_0000,
             "uuid": "12345678-1234-1234-1234-123456789abc",
             "path": "/Users/jane.doe/Library/Application Support/Evil/libspy.dylib", "name": "libspy.dylib"],
            ["source": "A", "base": 0, "size": 0, "uuid": "00000000-0000-0000-0000-000000000000"],
        ]
        var body: [String: Any] = [
            "pid": pid, "procName": procName, "procPath": procPath ?? bundle + "/Contents/MacOS/Airc",
            "parentProc": "launchd", "coalitionName": "org.airc.Airc", "crashReporterKey": "crashReporterKey-ABC",
            "sleepWakeUUID": "sleepWake-XYZ", "userID": 501, "captureTime": "2026-11-06 12:00:00.0000 +0100",
            "bundleInfo": ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "202611061200",
                           "CFBundleIdentifier": "org.airc.Airc"],
            "exception": ["codes": "0x0000000000000001, 0x00000000deadbeef", "rawCodes": [1, 3_735_928_559],
                          "type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x00000000deadbeef"],
            "termination": ["flags": 0, "code": 11, "namespace": "SIGNAL", "indicator": "Segmentation fault: 11",
                            "byProc": "exc handler", "byPid": pid],
            "asi": ["libsystem_c.dylib": ["Secret page https://bank.example/account?id=1 password hunter2"]],
            "environment": ["HOME": "/Users/jane.doe"],
            "vmSummary": "https://bank.example/account?id=1",
            "faultingThread": 1,
            "threads": [
                ["id": 1, "name": "https://bank.example/account?id=1", "queue": "queue-name", "frames": []],
                ["id": 2, "triggered": true, "name": "Secret page", "queue": "queue-name",
                 "threadState": ["x": [["value": 1]], "fp": ["value": 0x29], "flavor": "ARM_THREAD_STATE64"],
                 "frames": frames],
            ],
            "usedImages": images,
        ]
        if exceptionBacktrace {
            body["lastExceptionBacktrace"] = [
                ["imageOffset": 0x5c_0200, "symbol": "-[NSException raise]", "imageIndex": 1],
                ["imageOffset": 0x1_0000, "symbol": "main", "imageIndex": 0],
            ]
        }
        let h = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let b = try! JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        return h + Data("\n".utf8) + b
    }

    /// The shape of `MXDiagnosticPayload.jsonRepresentation()`: a crash, a hang and a CPU exception.
    static let metricKit = Data(#"""
    {
      "timeStampBegin": "2026-11-05 00:00:00", "timeStampEnd": "2026-11-06 00:00:00",
      "crashDiagnostics": [{
        "version": "1.0.0",
        "diagnosticMetaData": {
          "appVersion": "0.1.0", "appBuildVersion": "202611051800", "osVersion": "macOS 26.6.2 (25G83)",
          "platformArchitecture": "arm64e", "deviceType": "Mac17,2", "regionFormat": "AT", "bundleIdentifier": "org.airc.Airc",
          "exceptionType": 1, "exceptionCode": 2, "signal": 11, "pid": 777,
          "terminationReason": "Namespace SIGNAL, Code 0xb Segmentation fault: 11 https://bank.example",
          "virtualMemoryRegionInfo": "0 is not in any region. /Users/jane.doe/Secret page",
          "objectiveCexceptionReason": {"composedMessage": "Secret page hunter2", "className": "SpyClass"}
        },
        "callStackTree": {"callStackPerThread": true, "callStacks": [
          {"threadAttributed": false, "callStackRootFrames": [{"binaryUUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "offsetIntoBinaryTextSegment": 100, "sampleCount": 1, "binaryName": "libsystem_kernel.dylib", "address": 6694109284}]},
          {"threadAttributed": true, "callStackRootFrames": [{
            "binaryUUID": "4C4C4480-5555-3144-A1FE-EFD110699E75", "offsetIntoBinaryTextSegment": 6029312, "sampleCount": 1,
            "binaryName": "Airc Framework", "address": 4566548480,
            "subFrames": [{"binaryUUID": "C0FFEE00-1234-5678-9ABC-DEF012345678", "offsetIntoBinaryTextSegment": 65536,
              "sampleCount": 1, "binaryName": "Airc", "address": 4295032832,
              "subFrames": [{"binaryUUID": "12345678-1234-1234-1234-123456789ABC", "offsetIntoBinaryTextSegment": 4,
                "sampleCount": 1, "binaryName": "/Users/jane.doe/libspy.dylib", "address": 4378853380}]}]
          }]}
        ]}
      }],
      "hangDiagnostics": [{
        "version": "1.0.0",
        "diagnosticMetaData": {"appVersion": "0.1.0", "appBuildVersion": "202611051800", "osVersion": "macOS 26.6.2 (25G83)",
                               "hangDuration": "3.5 sec", "pid": 778},
        "callStackTree": {"callStackPerThread": true, "callStacks": [{"threadAttributed": true, "callStackRootFrames": [{
          "binaryUUID": "C0FFEE00-1234-5678-9ABC-DEF012345678", "offsetIntoBinaryTextSegment": 70000, "sampleCount": 30,
          "binaryName": "Airc", "address": 4295037296}]}]}
      }],
      "cpuExceptionDiagnostics": [{
        "version": "1.0.0",
        "diagnosticMetaData": {"appVersion": "0.1.0", "appBuildVersion": "202611051800", "osVersion": "macOS 26.6.2 (25G83)",
                               "totalCPUTime": "90 sec", "totalSampledTime": "180 sec"},
        "callStackTree": {"callStackPerThread": false, "callStacks": [{"threadAttributed": false, "callStackRootFrames": [
          {"binaryUUID": "C0FFEE00-1234-5678-9ABC-DEF012345678", "offsetIntoBinaryTextSegment": 1000, "sampleCount": 2,
           "binaryName": "Airc", "address": 4294968296},
          {"binaryUUID": "4C4C4480-5555-3144-A1FE-EFD110699E75", "offsetIntoBinaryTextSegment": 2000, "sampleCount": 40,
           "binaryName": "Airc Framework", "address": 4563404752,
           "subFrames": [{"binaryUUID": "C0FFEE00-1234-5678-9ABC-DEF012345678", "offsetIntoBinaryTextSegment": 3000,
             "sampleCount": 40, "binaryName": "Airc", "address": 4294970296}]}
        ]}]}
      }]
    }
    """#.utf8)

    /// When the .ips fixture's crash was captured ("2026-11-06 12:00:00.0000 +0100").
    static let ipsCrashTime = Date(timeIntervalSince1970: 1_793_962_800)

    /// What AircCrashLog writes at the crash: the browser's frames, Airc's and the system's binaries, and planted
    /// things that must stay behind (a binary named by its path, one of nobody's, junk lines, a URL where a value goes).
    static func record(pid: Int = 4242, build: String = "202611061200", time: Date = ipsCrashTime.addingTimeInterval(-2),
                       fault: String = "0xdeadbeef", end: Bool = true) -> Data {
        var lines = [
            "airc-crash-record 1", "pid \(pid)", "version 0.1.0", "build \(build)", "os 26.6",
            "time \(Int(time.timeIntervalSince1970))", "signal 11", "code 1", "fault \(fault)",
            "frame 0x18f009a3c",   // libsystem_kernel
            "frame 0x105001234",   // the injected library: nobody's
            "frame 0x1105c0000",   // Airc Framework
            "frame 0x106000044",   // a binary named by a path
            "frame 0x100023456",   // Airc
            "frame 0x100010000",
            "frame nonsense https://bank.example/account?id=1",
            "image 0x100000000 0x400000 a C0FFEE00123456789ABCDEF012345678 Airc",
            "image 0x110000000 0xf000000 a 4C4C448055553144A1FEEFD110699E75 Airc Framework",
            "image 0x18f000000 0x3c000 s AAAAAAAABBBBCCCCDDDDEEEEEEEEEEEE libsystem_kernel.dylib",
            "image 0x105000000 0x10000 o 12345678123412341234123456789ABC libspy.dylib",
            "image 0x106000000 0x10000 a 1234567812341234123412345678ABCD /Users/jane.doe/Evil/libspy.dylib",
            "image 0x107000000 0x10000 s 00000000000000000000000000000000 Secret page",
            "url https://bank.example/account?id=1 hunter2",
        ]
        if end { lines.append("end") }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: Parsing

    func testIPSCrashKeepsFramesImagesAndCodesOnly() throws {
        let r = try XCTUnwrap(CrashReport.parseIPS(Self.ips(), bundlePath: Self.bundle))
        XCTAssertEqual(r.kind, .crash)
        XCTAssertEqual(r.source, .diagnosticReport)
        XCTAssertEqual(r.process, .browser)
        XCTAssertEqual(r.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(r.signal, "SIGSEGV")
        XCTAssertEqual(r.machCode, 1, "the first code only: the second is the fault address")
        XCTAssertEqual(r.terminationNamespace, "SIGNAL")
        XCTAssertEqual(r.terminationCode, 11)
        XCTAssertEqual(r.appVersion, "0.1.0")
        XCTAssertEqual(r.appBuild, "202611061200")
        XCTAssertEqual(r.osVersion, "26.6")
        XCTAssertEqual(r.pid, 4242)
        // Airc, Airc Framework and the system's binary; the injected one and the absent one are nobody's.
        XCTAssertEqual(r.images.map(\.name), ["libsystem_kernel.dylib", "Airc Framework", "Airc"])
        XCTAssertEqual(r.images.map(\.origin), [.system, .app, .app])
        XCTAssertEqual(r.images.map(\.uuid), ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "4C4C4480-5555-3144-A1FE-EFD110699E75",
                                              "C0FFEE00-1234-5678-9ABC-DEF012345678"])
        XCTAssertEqual(r.frames.count, 7)
        XCTAssertEqual(r.frames[0], .init(image: 0, address: 0x1_8f00_9a3c, function: "__pthread_kill"))
        XCTAssertEqual(r.frames[1], .init(image: nil, address: 0x1_0500_1234, function: nil), "another binary: no name, no symbol")
        XCTAssertEqual(r.frames[2].function, "content::RenderFrameHostImpl::DidCommitNavigation()")
        XCTAssertEqual(r.frames[2].address, 0x1_1000_0000 + 0x5c_0000)
        XCTAssertNil(r.frames[3].function, "a symbol holding a path is dropped")
        XCTAssertEqual(r.frames[3].image, 1, "but the frame stays")
        XCTAssertNil(r.frames[4].image)
        XCTAssertEqual(r.frames[6], .init(image: 2, address: 0x1_0001_0000, function: "main"))
    }

    func testIPSOfAnotherAppOrKindIsIgnored() {
        XCTAssertNil(CrashReport.parseIPS(Self.ips(procPath: "/Applications/Arc.app/Contents/MacOS/Arc"), bundlePath: Self.bundle))
        XCTAssertNil(CrashReport.parseIPS(Self.ips(procPath: Self.bundle + "-old/Contents/MacOS/Airc"), bundlePath: Self.bundle),
                     "another copy whose path merely starts the same")
        XCTAssertNil(CrashReport.parseIPS(Self.ips(bugType: "288"), bundlePath: Self.bundle), "a stackshot, not a crash")
        XCTAssertNil(CrashReport.parseIPS(Data("not json\n{}".utf8), bundlePath: Self.bundle))
        XCTAssertNil(CrashReport.parseIPS(Data(), bundlePath: Self.bundle))
    }

    /// macOS writes paths under a home folder redacted: "/Users/USER/*/Airc.app/…". That is still this app's crash
    /// (with its bundle identifier), and its binaries are still Airc's own.
    func testIPSWithRedactedPathsIsStillOurs() throws {
        let redacted = "/Users/USER/*/Airc.app"
        let text = String(decoding: Self.ips(procPath: redacted + "/Contents/MacOS/Airc"), as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")   // JSONSerialization escapes slashes
            .replacingOccurrences(of: Self.bundle + "/Contents", with: redacted + "/Contents")
        XCTAssertFalse(text.contains("jane.doe/Applications"))
        let r = try XCTUnwrap(CrashReport.parseIPS(Data(text.utf8), bundlePath: Self.bundle, bundleID: "org.airc.Airc"))
        XCTAssertEqual(r.images.map(\.name), ["libsystem_kernel.dylib", "Airc Framework", "Airc"])
        XCTAssertEqual(r.images.map(\.origin), [.system, .app, .app], "Airc's binaries by their redacted paths")
        XCTAssertNil(CrashReport.parseIPS(Data(text.utf8), bundlePath: Self.bundle, bundleID: "org.airc.crashvis"),
                     "a redacted path of another app's Airc.app")
        let other = text.replacingOccurrences(of: redacted, with: "/Users/USER/*/Arc.app")
        XCTAssertNil(CrashReport.parseIPS(Data(other.utf8), bundlePath: Self.bundle, bundleID: "org.airc.Airc"))
        XCTAssertNil(CrashReport.parseIPS(Data(text.utf8), bundlePath: "/Applications/Airc.app", bundleID: "org.airc.Airc"),
                     "macOS doesn't redact /Applications: a redacted path there is another copy")
    }

    func testHelperCrashAndThrownExceptionBacktrace() throws {
        let path = Self.bundle + "/Contents/Frameworks/Airc Framework.framework/Helpers/Airc Helper (Renderer).app/Contents/MacOS/Airc Helper (Renderer)"
        let r = try XCTUnwrap(CrashReport.parseIPS(Self.ips(procName: "Airc Helper (Renderer)", procPath: path, exceptionBacktrace: true),
                                                   bundlePath: Self.bundle))
        XCTAssertEqual(r.process, .renderer)
        XCTAssertEqual(r.frames.map(\.function), ["-[NSException raise]", "main"], "the throw site, not the abort")
        XCTAssertEqual(CrashReport.process(named: "Airc Helper (Aperitif GPU)"), .gpu)
        XCTAssertEqual(CrashReport.process(named: "Airc Helper (Plugin)"), .plugin)
        XCTAssertEqual(CrashReport.process(named: "Airc Helper"), .helper)
        XCTAssertEqual(CrashReport.process(named: "Airc Helper (Alerts)"), .alerts)
        XCTAssertEqual(CrashReport.process(named: "jane's tool"), .other)
    }

    func testSignalRecordKeepsFramesImagesAndSignalOnly() throws {
        let r = try XCTUnwrap(CrashReport.parseSignalRecord(Self.record()))
        XCTAssertEqual(r.kind, .crash)
        XCTAssertEqual(r.source, .signal)
        XCTAssertEqual(r.process, .browser)
        XCTAssertNil(r.exceptionType, "a signal handler never sees the Mach exception")
        XCTAssertEqual(r.signal, "SIGSEGV")
        XCTAssertEqual(r.signalCode, 1)
        XCTAssertEqual(r.terminationNamespace, "SIGNAL")
        XCTAssertEqual(r.terminationCode, 11)
        XCTAssertEqual(r.appVersion, "0.1.0")
        XCTAssertEqual(r.appBuild, "202611061200")
        XCTAssertEqual(r.osVersion, "26.6")
        XCTAssertEqual(r.pid, 4242)
        XCTAssertEqual(r.crashTime, Self.ipsCrashTime.addingTimeInterval(-2))
        XCTAssertEqual(r.faultAddress, 0xdead_beef)
        // In the order the frames use them; nobody's binary, a path-named one and a zero UUID are left out.
        XCTAssertEqual(r.images.map(\.name), ["libsystem_kernel.dylib", "Airc Framework", "Airc"])
        XCTAssertEqual(r.images.map(\.origin), [.system, .app, .app])
        XCTAssertEqual(r.images[2].uuid, "C0FFEE00-1234-5678-9ABC-DEF012345678")
        XCTAssertEqual(r.images[2].size, 0x40_0000)
        XCTAssertEqual(r.frames.map(\.image), [0, nil, 1, nil, 2, 2], "an unreadable frame line is skipped")
        XCTAssertEqual(r.frames.map(\.address), [0x1_8f00_9a3c, 0x1_0500_1234, 0x1_105c_0000, 0x1_0600_0044, 0x1_0002_3456, 0x1_0001_0000])
        XCTAssertTrue(r.frames.allSatisfy { $0.function == nil }, "symbols come from the dSYMs, in PostHog")

        // The same event shape as an .ips: PostHog's Apple frames and debug images, marked as the signal handler's.
        let json = try Self.json(r.properties())
        let list = try XCTUnwrap(json["$exception_list"] as? [[String: Any]])
        XCTAssertEqual(list[0]["type"] as? String, "SIGSEGV")
        XCTAssertEqual(list[0]["value"] as? String, "SIGSEGV in the browser process")
        XCTAssertEqual((list[0]["mechanism"] as? [String: Any])?["type"] as? String, "signal")
        let frames = try XCTUnwrap((list[0]["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.last?["instruction_addr"] as? String, "0x000000018f009a3c", "the crash site last")
        XCTAssertEqual(frames.last?["image_addr"] as? String, "0x000000018f000000")
        XCTAssertEqual(frames.last?["module"] as? String, "libsystem_kernel.dylib")
        XCTAssertEqual(frames.first?["module"] as? String, "Airc")
        XCTAssertEqual(frames.first?["in_app"] as? Bool, true)
        XCTAssertEqual(frames[frames.count - 2]["module"] as? String, "other")
        XCTAssertNil(frames[frames.count - 2]["image_addr"])
        let images = try XCTUnwrap(json["$debug_images"] as? [[String: Any]])
        XCTAssertEqual(images.map { $0["debug_id"] as? String }, ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                                                                  "4C4C4480-5555-3144-A1FE-EFD110699E75",
                                                                  "C0FFEE00-1234-5678-9ABC-DEF012345678"])
        XCTAssertEqual(json["$exception_source"] as? String, "airc.signal_handler")
        XCTAssertEqual(json["crash_source"] as? String, "signal")
        XCTAssertEqual(json["signal_code"] as? String, "1")
        XCTAssertEqual(json["termination_code"] as? String, "0xb")
        XCTAssertNil(json["mach_code"])
        XCTAssertNil(json["exception_type"])

        // Cut short while writing (no `end`) still counts; anything else isn't a record.
        XCTAssertEqual(CrashReport.parseSignalRecord(Self.record(end: false))?.frames.count, 6)
        XCTAssertNil(CrashReport.parseSignalRecord(Data("airc-crash-record 2\nsignal 11\ntime 5\n".utf8)))
        XCTAssertNil(CrashReport.parseSignalRecord(Data("airc-crash-record 1\npid 1\ntime 5\n".utf8)), "no signal")
        XCTAssertNil(CrashReport.parseSignalRecord(Data("airc-crash-record 1\nsignal 11\n".utf8)), "no time")
        XCTAssertNil(CrashReport.parseSignalRecord(Data()))
        XCTAssertNil(CrashReport.parseSignalRecord(Self.ips()))
        let junk = CrashReport.parseSignalRecord(Data("airc-crash-record 1\ntime 5\nsignal 11\nbuild dev /Users/jane\nversion x\nos 26\n".utf8))
        XCTAssertNil(junk?.appBuild)
        XCTAssertNil(junk?.appVersion)
        XCTAssertNil(junk?.osVersion)
    }

    func testIPSKnowsWhenAndWhereItCrashed() throws {
        let r = try XCTUnwrap(CrashReport.parseIPS(Self.ips(), bundlePath: Self.bundle))
        XCTAssertEqual(r.crashTime, Self.ipsCrashTime)
        XCTAssertEqual(r.faultAddress, 0xdead_beef)
        XCTAssertNil(try Self.json(r.properties())["fault_address"], "local only")
        XCTAssertEqual(try Self.json(r.properties())["crash_source"] as? String, "ips")
        XCTAssertEqual(CrashReport.ipsTime("2026-11-06 12:00:00.00 +0100"), Self.ipsCrashTime)
        XCTAssertNil(CrashReport.ipsTime("yesterday"))
    }

    func testMetricKitPayload() throws {
        let reports = CrashReport.parseMetricKit(Self.metricKit)
        XCTAssertEqual(reports.map(\.kind), [.crash, .hang, .cpuException])
        let crash = reports[0]
        XCTAssertEqual(crash.source, .metricKit)
        XCTAssertEqual(crash.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(crash.signal, "SIGSEGV")
        XCTAssertEqual(crash.machCode, 2)
        XCTAssertEqual(crash.terminationNamespace, "SIGNAL")
        XCTAssertEqual(crash.terminationCode, 11)
        XCTAssertEqual(crash.appBuild, "202611051800")
        XCTAssertEqual(crash.osVersion, "26.6")
        XCTAssertEqual(crash.pid, 777)
        XCTAssertEqual(crash.images.map(\.name), ["Airc Framework", "Airc"], "a binary name holding a path is dropped")
        XCTAssertEqual(crash.images[0].base, 4_566_548_480 - 6_029_312)
        XCTAssertEqual(crash.frames.map(\.image), [0, 1, nil], "the attributed thread, crash site first")
        XCTAssertEqual(reports[1].hangSeconds, 3.5)
        XCTAssertEqual(reports[1].properties()["hang_duration_s"], .string("2-5"))
        XCTAssertEqual(reports[2].frames.map(\.address), [4_563_404_752, 4_294_970_296], "the heaviest branch")
        XCTAssertEqual(CrashReport.seconds("250 ms"), 0.25)
        XCTAssertEqual(CrashReport.seconds("1.5 min"), 90)
    }

    // MARK: The event

    func testExceptionMatchesPostHogsAppleFormat() throws {
        let r = try XCTUnwrap(CrashReport.parseIPS(Self.ips(), bundlePath: Self.bundle))
        let json = try Self.json(r.properties())
        let list = try XCTUnwrap(json["$exception_list"] as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["type"] as? String, "EXC_BAD_ACCESS")
        XCTAssertEqual(list[0]["value"] as? String, "EXC_BAD_ACCESS / SIGSEGV in the browser process")
        let mechanism = try XCTUnwrap(list[0]["mechanism"] as? [String: Any])
        XCTAssertEqual(mechanism["type"] as? String, "signal")
        XCTAssertEqual(mechanism["handled"] as? Bool, false)
        let stack = try XCTUnwrap(list[0]["stacktrace"] as? [String: Any])
        XCTAssertEqual(stack["type"] as? String, "raw")
        let frames = try XCTUnwrap(stack["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 7)
        // Outermost first, the crash site last; absolute addresses and the image's load address, like posthog-ios.
        XCTAssertEqual(frames.first?["function"] as? String, "main")
        XCTAssertEqual(frames.first?["instruction_addr"] as? String, "0x0000000100010000")
        XCTAssertEqual(frames.first?["image_addr"] as? String, "0x0000000100000000")
        XCTAssertEqual(frames.first?["module"] as? String, "Airc")
        XCTAssertEqual(frames.first?["in_app"] as? Bool, true)
        XCTAssertEqual(frames.last?["function"] as? String, "__pthread_kill")
        XCTAssertEqual(frames.last?["in_app"] as? Bool, false)
        XCTAssertTrue(frames.allSatisfy { $0["platform"] as? String == "apple" })
        let images = try XCTUnwrap(json["$debug_images"] as? [[String: Any]])
        XCTAssertEqual(images.map { $0["code_file"] as? String }, ["libsystem_kernel.dylib", "Airc Framework", "Airc"])
        XCTAssertEqual(images[2]["debug_id"] as? String, "C0FFEE00-1234-5678-9ABC-DEF012345678")
        XCTAssertEqual(images[2]["image_addr"] as? String, "0x0000000100000000")
        XCTAssertEqual(images[2]["image_size"] as? Int, 0x40_0000)
        XCTAssertEqual(images[2]["type"] as? String, "macho")
        XCTAssertEqual(json["$exception_level"] as? String, "fatal")
        XCTAssertEqual(json["termination_code"] as? String, "0xb")
        XCTAssertNil(json["smoke"])
        XCTAssertEqual(try Self.json(r.properties(smoke: true))["smoke"] as? Bool, true)
    }

    /// Every report from every fixture, recorded and sent as PostHog receives it: only allowlisted keys and values,
    /// nothing planted in the fixtures, no path or user name anywhere.
    func testEveryCrashEventSerialisesToTheAllowlist() throws {
        let path = Self.bundle + "/Contents/Frameworks/Airc Framework.framework/Helpers/Airc Helper (GPU).app/Contents/MacOS/Airc Helper (GPU)"
        let reports = [CrashReport.parseIPS(Self.ips(), bundlePath: Self.bundle),
                       CrashReport.parseIPS(Self.ips(procName: "Airc Helper (GPU)", procPath: path, exceptionBacktrace: true),
                                            bundlePath: Self.bundle)].compactMap { $0 } + CrashReport.parseMetricKit(Self.metricKit)
            + [CrashReport.parseSignalRecord(Self.record()), CrashReport.parseSignalRecord(Self.record(end: false))].compactMap { $0 }
        XCTAssertEqual(reports.count, 7)
        let h = TelemetryHarness()
        h.startSending()
        reports.forEach { h.client.record($0) }
        h.client.record(reports[0], smoke: true)
        h.settle()
        h.scheduler.fireAll(h.client)
        let events = h.transport.events
        XCTAssertEqual(events.count, 8)
        for event in events {
            XCTAssertEqual(event["event"] as? String, "$exception")
            let props = try XCTUnwrap(event["properties"] as? [String: Any])
            for key in Array(TelemetryEventTests.superRules.keys) + Array(Self.rules.required.keys) {
                XCTAssertNotNil(props[key], "$exception lacks \(key)")
            }
            for (key, value) in props {
                let rule = TelemetryEventTests.superRules[key] ?? Self.rules.required[key] ?? Self.rules.optional[key]
                XCTAssertNotNil(rule, "$exception carries a key outside the allowlist: \(key)")
                if key != "$exception_list", key != "$debug_images" {
                    XCTAssertTrue(rule?.allows(value) ?? false, "$exception.\(key) = \(value) isn't allowed")
                }
            }
            try checkExceptionList(props["$exception_list"])
            try checkDebugImages(props["$debug_images"])
            let text = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
            for s in Self.secrets { XCTAssertFalse(text.contains(s), "\(s) reached the event") }
            XCTAssertFalse(text.contains(NSUserName()), "the user name reached the event")
        }
    }

    private func checkExceptionList(_ v: Any?) throws {
        let list = try XCTUnwrap(v as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        let e = list[0]
        XCTAssertEqual(Set(e.keys), ["type", "value", "mechanism", "stacktrace"])
        let type = try XCTUnwrap(e["type"] as? String)
        XCTAssertTrue(["Crash", "Hang", "CPU exception", "Disk write exception"].contains(type)
                      || Rule.format(CrashReport.exceptionTypeFormat).allows(type) || Rule.format(CrashReport.signalFormat).allows(type))
        let value = try XCTUnwrap(e["value"] as? String)
        XCTAssertNotNil(value.range(of: #"^(EXC_[A-Z_]+ / SIG[A-Z0-9]+|EXC_[A-Z_]+|SIG[A-Z0-9]+|Hang( of [0-9<>+-]+ s)?|Too much CPU|Too many disk writes)? ?in the [a-z]+ process$"#,
                                    options: .regularExpression), value)
        let mechanism = try XCTUnwrap(e["mechanism"] as? [String: Any])
        XCTAssertEqual(Set(mechanism.keys), ["type", "handled", "synthetic"])
        XCTAssertTrue(Rule.oneOf(["signal", "mach_exception", "metrickit"]).allows(mechanism["type"] as Any))
        let stack = try XCTUnwrap(e["stacktrace"] as? [String: Any])
        XCTAssertEqual(Set(stack.keys), ["type", "frames"])
        for f in try XCTUnwrap(stack["frames"] as? [[String: Any]]) {
            XCTAssertTrue(Set(f.keys).isSubset(of: ["platform", "instruction_addr", "image_addr", "module", "in_app", "function"]), "\(f.keys)")
            XCTAssertEqual(f["platform"] as? String, "apple")
            XCTAssertTrue(Rule.format(Self.paddedHex).allows(f["instruction_addr"] as Any))
            if let a = f["image_addr"] { XCTAssertTrue(Rule.format(Self.paddedHex).allows(a)) }
            XCTAssertTrue(Rule.bool.allows(f["in_app"] as Any))
            let module = try XCTUnwrap(f["module"] as? String)
            XCTAssertTrue(module == "other" || Rule.format(CrashReport.imageNameFormat).allows(module), module)
            if let fn = f["function"] { XCTAssertTrue(Rule.format(CrashReport.functionFormat).allows(fn)) }
        }
    }

    private func checkDebugImages(_ v: Any?) throws {
        for image in try XCTUnwrap(v as? [[String: Any]]) {
            XCTAssertTrue(Set(image.keys).isSubset(of: ["type", "debug_id", "image_addr", "code_file", "image_size"]))
            XCTAssertEqual(image["type"] as? String, "macho")
            XCTAssertTrue(Rule.format(Self.uuid).allows(image["debug_id"] as Any))
            XCTAssertTrue(Rule.format(Self.paddedHex).allows(image["image_addr"] as Any))
            XCTAssertTrue(Rule.format(CrashReport.imageNameFormat).allows(image["code_file"] as Any))
            if let s = image["image_size"] { XCTAssertNotNil(s as? Int) }
        }
    }

    func testNamesAreBasenamesNeverPaths() {
        XCTAssertEqual(CrashReport.imageName(path: "/Users/jane.doe/Applications/Airc.app/Contents/MacOS/Airc", name: "x"), "Airc")
        XCTAssertEqual(CrashReport.imageName(path: nil, name: "Airc Framework"), "Airc Framework")
        XCTAssertNil(CrashReport.imageName(path: nil, name: "/Users/jane.doe/libspy.dylib"))
        XCTAssertNil(CrashReport.imageName(path: nil, name: "~jane"))
        XCTAssertNil(CrashReport.imageName(path: nil, name: ""))
        XCTAssertNil(CrashReport.origin(path: "/Users/jane.doe/Library/libspy.dylib", bundlePath: Self.bundle + "/"))
        XCTAssertEqual(CrashReport.origin(path: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
                                          bundlePath: Self.bundle + "/"), .system)
        XCTAssertNil(CrashReport.cleanFunction("open(/private/var/folders/x)"))
        XCTAssertNil(CrashReport.cleanFunction("visit https://bank.example"))
        XCTAssertNil(CrashReport.cleanFunction("mail jane@bank.example"))
        XCTAssertEqual(CrashReport.cleanFunction("static Double./ infix(_:_:)"), "static Double./ infix(_:_:)")
        XCTAssertNil(CrashReport.normalizedUUID("00000000-0000-0000-0000-000000000000"))
        XCTAssertEqual(CrashReport.normalizedUUID("c0ffee0012345678 9abcdef012345678".replacingOccurrences(of: " ", with: "")),
                       "C0FFEE00-1234-5678-9ABC-DEF012345678")
        XCTAssertNil(CrashReport(kind: .crash, source: .diagnosticReport, process: .browser, exceptionType: "EXC_jane /Users",
                                 frames: [], images: []).exceptionType)
    }

    // MARK: Finding reports

    func testScanReadsOnlyNewAircReportsOnce() throws {
        let dir = TelemetryHarness.temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func write(_ name: String, _ data: Data, at: Date) throws {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
        }
        try write("Airc-2026-11-01-100000.ips", Self.ips(pid: 1), at: start.addingTimeInterval(-60))   // before the mark
        try write("Airc-2026-11-06-120000.ips", Self.ips(pid: 2), at: start.addingTimeInterval(60))
        try write("Arc-2026-11-06-120000.ips", Self.ips(pid: 3), at: start.addingTimeInterval(60))     // another app's
        try write("Airc-2026-11-06-120001.diag", Self.ips(pid: 4), at: start.addingTimeInterval(60))
        try write("Airc Helper (Renderer)-2026-11-06-120002.ips", Self.ips(procPath: "/Applications/Airc.app/Contents/MacOS/Airc", pid: 5),
                  at: start.addingTimeInterval(61))   // a crash of another copy of Airc
        var log = CrashReportLog(since: start)
        let first = log.scan(dir, bundlePath: Self.bundle, now: start.addingTimeInterval(120))
        XCTAssertEqual(first.map(\.pid), [2])
        XCTAssertEqual(log.since, start.addingTimeInterval(61), "past every file read")
        XCTAssertEqual(log.scan(dir, bundlePath: Self.bundle, now: start.addingTimeInterval(130)).count, 0, "once only")

        // The log survives a relaunch; MetricKit's report of the same crash (same build and process) is a duplicate.
        let url = dir.appendingPathComponent("log/crash-reports.json")
        log.save(url)
        var again = CrashReportLog.load(url, now: start)
        XCTAssertEqual(again, log)
        var mk = CrashReport.parseMetricKit(Self.metricKit)[0]
        mk.pid = 2
        mk.appBuild = "202611061200"
        XCTAssertFalse(again.admit(mk, now: start.addingTimeInterval(140)))
        mk.appBuild = "202611051800"
        XCTAssertTrue(again.admit(mk, now: start.addingTimeInterval(140)), "another build's process 2: another crash")
        mk.pid = 9
        XCTAssertTrue(again.admit(mk, now: start.addingTimeInterval(140)))
        XCTAssertTrue(again.admit(CrashReport.parseMetricKit(Self.metricKit)[1], now: start), "hangs have no duplicate")

        // A crash loop: at most maxPerScan a launch, and the rest are skipped for good.
        for i in 0..<15 {
            try write("Airc-loop-\(i).ips", Self.ips(pid: 100 + i), at: start.addingTimeInterval(200 + Double(i)))
        }
        let loop = again.scan(dir, bundlePath: Self.bundle, now: start.addingTimeInterval(300))
        XCTAssertEqual(loop.count, CrashReportLog.maxPerScan)
        XCTAssertEqual(again.scan(dir, bundlePath: Self.bundle, now: start.addingTimeInterval(310)).count, 0)

        let missing = CrashReportLog.load(dir.appendingPathComponent("nope.json"), now: start)
        XCTAssertEqual(missing.since, start, "no log yet: start from now, never from old reports")
    }

    /// Signal records: only record.1 … record.3 (the running app's own `record` is never read), oldest first, each
    /// crash once, none from before the mark, and a fresh crash waits for macOS's report.
    func testScanRecordsReadsEachCrashOnceAfterTheMark() throws {
        let dir = TelemetryHarness.temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = Self.ipsCrashTime
        func write(_ name: String, _ data: Data) throws { try data.write(to: dir.appendingPathComponent(name)) }
        try write("record", Self.record(pid: 1, time: t.addingTimeInterval(30)))          // the running app's
        try write("record.1", Self.record(pid: 2, time: t.addingTimeInterval(20)))
        try write("record.2", Self.record(pid: 3, time: t.addingTimeInterval(10)))
        try write("record.3", Self.record(pid: 4, time: t.addingTimeInterval(-3600)))     // before the mark
        try write("record.4", Self.record(pid: 5, time: t.addingTimeInterval(15)))        // not one AircCrashLog keeps
        var log = CrashReportLog(since: t)
        let first = log.scanRecords(dir, now: t.addingTimeInterval(600))
        XCTAssertEqual(first.reports.map(\.pid), [3, 2], "oldest first")
        XCTAssertNil(first.retry)
        XCTAssertEqual(log.recordsSince, t.addingTimeInterval(20))
        XCTAssertTrue(log.scanRecords(dir, now: t.addingTimeInterval(700)).reports.isEmpty, "once only")

        // A new crash (rotated in as record.1) waits for its .ips until a minute after it happened.
        try write("record.1", Self.record(pid: 6, time: t.addingTimeInterval(650)))
        let young = log.scanRecords(dir, now: t.addingTimeInterval(680))
        XCTAssertTrue(young.reports.isEmpty)
        XCTAssertEqual(young.retry, t.addingTimeInterval(650 + CrashReportLog.recordSettle))
        XCTAssertEqual(log.scanRecords(dir, now: t.addingTimeInterval(720)).reports.map(\.pid), [6])

        // A log written before signal records has no record mark: it starts at its `since`, as loaded (the .ips scan
        // moves `since` on before the records are read).
        let url = dir.appendingPathComponent("crash-reports.json")
        try Data(#"{"reported":{},"since":"2026-11-06T11:00:05Z","version":1}"#.utf8).write(to: url)
        var old = CrashReportLog.load(url, now: t.addingTimeInterval(800))
        XCTAssertEqual(old.recordsSince, t.addingTimeInterval(5))
        old.since = t.addingTimeInterval(700)
        XCTAssertEqual(old.scanRecords(dir, now: t.addingTimeInterval(800)).reports.map(\.pid), [3, 6])
    }

    /// The same crash from the signal record and macOS's .ips is one event, whichever comes first, and the .ips wins
    /// when both are there; another crash at the same place is not the same crash.
    func testSignalRecordAndIPSOfOneCrashAreOneEvent() throws {
        let ips = try XCTUnwrap(CrashReport.parseIPS(Self.ips(), bundlePath: Self.bundle))
        let signal = try XCTUnwrap(CrashReport.parseSignalRecord(Self.record()))
        let now = Self.ipsCrashTime.addingTimeInterval(600)
        var log = CrashReportLog(since: .distantPast)
        XCTAssertTrue(log.admit(ips, now: now))
        XCTAssertFalse(log.admit(signal, now: now), "the .ips came first")
        log = CrashReportLog(since: .distantPast)
        XCTAssertTrue(log.admit(signal, now: now))
        XCTAssertFalse(log.admit(ips, now: now), "the .ips came after the signal record was sent")

        func variant(pid: Int = 4242, build: String = "202611061200", time: Date = Self.ipsCrashTime.addingTimeInterval(-2),
                     fault: String = "0xdeadbeef") -> CrashReport {
            CrashReport.parseSignalRecord(Self.record(pid: pid, build: build, time: time, fault: fault))!
        }
        log = CrashReportLog(since: .distantPast)
        XCTAssertTrue(log.admit(ips, now: now))
        XCTAssertTrue(log.admit(variant(pid: 4243), now: now), "another process crashing at the same address")
        XCTAssertTrue(log.admit(variant(build: "202611061300"), now: now), "another build")
        XCTAssertTrue(log.admit(variant(time: Self.ipsCrashTime.addingTimeInterval(-3600)), now: now),
                      "the same process ID an hour earlier")
        XCTAssertFalse(log.admit(variant(fault: "0x0"), now: now), "the process decides, not the address")

        // Without a process ID, the build, the time and the fault address do.
        var noPID = signal
        noPID.pid = nil
        log = CrashReportLog(since: .distantPast)
        XCTAssertTrue(log.admit(ips, now: now))
        XCTAssertFalse(log.admit(noPID, now: now))
        noPID.faultAddress = 0x10
        XCTAssertTrue(log.admit(noPID, now: now))

        // In one launch's look: the .ips first, then the records, so the record of the same crash is skipped.
        let dir = TelemetryHarness.temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ipsURL = dir.appendingPathComponent("Airc-2026-11-06-120000.ips")
        try Self.ips().write(to: ipsURL)
        try FileManager.default.setAttributes([.modificationDate: Self.ipsCrashTime.addingTimeInterval(5)], ofItemAtPath: ipsURL.path)
        try Self.record().write(to: dir.appendingPathComponent("record.1"))
        try Self.record(pid: 5000, time: Self.ipsCrashTime.addingTimeInterval(120)).write(to: dir.appendingPathComponent("record.2"))
        log = CrashReportLog(since: Self.ipsCrashTime.addingTimeInterval(-60))
        let fromIPS = log.scan(dir, bundlePath: Self.bundle, now: now)
        XCTAssertEqual(log.since, Self.ipsCrashTime.addingTimeInterval(5), "the .ips moved its mark")
        XCTAssertEqual(log.recordsSince, Self.ipsCrashTime.addingTimeInterval(-60), "but not the records'")
        let fromRecords = log.scanRecords(dir, now: now).reports
        XCTAssertEqual(fromIPS.map(\.source), [.diagnosticReport])
        XCTAssertEqual(fromRecords.map(\.pid), [5000], "the same crash's record is skipped; the crash without an .ips is sent")
        XCTAssertEqual(log.recordsSince, Self.ipsCrashTime.addingTimeInterval(120))
        let url = dir.appendingPathComponent("crash-reports.json")
        log.save(url)
        var relaunched = CrashReportLog.load(url, now: now)
        XCTAssertEqual(relaunched, log, "identities survive a relaunch")
        XCTAssertTrue(relaunched.scanRecords(dir, now: now.addingTimeInterval(60)).reports.isEmpty)
    }

    /// A crash report goes through the same queue as every event: buffered, shown in "See what Airc sends", dropped
    /// when telemetry is off, and only recorded (never queued) in a scripted run.
    func testCrashGoesThroughTheTelemetryPipeline() throws {
        let r = try XCTUnwrap(CrashReport.parseIPS(Self.ips(), bundlePath: Self.bundle))
        let h = TelemetryHarness()
        h.startSending()
        h.client.record(r)
        h.settle()
        XCTAssertEqual(h.client.status.pending, 1, "buffered")
        XCTAssertEqual(h.scheduler.armed, [30])
        XCTAssertEqual(h.recent().map(\.event), ["$exception"], "shown in See what Airc sends")
        XCTAssertTrue(h.recent().first?.json.contains("\"$exception_list\"") ?? false)

        let scripted = TelemetryHarness()
        scripted.start(automated: true)
        scripted.client.record(r)
        scripted.settle()
        XCTAssertEqual(scripted.client.status.pending, 0, "a scripted run never queues it")
        XCTAssertEqual(scripted.recent().map(\.event), ["$exception"])
        scripted.scheduler.fireAll(scripted.client)
        XCTAssertTrue(scripted.transport.bodies.isEmpty)

        let off = TelemetryHarness()
        off.start(userEnabled: false)
        off.client.record(r)
        off.settle()
        XCTAssertEqual(off.client.status.pending, 0)
        XCTAssertTrue(off.recent().isEmpty)
    }

    func testQueueWithCrashEventsSurvivesARelaunch() throws {
        let dir = TelemetryHarness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try XCTUnwrap(CrashReport.parseIPS(Self.ips(), bundlePath: Self.bundle))
        let a = TelemetryHarness(directory: dir)
        a.transport.result = .failed   // offline: it stays queued on disk
        a.startSending()
        a.client.record(r)
        a.settle()
        a.client.flushForQuit(timeout: 0)
        let b = TelemetryHarness(directory: dir)
        b.startSending()
        XCTAssertEqual(b.client.status.pending, 1)
        b.scheduler.fireAll(b.client)
        let sent = try XCTUnwrap(b.transport.events.first?["properties"] as? [String: Any])
        XCTAssertEqual(try Self.json(r.properties())["$exception_list"] as? NSArray, sent["$exception_list"] as? NSArray)
    }

    static func json(_ p: [String: TelemetryValue]) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
    }
}

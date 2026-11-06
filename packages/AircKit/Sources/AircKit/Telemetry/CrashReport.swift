// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// A crash, hang or resource exception of Airc or one of its helper processes, sent as PostHog error tracking's
/// `$exception` (docs/user/telemetry.md, "Crash reports"). Built at the next launch from macOS's own crash report (an
/// `.ips` file in ~/Library/Logs/DiagnosticReports), from Airc's own signal-time record of a browser crash
/// (apps/browser/Sources/AircCrashLog: macOS often writes no `.ips` for a process as big as Chromium's), or from a
/// MetricKit diagnostic.
///
/// Only what symbolication needs survives parsing: the crashed thread's frames (binary and offset, and the function
/// name macOS resolved), binary names (basenames only: Airc's own binaries, Sparkle and the system's; any other binary
/// becomes "other", with no UUID or name), binary UUIDs and load addresses, the exception type, signal and termination
/// codes, and the crashed build's and macOS's versions. Never paths, thread or queue names, crash or exception
/// messages, registers, memory, the environment or anything a page holds. Every string is checked against a strict
/// format here (and again by the allowlist test).
public struct CrashReport: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case crash, hang, cpuException = "cpu_exception", diskWriteException = "disk_write_exception"
    }

    public enum Source: String, Sendable, CaseIterable {
        case diagnosticReport = "diagnostic_report", metricKit = "metrickit"
        /// Airc's signal handler (AircCrashLog/CrashLog.c), for the browser process.
        case signal

        /// `crash_source`, for triage: which of the three reported it.
        public var crashSource: String {
            switch self {
            case .diagnosticReport: "ips"
            case .metricKit: "metrickit"
            case .signal: "signal"
            }
        }
    }

    /// Which process it was, from the process name: the browser itself or one of Chromium's helpers.
    public enum Process: String, Sendable, CaseIterable {
        case browser, renderer, gpu, plugin, alerts, helper, other
    }

    public struct Image: Sendable, Equatable {
        public enum Origin: String, Sendable {
            /// Inside Airc's bundle: Airc, Airc Framework, Sparkle, the helpers.
            case app
            case system
        }

        public var name: String
        /// Uppercase and dashed, the way posthog-cli keys an uploaded dSYM.
        public var uuid: String
        public var base: UInt64
        public var size: UInt64?
        public var origin: Origin

        public init(name: String, uuid: String, base: UInt64, size: UInt64?, origin: Origin) {
            self.name = name
            self.uuid = uuid
            self.base = base
            self.size = size
            self.origin = origin
        }
    }

    public struct Frame: Sendable, Equatable {
        /// Index into `images`; nil for a binary that is neither Airc's nor the system's.
        public var image: Int?
        public var address: UInt64
        /// The function name macOS resolved, if any (never for "other" binaries).
        public var function: String?

        public init(image: Int?, address: UInt64, function: String?) {
            self.image = image
            self.address = address
            self.function = function
        }
    }

    public var kind: Kind
    public var source: Source
    public var process: Process
    public var exceptionType: String?
    public var signal: String?
    /// The signal's `si_code` (SEGV_MAPERR, SEGV_ACCERR …), from a signal record.
    public var signalCode: Int?
    /// The first Mach exception code (EXC_BAD_ACCESS: KERN_INVALID_ADDRESS …). The second, a fault address, is dropped.
    public var machCode: UInt64?
    public var terminationNamespace: String?
    public var terminationCode: Int64?
    /// The build that crashed, which may be older than the one reporting it (after an update).
    public var appVersion: String?
    public var appBuild: String?
    /// major.minor, like the super property.
    public var osVersion: String?
    public var hangSeconds: Double?
    /// The crash site first.
    public var frames: [Frame]
    public var images: [Image]
    /// Local only, never sent, like the two below: tell the same crash from different sources apart (CrashReportLog).
    public var pid: Int?
    /// When it crashed (the .ips capture time, the signal record's clock); MetricKit doesn't say.
    public var crashTime: Date?
    /// The faulting address (the .ips's second Mach code, the signal's `si_addr`).
    public var faultAddress: UInt64?

    public init(kind: Kind, source: Source, process: Process, exceptionType: String? = nil, signal: String? = nil,
                signalCode: Int? = nil, machCode: UInt64? = nil, terminationNamespace: String? = nil,
                terminationCode: Int64? = nil, appVersion: String? = nil, appBuild: String? = nil, osVersion: String? = nil,
                hangSeconds: Double? = nil, frames: [Frame], images: [Image], pid: Int? = nil, crashTime: Date? = nil,
                faultAddress: UInt64? = nil) {
        self.kind = kind
        self.source = source
        self.process = process
        self.exceptionType = exceptionType.flatMap { Self.matching($0, Self.exceptionTypeFormat) }
        self.signal = signal.flatMap { Self.matching($0, Self.signalFormat) }
        self.signalCode = signalCode.flatMap { (0...0x7fff_ffff).contains($0) ? $0 : nil }
        self.machCode = machCode
        self.terminationNamespace = terminationNamespace.flatMap { Self.matching($0, Self.namespaceFormat) }
        self.terminationCode = terminationCode
        self.appVersion = appVersion.flatMap { Self.matching($0, Self.versionFormat) }
        self.appBuild = appBuild.flatMap { Self.matching($0, Self.buildFormat) }
        self.osVersion = osVersion.flatMap(Self.majorMinor)
        self.hangSeconds = hangSeconds
        self.frames = Array(frames.prefix(Self.maxFrames))
        self.images = images
        self.pid = pid
        self.crashTime = crashTime
        self.faultAddress = faultAddress
    }

    /// The crashed thread's innermost frames are what matter; a runaway recursion is cut here.
    public static let maxFrames = 128
    /// Hang durations, in seconds.
    public static let hangDuration = TelemetryBucket.Scale(bounds: [1, 2, 5, 10, 30, 60], exact: 0)

    static let exceptionTypeFormat = #"^EXC_[A-Z_]{1,40}$"#
    static let signalFormat = #"^SIG[A-Z0-9]{2,10}$"#
    static let namespaceFormat = #"^[A-Z_]{1,40}$"#
    static let versionFormat = #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#
    static let buildFormat = #"^[0-9]{1,14}$"#
    /// A binary's file name: letters, digits, spaces and . _ ( ) + -, never a path.
    static let imageNameFormat = #"^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}$"#
    static let uuidFormat = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#
    /// Printable ASCII; checked further in `cleanFunction`.
    static let functionFormat = #"^[ -~]{1,256}$"#

    // MARK: The $exception event

    /// The event's properties (the super properties are added when it is recorded). `smoke`: the one manual smoke event.
    public func properties(smoke: Bool = false) -> [String: TelemetryValue] {
        var frameValues: [TelemetryValue] = []
        // PostHog wants the outermost frame first and the crash site last.
        for f in frames.reversed() {
            var v: [String: TelemetryValue] = ["platform": .string("apple"), "instruction_addr": .string(Self.hex(f.address))]
            if let i = f.image, images.indices.contains(i) {
                let image = images[i]
                v["image_addr"] = .string(Self.hex(image.base))
                v["module"] = .string(image.name)
                v["in_app"] = .bool(image.origin == .app)
            } else {
                v["module"] = .string("other")
                v["in_app"] = .bool(false)
            }
            if let fn = f.function { v["function"] = .string(fn) }
            frameValues.append(.object(v))
        }
        var mechanism: [String: TelemetryValue] = ["handled": .bool(false), "synthetic": .bool(false)]
        mechanism["type"] = .string(source == .metricKit ? "metrickit" : source == .signal || signal != nil ? "signal" : "mach_exception")
        let exception: [String: TelemetryValue] = [
            "type": .string(title),
            "value": .string(summary),
            "mechanism": .object(mechanism),
            "stacktrace": .object(["type": .string("raw"), "frames": .list(frameValues)]),
        ]
        let debugImages: [TelemetryValue] = images.map { image in
            var v: [String: TelemetryValue] = ["type": .string("macho"), "debug_id": .string(image.uuid),
                                               "image_addr": .string(Self.hex(image.base)), "code_file": .string(image.name)]
            if let size = image.size, let n = Int(exactly: size) { v["image_size"] = .int(n) }
            return .object(v)
        }
        var p: [String: TelemetryValue] = [
            "$exception_list": .list([.object(exception)]),
            "$exception_level": .string(kind == .crash ? "fatal" : kind == .hang ? "error" : "warning"),
            "$exception_source": .string(exceptionSource),
            "$debug_images": .list(debugImages),
            "crash_kind": .string(kind.rawValue),
            "crash_process": .string(process.rawValue),
            "crash_source": .string(source.crashSource),
        ]
        if let exceptionType { p["exception_type"] = .string(exceptionType) }
        if let signal { p["signal"] = .string(signal) }
        if let signalCode { p["signal_code"] = .string(String(signalCode)) }
        if let machCode { p["mach_code"] = .string(Self.hex(machCode, padded: false)) }
        if let terminationNamespace { p["termination_namespace"] = .string(terminationNamespace) }
        if let terminationCode { p["termination_code"] = .string(Self.hex(UInt64(bitPattern: terminationCode), padded: false)) }
        if let appVersion { p["crash_app_version"] = .string(appVersion) }
        if let appBuild { p["crash_build"] = .string(appBuild) }
        if let osVersion { p["crash_os_version"] = .string(osVersion) }
        if let hangSeconds { p["hang_duration_s"] = .string(Self.hangDuration.label(hangSeconds)) }
        if smoke { p["smoke"] = .bool(true) }
        return p
    }

    var exceptionSource: String {
        switch source {
        case .diagnosticReport: "macos.diagnostic_report"
        case .metricKit: "macos.metrickit"
        case .signal: "airc.signal_handler"
        }
    }

    /// The exception's type in PostHog: the Mach exception, else the signal, else what kind of report it is.
    var title: String {
        if let exceptionType { return exceptionType }
        if let signal { return signal }
        switch kind {
        case .crash: return "Crash"
        case .hang: return "Hang"
        case .cpuException: return "CPU exception"
        case .diskWriteException: return "Disk write exception"
        }
    }

    /// The exception's "message", made only from the fields above: never the crash's own message.
    var summary: String {
        var parts: [String] = []
        switch kind {
        case .crash: parts.append([exceptionType, signal].compactMap { $0 }.joined(separator: " / "))
        case .hang: parts.append("Hang" + (hangSeconds.map { " of \(Self.hangDuration.label($0)) s" } ?? ""))
        case .cpuException: parts.append("Too much CPU")
        case .diskWriteException: parts.append("Too many disk writes")
        }
        parts.append("in the \(process.rawValue) process")
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Checks

    static func hex(_ v: UInt64, padded: Bool = true) -> String {
        padded ? "0x" + String(repeating: "0", count: max(0, 16 - String(v, radix: 16).count)) + String(v, radix: 16)
            : "0x" + String(v, radix: 16)
    }

    static func matching(_ s: String, _ pattern: String) -> String? {
        s.range(of: pattern, options: .regularExpression) != nil ? s : nil
    }

    /// "macOS 26.6.2 (25G83)" or "26.6.2" → "26.6".
    static func majorMinor(_ s: String) -> String? {
        guard let r = s.range(of: #"[0-9]{1,3}\.[0-9]{1,3}"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }

    /// A binary's name: the basename of its path (never the path: it can hold the user name) or its own name.
    static func imageName(path: String?, name: String?) -> String? {
        let base = path.flatMap { $0.split(separator: "/").last.map(String.init) } ?? name
        return base.flatMap { matching($0, imageNameFormat) }
    }

    /// "4c4c4480-5555-3144-a1fe-efd110699e75" or without dashes → "4C4C4480-5555-3144-A1FE-EFD110699E75"; an
    /// all-zero or malformed UUID is nil.
    static func normalizedUUID(_ s: String?) -> String? {
        guard let s else { return nil }
        let hex = s.replacingOccurrences(of: "-", with: "").uppercased()
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit), hex != String(repeating: "0", count: 32) else { return nil }
        let c = Array(hex)
        return [c[0..<8], c[8..<12], c[12..<16], c[16..<20], c[20..<32]].map { String($0) }.joined(separator: "-")
    }

    /// A function name macOS resolved: printable, no path, no address-like noise. Anything else is dropped.
    static func cleanFunction(_ s: String?) -> String? {
        guard let s, matching(s, functionFormat) != nil else { return nil }
        // A path ("/Users/…", "/private/…") or a URL has no place in a symbol.
        if s.range(of: #"/[A-Za-z~]|://|@[A-Za-z0-9-]+\."#, options: .regularExpression) != nil { return nil }
        return s
    }

    /// Whether `path` is inside the bundle at `bundle` (with a trailing slash). macOS redacts paths under a home folder
    /// in its reports ("/Users/USER/*/Airc.app/Contents/MacOS/Airc"): for a bundle there, that form of its name counts.
    static func inBundle(_ path: String, bundle: String) -> Bool {
        if path.hasPrefix(bundle) { return true }
        guard bundle.hasPrefix("/Users/"), let name = bundle.split(separator: "/").last else { return false }
        return path.hasPrefix("/Users/USER/*/\(name)/") || path.hasPrefix("/Users/USER/\(name)/")
    }

    /// Whose binary it is: Airc's (inside the bundle), the system's, or nobody we name.
    static func origin(path: String?, bundlePath: String) -> Image.Origin? {
        guard let path else { return nil }
        if inBundle(path, bundle: bundlePath) { return .app }
        if ["/System/", "/usr/lib/", "/Library/Apple/"].contains(where: path.hasPrefix) { return .system }
        return nil
    }

    /// Airc's own binary names, for MetricKit (which names binaries but gives no path).
    static func isAppBinary(_ name: String) -> Bool {
        name == "Airc" || name == "Airc Framework" || name == "Sparkle" || name.hasPrefix("Airc Helper")
    }

    static func process(named name: String?) -> Process {
        guard let name else { return .other }
        if name == "Airc" { return .browser }
        guard name.hasPrefix("Airc Helper") else { return .other }
        if name.hasSuffix("Renderer)") { return .renderer }
        if name.hasSuffix("GPU)") { return .gpu }
        if name.hasSuffix("Plugin)") { return .plugin }
        if name.hasSuffix("Alerts)") { return .alerts }
        return .helper
    }

    // MARK: macOS crash reports (.ips)

    /// A crash report macOS wrote (`bug_type` 309: a JSON header line, then the JSON report), if it is a crash of a
    /// process inside `bundlePath` (Airc.app). Reads only the fields listed in the type's comment. When macOS redacted
    /// the path (a bundle under a home folder), the report's bundle identifier must be `bundleID` as well.
    public static func parseIPS(_ data: Data, bundlePath: String, bundleID: String? = nil) -> CrashReport? {
        guard let newline = data.firstIndex(of: 0x0A),
              let header = (try? JSONSerialization.jsonObject(with: Data(data[data.startIndex..<newline]))) as? [String: Any],
              header["bug_type"] as? String == "309",
              let body = (try? JSONSerialization.jsonObject(with: Data(data[data.index(after: newline)...]))) as? [String: Any]
        else { return nil }
        let bundle = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        guard let procPath = body["procPath"] as? String, inBundle(procPath, bundle: bundle) else { return nil }
        if !procPath.hasPrefix(bundle), let bundleID,
           ((body["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] as? String ?? header["bundleID"] as? String) != bundleID {
            return nil
        }

        let used = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil }
            ?? threads.first { $0["triggered"] as? Bool == true }
        // An uncaught exception's own backtrace (where it was thrown) beats the abort that followed it.
        var rawFrames = body["lastExceptionBacktrace"] as? [[String: Any]] ?? []
        if rawFrames.isEmpty { rawFrames = faulting?["frames"] as? [[String: Any]] ?? [] }

        var images: [Image] = []
        var imageFor: [Int: Int] = [:]
        var frames: [Frame] = []
        for raw in rawFrames.prefix(maxFrames) {
            let offset = uint64(raw["imageOffset"]) ?? 0
            guard let index = raw["imageIndex"] as? Int, used.indices.contains(index) else {
                frames.append(Frame(image: nil, address: offset, function: nil))
                continue
            }
            let u = used[index]
            let base = uint64(u["base"]) ?? 0
            if imageFor[index] == nil, let origin = origin(path: u["path"] as? String, bundlePath: bundle),
               let name = imageName(path: u["path"] as? String, name: u["name"] as? String),
               let uuid = normalizedUUID(u["uuid"] as? String) {
                imageFor[index] = images.count
                images.append(Image(name: name, uuid: uuid, base: base, size: uint64(u["size"]), origin: origin))
            }
            if let i = imageFor[index] {
                frames.append(Frame(image: i, address: base &+ offset, function: cleanFunction(raw["symbol"] as? String)))
            } else {
                frames.append(Frame(image: nil, address: base &+ offset, function: nil))
            }
        }

        let exception = body["exception"] as? [String: Any] ?? [:]
        let termination = body["termination"] as? [String: Any] ?? [:]
        let bundleInfo = body["bundleInfo"] as? [String: Any] ?? [:]
        let codes = exception["rawCodes"] as? [Any] ?? []
        return CrashReport(kind: .crash, source: .diagnosticReport, process: process(named: body["procName"] as? String),
                           exceptionType: exception["type"] as? String, signal: exception["signal"] as? String,
                           machCode: codes.first.flatMap(uint64),
                           terminationNamespace: termination["namespace"] as? String,
                           terminationCode: (termination["code"] as? NSNumber)?.int64Value,
                           appVersion: bundleInfo["CFBundleShortVersionString"] as? String,
                           appBuild: bundleInfo["CFBundleVersion"] as? String,
                           osVersion: header["os_version"] as? String, frames: frames, images: images,
                           pid: body["pid"] as? Int,
                           crashTime: ipsTime(body["captureTime"] as? String) ?? ipsTime(header["timestamp"] as? String),
                           faultAddress: codes.count > 1 ? uint64(codes[1]) : nil)
    }

    /// Thread-safe for parsing on macOS 10.9 and later.
    nonisolated(unsafe) private static let ipsTimeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// "2026-11-06 12:00:00.0000 +0100" (the fraction is dropped).
    static func ipsTime(_ s: String?) -> Date? {
        guard let s, let m = s.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)? [+-][0-9]{4}$"#,
                                       options: .regularExpression) else { return nil }
        let parts = s[m].split(separator: " ")
        let time = parts[1].split(separator: ".")[0]
        return ipsTimeFormat.date(from: "\(parts[0]) \(time) \(parts[2])")
    }

    // MARK: Airc's signal records

    /// A record is a few kilobytes; anything much bigger isn't one.
    public static let maxRecordSize = 256 << 10

    /// A crash record Airc's signal handler wrote at the crash (AircCrashLog/CrashLog.c), one `key value` per line:
    /// pid, version, build, os, time, signal, code, fault, then `frame <address>` (the crash site first) and
    /// `image <base> <size> <a|s> <UUID> <name>` for Airc's and the system's binaries the frames fall in, then `end`
    /// (missing if writing it was cut short). Every value goes through the same checks as an .ips's; nil if it isn't a
    /// record or has no signal or time.
    public static func parseSignalRecord(_ data: Data) -> CrashReport? {
        guard data.count <= maxRecordSize else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard lines.first == "airc-crash-record 1" else { return nil }
        var fields: [String: String] = [:]
        var addresses: [UInt64] = []
        var known: [(base: UInt64, size: UInt64, image: Image)] = []
        for line in lines.dropFirst() {
            let kv = line.split(separator: " ", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let value = kv[1]
            switch kv[0] {
            case "frame":
                if addresses.count < maxFrames, let a = hexValue(value) { addresses.append(a) }
            case "image":
                let f = value.split(separator: " ", maxSplits: 4)
                guard f.count == 5, let base = hexValue(f[0]), let size = hexValue(f[1]), size > 0,
                      let origin: Image.Origin = f[2] == "a" ? .app : f[2] == "s" ? .system : nil,
                      let uuid = normalizedUUID(String(f[3])), let name = imageName(path: nil, name: String(f[4])) else { continue }
                known.append((base, size, Image(name: name, uuid: uuid, base: base, size: size, origin: origin)))
            default:
                if fields[String(kv[0])] == nil { fields[String(kv[0])] = String(value) }
            }
        }
        guard let sig = fields["signal"].flatMap({ Int($0) }), (1...31).contains(sig),
              let seconds = fields["time"].flatMap({ Int64($0) }), seconds > 0 else { return nil }
        // Binaries in the order the frames first use them, as from an .ips.
        var images: [Image] = []
        var imageFor: [Int: Int] = [:]
        var frames: [Frame] = []
        for a in addresses {
            guard let k = known.firstIndex(where: { a >= $0.base && a - $0.base < $0.size }) else {
                frames.append(Frame(image: nil, address: a, function: nil))
                continue
            }
            if imageFor[k] == nil {
                imageFor[k] = images.count
                images.append(known[k].image)
            }
            frames.append(Frame(image: imageFor[k], address: a, function: nil))
        }
        return CrashReport(kind: .crash, source: .signal, process: .browser, signal: signals[sig],
                           signalCode: fields["code"].flatMap { Int($0) }, terminationNamespace: "SIGNAL",
                           terminationCode: Int64(sig), appVersion: fields["version"], appBuild: fields["build"],
                           osVersion: fields["os"], frames: frames, images: images, pid: fields["pid"].flatMap { Int($0) },
                           crashTime: Date(timeIntervalSince1970: TimeInterval(seconds)),
                           faultAddress: fields["fault"].flatMap(hexValue))
    }

    /// "0x1a2b" → 0x1a2b.
    static func hexValue<S: StringProtocol>(_ s: S) -> UInt64? {
        guard s.hasPrefix("0x"), s.count > 2, s.count <= 18 else { return nil }
        return UInt64(s.dropFirst(2), radix: 16)
    }

    private static func uint64(_ v: Any?) -> UInt64? {
        guard let n = v as? NSNumber else { return nil }
        return n.uint64Value
    }

    // MARK: MetricKit

    static let machExceptions: [Int: String] = [
        1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION", 5: "EXC_SOFTWARE",
        6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL", 9: "EXC_RPC_ALERT", 10: "EXC_CRASH",
        11: "EXC_RESOURCE", 12: "EXC_GUARD", 13: "EXC_CORPSE_NOTIFY",
    ]
    static let signals: [Int: String] = [
        1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT", 8: "SIGFPE",
        9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM",
        24: "SIGXCPU", 25: "SIGXFSZ",
    ]

    /// Every diagnostic in a MetricKit payload (`MXDiagnosticPayload.jsonRepresentation()`): crashes, hangs, CPU and
    /// disk-write exceptions. Reads the call stack tree and the metadata's codes and versions only.
    public static func parseMetricKit(_ data: Data) -> [CrashReport] {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let groups: [(String, Kind)] = [("crashDiagnostics", .crash), ("hangDiagnostics", .hang),
                                        ("cpuExceptionDiagnostics", .cpuException),
                                        ("diskWriteExceptionDiagnostics", .diskWriteException)]
        var out: [CrashReport] = []
        for (key, kind) in groups {
            for d in payload[key] as? [[String: Any]] ?? [] {
                if let r = metricKitDiagnostic(d, kind: kind) { out.append(r) }
            }
        }
        return out
    }

    private static func metricKitDiagnostic(_ d: [String: Any], kind: Kind) -> CrashReport? {
        let meta = d["diagnosticMetaData"] as? [String: Any] ?? [:]
        let tree = d["callStackTree"] as? [String: Any] ?? [:]
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        // Per thread, each frame has one caller; an aggregated tree (CPU, disk writes) follows its heaviest branch.
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.max(by: weight)
        var images: [Image] = []
        var imageFor: [String: Int] = [:]
        var frames: [Frame] = []
        while let f = frame, frames.count < maxFrames {
            let address = uint64(f["address"]) ?? 0
            let offset = uint64(f["offsetIntoBinaryTextSegment"]) ?? 0
            if let uuid = normalizedUUID(f["binaryUUID"] as? String),
               let name = imageName(path: nil, name: f["binaryName"] as? String), address >= offset {
                if imageFor[uuid] == nil {
                    imageFor[uuid] = images.count
                    images.append(Image(name: name, uuid: uuid, base: address - offset, size: nil,
                                        origin: isAppBinary(name) ? .app : .system))
                }
                frames.append(Frame(image: imageFor[uuid], address: address, function: nil))
            } else {
                frames.append(Frame(image: nil, address: address, function: nil))
            }
            frame = (f["subFrames"] as? [[String: Any]])?.max(by: weight)
        }
        guard !frames.isEmpty || kind == .crash else { return nil }
        var namespace: String?
        var code: Int64?
        if let reason = meta["terminationReason"] as? String,
           let m = reason.range(of: #"Namespace [A-Z_]+, Code (0x[0-9a-fA-F]+|[0-9]+)"#, options: .regularExpression) {
            let parts = reason[m].split(separator: " ")
            namespace = String(parts[1].dropLast())
            let c = String(parts[3])
            code = c.hasPrefix("0x") ? UInt64(c.dropFirst(2), radix: 16).map { Int64(bitPattern: $0) } : Int64(c)
        }
        return CrashReport(kind: kind, source: .metricKit, process: .browser,
                           exceptionType: (meta["exceptionType"] as? Int).flatMap { machExceptions[$0] },
                           signal: (meta["signal"] as? Int).flatMap { signals[$0] },
                           machCode: (meta["exceptionCode"] as? NSNumber)?.uint64Value,
                           terminationNamespace: namespace, terminationCode: code,
                           appVersion: meta["appVersion"] as? String, appBuild: meta["appBuildVersion"] as? String,
                           osVersion: meta["osVersion"] as? String,
                           hangSeconds: kind == .hang ? (meta["hangDuration"] as? String).flatMap(seconds) : nil,
                           frames: frames, images: images, pid: meta["pid"] as? Int)
    }

    private static func weight(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        (a["sampleCount"] as? Int ?? 0) < (b["sampleCount"] as? Int ?? 0)
    }

    /// MetricKit's formatted durations: "3.5 sec", "250 ms", "1.2 min".
    static func seconds(_ s: String) -> Double? {
        let parts = s.split(separator: " ")
        guard let n = parts.first.flatMap({ Double($0) }) else { return nil }
        switch parts.count > 1 ? parts[1].lowercased() : "sec" {
        case "ms": return n / 1000
        case "min": return n * 60
        default: return n
        }
    }
}

/// Finds Airc's new crash reports at launch, in macOS's DiagnosticReports folder and in Airc's own signal records, and
/// remembers what it has reported. Only `.ips` files named after Airc's processes and written after the last scan are
/// read, and signal records of crashes after the last look, at most `maxPerScan` of each a launch (a crash loop doesn't
/// flood anything). The first scan only sets the mark: crashes from before crash reporting was on are never sent.
///
/// One crash can reach Airc three ways: its signal record, macOS's `.ips` and MetricKit. It is reported once: two
/// reports are the same crash when they come from the same build, within `sameCrashWindow` of each other, and from the
/// same process ID (or, when one has none, at the same fault address). In one look, the `.ips` goes first (macOS
/// resolved its function names); a signal record waits `recordSettle` after its crash so that the `.ips` can come.
public struct CrashReportLog: Codable, Sendable, Equatable {
    public var version = 1
    /// Reports written up to here have been looked at.
    public var since: Date
    /// Before identities (`crashes`): crashes reported by process ID alone, and when. Read for a week, no longer written.
    public var reported: [String: Date] = [:]
    /// Crashes already reported, kept a week, to know the same crash from another source.
    public var crashes: [Crash]?
    /// Signal records of crashes up to here have been looked at. A log from before signal records starts at `since`.
    public var recordsSince: Date?

    /// What tells one crash from another. Local only, like `CrashReport.pid`.
    public struct Crash: Codable, Sendable, Equatable {
        public var pid: Int?
        public var time: Date?
        public var build: String?
        public var fault: UInt64?
        /// When it was reported (forgotten a week later).
        public var at: Date

        public init(_ report: CrashReport, at: Date) {
            pid = report.pid
            time = report.crashTime
            build = report.appBuild
            fault = report.faultAddress
            self.at = at
        }

        /// The same crash: the same build, close in time, and the same process (or, without a process ID on one side,
        /// the same fault address). What either side doesn't know doesn't count against it.
        public func matches(_ other: Crash) -> Bool {
            if let a = build, let b = other.build, a != b { return false }
            if let a = time, let b = other.time, abs(a.timeIntervalSince(b)) > CrashReportLog.sameCrashWindow { return false }
            if let a = pid, let b = other.pid { return a == b }
            if let a = fault, let b = other.fault, a != 0, time != nil, other.time != nil { return a == b }
            return false
        }
    }

    public static let maxPerScan = 10
    public static let maxFileSize = 4 << 20
    /// macOS writes its report seconds (for Chromium's browser process, up to a minute or two) after the crash.
    public static let sameCrashWindow: TimeInterval = 300
    /// How long a signal record waits for macOS's report of the same crash.
    public static let recordSettle: TimeInterval = 60
    /// record.1 … record.3 (AircCrashLog keeps the last three crashes; `record` is the running app's own).
    public static let recordNames = ["record.1", "record.2", "record.3"]

    public init(since: Date) {
        self.since = since
        recordsSince = since
    }

    /// The log at `url`, or a new one that starts now.
    public static func load(_ url: URL, now: Date) -> CrashReportLog {
        guard let data = try? Data(contentsOf: url), var log = try? TelemetryRecord.decoder.decode(Self.self, from: data),
              log.version == 1 else { return CrashReportLog(since: now) }
        // Before the .ips scan moves `since` on.
        if log.recordsSince == nil { log.recordsSince = log.since }
        return log
    }

    public func save(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? TelemetryRecord.encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The new crashes of the app at `bundlePath` (`bundleID`) in `directory`, oldest first; moves the mark past every
    /// file read.
    public mutating func scan(_ directory: URL, bundlePath: String, bundleID: String? = nil, now: Date) -> [CrashReport] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        var candidates: [(url: URL, date: Date)] = []
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("Airc"), url.pathExtension == "ips",
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let date = v.contentModificationDate, date > since else { continue }
            if (v.fileSize ?? 0) <= Self.maxFileSize { candidates.append((url, date)) } else { since = max(since, date) }
        }
        var out: [CrashReport] = []
        for c in candidates.sorted(by: { $0.date < $1.date }) {
            since = max(since, c.date)
            guard out.count < Self.maxPerScan, let data = try? Data(contentsOf: c.url),
                  let report = CrashReport.parseIPS(data, bundlePath: bundlePath, bundleID: bundleID),
                  admit(report, now: now) else { continue }
            out.append(report)
        }
        prune(now: now)
        return out
    }

    /// Airc's signal records in `directory` (CrashLog.recordsDirectory) of crashes since the last look, oldest first,
    /// each crash once (`admit`: none whose `.ips` or MetricKit report was already sent). A crash younger than `settle`
    /// stays for a later look, from `retry` on, and so does every crash after it.
    public mutating func scanRecords(_ directory: URL, now: Date, settle: TimeInterval = recordSettle)
        -> (reports: [CrashReport], retry: Date?) {
        let mark = recordsSince ?? since
        recordsSince = mark
        var found: [(report: CrashReport, time: Date)] = []
        for name in Self.recordNames {
            let url = directory.appendingPathComponent(name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])).flatMap({
                      $0.isRegularFile == true ? $0.fileSize : nil }), size > 0, size <= CrashReport.maxRecordSize,
                  let data = try? Data(contentsOf: url), let report = CrashReport.parseSignalRecord(data),
                  let time = report.crashTime, time > mark else { continue }
            found.append((report, time))
        }
        var out: [CrashReport] = []
        for f in found.sorted(by: { $0.time < $1.time }) {
            if now.timeIntervalSince(f.time) < settle { return (out, f.time.addingTimeInterval(settle)) }
            recordsSince = max(recordsSince ?? mark, f.time)
            if out.count < Self.maxPerScan, admit(f.report, now: now) { out.append(f.report) }
        }
        prune(now: now)
        return (out, nil)
    }

    /// Whether `report` is new (a crash not reported yet from any source: `Crash.matches`), noting it if so.
    public mutating func admit(_ report: CrashReport, now: Date) -> Bool {
        guard report.kind == .crash else { return true }
        if report.crashTime == nil, let pid = report.pid, let at = reported["pid:\(pid)"],
           now.timeIntervalSince(at) < Self.week { return false }
        let crash = Crash(report, at: now)
        if (crashes ?? []).contains(where: { $0.matches(crash) }) { return false }
        crashes = (crashes ?? []) + [crash]
        return true
    }

    private static let week: TimeInterval = 7 * 24 * 3600

    private mutating func prune(now: Date) {
        reported = reported.filter { now.timeIntervalSince($0.value) < Self.week }
        crashes = crashes?.filter { now.timeIntervalSince($0.at) < Self.week }
    }
}

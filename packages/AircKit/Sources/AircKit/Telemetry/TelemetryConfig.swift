// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Whether and where telemetry goes. The app resolves it at launch from Info.plist (`AircTelemetryHost`,
/// `AircTelemetryKey`, written by scripts/build-app.sh from infra/release/telemetry.json), the environment, the user
/// defaults and Settings → Privacy.
public struct TelemetryResolution: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// No project key or no valid host in this build: nothing is recorded or sent.
        case unavailable
        /// `AIRC_TELEMETRY_ENABLED=0` or `defaults write … AircTelemetryEnabled -bool false`: off, and Settings can't
        /// turn it on.
        case lockedOff(OffSource)
        /// The person turned "Share anonymous usage data" off.
        case off
        /// Recorded for "See what Airc sends" only, never sent: a scripted or automated run with a real host.
        case recordOnly
        case sending
    }

    public enum OffSource: String, Sendable {
        case environment, defaults
    }

    public var state: State
    public var endpoint: URL?
    public var apiKey: String

    public init(state: State, endpoint: URL?, apiKey: String) {
        self.state = state
        self.endpoint = endpoint
        self.apiKey = apiKey
    }

    /// No key: nothing recorded or sent.
    public static let unavailable = TelemetryResolution(state: .unavailable, endpoint: nil, apiKey: "")

    public var records: Bool { state == .recordOnly || state == .sending }
    public var sends: Bool { state == .sending }

    /// The env var and the defaults key that turn telemetry off.
    public static let environmentKey = "AIRC_TELEMETRY_ENABLED"
    public static let defaultsKey = "AircTelemetryEnabled"

    public static func resolve(host: String?, key: String?, environment: [String: String], defaultsValue: Bool?,
                               userEnabled: Bool, automated: Bool) -> TelemetryResolution {
        let apiKey = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = host.flatMap(batchEndpoint)
        var r = TelemetryResolution(state: .unavailable, endpoint: endpoint, apiKey: apiKey)
        guard !apiKey.isEmpty, apiKey.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }), let endpoint else {
            return r
        }
        if let v = environment[environmentKey], isOff(v) {
            r.state = .lockedOff(.environment)
        } else if defaultsValue == false {
            r.state = .lockedOff(.defaults)
        } else if !userEnabled {
            r.state = .off
        } else if automated {
            // Scripted runs never send to a real host; a loopback one is the mock PostHog of a delivery check.
            r.state = isLoopback(endpoint) ? .sending : .recordOnly
        } else {
            r.state = .sending
        }
        return r
    }

    static func isOff(_ value: String) -> Bool {
        ["0", "false", "no", "off"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// `<host>/batch/` for an https host, or an http one on this Mac only (the mock server of a delivery check).
    public static func batchEndpoint(_ host: String) -> URL? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: h), let scheme = base.scheme?.lowercased(), base.host != nil,
              base.query == nil, base.fragment == nil, base.user == nil else { return nil }
        guard scheme == "https" || (scheme == "http" && isLoopback(base)) else { return nil }
        let trimmed = h.hasSuffix("/") ? String(h.dropLast()) : h
        return URL(string: trimmed + "/batch/")
    }

    public static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }
}

/// The properties every event carries: which build, engine and Mac, never who.
public struct TelemetryContext: Sendable, Equatable {
    public enum Channel: String, Sendable, CaseIterable { case dev, stable }
    public enum Engine: String, Sendable, CaseIterable { case chromium, webkit }

    public var appVersion: String
    public var build: String
    public var channel: Channel
    public var engine: Engine
    public var osVersion: String
    public var arch: String
    public var language: String

    /// Each value is checked against its format here; anything else becomes "unknown", so a modified Info.plist can't
    /// carry free text either.
    public init(appVersion: String, build: String, channel: Channel, engine: Engine, osVersion: OperatingSystemVersion,
                arch: String, preferredLanguage: String?) {
        self.appVersion = Self.matching(appVersion, #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#)
        self.build = Self.matching(build, #"^[0-9]{1,14}$"#)
        self.channel = channel
        self.engine = engine
        self.osVersion = "\(max(0, min(osVersion.majorVersion, 999))).\(max(0, min(osVersion.minorVersion, 999)))"
        self.arch = ["arm64", "x86_64"].contains(arch) ? arch : "unknown"
        // "en-GB" → "en". The language only: never the region.
        let code = preferredLanguage?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() }
        self.language = code.map { Self.matching($0, #"^[a-z]{2,3}$"#) } ?? "unknown"
    }

    private static func matching(_ s: String, _ pattern: String) -> String {
        s.range(of: pattern, options: .regularExpression) != nil ? s : "unknown"
    }

    /// The super properties, with the install's age in days and PostHog's own: anonymous events (no person profile),
    /// no GeoIP lookup.
    public func superProperties(installAgeDays: Int) -> [String: TelemetryValue] {
        [
            "app_version": .string(appVersion),
            "build": .string(build),
            "channel": .string(channel.rawValue),
            "engine": .string(engine.rawValue),
            "os_version": .string(osVersion),
            "arch": .string(arch),
            "language": .string(language),
            "install_age_days": .string(TelemetryBucket.days(installAgeDays)),
            "$lib": .string("airc-macos"),
            "$lib_version": .string(appVersion),
            "$process_person_profile": .bool(false),
            "$geoip_disable": .bool(true),
        ]
    }
}

/// The install ID: a random UUID in Airc's data folder (`Telemetry/install.json`), the `distinct_id` of every event.
/// Not derived from anything on the Mac; "Reset" in Settings → Privacy replaces it (and the install's age with it).
public struct TelemetryInstall: Codable, Sendable, Equatable {
    public var id: String
    /// The day it was made (install_age_days counts from here).
    public var created: Date

    public init(id: String = UUID().uuidString.lowercased(), created: Date) {
        self.id = id
        self.created = created
    }

    public func ageInDays(at now: Date, calendar: Calendar = .current) -> Int {
        max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: created), to: calendar.startOfDay(for: now)).day ?? 0)
    }

    /// Reads the install ID at `url`, or makes one (`created` true).
    public static func load(_ url: URL, now: Date) -> (install: TelemetryInstall, created: Bool) {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let i = try? d.decode(TelemetryInstall.self, from: data),
           UUID(uuidString: i.id) != nil {
            return (i, false)
        }
        return (make(url, now: now), true)
    }

    /// A new install ID, written to `url`.
    @discardableResult
    public static func make(_ url: URL, now: Date) -> TelemetryInstall {
        let i = TelemetryInstall(created: now)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(i).write(to: url, options: .atomic)
        return i
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// What may leave Airc (docs/user/telemetry.md, "What is never sent"): every event type is serialised exactly as it is
/// sent, and every key and value checked against a strict allowlist. A new event, property or feature fails here until
/// it is added below and documented.
final class TelemetryEventTests: XCTestCase {
    enum Rule {
        case bool
        case oneOf(Set<String>)
        case format(String)

        func allows(_ v: Any) -> Bool {
            switch self {
            case .bool: return (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            case let .oneOf(set): return (v as? String).map(set.contains) ?? false
            case let .format(p): return (v as? String).map { $0.range(of: p, options: .regularExpression) != nil } ?? false
            }
        }
    }

    static func labels(_ s: TelemetryBucket.Scale) -> Rule { .oneOf(Set(s.labels)) }
    static func values<E: CaseIterable & RawRepresentable>(_: E.Type) -> Rule where E.RawValue == String {
        .oneOf(Set(E.allCases.map(\.rawValue)))
    }

    static let superRules: [String: Rule] = [
        "app_version": .format(#"^([0-9]{1,4}(\.[0-9]{1,4}){0,3}|unknown)$"#),
        "build": .format(#"^([0-9]{1,14}|unknown)$"#),
        "channel": values(TelemetryContext.Channel.self),
        "engine": values(TelemetryContext.Engine.self),
        "os_version": .format(#"^[0-9]{1,3}\.[0-9]{1,3}$"#),
        "arch": .oneOf(["arm64", "x86_64", "unknown"]),
        "language": .format(#"^([a-z]{2,3}|unknown)$"#),
        "install_age_days": labels(TelemetryBucket.installAge),
        "$lib": .oneOf(["airc-macos"]),
        "$lib_version": .format(#"^([0-9]{1,4}(\.[0-9]{1,4}){0,3}|unknown)$"#),
        "$process_person_profile": .bool,
        "$geoip_disable": .bool,
    ]

    static let featureNames: Set<String> = [
        "command_bar.open", "split.create", "split.pin", "split.favorite", "peek.open", "peek.promote", "little_arc.open",
        "pip.open", "space.create", "profile.create", "favorite.add", "air_traffic.rule_add", "find.open",
        "history_menu.open", "download.start", "download.complete", "site_controls.open", "default_browser.prompt",
        "extension.install", "update.install", "theme.change", "calendar.enable", "calendar.join", "telemetry.smoke",
        "update.ready_shown", "update.restart_clicked", "boost.save", "private_window.open", "tab_preview.action",
    ]

    static let variants: Set<String> = ["new_tab", "edit_url", "2", "3", "4", "shortcut", "link", "video", "call", "document",
                                        "back", "forward", "shown", "accepted", "declined", "pin", "unpin", "favorite",
                                        "unfavorite", "split", "peek"]

    /// Per event: its own properties (required ones first) beyond the super properties.
    static let eventRules: [String: (required: [String: Rule], optional: [String: Rule])] = [
        "app.launched": (["launch_ms": labels(TelemetryBucket.launch), "first_launch": .bool,
                          "previous_exit": values(TelemetryEvent.PreviousExit.self)], [:]),
        "app.active_day": (["spaces": labels(TelemetryBucket.counts), "profiles": labels(TelemetryBucket.counts),
                            "pinned_tabs": labels(TelemetryBucket.counts), "favorites": labels(TelemetryBucket.counts),
                            "open_tabs": labels(TelemetryBucket.counts),
                            "sidebar_position": values(TelemetryEvent.SidebarPosition.self), "default_browser": .bool], [:]),
        "onboarding.step": (["step": values(TelemetryEvent.OnboardingStep.self),
                             "action": values(TelemetryEvent.OnboardingAction.self)], [:]),
        "onboarding.finished": (["imported": .bool], [:]),
        "import.arc": (["result": values(TelemetryEvent.ImportArc.Result.self), "spaces": labels(TelemetryBucket.counts),
                        "tabs": labels(TelemetryBucket.counts), "profiles": labels(TelemetryBucket.counts), "logins": .bool], [:]),
        "import.browser": (["browser": values(TelemetryEvent.ImportBrowser.Source.self), "result": values(TelemetryEvent.ImportArc.Result.self),
                            "profiles": labels(TelemetryBucket.counts), "bookmarks": labels(TelemetryBucket.counts),
                            "folders": labels(TelemetryBucket.counts), "history": labels(TelemetryBucket.counts),
                            "passwords": labels(TelemetryBucket.counts)], [:]),
        "feature.used": (["feature": .oneOf(featureNames)], ["variant": .oneOf(variants)]),
        "perf.daily": (["command_bar_opens": labels(TelemetryBucket.counts)],
                       ["command_bar_p50_ms": labels(TelemetryBucket.frame), "command_bar_p95_ms": labels(TelemetryBucket.frame),
                        "memory_mb": labels(TelemetryBucket.memory), "idle_cpu_pct": labels(TelemetryBucket.cpu)]),
        "process.gone": (["process_type": values(TelemetryEvent.ChildProcess.self),
                          "exit_signal": values(TelemetryEvent.ExitSignal.self)], [:]),
    ]

    /// One of every feature, every variant included.
    static let allFeatures: [TelemetryFeature] = TelemetryFeature.CommandBarEntry.allCases.map { .commandBar($0) }
        + [1, 2, 3, 4, 9].map { .splitCreate(panes: $0) }
        + [.splitPin, .splitFavorite, .peekOpen, .peekPromote]
        + TelemetryFeature.LittleArcSource.allCases.map { .littleArcOpen($0) }
        + TelemetryFeature.PictureInPictureKind.allCases.map { .pictureInPicture($0) }
        + [.spaceCreate, .profileCreate, .favoriteAdd, .airTrafficRuleAdd, .find]
        + TelemetryFeature.HistoryDirection.allCases.map { .historyMenu($0) }
        + [.downloadStarted, .downloadCompleted, .siteControlsOpened]
        + TelemetryFeature.DefaultBrowserAction.allCases.map { .defaultBrowser($0) }
        + [.extensionInstalled, .updateInstalled, .themeChanged, .calendarEnable, .calendarJoin, .telemetrySmoke,
           .updateReadyShown, .updateRestartClicked, .boostSaved, .privateWindowOpen]
        + TelemetryFeature.TabPreviewAction.allCases.map { .tabPreviewAction($0) }

    /// One of every event, with extreme numbers too.
    static let allEvents: [TelemetryEvent] = {
        var e: [TelemetryEvent] = []
        for previous in TelemetryEvent.PreviousExit.allCases {
            for ms in [-1.0, 0, 249, 250, 1234, 99_999, .infinity, .nan] {
                e.append(.appLaunched(launchMilliseconds: ms, firstLaunch: previous == .none, previousExit: previous))
            }
        }
        for (n, side) in zip([0, 1, 2, 7, 10_000], [TelemetryEvent.SidebarPosition.left, .right, .left, .right, .left]) {
            e.append(.activeDay(.init(spaces: n, profiles: n, pinnedTabs: n * 3, favorites: n, openTabs: n * 7,
                                      sidebarPosition: side, isDefaultBrowser: n % 2 == 0)))
        }
        for step in TelemetryEvent.OnboardingStep.allCases {
            for action in TelemetryEvent.OnboardingAction.allCases { e.append(.onboardingStep(step: step, action: action)) }
        }
        e += [.onboardingFinished(imported: true), .onboardingFinished(imported: false)]
        for result in TelemetryEvent.ImportArc.Result.allCases {
            e.append(.importArc(.init(result: result, spaces: 6, tabs: 140, profiles: 2, logins: result == .success)))
        }
        for source in TelemetryEvent.ImportBrowser.Source.allCases {
            e.append(.importBrowser(.init(source: source, result: source == .opera ? .failed : .success, profiles: 2, bookmarks: 312,
                                          folders: 4, history: 20_000, passwords: source == .passwordsFile ? 24 : 0)))
        }
        e += allFeatures.map { .featureUsed($0) }
        e.append(.perfDaily(.init(commandBarOpens: 0, commandBarP50Milliseconds: nil, commandBarP95Milliseconds: nil,
                                  memoryMegabytes: nil, idleCPUPercent: nil)))
        e.append(.perfDaily(.init(commandBarOpens: 37, commandBarP50Milliseconds: 6.2, commandBarP95Milliseconds: 19,
                                  memoryMegabytes: 527, idleCPUPercent: 0.3)))
        e.append(.perfDaily(.init(commandBarOpens: 5000, commandBarP50Milliseconds: 1e9, commandBarP95Milliseconds: -3,
                                  memoryMegabytes: 1e7, idleCPUPercent: 400)))
        for process in TelemetryEvent.ChildProcess.allCases {
            e += TelemetryEvent.ExitSignal.allCases.map { .processGone(process: process, exit: $0) }
        }
        return e
    }()

    func testEveryFeatureCaseHasAnExample() {
        // Exhaustive: a new feature case doesn't compile here until it gets an example and a name above.
        func index(_ f: TelemetryFeature) -> Int {
            switch f {
            case .commandBar: 0
            case .splitCreate: 1
            case .splitPin: 2
            case .splitFavorite: 3
            case .peekOpen: 4
            case .peekPromote: 5
            case .littleArcOpen: 6
            case .pictureInPicture: 7
            case .spaceCreate: 8
            case .profileCreate: 9
            case .favoriteAdd: 10
            case .airTrafficRuleAdd: 11
            case .find: 12
            case .historyMenu: 13
            case .downloadStarted: 14
            case .downloadCompleted: 15
            case .siteControlsOpened: 16
            case .defaultBrowser: 17
            case .extensionInstalled: 18
            case .updateInstalled: 19
            case .themeChanged: 20
            case .telemetrySmoke: 21
            case .calendarEnable: 22
            case .calendarJoin: 23
            case .updateReadyShown: 24
            case .updateRestartClicked: 25
            case .boostSaved: 26
            case .privateWindowOpen: 27
            case .tabPreviewAction: 28
            }
        }
        XCTAssertEqual(Set(Self.allFeatures.map(index)), Set(0...28))
        XCTAssertEqual(Set(Self.allFeatures.map(\.name)), Self.featureNames)
        func covered(_ e: TelemetryEvent) -> String {
            switch e {
            case .appLaunched, .activeDay, .onboardingStep, .onboardingFinished, .importArc, .importBrowser, .featureUsed, .perfDaily,
                 .processGone: e.name
            }
        }
        XCTAssertEqual(Set(Self.allEvents.map(covered)), Set(Self.eventRules.keys))
    }

    /// Every event type, serialised as PostHog receives it, holds only allowlisted keys with allowlisted values.
    func testEveryEventSerialisesToTheAllowlist() throws {
        let h = TelemetryHarness()
        h.startSending()
        Self.allEvents.forEach(h.client.record)
        h.client.drain()
        h.scheduler.fireAll(h.client)
        let batches = h.transport.bodies.map { try! JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        XCTAssertFalse(batches.isEmpty)
        var seen = 0
        for batch in batches {
            XCTAssertEqual(Set(batch.keys), ["api_key", "historical_migration", "batch"])
            XCTAssertEqual(batch["api_key"] as? String, "phc_test")
            XCTAssertEqual(batch["historical_migration"] as? Bool, false)
            for event in batch["batch"] as! [[String: Any]] {
                seen += 1
                try checkEvent(event)
            }
        }
        XCTAssertEqual(seen, Self.allEvents.count)
    }

    private func checkEvent(_ event: [String: Any]) throws {
        XCTAssertEqual(Set(event.keys), ["uuid", "event", "distinct_id", "timestamp", "properties"])
        XCTAssertNotNil(UUID(uuidString: event["uuid"] as? String ?? ""), "uuid")
        XCTAssertNotNil(UUID(uuidString: event["distinct_id"] as? String ?? ""), "distinct_id is the random install ID")
        XCTAssertNotNil((event["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }, "ISO 8601 timestamp")
        let name = try XCTUnwrap(event["event"] as? String)
        let rules = try XCTUnwrap(Self.eventRules[name], "\(name) isn't in the allowlist")
        let props = try XCTUnwrap(event["properties"] as? [String: Any])
        for key in Array(Self.superRules.keys) + Array(rules.required.keys) {
            XCTAssertNotNil(props[key], "\(name) lacks \(key)")
        }
        for (key, value) in props {
            let rule = Self.superRules[key] ?? rules.required[key] ?? rules.optional[key]
            XCTAssertNotNil(rule, "\(name) carries a key outside the allowlist: \(key)")
            XCTAssertTrue(rule?.allows(value) ?? false, "\(name).\(key) = \(value) isn't allowed")
        }
    }

    func testFeatureEventCarriesItsVariant() {
        XCTAssertEqual(TelemetryEvent.featureUsed(.splitCreate(panes: 2)).properties,
                       ["feature": .string("split.create"), "variant": .string("2")])
        XCTAssertEqual(TelemetryEvent.featureUsed(.splitCreate(panes: 7)).properties["variant"], .string("4"))
        XCTAssertEqual(TelemetryEvent.featureUsed(.find).properties, ["feature": .string("find.open")])
        XCTAssertEqual(TelemetryEvent.featureUsed(.telemetrySmoke).properties["feature"], .string("telemetry.smoke"))
    }

    /// A renderer's wait status (WIFSIGNALED: the low 7 bits) becomes its signal, never the raw number.
    func testChildProcessLabelsAreClosed() {
        XCTAssertEqual(Set(TelemetryEvent.ChildProcess.allCases.map(\.rawValue)),
                       ["renderer", "gpu", "network", "storage", "audio", "other",
                        "utility:data_decoder", "utility:video_capture"])
        for name in ["https://private.example", "/Users/private/file", "utility:unknown"] {
            XCTAssertEqual(TelemetryEvent.ChildProcess(engineType: name), .other)
        }
    }

    func testChildProcessExitSignal() {
        XCTAssertEqual(TelemetryEvent.ExitSignal(waitStatus: 11), .segv)
        XCTAssertEqual(TelemetryEvent.ExitSignal(waitStatus: 11 | 0x80), .segv, "with a core dump")
        XCTAssertEqual(TelemetryEvent.ExitSignal(waitStatus: 5), .trap, "Chromium's CHECK (brk)")
        XCTAssertEqual(TelemetryEvent.ExitSignal(waitStatus: 9), .kill)
        XCTAssertEqual(TelemetryEvent.ExitSignal(waitStatus: 0x0100), .exit, "exit(1)")
        XCTAssertEqual(TelemetryEvent.ExitSignal(waitStatus: 30), .other)
        XCTAssertEqual(TelemetryEvent.processGone(process: .renderer, exit: .segv).properties,
                       ["process_type": .string("renderer"), "exit_signal": .string("SIGSEGV")])
    }

    func testBuckets() {
        XCTAssertEqual([0, 1, 2, 3, 5, 6, 10, 11, 20, 21, 50, 51, 100, 101, 200, 201, 500, 501, 9999, -4].map(TelemetryBucket.count),
                       ["0", "1", "2", "3-5", "3-5", "6-10", "6-10", "11-20", "11-20", "21-50", "21-50", "51-100", "51-100",
                        "101-200", "101-200", "201-500", "201-500", "501+", "501+", "0"])
        XCTAssertEqual(TelemetryBucket.counts.labels,
                       ["0", "1", "2", "3-5", "6-10", "11-20", "21-50", "51-100", "101-200", "201-500", "501+"])
        XCTAssertEqual([0, 249, 250, 999, 10_000].map(TelemetryBucket.launchMilliseconds),
                       ["<250", "<250", "250-500", "750-1000", "10000+"])
        XCTAssertEqual([3.9, 4, 7.99, 8, 16.6, 251].map(TelemetryBucket.frameMilliseconds), ["<4", "4-8", "4-8", "8-12", "16-25", "250+"])
        XCTAssertEqual([0.1, 0.5, 3, 30].map(TelemetryBucket.percent), ["<0.5", "0.5-1", "2-5", "25+"])
        XCTAssertEqual([0, 1, 2, 7, 8, 30, 31, 365, 366].map(TelemetryBucket.days),
                       ["0", "1", "2-7", "2-7", "8-30", "8-30", "31-90", "181-365", "366+"])
        for scale in [TelemetryBucket.counts, TelemetryBucket.launch, TelemetryBucket.frame, TelemetryBucket.memory, TelemetryBucket.cpu,
                      TelemetryBucket.installAge] {
            for v in stride(from: 0.0, through: 12_000, by: 0.5) {
                XCTAssertTrue(scale.labels.contains(scale.label(v)), "\(v) → \(scale.label(v))")
            }
        }
    }

    func testContextKeepsOnlyWellFormedValues() {
        let c = TelemetryContext(appVersion: "0.1.0", build: "202611061230", channel: .dev, engine: .chromium,
                                 osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 2),
                                 arch: "arm64", preferredLanguage: "en-GB")
        XCTAssertEqual([c.appVersion, c.build, c.osVersion, c.arch, c.language], ["0.1.0", "202611061230", "26.6", "arm64", "en"])
        let odd = TelemetryContext(appVersion: "1.0 (my-mac.local)", build: "dev /Users/someone", channel: .stable,
                                   engine: .webkit, osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
                                   arch: "ppc", preferredLanguage: "zh-Hans-CN")
        XCTAssertEqual([odd.appVersion, odd.build, odd.arch, odd.language], ["unknown", "unknown", "unknown", "zh"])
        XCTAssertEqual(TelemetryContext(appVersion: "1", build: "1", channel: .dev, engine: .webkit,
                                        osVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0),
                                        arch: "x86_64", preferredLanguage: "Deutsch").language, "unknown")
    }

    func testResolution() {
        func r(host: String? = "https://eu.i.posthog.com", key: String? = "phc_abc", env: [String: String] = [:],
               defaults: Bool? = nil, user: Bool = true, automated: Bool = false) -> TelemetryResolution.State {
            TelemetryResolution.resolve(host: host, key: key, environment: env, defaultsValue: defaults, userEnabled: user,
                                        automated: automated).state
        }
        XCTAssertEqual(r(), .sending)
        XCTAssertEqual(r(key: ""), .unavailable, "no key: fully off")
        XCTAssertEqual(r(key: nil), .unavailable)
        XCTAssertEqual(r(key: "phc abc\"}"), .unavailable)
        XCTAssertEqual(r(host: "http://eu.i.posthog.com"), .unavailable, "plain HTTP only to this Mac")
        XCTAssertEqual(r(host: "not a url"), .unavailable)
        XCTAssertEqual(r(env: ["AIRC_TELEMETRY_ENABLED": "0"]), .lockedOff(.environment))
        XCTAssertEqual(r(env: ["AIRC_TELEMETRY_ENABLED": "false"], user: false), .lockedOff(.environment))
        XCTAssertEqual(r(env: ["AIRC_TELEMETRY_ENABLED": "1"]), .sending)
        XCTAssertEqual(r(defaults: false), .lockedOff(.defaults))
        XCTAssertEqual(r(defaults: true), .sending)
        XCTAssertEqual(r(user: false), .off)
        XCTAssertEqual(r(automated: true), .recordOnly, "scripted runs never send to a real host")
        XCTAssertEqual(r(host: "http://127.0.0.1:8123", automated: true), .sending, "the mock PostHog of a delivery check")
        XCTAssertEqual(TelemetryResolution.batchEndpoint("https://eu.i.posthog.com")?.absoluteString, "https://eu.i.posthog.com/batch/")
        XCTAssertEqual(TelemetryResolution.batchEndpoint("https://eu.i.posthog.com/")?.absoluteString, "https://eu.i.posthog.com/batch/")
    }

    func testInstallIDPersistsAndResets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-telemetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("install.json")
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let first = TelemetryInstall.load(url, now: day)
        XCTAssertTrue(first.created)
        XCTAssertNotNil(UUID(uuidString: first.install.id))
        let again = TelemetryInstall.load(url, now: day.addingTimeInterval(9 * 86400))
        XCTAssertFalse(again.created)
        XCTAssertEqual(again.install, first.install)
        XCTAssertEqual(again.install.ageInDays(at: day.addingTimeInterval(9 * 86400)), 9)
        let reset = TelemetryInstall.make(url, now: day)
        XCTAssertNotEqual(reset.id, first.install.id)
        XCTAssertEqual(TelemetryInstall.load(url, now: day).install, reset)
    }
}

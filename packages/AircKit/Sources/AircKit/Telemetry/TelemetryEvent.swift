// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Airc's product analytics events (docs/user/telemetry.md). Every name and every property value comes from a closed
/// enum, a numeric bucket or a flag, so nothing a page, a user or a file name holds can reach analytics: there is no
/// case that takes a string. Counts and timings are bucketed when the event is serialised (TelemetryBucket).
public enum TelemetryEvent: Sendable, Equatable {
    /// Once per launch, when the first window (browser or onboarding) is on screen.
    case appLaunched(launchMilliseconds: Double, firstLaunch: Bool, previousExit: PreviousExit)
    /// Once per calendar day, at the first launch or activation that day.
    case activeDay(ActiveDay)
    /// The person acted on an onboarding step.
    case onboardingStep(step: OnboardingStep, action: OnboardingAction)
    /// Onboarding's "Open Airc".
    case onboardingFinished(imported: Bool)
    /// An Arc import ran (onboarding, or Settings → Import).
    case importArc(ImportArc)
    /// A feature was used (TelemetryFeature).
    case featureUsed(TelemetryFeature)
    /// Once per calendar day: how fast and how light Airc ran since the last one.
    case perfDaily(PerfDaily)
    /// A child process ended abnormally: a tab's renderer ("Aw, Snap"). Which kind of process and how it ended, nothing
    /// else (never the tab, its page or its site).
    case processGone(process: ChildProcess, exit: ExitSignal)

    /// How the previous run ended: the app's "running" sentinel was still there at launch (unclean), or not.
    public enum PreviousExit: String, Sendable, CaseIterable {
        case clean, unclean
        /// The first launch on this data folder.
        case none
    }

    public enum OnboardingStep: String, Sendable, CaseIterable {
        case welcome, arc, accounts, logins, theme, defaultBrowser = "default_browser", done
    }

    public enum OnboardingAction: String, Sendable, CaseIterable {
        case next, skip, back
    }

    public enum SidebarPosition: String, Sendable, CaseIterable {
        case left, right
    }

    public enum ChildProcess: String, Sendable, CaseIterable {
        case renderer
    }

    /// How a child process ended: the signal that ended it, or `exit` for an exit code of its own.
    public enum ExitSignal: String, Sendable, CaseIterable {
        case segv = "SIGSEGV", bus = "SIGBUS", ill = "SIGILL", abrt = "SIGABRT", trap = "SIGTRAP", fpe = "SIGFPE",
             sys = "SIGSYS", kill = "SIGKILL", term = "SIGTERM", exit, other

        /// From a wait status, as Chromium gives it for a child on macOS (`GetCrashedErrorCode`).
        public init(waitStatus: Int32) {
            let signal = waitStatus & 0x7f
            switch signal {
            case 0: self = .exit
            case 11: self = .segv
            case 10: self = .bus
            case 4: self = .ill
            case 6: self = .abrt
            case 5: self = .trap
            case 8: self = .fpe
            case 12: self = .sys
            case 9: self = .kill
            case 15: self = .term
            default: self = .other
            }
        }
    }

    public struct ActiveDay: Sendable, Equatable {
        public var spaces: Int
        public var profiles: Int
        public var pinnedTabs: Int
        public var favorites: Int
        public var openTabs: Int
        public var sidebarPosition: SidebarPosition
        public var isDefaultBrowser: Bool

        public init(spaces: Int, profiles: Int, pinnedTabs: Int, favorites: Int, openTabs: Int,
                    sidebarPosition: SidebarPosition, isDefaultBrowser: Bool) {
            self.spaces = spaces
            self.profiles = profiles
            self.pinnedTabs = pinnedTabs
            self.favorites = favorites
            self.openTabs = openTabs
            self.sidebarPosition = sidebarPosition
            self.isDefaultBrowser = isDefaultBrowser
        }
    }

    public struct ImportArc: Sendable, Equatable {
        public enum Result: String, Sendable, CaseIterable {
            case success, failed
        }

        public var result: Result
        public var spaces: Int
        /// Pinned tabs, Favorites and Today tabs together.
        public var tabs: Int
        public var profiles: Int
        public var logins: Bool

        public init(result: Result, spaces: Int, tabs: Int, profiles: Int, logins: Bool) {
            self.result = result
            self.spaces = spaces
            self.tabs = tabs
            self.profiles = profiles
            self.logins = logins
        }
    }

    public struct PerfDaily: Sendable, Equatable {
        /// Command Bar openings measured (each one's main-thread work up to its first committed frame).
        public var commandBarOpens: Int
        public var commandBarP50Milliseconds: Double?
        public var commandBarP95Milliseconds: Double?
        /// The browser process's memory footprint when the event is recorded.
        public var memoryMegabytes: Double?
        /// The browser process's CPU while Airc was in the background (spans of a minute or more).
        public var idleCPUPercent: Double?

        public init(commandBarOpens: Int, commandBarP50Milliseconds: Double?, commandBarP95Milliseconds: Double?,
                    memoryMegabytes: Double?, idleCPUPercent: Double?) {
            self.commandBarOpens = commandBarOpens
            self.commandBarP50Milliseconds = commandBarP50Milliseconds
            self.commandBarP95Milliseconds = commandBarP95Milliseconds
            self.memoryMegabytes = memoryMegabytes
            self.idleCPUPercent = idleCPUPercent
        }
    }

    /// The event's name in PostHog.
    public var name: String {
        switch self {
        case .appLaunched: "app.launched"
        case .activeDay: "app.active_day"
        case .onboardingStep: "onboarding.step"
        case .onboardingFinished: "onboarding.finished"
        case .importArc: "import.arc"
        case .featureUsed: "feature.used"
        case .perfDaily: "perf.daily"
        case .processGone: "process.gone"
        }
    }

    /// The event's own properties (the super properties are added when it is recorded).
    public var properties: [String: TelemetryValue] {
        switch self {
        case let .appLaunched(ms, first, previous):
            return ["launch_ms": .string(TelemetryBucket.launchMilliseconds(ms)), "first_launch": .bool(first),
                    "previous_exit": .string(previous.rawValue)]
        case let .activeDay(d):
            return ["spaces": .string(TelemetryBucket.count(d.spaces)), "profiles": .string(TelemetryBucket.count(d.profiles)),
                    "pinned_tabs": .string(TelemetryBucket.count(d.pinnedTabs)),
                    "favorites": .string(TelemetryBucket.count(d.favorites)),
                    "open_tabs": .string(TelemetryBucket.count(d.openTabs)),
                    "sidebar_position": .string(d.sidebarPosition.rawValue), "default_browser": .bool(d.isDefaultBrowser)]
        case let .onboardingStep(step, action):
            return ["step": .string(step.rawValue), "action": .string(action.rawValue)]
        case let .onboardingFinished(imported):
            return ["imported": .bool(imported)]
        case let .importArc(i):
            return ["result": .string(i.result.rawValue), "spaces": .string(TelemetryBucket.count(i.spaces)),
                    "tabs": .string(TelemetryBucket.count(i.tabs)), "profiles": .string(TelemetryBucket.count(i.profiles)),
                    "logins": .bool(i.logins)]
        case let .featureUsed(f):
            var p: [String: TelemetryValue] = ["feature": .string(f.name)]
            if let v = f.variant { p["variant"] = .string(v) }
            return p
        case let .perfDaily(d):
            var p: [String: TelemetryValue] = ["command_bar_opens": .string(TelemetryBucket.count(d.commandBarOpens))]
            if let v = d.commandBarP50Milliseconds { p["command_bar_p50_ms"] = .string(TelemetryBucket.frameMilliseconds(v)) }
            if let v = d.commandBarP95Milliseconds { p["command_bar_p95_ms"] = .string(TelemetryBucket.frameMilliseconds(v)) }
            if let v = d.memoryMegabytes { p["memory_mb"] = .string(TelemetryBucket.megabytes(v)) }
            if let v = d.idleCPUPercent { p["idle_cpu_pct"] = .string(TelemetryBucket.percent(v)) }
            return p
        case let .processGone(process, exit):
            return ["process": .string(process.rawValue), "exit_signal": .string(exit.rawValue)]
        }
    }
}

/// `feature.used`: closed feature names, each with at most a closed variant (T3 Code's FeatureUsage idea). A feature
/// is counted where the person starts it, at one dispatch point, never per frame or per keystroke.
public enum TelemetryFeature: Sendable, Equatable {
    /// ⌘T (new tab) or ⌘L / a click on the URL field (edit URL).
    case commandBar(CommandBarEntry)
    /// A split made of 2, 3 or 4 panes (more count as 4).
    case splitCreate(panes: Int)
    case splitPin
    case splitFavorite
    case peekOpen
    case peekPromote
    /// ⌥⌘N (shortcut) or a link from another app (link).
    case littleArcOpen(LittleArcSource)
    case pictureInPicture(PictureInPictureKind)
    case spaceCreate
    case profileCreate
    case favoriteAdd
    case airTrafficRuleAdd
    case find
    case historyMenu(HistoryDirection)
    case downloadStarted
    case downloadCompleted
    case siteControlsOpened
    case defaultBrowser(DefaultBrowserAction)
    /// Count only: never which extension.
    case extensionInstalled
    /// The app launched on a newer build than last time on this data folder.
    case updateInstalled
    case themeChanged
    /// Live Calendar turned on (Settings or the Calendar Favorite's invitation), and a meeting joined from it. Never
    /// which meeting, its link or its time.
    case calendarEnable
    case calendarJoin
    /// The sidebar's "New Airc Version Available" button appeared for a downloaded update, and was clicked (restart now).
    case updateReadyShown
    case updateRestartClicked
    /// A Boost changed in the editor (once per editing session). Never the site, its style or its code.
    case boostSaved
    /// A private window opened (⇧⌘N). Nothing about its pages, ever.
    case privateWindowOpen
    /// The one manual smoke event that checks a new key end to end.
    case telemetrySmoke

    public enum CommandBarEntry: String, Sendable, CaseIterable {
        case newTab = "new_tab", editURL = "edit_url"
    }

    public enum LittleArcSource: String, Sendable, CaseIterable {
        case shortcut, link
    }

    public enum PictureInPictureKind: String, Sendable, CaseIterable {
        case video, call, document
    }

    public enum HistoryDirection: String, Sendable, CaseIterable {
        case back, forward
    }

    public enum DefaultBrowserAction: String, Sendable, CaseIterable {
        case shown, accepted, declined
    }

    /// The `feature` property.
    public var name: String {
        switch self {
        case .commandBar: "command_bar.open"
        case .splitCreate: "split.create"
        case .splitPin: "split.pin"
        case .splitFavorite: "split.favorite"
        case .peekOpen: "peek.open"
        case .peekPromote: "peek.promote"
        case .littleArcOpen: "little_arc.open"
        case .pictureInPicture: "pip.open"
        case .spaceCreate: "space.create"
        case .profileCreate: "profile.create"
        case .favoriteAdd: "favorite.add"
        case .airTrafficRuleAdd: "air_traffic.rule_add"
        case .find: "find.open"
        case .historyMenu: "history_menu.open"
        case .downloadStarted: "download.start"
        case .downloadCompleted: "download.complete"
        case .siteControlsOpened: "site_controls.open"
        case .defaultBrowser: "default_browser.prompt"
        case .extensionInstalled: "extension.install"
        case .updateInstalled: "update.install"
        case .themeChanged: "theme.change"
        case .calendarEnable: "calendar.enable"
        case .calendarJoin: "calendar.join"
        case .updateReadyShown: "update.ready_shown"
        case .updateRestartClicked: "update.restart_clicked"
        case .boostSaved: "boost.save"
        case .privateWindowOpen: "private_window.open"
        case .telemetrySmoke: "telemetry.smoke"
        }
    }

    /// The `variant` property, if the feature has one.
    public var variant: String? {
        switch self {
        case let .commandBar(e): e.rawValue
        case let .splitCreate(n): n <= 2 ? "2" : n == 3 ? "3" : "4"
        case let .littleArcOpen(s): s.rawValue
        case let .pictureInPicture(k): k.rawValue
        case let .historyMenu(d): d.rawValue
        case let .defaultBrowser(a): a.rawValue
        default: nil
        }
    }
}

/// A property value: a closed string (an enum's raw value or a bucket label) or a flag. Crash reports (CrashReport)
/// also need numbers, lists and objects for PostHog's `$exception_list` and `$debug_images`; product events never use them.
public enum TelemetryValue: Sendable, Equatable, Codable, CustomStringConvertible {
    case string(String)
    case bool(Bool)
    case int(Int)
    case list([TelemetryValue])
    case object([String: TelemetryValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let l = try? c.decode([TelemetryValue].self) {
            self = .list(l)
        } else {
            self = .object(try c.decode([String: TelemetryValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .bool(b): try c.encode(b)
        case let .int(i): try c.encode(i)
        case let .list(l): try c.encode(l)
        case let .object(o): try c.encode(o)
        }
    }

    public var description: String {
        switch self {
        case let .string(s): s
        case let .bool(b): b ? "true" : "false"
        case let .int(i): String(i)
        case let .list(l): "[" + l.map(\.description).joined(separator: ", ") + "]"
        case let .object(o): "{" + o.keys.sorted().map { "\($0): \(o[$0]!.description)" }.joined(separator: ", ") + "}"
        }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// E15 (Arc's App Icon pane, "Play user interface sounds" and its tab-reordering haptics switch): the person's
/// choices, kept with the app's settings. A value this build doesn't know (a newer build's icon) reads as the default.
public struct PersonalizationPreferences: Codable, Equatable, Sendable {
    /// The Dock and app-switcher icon. Original Airc artwork only (assets/brand).
    public enum AppIcon: String, Codable, CaseIterable, Sendable {
        /// The app icon: the mark with its holographic ring.
        case holographic
        /// The outline mark on white (assets/brand/airc-outline-squircle).
        case outline
        /// The same icon recoloured (assets/brand/alticons.py): a warm ring of coral, peach and gold.
        case sunset
        /// Blues and teals.
        case ocean
        /// A night-blue face with a white mark, the holographic ring around it.
        case midnight
        /// Monochrome: greys only.
        case graphite

        public var title: String {
            switch self {
            case .holographic: "Holographic"
            case .outline: "Outline"
            case .sunset: "Sunset"
            case .ocean: "Ocean"
            case .midnight: "Midnight"
            case .graphite: "Graphite"
            }
        }

        /// The .icns in the app's Resources (assets/brand/app-icons); nil for the app's own icon.
        public var resourceName: String? { self == .holographic ? nil : "AppIcon-" + rawValue }

        public init(from decoder: Decoder) throws {
            self = (try? AppIcon(rawValue: decoder.singleValueContainer().decode(String.self))) ?? .holographic
        }
    }

    public var appIcon: AppIcon = .holographic
    /// Airc's own sounds (the alert when it can't do something). Off: none at all.
    public var playsSounds = true
    /// Arc's "Haptic feedback when reordering tabs" (on, as Arc's): the trackpad's tap on each place a dragged tab
    /// moves to, when it moves on to the next Space, and when a swipe past the first or last Space is far enough.
    public var haptics = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appIcon = (try? c.decodeIfPresent(AppIcon.self, forKey: .appIcon)) ?? .holographic
        playsSounds = (try? c.decodeIfPresent(Bool.self, forKey: .playsSounds)) ?? true
        haptics = (try? c.decodeIfPresent(Bool.self, forKey: .haptics)) ?? true
    }
}

/// E13, Arc's "Automatically update my Arc" (Settings › General › Updates; off unless the person turns it on): with it
/// on, whether a downloaded update may restart Airc now, by itself. Only after 30 minutes without any input on the Mac
/// (HID idle) and never while Airc is in front, in an automated run, or while anything would be interrupted: music or
/// video playing or paused part-way, picture in picture, a call or screen sharing, a download, a page still loading or
/// sending, a page that would ask "Leave site?" or has changed form fields, a Developer Mode page, a private window
/// with pages (its session goes with the restart) or a sheet or dialog.
public struct IdleUpdatePolicy: Equatable, Sendable {
    /// How long the Mac has had no input from the person.
    public static let requiredIdle: TimeInterval = 30 * 60

    public enum Blocker: String, CaseIterable, Sendable {
        case turnedOff, automated, notReady, active, recentInput, media, pictureInPicture, call, screenSharing, downloads,
             loading, leaveSite, editedForms, developerMode, privateWindows, dialog,
             /// A page didn't say what it holds in time (a long script, a hung renderer): it might have typed text.
             unanswered
    }

    public var enabled = false
    /// A scripted run, a test harness switch, an automated launch: never.
    public var automated = false
    public var updateReady = false
    public var appActive = false
    /// Seconds since the last keyboard, mouse or trackpad input (the HID system's idle time).
    public var idleSeconds: TimeInterval = 0
    public var playing = false
    public var pausedMedia = false
    public var pictureInPicture = false
    public var call = false
    public var screenSharing = false
    public var downloads = 0
    public var loading = 0
    public var leaveSite = 0
    public var editedForms = 0
    public var developerMode = 0
    /// Pages that didn't answer what a restart would interrupt.
    public var unanswered = 0
    public var privateWindowsWithPages = false
    public var dialogOpen = false

    public init() {}

    /// Everything that keeps the restart waiting now, in this order; empty: restart.
    public var blockers: [Blocker] {
        var out: [Blocker] = []
        if !enabled { out.append(.turnedOff) }
        if automated { out.append(.automated) }
        if !updateReady { out.append(.notReady) }
        if appActive { out.append(.active) }
        if idleSeconds < Self.requiredIdle { out.append(.recentInput) }
        if playing || pausedMedia { out.append(.media) }
        if pictureInPicture { out.append(.pictureInPicture) }
        if call { out.append(.call) }
        if screenSharing { out.append(.screenSharing) }
        if downloads > 0 { out.append(.downloads) }
        if loading > 0 { out.append(.loading) }
        if leaveSite > 0 { out.append(.leaveSite) }
        if editedForms > 0 { out.append(.editedForms) }
        if developerMode > 0 { out.append(.developerMode) }
        if privateWindowsWithPages { out.append(.privateWindows) }
        if dialogOpen { out.append(.dialog) }
        if unanswered > 0 { out.append(.unanswered) }
        return out
    }

    /// The reasons that need no page to be asked: when one holds, the pages aren't asked at all.
    public var cheapBlockers: [Blocker] {
        blockers.filter { [.turnedOff, .automated, .notReady, .active, .recentInput, .privateWindows, .dialog].contains($0) }
    }

    public var restartsNow: Bool { blockers.isEmpty }
}

/// E12, Settings › General › "When Airc starts" (Arc: "When opening Arc, restore windows from previous session", on).
/// Only *what* the launch's first windows are; when they open is the launch's own business.
public enum StartupWindows: String, Codable, CaseIterable, Sendable {
    /// The windows from last time, each with its Space, tab, split, frame and sidebar (WIN-7). Airc's behaviour before
    /// the choice existed, so the default.
    case lastSession
    /// One new window on the Space used last, no tab open. Pinned tabs, Favorites and the Today list are still there:
    /// they're the sidebar's, not the window's.
    case newWindow

    public var title: String {
        switch self {
        case .lastSession: "Open my windows and tabs from last time"
        case .newWindow: "Open a new window"
        }
    }

    public init(from decoder: Decoder) throws {
        self = (try? StartupWindows(rawValue: decoder.singleValueContainer().decode(String.self))) ?? .lastSession
    }
}

/// How the last run ended, as the store's device-local "session.exit" mark says: "running" from the launch's first
/// windows until a quit is accepted, "clean" after it, "restart" when Airc quit to restart itself (an update).
public enum PreviousExit: String, Sendable {
    case clean, running, restart

    /// No mark (a first launch, or the build before the mark existed): as a crash, so nothing is lost.
    public init(mark: String?) { self = mark.flatMap(PreviousExit.init(rawValue:)) ?? .running }

    /// The last run crashed, was force-quit or lost power: it never accepted a quit.
    public var crashed: Bool { self == .running }
}

public enum LaunchRestore {
    /// Whether the launch brings back the last session's windows. "Open a new window" still does after a crash or a
    /// restart Airc did itself (an update), as Arc does: only a quit the person chose starts fresh.
    public static func restoresLastSession(_ choice: StartupWindows, previous: PreviousExit) -> Bool {
        choice == .lastSession || previous != .clean
    }

    /// The mark an accepted quit leaves: a restart Airc asked for stays one.
    public static func markOnQuit(current: PreviousExit) -> PreviousExit { current == .restart ? .restart : .clean }
}

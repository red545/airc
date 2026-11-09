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

        public var title: String {
            switch self {
            case .holographic: "Holographic"
            case .outline: "Outline"
            }
        }

        public init(from decoder: Decoder) throws {
            self = (try? AppIcon(rawValue: decoder.singleValueContainer().decode(String.self))) ?? .holographic
        }
    }

    public var appIcon: AppIcon = .holographic
    /// Airc's own sounds (the alert when it can't do something). Off: none at all.
    public var playsSounds = true
    /// The trackpad's tap when a dragged tab moves on to the next Space or a swipe past the first or last Space is
    /// far enough.
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
             loading, leaveSite, editedForms, developerMode, privateWindows, dialog
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
        return out
    }

    /// The reasons that need no page to be asked: when one holds, the pages aren't asked at all.
    public var cheapBlockers: [Blocker] {
        blockers.filter { [.turnedOff, .automated, .notReady, .active, .recentInput, .privateWindows, .dialog].contains($0) }
    }

    public var restartsNow: Bool { blockers.isEmpty }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AVFoundation
import CoreGraphics
import CoreLocation

/// macOS's own say over Airc (System Settings → Privacy & Security): a site allowed to use the camera, the microphone or
/// the location, or one that asked to share the screen, still gets nothing while macOS denies Airc. Site Controls says so
/// with a button to the right pane. Only reads the state: asking would put macOS's prompt in front of the person.
enum SystemPrivacy {
    enum Kind: String, CaseIterable {
        case camera, microphone, location, screen

        /// The pane in System Settings → Privacy & Security.
        var settingsURL: URL {
            let pane = switch self {
            case .camera: "Privacy_Camera"
            case .microphone: "Privacy_Microphone"
            case .location: "Privacy_LocationServices"
            case .screen: "Privacy_ScreenCapture"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        }

        /// The site permission the panel lists for it (screen sharing has none: Chromium asks with its picker).
        var permission: SitePermission? {
            switch self {
            case .camera: .camera
            case .microphone: .microphone
            case .location: .location
            case .screen: nil
            }
        }

        /// "Camera is off for Airc".
        var offText: String {
            switch self {
            case .camera: "Camera is off for Airc"
            case .microphone: "Microphone is off for Airc"
            case .location: "Location is off for Airc"
            case .screen: "Screen recording is off for Airc"
            }
        }
    }

    enum Status: String { case granted, denied, restricted, notDetermined }

    /// What macOS says now. Screen recording can only say granted or not (CGPreflightScreenCaptureAccess); not yet
    /// granted reads as denied, which is what a site wanting to share the screen meets.
    static func status(_ kind: Kind) -> Status {
        #if AIRC_TESTING
        if let s = overrides[kind] { return s }
        #endif
        switch kind {
        case .camera: return status(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone: return status(AVCaptureDevice.authorizationStatus(for: .audio))
        case .location:
            switch locationManager.authorizationStatus {
            case .authorizedAlways: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            default: return .notDetermined
            }
        case .screen: return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }

    /// macOS keeps it from Airc (the person said no, or a policy).
    static func blocks(_ kind: Kind) -> Bool { [.denied, .restricted].contains(status(kind)) }

    /// Opens the kind's pane in System Settings. Scripted runs only note the address (System Settings would come to the
    /// front on the owner's Mac).
    static func openSettings(_ kind: Kind) {
        #if AIRC_TESTING
        opened.append(kind.settingsURL)
        if LaunchOptions.current.isAutomated { return }
        #endif
        NSWorkspace.shared.open(kind.settingsURL)
    }

    private static func status(_ s: AVAuthorizationStatus) -> Status {
        switch s {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }

    /// Made once and never asked to start (that is what would prompt).
    private static let locationManager = CLLocationManager()

    #if AIRC_TESTING
    /// A check's stand-in for macOS's answers: `AIRC_TEST_SYSTEM_PRIVACY=camera=denied,location=restricted` at launch,
    /// or set directly. Never a real prompt.
    static var overrides: [Kind: Status] = {
        var o: [Kind: Status] = [:]
        for pair in (ProcessInfo.processInfo.environment["AIRC_TEST_SYSTEM_PRIVACY"] ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=").map(String.init)
            if kv.count == 2, let k = Kind(rawValue: kv[0]), let s = Status(rawValue: kv[1]) { o[k] = s }
        }
        return o
    }()
    /// The panes asked for in this run.
    static var opened: [URL] = []
    #endif
}

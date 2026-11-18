// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import Combine

/// darkfix: Airc's own appearance, Settings › Appearance › Airc (AppSettings.Values.appearance).
///
/// - Auto: `NSApp.appearance = nil`, so the app follows macOS (and its Auto switch at sunset and sunrise).
/// - Light / Dark: `NSApp.appearance` is aqua / darkAqua.
///
/// Everything that draws light or dark reads `NSApp.effectiveAppearance`: windows and the sidebar (a Space on Auto
/// follows it, WindowController.systemDark), Settings, menus, Little Airc, Peek, and pages (PageColorScheme and
/// ThemePagePalette observe it). So one assignment changes all of it at once, live, without a relaunch. A Space's own
/// Light or Dark (Edit Theme Color…) still wins for that Space's window and pages.
enum AppAppearance {
    /// Test hook (`--script darkfix`): what macOS's own appearance is, as the app sees it, so a check can play a dark
    /// Mac without touching the Mac's real setting. nil: the real one.
    static var simulatedSystem: Bool?
    private static var subscription: AnyCancellable?
    /// What was applied last, for the check's log.
    private(set) static var applied: Appearance = .auto

    /// Applies the setting now and whenever it changes (Settings, onboarding, or another Mac through sync), and
    /// redraws every window's chrome when the effective appearance flips (macOS's Auto switch or this setting).
    static func start(app: AppDelegate) {
        let settings = app.settings!
        apply(settings.values.appearance)
        lastDark = isDark
        subscription = settings.$values.map(\.appearance).removeDuplicates().dropFirst().sink { a in
            // @Published sends before the value is stored; the next turn reads it settled, like other observers.
            DispatchQueue.main.async { apply(a) }
        }
        // Pages follow by themselves (PageColorScheme, ThemePagePalette); the sidebar, window colour, Command Bar and
        // Little Airc drew their palette once and only redrew on a store change, so a flip left them stale.
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak app] _, _ in
            DispatchQueue.main.async {
                guard let app, isDark != lastDark else { return }
                lastDark = isDark
                redraws += 1
                app.controllers.forEach { $0.reloadAll(animated: false) }
                app.littleArcs.forEach { $0.refreshChrome() }
            }
        }
    }

    private static var observation: NSKeyValueObservation?
    private static var lastDark = false
    /// How many appearance flips redrew the windows (the check's log).
    private(set) static var redraws = 0
    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    static func apply(_ appearance: Appearance) {
        applied = appearance
        let name: NSAppearance.Name? = switch appearance {
        case .light: .aqua
        case .dark: .darkAqua
        case .auto: simulatedSystem.map { $0 ? .darkAqua : .aqua }
        }
        let target = name.flatMap(NSAppearance.init(named:))
        if NSApp.appearance?.name == target?.name { return }
        NSApp.appearance = target
    }
}

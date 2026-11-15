// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// E15 (Arc's App Icon pane, "Play Arc sound effects" and "Haptic feedback when reordering tabs"):
///   - App Icon (Settings › Appearance): six of Airc's own icons (assets/brand: the holographic one, and alticons.py's
///     recolourings in app-icons/*.icns), never another app's art. While Airc runs, `NSApp.applicationIconImage` (Dock,
///     app switcher); for the Finder and a Dock that shows Airc not running, the bundle's custom icon (`applyBundleIcon`).
///     macOS 26 has no alternate-icon API outside UIKit.
///   - Play Airc sound effects (Settings › General): off, Airc makes no sound of its own. Every `NSSound.beep()` in this module comes through here (a
///     member declared in this module shadows AppKit's), so no call site needs to know.
///   - Haptic feedback when reordering tabs (Settings › General; on, as Arc's): a tap on each place a dragged tab moves
///     to (`reorderStep`, prefs); off, `NSHapticFeedbackManager.defaultPerformer` (shadowed the same way) taps nothing.
///   - When Airc starts (Settings › General, E12): AircKit's `StartupWindows`, read by `restoreWindows`
///     (Browser/MultiWindow.swift).
enum AppPersonalization {
    private static weak var settings: AppSettings?
    /// Beeps that sound effects off kept quiet (the P21b check counts them).
    private(set) static var silencedBeeps = 0

    #if AIRC_TESTING
    /// The check's stand-in for the Mac's alert sound: counted, never heard.
    static var testBeep: (() -> Void)?
    /// The check's stand-in for the trackpad (parityprefs): records the taps haptic feedback on lets through.
    static var testHapticPerformer: NSHapticFeedbackPerformer?
    /// Every `-[NSSound play]` in the process (parityprefs; the probe is installed in test builds only).
    private(set) static var soundPlays = 0
    static func installSoundProbe() {
        guard !soundProbeInstalled, let a = class_getInstanceMethod(NSSound.self, #selector(NSSound.play)),
              let b = class_getInstanceMethod(NSSound.self, #selector(NSSound.airc_probedPlay)) else { return }
        method_exchangeImplementations(a, b)
        soundProbeInstalled = true
    }
    private static var soundProbeInstalled = false
    fileprivate static func soundPlayed() { soundPlays += 1 }
    #endif

    /// From MainMenu.build, once the settings are read: the chosen icon goes up at once; the Finder's a little later.
    static func attach(settings: AppSettings) {
        self.settings = settings
        applyIcon(bundle: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { applyBundleIcon() }
    }

    static var preferences: PersonalizationPreferences { settings?.values.personalization ?? PersonalizationPreferences() }

    static func update(_ change: (inout PersonalizationPreferences) -> Void) {
        guard let settings else { return }
        var p = settings.values.personalization
        change(&p)
        guard p != settings.values.personalization else { return }
        let iconChanged = p.appIcon != settings.values.personalization.appIcon
        settings.values.personalization = p
        if iconChanged { applyIcon(bundle: true) }
    }

    // MARK: The icon

    /// The icons this build has the artwork for: the app's own always, each other one when the bundle has its .icns
    /// (assets/brand/app-icons: Airc's own icon recoloured by alticons.py, never another app's art).
    static var availableIcons: [PersonalizationPreferences.AppIcon] {
        PersonalizationPreferences.AppIcon.allCases.filter { $0 == .holographic || image(for: $0) != nil }
    }

    /// The icon as the Dock shows it; the app's own for the default.
    static func image(for icon: PersonalizationPreferences.AppIcon) -> NSImage? {
        guard let name = icon.resourceName else { return AppIconImage.image }
        if let cached = images[icon] { return cached }
        let image = Bundle.main.url(forResource: name, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
        images[icon] = image
        return image
    }
    private static var images: [PersonalizationPreferences.AppIcon: NSImage?] = [:]

    static func applyIcon(bundle: Bool) {
        // nil gives the Dock the bundle's own icon back.
        let icon = preferences.appIcon
        NSApp.applicationIconImage = icon == .holographic ? nil : image(for: icon)
        if bundle { DispatchQueue.main.async { applyBundleIcon() } }
    }

    /// Scripted runs leave their test bundle alone unless a check asks.
    static var writesBundleIcon = !LaunchOptions.current.isAutomated
    /// The last bundle write failed (an app folder Airc can't write to, a translocated copy): Settings says so.
    private(set) static var bundleIconFailed = false
    private static let bundleIconKey = "AircBundleIcon"

    static var bundleHasCustomIcon: Bool {
        FileManager.default.fileExists(atPath: (Bundle.main.bundlePath as NSString).appendingPathComponent("Icon\r"))
    }

    /// The Finder's (and a quit Dock's) icon: the bundle's custom icon (`NSWorkspace.setIcon`, as Arc does), set for any
    /// icon but Holographic and taken off for it. It sits outside the code signature's seal: `codesign --verify --deep`
    /// and SecStaticCodeCheckValidity (Sparkle's check) still pass (artifacts/prefsicons). An update brings a bundle
    /// without it, so the next launch puts it on again.
    @discardableResult
    static func applyBundleIcon() -> Bool {
        guard writesBundleIcon else { return false }
        let path = Bundle.main.bundlePath, icon = preferences.appIcon, has = bundleHasCustomIcon
        let done: Bool
        if icon == .holographic {
            done = !has || NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
            if done { UserDefaults.standard.removeObject(forKey: bundleIconKey) }
        } else if has, UserDefaults.standard.string(forKey: bundleIconKey) == icon.rawValue {
            done = true
        } else if let image = image(for: icon), NSWorkspace.shared.setIcon(image, forFile: path, options: []) {
            UserDefaults.standard.set(icon.rawValue, forKey: bundleIconKey)
            done = true
        } else {
            done = false
        }
        bundleIconFailed = !done
        return done
    }

    // MARK: Sounds and haptics

    /// The Mac's alert sound, or nothing while sound effects are off.
    static func beep() {
        guard preferences.playsSounds else { silencedBeeps += 1; return }
        #if AIRC_TESTING
        if let t = testBeep { return t() }
        #endif
        systemBeep?()
    }

    /// A sound of Airc's own, unless sound effects are off (today Airc's only sound is the alert above; anything that
    /// plays an NSSound goes through here).
    @discardableResult
    static func play(_ sound: NSSound?) -> Bool {
        guard preferences.playsSounds, let sound else { silencedBeeps += 1; return false }
        return sound.play()
    }

    /// AppKit's NSBeep (Swift sees it only as NSSound.beep(), which this module shadows).
    private static let systemBeep: (@convention(c) () -> Void)? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSBeep")
        .map { unsafeBitCast($0, to: (@convention(c) () -> Void).self) }

    static var haptics: Bool { preferences.haptics }

    /// Places a dragged tab moved to (parityprefs counts them, on or off).
    private(set) static var reorderSteps = 0

    /// A dragged tab (or selection) moved to another place in the sidebar: one tap, as Arc's.
    static func reorderStep() {
        reorderSteps += 1
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// The trackpad's performer (read past the shadow below).
    static var systemHapticPerformer: NSHapticFeedbackPerformer? {
        #if AIRC_TESTING
        if let t = testHapticPerformer { return t }
        #endif
        return (NSHapticFeedbackManager.self as AnyObject).value(forKey: "defaultPerformer") as? NSHapticFeedbackPerformer
    }

    /// Taps nothing (haptic feedback off).
    final class SilentHaptics: NSObject, NSHapticFeedbackPerformer {
        static let shared = SilentHaptics()
        private(set) var skipped = 0
        func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern, performanceTime: NSHapticFeedbackManager.PerformanceTime) { skipped += 1 }
    }
}

#if AIRC_TESTING
extension NSSound {
    /// Exchanged with `play` by `installSoundProbe`: counts, then plays (this method's body is AppKit's play by then).
    @objc func airc_probedPlay() -> Bool {
        AppPersonalization.soundPlayed()
        return airc_probedPlay()
    }
}
#endif

extension NSSound {
    /// Airc's beep: the Mac's alert sound unless Settings › General › Play Airc sound effects is off (AppPersonalization).
    static func beep() { AppPersonalization.beep() }
}

extension NSHapticFeedbackManager {
    /// The trackpad's taps, or none while Settings › General's haptic feedback is off (AppPersonalization).
    static var defaultPerformer: NSHapticFeedbackPerformer {
        AppPersonalization.haptics ? AppPersonalization.systemHapticPerformer ?? AppPersonalization.SilentHaptics.shared
            : AppPersonalization.SilentHaptics.shared
    }
}

// MARK: - Settings

/// Settings › Appearance › App Icon.
struct AppIconSettingsSection: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.aircTheme) private var theme

    var body: some View {
        SettingsSection(title: "App Icon", help: "The icon in the Dock, the app switcher and the Finder. All of them are Airc’s own.") {
            HStack(spacing: 8) {   // six 84-pt tiles fit the pane in one row
                ForEach(AppPersonalization.availableIcons, id: \.self) { icon in
                    let on = model.settings.values.personalization.appIcon == icon
                    VStack(spacing: 6) {
                        Image(nsImage: AppPersonalization.image(for: icon) ?? NSImage()).resizable().interpolation(.high)
                            .frame(width: 56, height: 56)
                        Text(icon.title).aircFont(AircFont.caption).foregroundStyle(on ? theme.surfaceText.color : theme.surfaceTextSecondary.color)
                            .lineLimit(1)
                    }
                    .frame(width: 84)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? theme.accent.color.opacity(0.14) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? theme.accent.color : Color.clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                    .onTapGesture { AppPersonalization.update { $0.appIcon = icon } }
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityLabel("\(icon.title) app icon")
                    .testAnchor("prefs.icon." + icon.rawValue)
                }
            }
            .padding(.vertical, 6)
            if AppPersonalization.bundleIconFailed, model.settings.values.personalization.appIcon != .holographic {
                Text("The Finder keeps Airc’s usual icon: Airc can’t change its own app in this folder.")
                    .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color)
            }
        }
    }
}

/// Settings › General › When Airc starts (E12; Arc: "When opening Arc, restore windows from previous session").
struct StartupWindowsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsSection(title: "When Airc starts", help: "After a crash or an update’s restart, your windows always come back.") {
            SettingsRow(title: "Windows") {
                AircPopUp(options: StartupWindows.allCases.map { ($0.title, $0) }, selection: model.settings.values.startupWindows, width: 350) { value in
                    model.settings.values.startupWindows = value
                }
            }
        }
    }
}

/// Settings › General › Sounds and Haptics, in Arc's words ("Play Arc sound effects", "Haptic feedback when reordering
/// tabs", in its General pane).
struct SoundsAndHapticsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsSection(title: "Sounds and Haptics") {
            AircToggleRow("Play Airc sound effects", subtitle: "The alert when Airc can’t do something. Off, Airc makes no sound of its own.",
                          isOn: Binding(get: { model.settings.values.personalization.playsSounds },
                                        set: { on in AppPersonalization.update { $0.playsSounds = on } }))
                .testAnchor("prefs.sounds")
            AircToggleRow("Haptic feedback when reordering tabs",
                          subtitle: "A tap from the trackpad each time a tab you drag moves to a new place, and when a swipe past the first or last Space is far enough.",
                          isOn: Binding(get: { model.settings.values.personalization.haptics },
                                        set: { on in AppPersonalization.update { $0.haptics = on } }))
                .testAnchor("prefs.haptics")
        }
    }
}

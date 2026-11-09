// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// E15 (Arc's App Icon pane, "Play Arc sound effects" and "Haptic feedback when reordering tabs"):
///   - App Icon (Settings › Appearance): the Dock's and the app switcher's icon while Airc runs, from Airc's own artwork
///     (assets/brand). The Finder and a Dock that shows Airc not running keep the app's own icon (a Dock tile plug-in
///     would carry it there).
///   - Play Airc sound effects (Settings › General): off, Airc makes no sound of its own. Every `NSSound.beep()` in this module comes through here (a
///     member declared in this module shadows AppKit's), so no call site needs to know.
///   - Haptic feedback when reordering tabs (Settings › General): off, `NSHapticFeedbackManager.defaultPerformer`
///     (shadowed the same way) taps nothing.
enum AppPersonalization {
    private static weak var settings: AppSettings?
    /// Beeps that sound effects off kept quiet (the P21b check counts them).
    private(set) static var silencedBeeps = 0

    #if AIRC_TESTING
    /// The check's stand-in for the Mac's alert sound: counted, never heard.
    static var testBeep: (() -> Void)?
    #endif

    /// From MainMenu.build, once the settings are read: the chosen icon goes up at once.
    static func attach(settings: AppSettings) {
        self.settings = settings
        applyIcon()
    }

    static var preferences: PersonalizationPreferences { settings?.values.personalization ?? PersonalizationPreferences() }

    static func update(_ change: (inout PersonalizationPreferences) -> Void) {
        guard let settings else { return }
        var p = settings.values.personalization
        change(&p)
        guard p != settings.values.personalization else { return }
        let iconChanged = p.appIcon != settings.values.personalization.appIcon
        settings.values.personalization = p
        if iconChanged { applyIcon() }
    }

    // MARK: The icon

    /// The icons this build has the artwork for: the app's own always, the outline one when the bundle has its art.
    static var availableIcons: [PersonalizationPreferences.AppIcon] {
        PersonalizationPreferences.AppIcon.allCases.filter { $0 == .holographic || image(for: $0) != nil }
    }

    /// The icon as the Dock shows it; the app's own for the default.
    static func image(for icon: PersonalizationPreferences.AppIcon) -> NSImage? {
        switch icon {
        case .holographic: return AppIconImage.image
        case .outline: return outlineIcon
        }
    }

    /// The outline mark on white (assets/brand/airc-outline-squircle.png, copied into the bundle as AppIconOutline), on
    /// the macOS icon grid: an 824-pt body in a 1024-pt canvas, its own outline just inside the body's edge, a soft
    /// shadow under it. Drawn once into a 1024-pixel bitmap: a shadow's blur and offset ignore the drawing's scale, so
    /// an icon drawn at the Dock's size (or a 56-pt tile) would get a shadow as big as itself.
    private static let outlineIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIconOutline", withExtension: "png"), let art = NSImage(contentsOf: url),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor.white.setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()
        body.addClip()
        // The art's squircle spans about 915 of its 1024 px: drawn so it lies 6 pt inside the body.
        let side = 1024 * (812.0 / 915.0)
        art.draw(in: NSRect(x: 512 - side / 2, y: 512 - side / 2, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }()

    static func applyIcon() {
        // nil gives the Dock the bundle's own icon back.
        let icon = preferences.appIcon
        NSApp.applicationIconImage = icon == .holographic ? nil : image(for: icon)
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

    /// AppKit's NSBeep (Swift sees it only as NSSound.beep(), which this module shadows).
    private static let systemBeep: (@convention(c) () -> Void)? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSBeep")
        .map { unsafeBitCast($0, to: (@convention(c) () -> Void).self) }

    static var haptics: Bool { preferences.haptics }

    /// The trackpad's performer (read past the shadow below).
    static var systemHapticPerformer: NSHapticFeedbackPerformer? {
        (NSHapticFeedbackManager.self as AnyObject).value(forKey: "defaultPerformer") as? NSHapticFeedbackPerformer
    }

    /// Taps nothing (haptic feedback off).
    final class SilentHaptics: NSObject, NSHapticFeedbackPerformer {
        static let shared = SilentHaptics()
        private(set) var skipped = 0
        func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern, performanceTime: NSHapticFeedbackManager.PerformanceTime) { skipped += 1 }
    }
}

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
        SettingsSection(title: "App Icon", help: "The icon in the Dock and the app switcher while Airc is open.") {
            HStack(spacing: 14) {
                ForEach(AppPersonalization.availableIcons, id: \.self) { icon in
                    let on = model.settings.values.personalization.appIcon == icon
                    VStack(spacing: 6) {
                        Image(nsImage: AppPersonalization.image(for: icon) ?? NSImage()).resizable().interpolation(.high)
                            .frame(width: 56, height: 56)
                        Text(icon.title).aircFont(AircFont.caption).foregroundStyle(on ? theme.surfaceText.color : theme.surfaceTextSecondary.color)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? theme.accent.color.opacity(0.14) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? theme.accent.color : Color.clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                    .onTapGesture { AppPersonalization.update { $0.appIcon = icon } }
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityLabel("\(icon.title) app icon")
                }
            }
            .padding(.vertical, 6)
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
            AircToggleRow("Haptic feedback when reordering tabs",
                          subtitle: "A tap from the trackpad when a tab you drag moves on to the next Space, and when a swipe past the first or last Space is far enough.",
                          isOn: Binding(get: { model.settings.values.personalization.haptics },
                                        set: { on in AppPersonalization.update { $0.haptics = on } }))
        }
    }
}

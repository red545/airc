// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import SwiftUI

/// P06b (V06), Little Arc from anywhere, as Arc has it ("You make a new search in Little Arc by hitting Command-Option-N
/// from anywhere"; Settings › Links: "Open Little Arc when I press …", "Archive Little Arcs after:"):
///   - A global shortcut (off until turned on; ⌥⌘N, Arc's, by default) opens a Little Arc window from any app, its
///     address field ready; over another app's full screen it opens there, as a link from that app does
///     (LittleArcFullScreen). Registered as a Carbon hot key, as Arc's is: no Accessibility needed. Off: no handler and
///     no hot key at all.
///   - Rebinding checks the key against macOS's own shortcuts, other apps' (another app holding it makes the exclusive
///     registration fail) and Airc's commands (the hot key would take it from them).
///   - "Look up the selected text" (an Airc addition; Arc doesn't): pressing the shortcut with text selected in the app in
///     front searches it. Reading another app's selection needs Accessibility: it's read only when the shortcut is
///     pressed, only if access is granted already; otherwise Little Arc opens empty and says how to allow it. The
///     system's prompt comes only from Settings' "Allow…" button, never on its own and never in scripted runs.
///   - Show Little Arc Windows and Close Little Arc Windows (Arc's commands, and its Dock menu): Close sends each page to
///     its Space's Archive first, as auto-archiving does, so the Library can restore it.
///   - "Archive Little Arcs after:" Arc's choices, 6 hours by default.

/// The settings (settings.json's `littleArcGlobal`).
struct LittleArcGlobalSettings: Codable, Equatable {
    var enabled = false
    var shortcut = GlobalShortcut.littleArcDefault
    /// Search the text selected in the app in front (needs Accessibility).
    var searchesSelection = false
    var archiveAfter = LittleArcArchiveInterval.sixHours
    /// P06d: Arc's "Open Little Arc when clicking on links with ⌥⌘ held", on by default (Browser/LittleArcLinkClicks.swift).
    var opensOptionCommandClicks = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LittleArcGlobalSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        shortcut = (try? c.decodeIfPresent(GlobalShortcut.self, forKey: .shortcut)) ?? d.shortcut
        searchesSelection = (try? c.decodeIfPresent(Bool.self, forKey: .searchesSelection)) ?? d.searchesSelection
        archiveAfter = (try? c.decodeIfPresent(LittleArcArchiveInterval.self, forKey: .archiveAfter)) ?? d.archiveAfter
        opensOptionCommandClicks = (try? c.decodeIfPresent(Bool.self, forKey: .opensOptionCommandClicks)) ?? d.opensOptionCommandClicks
    }
}

/// A global shortcut by its physical key (any keyboard layout) and modifiers, with the character it shows.
struct GlobalShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags.RawValue
    var key: String

    static let littleArcDefault = GlobalShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, key: "n")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift]) }
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
    /// The same key as Airc's commands write it.
    var combo: KeyCombo {
        var m: KeyCombo.Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return KeyCombo(key, m)
    }
    var display: String { combo.display }

    /// A recorded key, if it can be a global shortcut (⌘, ⌥ or ⌃ with it).
    init?(event: NSEvent) {
        guard let combo = ShortcutCenter.typed(event), combo.isValidShortcut else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue,
                  key: combo.key)
    }
    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags.RawValue, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// Arc's "Archive Little Arcs after:" choices (its AutoArchiveInactiveThreshold, without the debug one).
enum LittleArcArchiveInterval: String, Codable, CaseIterable {
    case oneHour, sixHours, twelveHours, oneDay, sevenDays, thirtyDays, never

    var seconds: TimeInterval? {
        switch self {
        case .oneHour: 3600
        case .sixHours: 6 * 3600
        case .twelveHours: 12 * 3600
        case .oneDay: 24 * 3600
        case .sevenDays: 7 * 24 * 3600
        case .thirtyDays: 30 * 24 * 3600
        case .never: nil
        }
    }

    var title: String {
        switch self {
        case .oneHour: "1 hour"
        case .sixHours: "6 hours"
        case .twelveHours: "12 hours"
        case .oneDay: "24 hours"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .never: "Never"
        }
    }
}

// MARK: - The hot key

/// Registers one global hot key. The Carbon one in the app; checks inject their own.
protocol GlobalHotKeyRegistrar: AnyObject {
    /// noErr, or why not (eventHotKeyExistsErr: another app holds the key).
    func register(_ shortcut: GlobalShortcut, handler: @escaping () -> Void) -> OSStatus
    func unregister()
    /// A handler or a hot key is installed.
    var isInstalled: Bool { get }
}

final class CarbonHotKeyRegistrar: GlobalHotKeyRegistrar {
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var callback: (() -> Void)?
    /// 'LARC'.
    static let signature: OSType = 0x4C41_5243

    var isInstalled: Bool { handlerRef != nil || hotKeyRef != nil }

    func register(_ shortcut: GlobalShortcut, handler: @escaping () -> Void) -> OSStatus {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard got == noErr, id.signature == CarbonHotKeyRegistrar.signature else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { me.callback?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { unregister(); return status }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let registered = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(),
                                             OptionBits(kEventHotKeyExclusive), &hotKeyRef)
        guard registered == noErr else { unregister(); return registered }
        callback = handler
        return noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        callback = nil
    }
}

// MARK: - The selected text

/// Another app's selected text, through Accessibility. The app's reads it over AX; checks inject their own.
protocol SelectionReader: AnyObject {
    /// Accessibility is granted already (asking never prompts).
    var isTrusted: Bool { get }
    /// The text selected in the app in front (not Airc), if any and if trusted.
    func selectedText() -> String?
    /// The system's prompt (and Privacy & Security's list): only from Settings' button.
    func requestTrust()
}

final class AXSelectionReader: SelectionReader {
    var isTrusted: Bool { AXIsProcessTrusted() }

    func selectedText() -> String? {
        guard isTrusted, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        // swiftlint:disable:next force_cast
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success else { return nil }
        let text = (selected as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : String(text.prefix(LittleArcGlobalActions.maxSelection))
    }

    func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

// MARK: - The actions

final class LittleArcGlobalActions {
    static let shared = LittleArcGlobalActions()
    /// The selection a lookup takes at most.
    static let maxSelection = 500

    weak var app: AppDelegate?
    var registrar: GlobalHotKeyRegistrar = CarbonHotKeyRegistrar()
    var selection: SelectionReader = AXSelectionReader()
    /// macOS's own shortcuts (the user's symbolic hot keys over the defaults); checks inject theirs.
    var systemShortcuts: () -> [GlobalShortcut] = { LittleArcGlobalActions.macOSShortcuts() }
    /// The full-screen app in front, if any (a Little Arc opens over it); checks inject one.
    var fullScreenSource: () -> pid_t? = { LittleArcFullScreen.shared.takeLinkSource() }
    /// A registrar of its own for trying a key (never the one holding the shortcut); checks inject theirs.
    var makeProbe: () -> GlobalHotKeyRegistrar = { CarbonHotKeyRegistrar() }

    /// Why the shortcut isn't working, or nil when it is (or the feature is off).
    private(set) var problem: Conflict?
    /// The registrar's last status (noErr when registered).
    private(set) var lastStatus: OSStatus = noErr
    /// Hot-key presses handled, and the last one's outcome (the checks read them).
    private(set) var presses = 0
    private(set) var lastLookup: String?
    private(set) var lastNeededAccess = false
    private var observation: AnyCancellable?

    enum Conflict: Equatable {
        /// One of macOS's own shortcuts (Spotlight, input sources, screenshots…).
        case system(String)
        /// Another app registered it.
        case otherApp
        /// An Airc command uses it: the global shortcut would take it from that command.
        case airc(String)
        /// Registration failed otherwise.
        case failed(OSStatus)

        var message: String {
            switch self {
            case .system(let name): "macOS uses this shortcut for \(name). Choose another."
            case .otherApp: "Another app uses this shortcut. Choose another, or change it there."
            case .airc(let title): "Airc’s “\(title)” uses this shortcut; it would open Little Airc instead."
            case .failed(let s): "The shortcut couldn’t be set (error \(s))."
            }
        }
        /// A conflict the person may override (only Airc's own commands).
        var canUseAnyway: Bool { if case .airc = self { true } else { false } }
    }

    var settings: LittleArcGlobalSettings { app?.settings.values.littleArcGlobal ?? LittleArcGlobalSettings() }
    var isInstalled: Bool { registrar.isInstalled }

    /// At launch (from LittleArcFullScreen.install): applies the settings and follows their changes.
    func install(app: AppDelegate) {
        self.app = app
        apply()
        observation = app.settings.$values.map(\.littleArcGlobal).removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.apply() }
        }
    }

    /// The hot key as the settings say (none when off), the archive interval for Little Arc windows.
    func apply() {
        let s = settings
        LittleArcController.archiveAfter = s.archiveAfter.seconds ?? .infinity
        app?.littleArcs.forEach { $0.archiveIntervalChanged() }
        registrar.unregister()
        problem = nil
        lastStatus = noErr
        guard s.enabled else { return }
        if let c = conflict(for: s.shortcut, registering: false), !c.canUseAnyway {
            problem = c
            return
        }
        lastStatus = registrar.register(s.shortcut) { [weak self] in self?.hotKeyPressed() }
        if lastStatus == OSStatus(eventHotKeyExistsErr) {
            problem = .otherApp
        } else if lastStatus != noErr {
            problem = .failed(lastStatus)
        }
    }

    /// What `shortcut` would collide with. `registering`: also try it with the registrar (another app's), then let go.
    func conflict(for shortcut: GlobalShortcut, registering: Bool = true) -> Conflict? {
        if let hit = systemShortcuts().first(where: { $0.keyCode == shortcut.keyCode && $0.flags == shortcut.flags }) {
            return .system(Self.systemNames[hit.key] ?? "a system shortcut")
        }
        if let id = ShortcutCenter.shared.map.command(for: shortcut.combo), id != "file.newLittleArc" {
            return .airc(ShortcutCenter.title(id))
        }
        guard registering, !(settings.enabled && settings.shortcut == shortcut && isInstalled) else { return nil }
        let probe = makeProbe()
        let s = probe.register(shortcut) {}
        probe.unregister()
        if s == OSStatus(eventHotKeyExistsErr) { return .otherApp }
        return s == noErr ? nil : .failed(s)
    }

    /// The shortcut, from any app: a Little Arc window (over the full-screen app in front, if any), searching the
    /// selected text when that's asked for and allowed.
    func hotKeyPressed() {
        presses += 1
        lastLookup = nil
        lastNeededAccess = false
        guard let app else { return }
        var url: URL?
        if settings.searchesSelection {
            if selection.isTrusted, let text = selection.selectedText() {
                lastLookup = text
                let sid = app.controller?.currentSpaceID ?? app.store.selectedSpace.id
                url = URLRules.resolve(text, engine: app.store.profile(ofSpace: sid).searchEngine)
            } else if !selection.isTrusted {
                lastNeededAccess = true
            }
        }
        let l = app.openLittleArc(url: url, overFullScreenOf: fullScreenSource())
        if lastNeededAccess {
            l?.promptToast("To look up the selected text, allow Accessibility in Settings → Links")
        }
    }

    /// The system's Accessibility prompt, from Settings' button only, never in a scripted run.
    @discardableResult
    func requestAccess() -> Bool {
        guard !LaunchOptions.current.isAutomated else { return false }
        selection.requestTrust()
        return true
    }

    // MARK: Show and close all

    /// Arc's "Show Little Arc Windows": every Little Arc window visible (minimized ones back), the last one key.
    func showAll() {
        guard let app else { return }
        let windows = app.littleArcs.filter { !$0.isMiniPlayer }
        for l in windows {
            if l.window.isMiniaturized { l.window.deminiaturize(nil) }
            l.window.orderFront(nil)
        }
        if let last = windows.last, !LaunchOptions.current.isAutomated {
            last.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    /// Arc's "Close Little Arc Windows": each page to its Space's Archive, then the window closes (mini players play on).
    func closeAll() {
        app?.littleArcs.filter { !$0.isMiniPlayer }.forEach { $0.archiveAndClose() }
    }

    var hasLittleArcs: Bool { app?.littleArcs.contains { !$0.isMiniPlayer } == true }

    // MARK: macOS's own shortcuts

    /// The user's symbolic hot keys that are on (com.apple.symbolichotkeys), and the defaults the user hasn't changed.
    static func macOSShortcuts() -> [GlobalShortcut] {
        var byID = defaultSymbolicHotKeys
        if let hot = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") {
            for (key, raw) in hot {
                guard let id = Int(key), let d = raw as? [String: Any] else { continue }
                let enabled = (d["enabled"] as? Bool) ?? ((d["enabled"] as? Int) == 1)
                guard enabled, let value = d["value"] as? [String: Any], let p = value["parameters"] as? [Int], p.count == 3,
                      p[1] != 65535 else { byID[id] = nil; continue }
                let char = p[0] == 65535 ? "" : String(Character(UnicodeScalar(UInt8(clamping: p[0]))))
                byID[id] = GlobalShortcut(keyCode: UInt32(p[1]), modifiers: UInt(p[2]), key: systemNameKey(id) ?? char)
            }
        }
        return Array(byID.values)
    }

    private static func systemNameKey(_ id: Int) -> String? { defaultSymbolicHotKeys[id]?.key }

    /// macOS's defaults for the keys most worth not taking (Spotlight, Finder search, input sources, screenshots).
    static let defaultSymbolicHotKeys: [Int: GlobalShortcut] = [
        64: GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags.command.rawValue, key: "spotlight"),
        65: GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, key: "finder-search"),
        60: GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags.control.rawValue, key: "input-previous"),
        61: GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, key: "input-next"),
        28: GlobalShortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, key: "screenshot"),
        30: GlobalShortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, key: "screenshot-area"),
        184: GlobalShortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, key: "screenshot-options"),
    ]

    static let systemNames: [String: String] = [
        "spotlight": "Spotlight", "finder-search": "the Finder’s search window", "input-previous": "switching input sources",
        "input-next": "switching input sources", "screenshot": "screenshots", "screenshot-area": "screenshots",
        "screenshot-options": "screenshots",
    ]
}

// MARK: - The Dock menu

/// Window › Show Little Arc Windows and Close Little Arc Windows (Arc's), enabled while there are Little Arc windows.
final class LittleArcWindowsMenuItem: NSMenuItem, NSMenuItemValidation {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { LittleArcGlobalActions.shared.hasLittleArcs }
}

extension LittleArcGlobalActions {
    /// The Window menu's two (Commands.swift).
    static func windowMenuItems() -> [NSMenuItem] {
        [LittleArcWindowsMenuItem("Show Little Airc Windows") { shared.showAll() },
         LittleArcWindowsMenuItem("Close Little Airc Windows") { shared.closeAll() }]
    }

    /// Arc's Dock menu entries for Little Arc, while there are Little Arc windows (the Dock menu, MultiWindow.swift).
    func addDockItems(to menu: NSMenu) {
        guard hasLittleArcs else { return }
        menu.addItem(.separator())
        menu.add("Show Little Airc Windows") { [weak self] in self?.showAll() }
        menu.add("Close Little Airc Windows") { [weak self] in self?.closeAll() }
    }
}

// MARK: - Settings → Links

/// Settings → Links → Little Arc: the shortcut from anywhere (record, conflicts), looking up the selection (with the
/// Accessibility state and its button), and when Little Arcs go to the Archive.
struct LittleArcGlobalSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var recorder = LittleArcShortcutRecorder()
    @State private var trusted = LittleArcGlobalActions.shared.selection.isTrusted
    @State private var pending: (GlobalShortcut, LittleArcGlobalActions.Conflict)?

    private var value: LittleArcGlobalSettings { settings.values.littleArcGlobal }
    private func set(_ change: (inout LittleArcGlobalSettings) -> Void) {
        var v = settings.values.littleArcGlobal
        change(&v)
        settings.values.littleArcGlobal = v
    }

    var body: some View {
        SettingsSection(title: "Little Airc", help: "A small window for quick lookups. ⌘O moves its page into a Space.") {
            AircToggleRow("Open Little Airc from any app", subtitle: "Press \(value.shortcut.display) in any app, as in Arc. Over a full-screen app, it opens there.",
                          isOn: Binding(get: { value.enabled }, set: { on in set { $0.enabled = on } }))
            if value.enabled {
                SettingsRow(title: "Shortcut", subtitle: recorder.isRecording ? "Type the new shortcut. Esc cancels, Delete puts back \(GlobalShortcut.littleArcDefault.display)."
                            : (pending?.1.message ?? LittleArcGlobalActions.shared.problem?.message)) {
                    HStack(spacing: 8) {
                        if let p = pending, p.1.canUseAnyway {
                            Button("Use Anyway") { set { $0.shortcut = p.0 }; pending = nil }.buttonStyle(.airc(.secondary))
                        }
                        Button(recorder.isRecording ? "…" : value.shortcut.display) {
                            recorder.toggle { result in
                                switch result {
                                case .cancelled: break
                                case .reset: pending = nil; set { $0.shortcut = .littleArcDefault }
                                case .key(let s):
                                    if let c = LittleArcGlobalActions.shared.conflict(for: s) {
                                        pending = (s, c)
                                    } else {
                                        pending = nil
                                        set { $0.shortcut = s }
                                    }
                                }
                            }
                        }
                        .buttonStyle(.airc(.secondary))
                    }
                }
                AircToggleRow("Look up the selected text", subtitle: trusted
                              ? "With text selected in the app in front, the shortcut searches it. Read only when you press it."
                              : "Needs Accessibility access, so Airc can read the selection in the app in front when you press the shortcut, and only then.",
                              isOn: Binding(get: { value.searchesSelection }, set: { on in set { $0.searchesSelection = on } }))
                if value.searchesSelection && !trusted {
                    SettingsRow(title: "Accessibility access", subtitle: "Not allowed yet. macOS asks once; you can change it in Privacy & Security.") {
                        Button("Allow…") { LittleArcGlobalActions.shared.requestAccess() }.buttonStyle(.airc(.secondary))
                    }
                }
            }
            SettingsRow(title: "Archive Little Aircs after", subtitle: "A Little Airc window left alone this long goes to its Space’s Archive.") {
                AircPopUp(options: LittleArcArchiveInterval.allCases.map { ($0.title, $0) }, selection: value.archiveAfter, width: 120) { v in
                    set { $0.archiveAfter = v }
                }
            }
            AircToggleRow("Open Little Airc when clicking on links with ⌥⌘ held",
                          subtitle: "As in Arc. The page stays as it is; ⌘-click still opens a tab in the background.",
                          isOn: Binding(get: { value.opensOptionCommandClicks }, set: { on in set { $0.opensOptionCommandClicks = on } }))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = LittleArcGlobalActions.shared.selection.isTrusted
        }
    }
}

/// Records one global shortcut in Settings: the next key with ⌘, ⌥ or ⌃; Esc cancels, Delete puts back the default.
final class LittleArcShortcutRecorder: ObservableObject {
    enum Result { case key(GlobalShortcut), reset, cancelled }
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private var done: ((Result) -> Void)?

    func toggle(_ done: @escaping (Result) -> Void) {
        if isRecording { return finish(.cancelled) }
        self.done = done
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            self?.record(e)
            return nil
        }
    }

    func record(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.isEmpty, e.keyCode == 53 { return finish(.cancelled) }
        if mods.isEmpty, e.keyCode == 51 || e.keyCode == 117 { return finish(.reset) }
        guard let s = GlobalShortcut(event: e) else { return NSSound.beep() }
        finish(.key(s))
    }

    private func finish(_ r: Result) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        let d = done
        done = nil
        d?(r)
    }
}

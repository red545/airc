// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// Settings → Shortcuts (CB-4, Arc's Settings › Shortcuts): every command by menu with its key. A click on a key
/// records a new one (Esc cancels, Delete removes it); a key another command has offers a swap or taking it away; macOS's
/// own keys are refused, and keys pages use themselves come with a note that the page still gets them first (CB-3).
/// Changes apply at once in every window (App/ShortcutCenter.swift).
final class ShortcutsEditor: ObservableObject {
    static let shared = ShortcutsEditor()

    /// The command whose key is being recorded.
    @Published private(set) var recording: String?
    /// The modifiers held while recording, shown in the field.
    @Published private(set) var heldModifiers: NSEvent.ModifierFlags = []
    /// A key another command has, waiting for "Swap" or "Remove".
    @Published private(set) var conflict: Conflict?
    /// A row's note: why a key was refused, or what else uses the one it got.
    @Published private(set) var notices: [String: Notice] = [:]

    struct Conflict: Equatable {
        let id: String
        /// The key asked for; nil: the row's reset (its default key) was.
        let key: KeyCombo?
        let other: String
    }

    struct Notice: Equatable {
        enum Kind { case refused, warning }
        let kind: Kind
        let text: String
    }

    private var monitor: Any?
    private var resignObserver: Any?
    private let center = ShortcutCenter.shared

    // MARK: Recording

    func toggle(_ id: String) { recording == id ? stop() : start(id) }

    func start(_ id: String) {
        stop()
        conflict = nil
        notices = [:]
        recording = id
        heldModifiers = []
        // After the app's key monitor (it leaves the Settings window's keys alone, but for ⌘Q): nothing reaches the
        // menus while a key is recorded, so ⌥⌘L doesn't also open the address field.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording != nil else { return event }
            if event.type == .flagsChanged {
                self.heldModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                return event
            }
            self.record(event)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, w === self.settingsWindow else { return }
            self.stop()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        recording = nil
        heldModifiers = []
    }

    private var settingsWindow: NSWindow? { (NSApp.delegate as? AppDelegate)?.settingsWindow?.window }

    /// A key while recording: Esc cancels, Delete removes the shortcut, anything else is tried as the new key.
    func record(_ event: NSEvent) {
        guard let id = recording else { return }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.isEmpty, event.keyCode == 53 { return stop() }
        if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            stop()
            return assign(nil, to: id)
        }
        guard let key = ShortcutCenter.typed(event) else { return }
        switch center.map.check(key, for: id) {
        case .refused(let why):
            // Still recording: the next key may be one that works.
            notices[id] = Notice(kind: .refused, text: why)
        case .conflict(let other):
            stop()
            conflict = Conflict(id: id, key: key, other: other)
        default:
            stop()
            assign(key, to: id)
        }
    }

    // MARK: Changes

    func assign(_ key: KeyCombo?, to id: String, resolving: ShortcutMap.Resolution = .refuse) {
        let outcome = center.update { $0.assign(key, to: id, resolving: resolving) }
        switch outcome {
        case .done:
            Telemetry.shared.record(.featureUsed(.shortcutRemap))
            noteAfterChange(id)
        case .conflict(let other): conflict = Conflict(id: id, key: key, other: other)
        case .refused(let why): notices[id] = Notice(kind: .refused, text: why)
        case .unchanged, .unknownCommand: break
        }
    }

    func reset(_ id: String) {
        stop()
        conflict = nil
        notices = [:]
        switch center.update({ $0.reset(id) }) {
        case .conflict(let other): conflict = Conflict(id: id, key: nil, other: other)
        default: noteAfterChange(id)
        }
    }

    func resetAll() {
        stop()
        conflict = nil
        notices = [:]
        center.update { $0.resetAll(); return .done }
    }

    /// The answer to a conflict: `.swap` gives the other command this one's old key, `.clearOther` leaves it without.
    func resolve(_ resolution: ShortcutMap.Resolution) {
        guard let c = conflict else { return }
        conflict = nil
        guard resolution != .refuse else { return }
        if let key = c.key {
            assign(key, to: c.id, resolving: resolution)
        } else {
            center.update { $0.reset(c.id, resolving: resolution) }
            noteAfterChange(c.id)
        }
        if case .clearOther = resolution {
            notices[c.other] = Notice(kind: .warning, text: "No shortcut now: it went to \(ShortcutCenter.title(c.id)).")
        }
    }

    /// Keys pages use too: the command has it, and the page still gets it first (CB-3).
    private func noteAfterChange(_ id: String) {
        guard let key = center.map.key(id), let r = KeyReservation.of(key), r.kind == .pageCommon else { return }
        notices[id] = Notice(kind: .warning, text: "Pages use \(key.display) too (\(r.what)). A page that uses it keeps it; "
                             + "press \(key.display) again within a second to run this.")
    }
}

struct ShortcutsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var center = ShortcutCenter.shared
    @ObservedObject private var editor = ShortcutsEditor.shared
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Text("Click a shortcut to type a new one. Esc cancels, Delete removes it. Pages still get their own keys first: "
                     + "if a page uses one, press it again within a second.")
                    .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Reset All") { editor.resetAll() }
                    .buttonStyle(.airc(.secondary))
                    .disabled(center.map.stored.isEmpty)
            }
            ForEach(ShortcutCenter.groups, id: \.title) { group in
                SettingsSection(title: group.title) {
                    ForEach(group.commands.filter { !$0.id.isEmpty }, id: \.id) { c in
                        ShortcutRow(id: c.id, center: center, editor: editor)
                    }
                }
            }
            Text("⌘Q (hold to quit), ⌘H, ⌘M, ⌘Tab, ⌘Space, the Edit menu's ⌘C ⌘V ⌘X ⌘A ⇧⌘Z and the screenshot keys stay macOS's.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
        .onDisappear { editor.stop() }
    }
}

private struct ShortcutRow: View {
    let id: String
    @ObservedObject var center: ShortcutCenter
    @ObservedObject var editor: ShortcutsEditor
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ShortcutCenter.title(id)).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                    if let n = editor.notices[id] {
                        Text(n.text).aircFont(AircFont.callout)
                            .foregroundStyle((n.kind == .refused ? AircColor.destructive : theme.surfaceTextSecondary).color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if center.map.isCustomized(id) {
                    Button { editor.reset(id) } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.airc(.plain, size: .small))
                    .accessibilityLabel("Reset \(ShortcutCenter.title(id))")
                }
                recorder
            }
            if let c = editor.conflict, c.id == id { conflictBar(c) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
    }

    private var recording: Bool { editor.recording == id }

    private var recorder: some View {
        Button { editor.toggle(id) } label: {
            HStack(spacing: 3) {
                if recording {
                    let held = ShortcutCenter.combo("x", editor.heldModifiers)?.symbols.dropLast() ?? []
                    Text(held.isEmpty ? "Type a shortcut" : held.joined() + "…")
                        .aircFont(AircFont.callout).foregroundStyle(theme.accent.color)
                } else if let key = center.map.key(id) {
                    ForEach(Array(key.symbols.enumerated()), id: \.offset) { AircKeycap(text: $0.element) }
                } else {
                    Text("None").aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 26, alignment: .trailing)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(recording ? theme.accent.alpha(0.10).color : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).inset(by: 0.5)
                .stroke(recording ? theme.accent.color : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shortcut for \(ShortcutCenter.title(id))")
        .accessibilityValue(center.map.key(id)?.display ?? "none")
    }

    private func conflictBar(_ c: ShortcutsEditor.Conflict) -> some View {
        let key = c.key ?? center.map.defaultKey(id)
        let other = ShortcutCenter.title(c.other)
        let mine = center.map.key(id)
        let swap = mine.map { "Swap gives it \($0.display)" } ?? "Swap leaves it without one"
        return HStack(spacing: 8) {
            Text("\(key?.display ?? "That key") is \(other)’s shortcut. Replace takes it away; \(swap).")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel") { editor.resolve(.refuse) }.buttonStyle(.airc(.plain, size: .small)).fixedSize()
            Button("Replace") { editor.resolve(.clearOther) }.buttonStyle(.airc(.secondary, size: .small)).fixedSize()
            Button("Swap") { editor.resolve(.swap) }.buttonStyle(.airc(.primary, size: .small)).fixedSize()
        }
        .padding(.leading, 2)
    }
}

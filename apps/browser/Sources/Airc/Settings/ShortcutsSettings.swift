// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// Settings → Shortcuts (CB-4, Arc's Settings › Shortcuts): every command by menu with its key. A click on a key
/// records a new one (Esc cancels, Delete removes it); a key another command has offers a swap or taking it away; macOS's
/// own keys are refused, and keys pages use themselves come with a note that the page still gets them first (CB-3).
/// Each command a page could have first also says who goes first, with Arc's three choices: Use Both (the default: the
/// page first, a second press runs Airc's command), Prefer Websites, Prefer Airc. Under the list, Arc's sidebar choices:
/// Favorites in ⌘1–9, ⌘9 the ninth or the last item, and ⌥ for a hidden sidebar. Changes apply at once in every window
/// (App/ShortcutCenter.swift).
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

    /// Use Both, Prefer Websites or Prefer Airc for one command.
    func setPriority(_ p: KeyPriority, for id: String) {
        stop()
        conflict = nil
        notices = [:]
        guard center.update({ $0.setPriority(p, for: id) }) == .done else { return }
        Telemetry.shared.record(.featureUsed(.shortcutRemap))
        noteAfterChange(id)
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

    /// Keys pages use too: the command has it, and the page still gets it first (CB-3), unless Airc goes first.
    private func noteAfterChange(_ id: String) {
        guard let key = center.map.key(id), let r = KeyReservation.of(key), r.kind == .pageCommon else { return }
        switch center.map.priority(id) {
        case .airc:
            notices[id] = Notice(kind: .warning, text: "Pages use \(key.display) too (\(r.what)). With Prefer Airc, no page gets it.")
        case .websitesOnly:
            notices[id] = Notice(kind: .warning, text: "Pages use \(key.display) too (\(r.what)). A page that uses it keeps it.")
        case .websites:
            notices[id] = Notice(kind: .warning, text: "Pages use \(key.display) too (\(r.what)). A page that uses it keeps it; "
                                 + "press \(key.display) again within a second to run this.")
        }
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
                Text("Click a shortcut to type a new one. Esc cancels, Delete removes it. With Use Both, a page that uses a key "
                     + "keeps it: press it again within a second to run Airc’s command. Prefer Websites leaves it to the page; "
                     + "Prefer Airc always runs it.")
                    .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Reset All") { editor.resetAll() }
                    .buttonStyle(.airc(.secondary))
                    .disabled(center.map.stored.isEmpty)
            }
            ForEach(ShortcutCenter.groups, id: \.title) { group in
                SettingsSection(title: group.title) {
                    // ⌘Z's Reopen Closed Tab goes when the user gives ⌘Z to a command (that row has its priority then).
                    ForEach(group.commands.filter { !$0.id.isEmpty && ($0.id != KeyMonitor.reopenOnUndo.id || center.offersPriority($0.id)) },
                            id: \.id) { c in
                        ShortcutRow(id: c.id, center: center, editor: editor)
                    }
                }
            }
            SidebarKeysSection(center: center)
                .padding(.top, 8)
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
                    } else if let caption = center.caption(for: id) {
                        Text(caption).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if center.map.isCustomized(id) || center.map.priority(id) != .websites {
                    Button { editor.reset(id) } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.airc(.plain, size: .small))
                    .accessibilityLabel("Reset \(ShortcutCenter.title(id))")
                }
                if center.offersPriority(id) { priority }
                if center.map.isRemappable(id) { recorder } else { fixedKey }
            }
            if let c = editor.conflict, c.id == id { conflictBar(c) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
    }

    private var recording: Bool { editor.recording == id }

    /// Who gets the key first while a page has the keyboard: Arc's picker, in its order.
    private var priority: some View {
        AircPopUp(options: KeyPriority.allCases.map { ($0.title, $0) }, selection: center.map.priority(id), width: 172) {
            editor.setPriority($0, for: id)
        }
        .help(KeyPriority.allCases.map { "\($0.title): \($0.subtitle)" }.joined(separator: "\n"))
        .accessibilityLabel("Who gets \(ShortcutCenter.title(id))’s key first")
        .accessibilityValue(center.map.priority(id).title)
    }

    /// A key that can't change (⌘Z outside text fields): shown, not recorded.
    private var fixedKey: some View {
        HStack(spacing: 3) {
            ForEach(Array((center.map.defaultKey(id)?.symbols ?? []).enumerated()), id: \.offset) { AircKeycap(text: $0.element) }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 44, minHeight: 26, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shortcut for \(ShortcutCenter.title(id))")
        .accessibilityValue(center.map.defaultKey(id)?.display ?? "none")
    }

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

/// Arc's settings under its shortcut list (ShortcutsPane+AdditionalSettings): which items ⌘1–9 count, and what ⌘9 is;
/// with Airc's ⌥ reveal beside them (Arc ref §2.10).
private struct SidebarKeysSection: View {
    @ObservedObject var center: ShortcutCenter

    var body: some View {
        SettingsSection(title: "Sidebar") {
            AircToggleRow("Include Favorites in ordering",
                          subtitle: "⌘1 is your first Favorite. Off: ⌘1 is the first item after your Favorites.",
                          isOn: Binding(get: { center.navigation.includeFavoritesInOrdering },
                                        set: { v in center.setNavigation { $0.includeFavoritesInOrdering = v } }))
            AircToggleRow("Switch to ninth tab",
                          subtitle: "⌘9 jumps to the ninth item. Off: to the last item at the bottom of your Sidebar.",
                          isOn: Binding(get: { center.navigation.switchToNinthItem },
                                        set: { v in center.setNavigation { $0.switchToNinthItem = v } }))
            AircToggleRow("Hold ⌥ to show a hidden sidebar",
                          subtitle: "While the sidebar is hidden, holding ⌥ on its own slides it out; let go and it slides away.",
                          isOn: Binding(get: { center.navigation.optionRevealsSidebar },
                                        set: { v in center.setNavigation { $0.optionRevealsSidebar = v } }))
        }
    }
}

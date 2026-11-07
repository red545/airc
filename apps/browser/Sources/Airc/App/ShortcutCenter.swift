// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// The user's shortcuts (CB-4, Settings → Shortcuts) for the whole app. The defaults are today's table, the command
/// lists in Commands.swift (CB-2); settings.json keeps only what the user changed (AircKit's ShortcutMap). A change
/// applies at once everywhere: the key monitor reads `commands`, the main menu's items get their new keys, and private
/// windows and Little Arc look a typed key up here (`defaultKey(forTyped:)`), so every window follows the same map.
final class ShortcutCenter: ObservableObject {
    static let shared = ShortcutCenter()

    @Published private(set) var map: ShortcutMap
    /// Every command the key monitor runs, with the user's keys (`CommandMenus.all`).
    private(set) var commands: [BrowserCommand]
    private let defaultsByID: [String: BrowserCommand]
    private weak var settings: AppSettings?

    private init() {
        let all = CommandMenus.app() + CommandMenus.defaults
        var byID: [String: BrowserCommand] = [:]
        for c in all where !c.id.isEmpty && byID[c.id] == nil { byID[c.id] = c }
        defaultsByID = byID
        let undo = KeyMonitor.reopenOnUndo
        map = ShortcutMap(commands: all.filter { !$0.id.isEmpty }.map { .init(id: $0.id, defaultKey: Self.combo($0.key, $0.modifiers)) }
                          + [.init(id: undo.id, defaultKey: Self.combo(undo.key, undo.modifiers), remappable: false)])
        commands = CommandMenus.defaults
    }

    /// Reads the user's map from settings.json (once, before the main menu is built).
    func attach(settings: AppSettings) {
        self.settings = settings
        map = ShortcutMap(commands: map.commands, stored: settings.values.shortcuts)
        rebind()
    }

    /// Changes the map, saves it and applies it to the menus and every window's keys.
    @discardableResult
    func update(_ change: (inout ShortcutMap) -> ShortcutMap.Outcome) -> ShortcutMap.Outcome {
        var m = map
        let outcome = change(&m)
        guard m != map else { return outcome }
        map = m
        settings?.values.shortcuts = m.stored
        rebind()
        return outcome
    }

    /// `cmd` with the user's key: none ("") when they cleared it or gave it to another command.
    func bound(_ cmd: BrowserCommand) -> BrowserCommand {
        guard !cmd.id.isEmpty, defaultsByID[cmd.id] != nil else { return cmd }
        var c = cmd
        (c.key, c.modifiers) = map.key(cmd.id).map(Self.appKit) ?? ("", [])
        return c
    }

    func defaultCommand(_ id: String) -> BrowserCommand? { defaultsByID[id] }

    /// A command has this key now.
    func owns(_ key: String, _ mods: NSEvent.ModifierFlags) -> Bool {
        Self.combo(key, mods).flatMap(map.command) != nil
    }

    /// For windows with their own key tables (private windows, Little Arc), which spell keys as today's defaults: the
    /// default key of the command the typed key runs now. Nil when the typed key is no command's now (a default the user
    /// moved or cleared, or a key given to a command that had none), so it goes to the page; other keys as they are.
    func defaultKey(forTyped key: String, _ mods: NSEvent.ModifierFlags) -> (String, NSEvent.ModifierFlags)? {
        guard let typed = Self.combo(key, mods) else { return (key, mods) }
        if let id = map.command(for: typed) { return map.defaultKey(id).map(Self.appKit) }
        return map.isFreedDefault(typed) ? nil : (key, mods)
    }

    /// The row offers "Websites first / Airc first": a page can have the command's key first now (KeyMonitor.pageCanUse).
    /// Not for the app menu's own commands (the key monitor never sees them), nor ⌘← ⌘→ (always the page's and the
    /// fields' first: text navigation), nor ⌘Z's Reopen Closed Tab while the user gave ⌘Z to a command.
    func offersPriority(_ id: String) -> Bool {
        if id == KeyMonitor.reopenOnUndo.id { return !owns("z", .command) }
        guard let cmd = commands.first(where: { $0.id == id }), !cmd.key.isEmpty, cmd.order != .afterPage else { return false }
        return KeyMonitor.pageCanUse(cmd)
    }

    /// A key pages and editors use themselves (⌘B, ⇧⌘V …): the page has it first whatever command it runs (Websites first).
    static func isPageCommon(_ cmd: BrowserCommand) -> Bool {
        combo(cmd.key, cmd.modifiers).map { KeyReservation.pageCommon[$0] != nil } ?? false
    }

    private func rebind() {
        commands = CommandMenus.defaults.map(bound)
        if let menu = NSApp?.mainMenu { refresh(menu) }
    }

    /// The main menu's items show (and AppKit matches) the user's keys.
    private func refresh(_ menu: NSMenu) {
        for item in menu.items {
            if let sub = item.submenu { refresh(sub) }
            guard let i = item as? CommandMenuItem, let c = i.command, !c.id.isEmpty else { continue }
            let b = bound(c)
            i.command = b
            (i.keyEquivalent, i.keyEquivalentModifierMask) = Self.menuEquivalent(b.key, b.modifiers)
        }
    }

    /// A menu item's spelling of a key: a ⇧ letter in upper case without ⇧ in the mask. AppKit's matcher gives an
    /// unshifted key to an item spelled "l" with ⇧ (a freed ⌘L opened ⇧⌘L's Library), never to "L".
    static func menuEquivalent(_ key: String, _ mods: NSEvent.ModifierFlags) -> (String, NSEvent.ModifierFlags) {
        guard mods.contains(.shift), key.count == 1, key.lowercased() != key.uppercased() else { return (key, mods) }
        return (key.uppercased(), mods.subtracting(.shift))
    }

    // MARK: AppKit's keys and AircKit's

    /// AppKit's characters for keys that type nothing visible, and their names in settings.json.
    private static let names: [String: String] = {
        func ch(_ k: Int) -> String { String(Character(UnicodeScalar(k)!)) }
        var n: [String: String] = [
            BrowserCommand.left: "left", BrowserCommand.right: "right", BrowserCommand.up: "up", BrowserCommand.down: "down",
            BrowserCommand.pageUp: "pageup", BrowserCommand.pageDown: "pagedown", ch(NSHomeFunctionKey): "home", ch(NSEndFunctionKey): "end",
            "\t": "tab", "\r": "return", "\u{3}": "enter", "\u{7f}": "delete", ch(NSDeleteFunctionKey): "forwarddelete",
            "\u{1b}": "escape", " ": "space",
        ]
        for i in 0..<20 { n[ch(NSF1FunctionKey + i)] = "f\(i + 1)" }
        return n
    }()
    private static let characters: [String: String] = Dictionary(uniqueKeysWithValues: names.map { ($1, $0) })

    static func combo(_ key: String, _ mods: NSEvent.ModifierFlags) -> KeyCombo? {
        guard !key.isEmpty else { return nil }
        // ⇧⇥ types a back tab.
        let k = key == "\u{19}" ? "tab" : names[key] ?? key.lowercased()
        guard k.count == 1 || KeyCombo.names[k] != nil else { return nil }
        var m: KeyCombo.Modifiers = []
        if mods.contains(.control) { m.insert(.control) }
        if mods.contains(.option) { m.insert(.option) }
        // A menu's "L" is ⇧L (menuEquivalent).
        if mods.contains(.shift) || (key.count == 1 && key != key.lowercased()) { m.insert(.shift) }
        if mods.contains(.command) { m.insert(.command) }
        return KeyCombo(k, m)
    }

    static func appKit(_ c: KeyCombo) -> (String, NSEvent.ModifierFlags) {
        var m: NSEvent.ModifierFlags = []
        if c.modifiers.contains(.control) { m.insert(.control) }
        if c.modifiers.contains(.option) { m.insert(.option) }
        if c.modifiers.contains(.shift) { m.insert(.shift) }
        if c.modifiers.contains(.command) { m.insert(.command) }
        return (characters[c.key] ?? c.key, m)
    }

    /// A key-down as the key monitor reads it (KeyMonitor.install): lower case, ⌘+ as ⌘=, ⌃⇧ digits and = − by key.
    static func typed(_ event: NSEvent) -> KeyCombo? {
        var mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard var chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return nil }
        if chars == "+", mods.contains(.command) { chars = "="; mods.remove(.shift) }
        if mods == [.control, .shift], let k = [24: "=", 27: "-", 18: "1", 19: "2", 20: "3", 21: "4"][Int(event.keyCode)] { chars = k }
        return combo(chars, mods)
    }

    // MARK: Settings → Shortcuts

    /// The commands by menu, as the menus list them; the hidden keys and ⌘← ⌘→ with their menu's commands.
    static var groups: [(title: String, commands: [BrowserCommand])] {
        [("Airc", CommandMenus.app()),
         ("File", CommandMenus.file().compactMap { $0 }.flatMap { $0.id == "file.reopenClosedTab" ? [$0, KeyMonitor.reopenOnUndo] : [$0] }),
         ("Edit", CommandMenus.editExtras().compactMap { $0 }),
         ("View", CommandMenus.view().compactMap { $0 }),
         ("Spaces", CommandMenus.spaces().compactMap { $0 }),
         ("Tabs", CommandMenus.tabs().compactMap { $0 } + CommandMenus.hidden() + CommandMenus.keysOnly())]
    }

    /// The key a Command Bar action shows: `standard` (its default, as Arc writes it: ⌃⇧+) unless the user changed it.
    static func hint(_ id: String, _ standard: String) -> String {
        shared.map.isCustomized(id) ? shared.map.key(id)?.display ?? "" : standard
    }

    /// How Settings names a command (the menu's title, and which key it is where one command has several).
    static func title(_ id: String) -> String {
        switch id {
        case "tabs.next.brace": "Next Tab, second key"
        case "tabs.previous.brace": "Previous Tab, second key"
        case "tabs.next.page": "Next Tab, third key"
        case "tabs.previous.page": "Previous Tab, third key"
        case "tabs.back.arrow": "Back, outside text fields"
        case "tabs.forward.arrow": "Forward, outside text fields"
        case "file.openInSpace": "Open in Space (Little Arc, Peek)"
        case "file.moveToSpace": "Move to Space… (Little Arc)"
        case "file.reopenOnUndo": "Reopen Closed Tab, outside text fields"
        default: shared.defaultCommand(id)?.title ?? id
        }
    }
}

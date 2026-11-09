// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import Carbon

/// The user's shortcuts (CB-4, Settings → Shortcuts) for the whole app. The defaults are today's table, the command
/// lists in Commands.swift (CB-2); settings.json keeps only what the user changed (AircKit's ShortcutMap). A change
/// applies at once everywhere: the key monitor reads `commands`, the main menu's items get their new keys, and private
/// windows and Little Arc look a typed key up here (`defaultKey(forTyped:)`), so every window follows the same map.
final class ShortcutCenter: ObservableObject {
    static let shared = ShortcutCenter()

    @Published private(set) var map: ShortcutMap
    /// Settings → Shortcuts' sidebar choices (K02, W03), kept in settings.json. AircKit's commandNumberTarget and
    /// OptionReveal read them through `SidebarNavigation.preferences`.
    @Published private(set) var navigation = SidebarNavigationPreferences()
    /// Every command the key monitor runs, with the user's keys (`CommandMenus.all`).
    private(set) var commands: [BrowserCommand]
    private let defaultsByID: [String: BrowserCommand]
    private weak var settings: AppSettings?

    private init() {
        let all = CommandMenus.app() + CommandMenus.defaults + Self.commandBarKeys
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
        let migrated = ShortcutMigration.shiftedDigits(settings.values.shortcuts, symbols: Self.shiftedDigitSymbols())
        if migrated != settings.values.shortcuts { settings.values.shortcuts = migrated }
        map = ShortcutMap(commands: map.commands, stored: migrated)
        navigation = settings.values.sidebarNavigation
        SidebarNavigation.preferences = navigation
        rebind()
    }

    /// Changes the sidebar choices and saves them; ⌘1–9 and ⌥ follow at once.
    func setNavigation(_ change: (inout SidebarNavigationPreferences) -> Void) {
        var n = navigation
        change(&n)
        guard n != navigation else { return }
        navigation = n
        SidebarNavigation.preferences = n
        settings?.values.sidebarNavigation = n
    }

    /// The line under a command in Settings: what ⌘1–9 jump to with the sidebar choices (Arc's descriptions), or that
    /// macOS may take the key first (⌃Space with two input sources).
    func caption(for id: String) -> String? {
        if id.hasPrefix("tabs.sidebar"), let n = Int(id.dropFirst("tabs.sidebar".count)) { return navigation.describe(number: n) }
        if let k = map.key(id), let r = KeyReservation.of(k), r.kind == .systemMayTake {
            return "System shortcuts may take priority over this shortcut: macOS uses \(k.display) for \(r.what)."
        }
        return nil
    }

    /// The page may have `id`'s key first (CB-3): Use Both and Prefer Websites, not Prefer Airc.
    func pageMayHave(_ id: String) -> Bool { map.priority(id).pageMayHave }

    /// A second press within a second of one the page used runs `id` (Use Both only).
    func secondPressRuns(_ id: String) -> Bool { map.priority(id).secondPressRuns }

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
        // K03: ⌘Ü on a German layout is ⌘[ (layoutAliases).
        if let alias = layoutAliases.first(where: { Self.combo($0.key, $0.modifiers) == typed }) {
            return map.defaultKey(alias.id).map(Self.appKit)
        }
        if let id = map.command(for: typed) { return map.defaultKey(id).map(Self.appKit) }
        return map.isFreedDefault(typed) ? nil : (key, mods)
    }

    /// The row offers Use Both / Prefer Websites / Prefer Airc: a page can have the command's key first now
    /// (KeyMonitor.pageCanUse).
    /// Not for the app menu's own commands (the key monitor never sees them), nor ⌘← ⌘→ (always the page's and the
    /// fields' first: text navigation), nor ⌘Z's Reopen Closed Tab while the user gave ⌘Z to a command.
    func offersPriority(_ id: String) -> Bool {
        if id == KeyMonitor.reopenOnUndo.id { return !owns("z", .command) }
        guard let cmd = commands.first(where: { $0.id == id }), !cmd.key.isEmpty, cmd.order != .afterPage else { return false }
        return KeyMonitor.pageCanUse(cmd)
    }

    /// A key pages and editors use themselves (⌘B, ⇧⌘V …): the page has it first whatever command it runs (unless Prefer
    /// Airc).
    static func isPageCommon(_ cmd: BrowserCommand) -> Bool {
        combo(cmd.key, cmd.modifiers).map { KeyReservation.pageCommon[$0] != nil } ?? false
    }

    private func rebind() {
        let keys = CommandMenus.defaults.map(bound)
        layoutAliases = Self.layoutAliases(for: keys, map: map, layout: layoutForTesting ?? Self.currentLayout())
        commands = keys + layoutAliases
        if let menu = NSApp?.mainMenu { refresh(menu) }
        watchLayout()
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
        if mods == [.command, .shift], let k = digitKeys[Int(event.keyCode)] { chars = k }
        return combo(chars, mods)
    }

    /// The digit row by key code: ⇧ turns a digit into the layout's symbol (@ on US, " on German), so a ⇧⌘ digit is
    /// read by its key (Capture's ⇧⌘2, and ⇧⌘3–5 recognised as macOS's screenshot keys in Settings).
    static let digitKeys: [Int: String] = [18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]

    static func shiftedDigitSymbols() -> [String: String] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [:] }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var symbols: [String: String] = [:]
        for (code, digit) in digitKeys {
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            let result = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32(shiftKey >> 8),
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
            if result == noErr, length > 0 {
                symbols[String(utf16CodeUnits: chars, count: length).lowercased()] = digit
            }
        }
        return symbols
    }

    // MARK: C02, the Command Bar's own key

    /// Arc's ⌥⌘⌫ removes the highlighted history suggestion (CommandBarView.handleSuggestionKey). Not a menu command and
    /// never the key monitor's: the Command Bar reads its key here, so Settings → Shortcuts can change it like any other.
    static let removeSuggestion = BrowserCommand("Remove Suggestion from History", "\u{7f}", [.option, .command],
                                                 id: "commandBar.removeSuggestion") { _ in }
    static let commandBarKeys = [removeSuggestion]

    /// The Command Bar's key for `id` now, as a typed key reads (`typed`); nil when the user removed it.
    func commandBarKey(_ id: String) -> KeyCombo? { map.key(id) }

    // MARK: K03, brackets on other keyboard layouts

    /// Extra keys for commands whose bracket key this keyboard layout can't type without ⌥: German, Austrian, French,
    /// Swiss, Nordic, Spanish … (⌘[ is ⌥⌘5 on a German layout). As Arc does (Chromium matches ⇧⌘[ ⇧⌘] by key code) and
    /// as macOS localizes menu keys since Monterey, the key where a US keyboard has [ or ] runs the command, with ⇧ for
    /// { }: ⌘Ü is Back and ⇧⌘Ü Previous Tab on German. Typing the bracket itself, with ⌥, runs it too (⌥⌘5 for ⌘[). An
    /// extra key never takes one that is already a command's on this layout: ⌘+ (the key right of Ü) stays Zoom In.
    /// They follow the user's map (a ⌘[ moved elsewhere takes its extra keys along) and the input source.
    private(set) var layoutAliases: [BrowserCommand] = []

    /// What a key types on a layout: key code, ⇧, ⌥. Nil: nothing, or a dead key's accent alone.
    typealias Layout = (_ code: UInt16, _ shift: Bool, _ option: Bool) -> String?

    /// The main block of keys: letters, digits, punctuation and the ISO key beside the left ⇧ (key codes 0–50).
    private static let mainKeys: [UInt16] = Array(0...50).filter { $0 != 36 && $0 != 48 && $0 != 49 }
    /// The US key positions of the brackets: the key right of P (33) and the one after it (30).
    private static let usBracketKeys: [String: (code: UInt16, shift: Bool)] = ["[": (33, false), "{": (33, true), "]": (30, false), "}": (30, true)]

    static func layoutAliases(for commands: [BrowserCommand], map: ShortcutMap, layout: Layout?) -> [BrowserCommand] {
        guard let layout else { return [] }
        var typeable = Set<String>()
        for code in mainKeys { for shift in [false, true] { if let t = layout(code, shift, false) { typeable.insert(t) } } }
        var taken = Set(commands.compactMap { combo($0.key, $0.modifiers) })
        var out: [BrowserCommand] = []
        func add(_ cmd: BrowserCommand, _ key: String, _ mods: NSEvent.ModifierFlags) {
            guard key.count == 1, key.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) }) else { return }
            // As the key monitor reads it: ⌘+ is ⌘= (Zoom In).
            var k = key.lowercased(), m = mods
            if k == "+", m.contains(.command) { k = "="; m.remove(.shift) }
            guard let c = combo(k, m), map.command(for: c) == nil, !taken.contains(c), KeyReservation.of(c) == nil else { return }
            taken.insert(c)
            var alias = cmd
            (alias.key, alias.modifiers) = (k, m)
            out.append(alias)
        }
        for cmd in commands where !cmd.id.isEmpty {
            guard cmd.key.count == 1, let base = usBracketKeys[cmd.key] ?? usBracketKeys[cmd.key.uppercased()] else { continue }
            // ⌃⇧[ ⌃⇧] (the split keys) are matched by key code already, on every layout (KeyMonitor).
            if cmd.modifiers == [.control, .shift] { continue }
            let shift = base.shift || cmd.modifiers.contains(.shift)
            let bracket = shift ? (base.code == 33 ? "{" : "}") : (base.code == 33 ? "[" : "]")
            guard !typeable.contains(bracket) else { continue }
            var mods = cmd.modifiers.subtracting(.shift)
            // The US position.
            if let t = layout(base.code, shift, false) { add(cmd, t, shift ? mods.union(.shift) : mods) }
            // The bracket typed with ⌥ (⌥5 types [ on a German layout): ⌥ joins the command's modifiers.
            mods.insert(.option)
            for code in mainKeys {
                for sh in [false, true] where layout(code, sh, true) == bracket {
                    if let t = layout(code, sh, false) { add(cmd, t, sh ? mods.union(.shift) : mods) }
                }
            }
        }
        return out
    }

    /// The current keyboard layout (TIS's Unicode layout data). Nil when it has none (some input methods).
    static func currentLayout() -> Layout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return layout(of: source)
    }

    static func layout(of source: TISInputSource) -> Layout? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let kind = UInt32(LMGetKbdType())
        return { code, shift, option in
            data.withUnsafeBytes { buf -> String? in
                guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let mods = UInt32(((shift ? shiftKey : 0) | (option ? optionKey : 0)) >> 8)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), mods, kind,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: chars, count: length)
            }
        }
    }

    /// A layout by its input source ID ("com.apple.keylayout.French"), without selecting it.
    static func layout(id: String) -> Layout? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return nil }
        return layout(of: source)
    }

    private var layoutWatch: NSObjectProtocol?
    /// The input source changed (the menu bar's input menu, ⌃Space): the extra keys follow.
    private func watchLayout() {
        guard layoutWatch == nil else { return }
        layoutWatch = NotificationCenter.default.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            self?.rebind()
        }
    }

    /// ParityP03bCheck: another layout's extra keys, as if it were selected (nil: the real one again).
    var layoutForTesting: Layout? {
        didSet { rebind() }
    }

    // MARK: Settings → Shortcuts

    /// The commands by menu, as the menus list them; the hidden keys and ⌘← ⌘→ with their menu's commands.
    static var groups: [(title: String, commands: [BrowserCommand])] {
        [("Airc", CommandMenus.app()),
         ("File", CommandMenus.file().compactMap { $0 }.flatMap { $0.id == "file.reopenClosedTab" ? [$0, KeyMonitor.reopenOnUndo] : [$0] }),
         ("Edit", CommandMenus.editExtras().compactMap { $0 }),
         ("View", CommandMenus.view().compactMap { $0 }),
         ("Spaces", CommandMenus.spaces().compactMap { $0 }),
         ("Tabs", CommandMenus.tabs().compactMap { $0 } + CommandMenus.hidden() + CommandMenus.keysOnly()),
         ("Command Bar", commandBarKeys)]
    }

    /// The key a Command Bar action shows: `standard` (its default, as Arc writes it: ⌃⇧+) unless the user changed it.
    static func hint(_ id: String, _ standard: String) -> String {
        shared.map.key(id) == nil ? "" : (shared.map.isCustomized(id) ? shared.map.key(id)?.display ?? "" : standard)
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
        case "file.openInSpace": "Open in Space (Little Airc, Peek)"
        case "file.moveToSpace": "Move to Space… (Little Airc)"
        case "file.reopenOnUndo": "Reopen Closed Tab, outside text fields"
        default: shared.defaultCommand(id)?.title ?? id
        }
    }
}

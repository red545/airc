// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

/// One key with its modifiers, as Settings → Shortcuts stores it ("alt+cmd+l") and shows it (⌥⌘L). `key` is what the
/// key types without its modifiers, lower case ("l", "1", "[", "}"), or a name for keys that type nothing visible
/// (`KeyCombo.names`: "left", "tab", "pagedown", "f5" …). It matches what AppKit's `charactersIgnoringModifiers`
/// gives, so on a German layout ⌘Z is the key labelled Z, as AppKit's menus have it.
public struct KeyCombo: Hashable, Sendable, Codable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    /// Keys that type nothing visible, by name, with the symbol macOS menus show for them.
    public static let names: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "pageup": "⇞", "pagedown": "⇟", "home": "↖", "end": "↘",
        "tab": "⇥", "return": "↩", "enter": "⌅", "delete": "⌫", "forwarddelete": "⌦", "escape": "⎋", "space": "Space",
    ].merging((1...20).map { ("f\($0)", "F\($0)") }) { a, _ in a }

    /// "ctrl+alt+shift+cmd+key", the modifiers in macOS's own order. Nil for an empty or unknown key.
    public init?(string: String) {
        // The key may itself be "+" ("cmd++"): the last part, even when empty, is the key.
        var parts = string.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        var key = parts.removeLast()
        if key.isEmpty, parts.last == "" { parts.removeLast(); key = "+" }
        var m: Modifiers = []
        for p in parts {
            switch p {
            case "ctrl": m.insert(.control)
            case "alt": m.insert(.option)
            case "shift": m.insert(.shift)
            case "cmd": m.insert(.command)
            default: return nil
            }
        }
        guard key.count == 1 || Self.names[key] != nil else { return nil }
        self.init(key, m)
    }

    public var string: String {
        (modifiers.contains(.control) ? "ctrl+" : "") + (modifiers.contains(.option) ? "alt+" : "")
            + (modifiers.contains(.shift) ? "shift+" : "") + (modifiers.contains(.command) ? "cmd+" : "") + key
    }

    public var description: String { display }

    /// The modifier symbols and the key, each as its own keycap: ["⌥", "⌘", "L"].
    public var symbols: [String] {
        var s: [String] = []
        if modifiers.contains(.control) { s.append("⌃") }
        if modifiers.contains(.option) { s.append("⌥") }
        if modifiers.contains(.shift) { s.append("⇧") }
        if modifiers.contains(.command) { s.append("⌘") }
        return s + [Self.names[key] ?? key.uppercased()]
    }

    /// "⌥⌘L", as menus show it.
    public var display: String { symbols.joined() }

    /// A shortcut needs ⌘, ⌥ or ⌃: a plain or ⇧ key is typing.
    public var isValidShortcut: Bool { !modifiers.intersection([.command, .option, .control]).isEmpty }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = KeyCombo(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a key: \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string)
    }
}

/// Why a key can't be a shortcut (`.system`) or what else uses it (`.pageCommon`: allowed, with a warning).
public struct KeyReservation: Equatable, Sendable {
    public enum Kind: Sendable { case system, pageCommon }
    public let kind: Kind
    /// What it does, as Settings says it: "Quit Airc (hold ⌘Q)", "bold in text editors".
    public let what: String

    /// macOS's own keys and the menu keys every app keeps: never a browser command's. ⌘Q stays hold-to-quit.
    public static let system: [KeyCombo: String] = {
        let cmd: KeyCombo.Modifiers = .command
        var r: [KeyCombo: String] = [
            KeyCombo("q", cmd): "Quit Airc (hold ⌘Q)",
            KeyCombo("h", cmd): "Hide Airc",
            KeyCombo("h", [.option, .command]): "Hide Others",
            KeyCombo("m", cmd): "Minimize",
            KeyCombo("tab", cmd): "switching apps",
            KeyCombo("tab", [.shift, .command]): "switching apps",
            KeyCombo("`", cmd): "switching windows",
            KeyCombo("~", [.shift, .command]): "switching windows",
            KeyCombo("space", cmd): "Spotlight",
            KeyCombo("space", [.option, .command]): "Finder search",
            KeyCombo("space", .control): "switching input sources",
            KeyCombo("space", [.control, .option]): "switching input sources",
            KeyCombo("space", [.control, .command]): "Emoji & Symbols",
            KeyCombo("q", [.control, .command]): "Lock Screen",
            KeyCombo("escape", [.option, .command]): "Force Quit",
            KeyCombo("d", [.option, .command]): "showing and hiding the Dock",
            KeyCombo("f", [.control, .command]): "Enter Full Screen",
            KeyCombo("c", cmd): "Copy",
            KeyCombo("v", cmd): "Paste",
            KeyCombo("x", cmd): "Cut",
            KeyCombo("a", cmd): "Select All",
            KeyCombo("z", [.shift, .command]): "Redo",
        ]
        for n in ["3", "4", "5"] {
            r[KeyCombo(n, [.shift, .command])] = "screenshots"
            r[KeyCombo(n, [.control, .shift, .command])] = "screenshots"
        }
        for k in ["left", "right", "up", "down"] { r[KeyCombo(k, .control)] = "Mission Control" }
        return r
    }()

    /// Keys web pages and editors use for themselves (Docs, Notion, Slack, Figma). A browser command may have one: the
    /// page still gets the key first (CB-3), and pressing it again within a second runs the command.
    public static let pageCommon: [KeyCombo: String] = [
        KeyCombo("b", .command): "bold in text editors",
        KeyCombo("i", .command): "italic in text editors",
        KeyCombo("u", .command): "underline in text editors",
        KeyCombo("k", .command): "links in editors and search in chat apps",
        KeyCombo("z", .command): "undo (outside a text field it reopens a closed tab)",
        KeyCombo("v", [.shift, .command]): "Paste and Match Style",
        KeyCombo("v", [.option, .shift, .command]): "Paste and Match Style",
        KeyCombo("v", [.option, .command]): "Docs' Paste Formatting",
        KeyCombo("return", .command): "sending and saving in web apps",
        KeyCombo("/", .command): "shortcut help and comments in web apps",
        KeyCombo("delete", .command): "deleting to the line's start",
    ]

    public static func of(_ combo: KeyCombo) -> KeyReservation? {
        if let w = system[combo] { return KeyReservation(kind: .system, what: w) }
        if let w = pageCommon[combo] { return KeyReservation(kind: .pageCommon, what: w) }
        return nil
    }
}

/// Who gets a command's key first while a page has the keyboard (Arc's per-command "Prefer Websites" / "Prefer Arc").
public enum KeyPriority: String, Sendable {
    /// The page may claim the key (CB-3); pressing it again within a second runs the command. The default.
    case websites
    /// The command always runs; the page never sees the key.
    case airc
}

/// The user's shortcuts (CB-4): today's table as defaults, and only what the user changed on top. `stored` is what
/// settings.json keeps, so a command the user never touched follows a new default in a later version, an override that
/// equals its default is dropped, and commands that no longer exist are ignored. A key belongs to one command at most:
/// the user's choice wins over a default, the earlier command over a later one. Each command also has a `KeyPriority`;
/// only "Airc first" is stored.
public struct ShortcutMap: Equatable, Sendable {
    public struct Command: Equatable, Sendable {
        public let id: String
        public let defaultKey: KeyCombo?
        /// False for a key the user can't change, only its priority (⌘Z's Reopen Closed Tab outside text fields). It
        /// holds no key in the map: another command may take that key, and then this one gives way.
        public let remappable: Bool
        public init(id: String, defaultKey: KeyCombo?, remappable: Bool = true) {
            self.id = id
            self.defaultKey = defaultKey
            self.remappable = remappable
        }
    }

    /// When a new key is another command's.
    public enum Resolution: Sendable {
        /// Nothing changes; `assign` answers `.conflict`.
        case refuse
        /// The other command gets this one's old key (or none, if it had none).
        case swap
        /// The other command loses the key.
        case clearOther
    }

    public enum Outcome: Equatable, Sendable {
        case done
        /// Already this command's key.
        case unchanged
        /// The key is this command's (by id); nothing changed (`.refuse`).
        case conflict(String)
        /// macOS's or a menu's own key (`KeyReservation.system`), or no ⌘ ⌥ ⌃.
        case refused(String)
        case unknownCommand
    }

    public let commands: [Command]
    /// Command id → the user's key, or nil for "no shortcut".
    public private(set) var overrides: [String: KeyCombo?]
    /// Commands whose key always runs the command, even when a page has the keyboard ("Airc first").
    public private(set) var aircFirst: Set<String>
    private var keys: [String: KeyCombo] = [:]
    private var owners: [KeyCombo: String] = [:]
    private let index: [String: Command]

    public init(commands: [Command], overrides: [String: KeyCombo?] = [:], aircFirst: Set<String> = []) {
        var seen = Set<String>()
        self.commands = commands.filter { seen.insert($0.id).inserted }
        let index = Dictionary(uniqueKeysWithValues: self.commands.map { ($0.id, $0) })
        self.index = index
        self.overrides = [:]
        self.aircFirst = aircFirst.filter { index[$0] != nil }
        for (id, key) in overrides {
            guard let c = index[id], c.remappable else { continue }   // a removed command, or a fixed key
            if let key, !Self.allowed(key) { continue }  // a hand-edited file
            if key != c.defaultKey { self.overrides[id] = key }
        }
        resolve()
    }

    /// From settings.json: id → "alt+cmd+l", or "" for no shortcut; "<id>:first" → "airc" for Airc first.
    /// Unreadable keys are ignored. (Builds before the priority read "<id>:first" as an unknown command and skip it.)
    public init(commands: [Command], stored: [String: String]) {
        var o: [String: KeyCombo?] = [:]
        var first = Set<String>()
        for (id, s) in stored {
            if id.hasSuffix(Self.prioritySuffix) {
                if s == KeyPriority.airc.rawValue { first.insert(String(id.dropLast(Self.prioritySuffix.count))) }
            } else if s.isEmpty { o[id] = .some(nil) } else if let k = KeyCombo(string: s) { o[id] = k }
        }
        self.init(commands: commands, overrides: o, aircFirst: first)
    }

    /// What settings.json keeps (see `init(commands:stored:)`).
    public var stored: [String: String] {
        var s = overrides.mapValues { $0?.string ?? "" }
        for id in aircFirst { s[id + Self.prioritySuffix] = KeyPriority.airc.rawValue }
        return s
    }

    /// The settings.json entry for a command's priority: "file.openLocation:first".
    public static let prioritySuffix = ":first"

    public func priority(_ id: String) -> KeyPriority { aircFirst.contains(id) ? .airc : .websites }

    /// Websites first (the default) or Airc first for `id`.
    @discardableResult
    public mutating func setPriority(_ p: KeyPriority, for id: String) -> Outcome {
        guard index[id] != nil else { return .unknownCommand }
        guard priority(id) != p else { return .unchanged }
        if p == .airc { aircFirst.insert(id) } else { aircFirst.remove(id) }
        return .done
    }

    /// The key `id` has now: the user's, else its default unless the user gave that key to another command.
    public func key(_ id: String) -> KeyCombo? { keys[id] }

    /// The command whose key `combo` is now.
    public func command(for combo: KeyCombo) -> String? { owners[combo] }

    public func defaultKey(_ id: String) -> KeyCombo? { index[id]?.defaultKey }

    /// The user changed its key (`key` may still equal another command's default). Its priority doesn't count.
    public func isCustomized(_ id: String) -> Bool { overrides[id] != nil }

    /// The user can record a key for it (`Command.remappable`).
    public func isRemappable(_ id: String) -> Bool { index[id]?.remappable ?? false }

    /// A key some command has by default that the user moved elsewhere or cleared: it isn't Airc's any more, so it goes
    /// to the page and macOS's menus.
    public func isFreedDefault(_ combo: KeyCombo) -> Bool {
        owners[combo] == nil && commands.contains { $0.remappable && $0.defaultKey == combo }
    }

    public static func allowed(_ combo: KeyCombo) -> Bool {
        combo.isValidShortcut && KeyReservation.system[combo] == nil
    }

    /// What `assign(combo, to: id)` would do, without doing it.
    public func check(_ combo: KeyCombo, for id: String) -> Outcome {
        guard let c = index[id] else { return .unknownCommand }
        guard c.remappable else { return .refused("This key can't be changed.") }
        guard combo.isValidShortcut else { return .refused("A shortcut needs ⌘, ⌥ or ⌃.") }
        if let r = KeyReservation.system[combo] { return .refused("\(combo.display) is for \(r).") }
        if keys[id] == combo { return .unchanged }
        if let other = owners[combo] { return .conflict(other) }
        return .done
    }

    /// Gives `id` the key `combo` (nil: no shortcut).
    @discardableResult
    public mutating func assign(_ combo: KeyCombo?, to id: String, resolving: Resolution = .refuse) -> Outcome {
        guard let c = index[id] else { return .unknownCommand }
        guard c.remappable else { return .refused("This key can't be changed.") }
        guard let combo else {
            if keys[id] == nil { return .unchanged }
            set(id, nil)
            resolve()
            return .done
        }
        switch check(combo, for: id) {
        case .done: break
        case .conflict(let other):
            switch resolving {
            case .refuse: return .conflict(other)
            case .swap: set(other, keys[id])
            case .clearOther: set(other, nil)
            }
        case let o: return o
        }
        set(id, combo)
        resolve()
        return .done
    }

    /// `id` back to its default key and Websites first. If another command has that key now, `resolving` decides as in
    /// `assign` (and on `.conflict` nothing changes, the priority neither).
    @discardableResult
    public mutating func reset(_ id: String, resolving: Resolution = .refuse) -> Outcome {
        guard let c = index[id] else { return .unknownCommand }
        guard c.remappable else { aircFirst.remove(id); return .done }
        let o = resetKey(c, resolving: resolving)
        if o == .done { aircFirst.remove(id) }
        return o
    }

    private mutating func resetKey(_ c: Command, resolving: Resolution) -> Outcome {
        let id = c.id
        guard let d = c.defaultKey else {
            overrides[id] = nil
            resolve()
            return .done
        }
        let o = assign(d, to: id, resolving: resolving)
        if o == .unchanged { overrides[id] = nil; resolve(); return .done }
        return o
    }

    public mutating func resetAll() {
        overrides = [:]
        aircFirst = []
        resolve()
    }

    private mutating func set(_ id: String, _ key: KeyCombo?) {
        if key == index[id]?.defaultKey { overrides[id] = nil } else { overrides[id] = .some(key) }
    }

    /// The keys now: the user's first (in command order), then the defaults nobody took.
    private mutating func resolve() {
        keys = [:]
        owners = [:]
        for c in commands where c.remappable {
            guard let o = overrides[c.id], let k = o, owners[k] == nil else { continue }
            keys[c.id] = k
            owners[k] = c.id
        }
        for c in commands where c.remappable && overrides[c.id] == nil {
            guard let k = c.defaultKey, owners[k] == nil else { continue }
            keys[c.id] = k
            owners[k] = c.id
        }
        // An override that lost its key to an earlier command's (two in a hand-edited file) means no key: keep it so.
        for c in commands {
            if let o = overrides[c.id], let k = o, owners[k] != c.id { overrides[c.id] = .some(nil) }
        }
    }

    public static func == (a: ShortcutMap, b: ShortcutMap) -> Bool {
        a.commands == b.commands && a.overrides == b.overrides && a.aircFirst == b.aircFirst
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

// What the person sees of agents at work (docs/user/agents.md, "Follow along"): the sidebar's Agents folder (one row
// per agent tab, acting or idle, then Done), Watch's caption of the current tool call, and Settings › Agents ›
// Activity, a short history per app. None of it ever holds page content, typed text or a field's value: a caption
// names at most the visible label of what is acted on ("Clicking ‘Archive’"), and the history not even that.

/// One kind of agent tool call, for captions and history.
public enum AgentActionKind: String, Codable, Sendable, CaseIterable {
    case open, navigate, click, type, key, scroll, drag, read, look, find, fill, wait, tab, other

    /// The kind of a tool by its MCP name (the browser tools and Anthropic's computer-use members).
    public static func of(tool: String, action: String? = nil) -> AgentActionKind {
        switch tool == "computer" ? (action ?? "") : tool {
        case "open_window", "open_tab": return .open
        case "navigate", "go_back", "go_forward", "reload": return .navigate
        case "left_click", "right_click", "middle_click", "double_click", "triple_click", "left_mouse_down", "left_mouse_up": return .click
        case "type": return .type
        case "key", "hold_key": return .key
        case "scroll": return .scroll
        case "left_click_drag", "mouse_move": return .drag
        case "read_page": return .read
        case "screenshot", "zoom": return .look
        case "find_element": return .find
        case "fill_saved_login": return .fill
        case "wait", "wait_for_load": return .wait
        case "select_tab", "close_tab", "list_tabs": return .tab
        default: return .other
        }
    }
}

/// One tool call as the person may see it. `label` is the visible name of the element acted on (a button's text, a
/// field's label), never a value; `keyName` only a named key or a shortcut, never a typed character.
public struct AgentAction: Equatable, Sendable {
    public var kind: AgentActionKind
    public var label: String?
    public var isPasswordField: Bool
    public var keyName: String?
    public var host: String?

    public init(kind: AgentActionKind, label: String? = nil, isPasswordField: Bool = false, keyName: String? = nil, host: String? = nil) {
        self.kind = kind
        self.label = AgentRedaction.label(label)
        self.isPasswordField = isPasswordField
        self.keyName = keyName
        self.host = host
    }
}

public enum AgentRedaction {
    public static let maxLabel = 40

    /// A label safe to show: one line, at most 40 characters, nothing that looks like a code, card or address. Nil when
    /// nothing is left.
    public static func label(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let one = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !one.isEmpty else { return nil }
        // Six or more digits: a code, a card or a phone number shown as a button's text. An @: an address.
        if one.filter(\.isNumber).count >= 6 || one.contains("@") { return nil }
        if one.count <= maxLabel { return one }
        return String(one.prefix(maxLabel - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The site of an address, for rows, captions and history: its host only (no path, query or fragment), without
    /// "www.". Nil for about:blank and other addresses without a host.
    public static func site(_ url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A row's site name: the page title's short form when it names the site ("Inbox (3) - Gmail" → "Gmail", a title
    /// that is only a name: "Pastelaria Aurora"), else the site. Only a trailing " - Name" / " | Name" / " · Name" part,
    /// or a whole title without separators, of 24 characters or less counts, and no digits-heavy one or address.
    public static func siteName(title: String, url: URL?) -> String {
        func name(_ s: Substring) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && t.count <= 24 && t.filter(\.isNumber).count < 3 && !t.contains("@") && !t.contains("/") ? t : nil
        }
        let seps = [" - ", " | ", " · ", " — ", " – "]
        for sep in seps {
            if let r = title.range(of: sep, options: .backwards), let n = name(title[r.upperBound...]) { return n }
        }
        if !seps.contains(where: { title.contains($0) }), let n = name(title[...]) { return n }
        return site(url) ?? "New page"
    }

    /// The key of a `key` call, when it's a named key or a shortcut: "Return", "Tab", "⌘A". A lone character is
    /// typing, and stays unnamed.
    public static func keyName(_ combo: String) -> String? {
        var parts = combo.split(separator: "+", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        let named: [String: String] = ["return": "Return", "enter": "Return", "kp_enter": "Return", "tab": "Tab", "escape": "Escape",
                                       "esc": "Escape", "backspace": "Delete", "delete": "Forward Delete", "space": "Space",
                                       "up": "↑", "down": "↓", "left": "←", "right": "→", "arrowup": "↑", "arrowdown": "↓",
                                       "arrowleft": "←", "arrowright": "→", "home": "Home", "end": "End", "page_up": "Page Up",
                                       "page_down": "Page Down", "pageup": "Page Up", "pagedown": "Page Down"]
        var mods = ""
        for p in parts {
            switch p.lowercased() {
            case "ctrl", "control": mods += "⌃"
            case "alt", "option", "opt": mods += "⌥"
            case "shift": mods += "⇧"
            case "super", "cmd", "command", "meta", "win": mods += "⌘"
            default: return nil
            }
        }
        let low = last.lowercased()
        if let n = named[low] { return mods + n }
        if low.count >= 2, low.hasPrefix("f"), Int(low.dropFirst()).map({ (1...12).contains($0) }) == true { return mods + last.uppercased() }
        // A character with ⌘ or ⌃ is a shortcut; without, it's typing (or ⇧/⌥ typing): unnamed.
        guard last.count == 1, mods.contains("⌘") || mods.contains("⌃") else { return nil }
        return mods + last.uppercased()
    }

    private static func quoted(_ s: String) -> String { "‘" + s + "’" }

    /// Watch's caption for a call in progress.
    public static func caption(_ a: AgentAction) -> String {
        switch a.kind {
        case .open, .navigate: return a.host.map { "Opening \($0)" } ?? "Opening a page"
        case .click: return a.label.map { "Clicking " + quoted($0) } ?? "Clicking"
        case .type:
            if let l = a.label { return "Typing in " + quoted(l) + (a.isPasswordField ? " (hidden)" : "") }
            return a.isPasswordField ? "Typing a password" : "Typing…"
        case .key: return a.keyName.map { "Pressing \($0)" } ?? "Typing…"
        case .scroll: return "Scrolling"
        case .drag: return "Moving the pointer"
        case .read: return "Reading the page"
        case .look: return "Looking at the page"
        case .find: return "Finding something on the page"
        case .fill: return "Filling a saved login"
        case .wait: return "Waiting for the page"
        case .tab: return "Switching tabs"
        case .other: return "Working…"
        }
    }

    /// The history's words for a call: its kind only, never a label.
    public static func summary(_ a: AgentAction) -> String? {
        switch a.kind {
        case .open, .navigate: return "Opened a page"
        case .click: return "Clicked"
        case .type: return a.isPasswordField ? "Typed in a password field" : "Typed in a field"
        case .key: return a.keyName.map { "Pressed \($0)" } ?? "Typed in a field"
        case .scroll: return "Scrolled"
        case .drag: return "Moved the pointer"
        case .read: return "Read the page"
        case .look: return "Took a screenshot"
        case .find: return "Looked for an element"
        case .fill: return "Filled a saved login"
        case .tab: return "Switched tabs"
        case .wait, .other: return nil
        }
    }
}

// MARK: - The Agents folder's rows

/// One agent tab, as the Agents folder shows it.
public struct AgentTabRow: Equatable, Identifiable, Sendable {
    public enum End: String, Sendable { case done, stopped, takenOver }

    public var id: String
    /// The connection the tab belongs to (AgentSession.ownerKey).
    public var sessionKey: String
    /// The app's identity (AgentClientIdentity.key), for Stop and Allow again.
    public var clientKey: String?
    public var client: String
    public var profileID: String
    public var window: Int
    public var tab: Int
    public var title: String
    public var url: URL?
    public var started: Date
    public var lastAction: Date?
    public var caption: String?
    public var ended: Date?
    public var end: End?

    public init(id: String, sessionKey: String, clientKey: String?, client: String, profileID: String, window: Int, tab: Int,
                title: String = "", url: URL? = nil, started: Date) {
        self.id = id; self.sessionKey = sessionKey; self.clientKey = clientKey; self.client = client
        self.profileID = profileID; self.window = window; self.tab = tab; self.title = title; self.url = url; self.started = started
    }

    /// "Claude · Gmail".
    public var label: String { client + " · " + AgentRedaction.siteName(title: title, url: url) }
    public var site: String? { AgentRedaction.site(url) }
    public var isLive: Bool { ended == nil }
}

/// What a row shows now.
public enum AgentRowState: Equatable, Sendable {
    case acting(String?)
    case idle
    /// "Done" (or "Stopped", "You took over") right after the end.
    case justEnded(AgentTabRow.End)
    /// Faded: "Ended 5 min ago".
    case faded(AgentTabRow.End, minutes: Int)
}

/// The Agents folder's model: rows per agent tab, live while their connection is, then Done, faded, and gone 30 minutes
/// after their end. Calls in flight make a row "acting" (the pulsing dot), and it stays so for a moment after each one
/// so a loop of quick calls reads as one stretch of work.
public struct AgentActivityModel: Sendable {
    public static let actingTail: TimeInterval = 1.5
    public static let justEndedFor: TimeInterval = 90
    public static let keepFor: TimeInterval = 30 * 60

    public private(set) var rows: [AgentTabRow] = []
    private var inFlight: [String: Int] = [:]

    public init() {}

    public func row(_ id: String) -> AgentTabRow? { rows.first { $0.id == id } }

    public static func rowID(window: Int, tab: Int) -> String { "agent-\(window)-\(tab)" }

    /// A call of this row is running now.
    public func isBusy(_ id: String) -> Bool { inFlight[id] != nil }

    /// A new agent tab. True when it's its connection's first row (the start banner).
    @discardableResult
    public mutating func tabOpened(_ row: AgentTabRow) -> Bool {
        let first = !rows.contains { $0.sessionKey == row.sessionKey && $0.isLive }
        rows.removeAll { $0.id == row.id }
        rows.append(row)
        return first
    }

    public mutating func update(_ id: String, title: String, url: URL?) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].title = title
        rows[i].url = url
    }

    public mutating func began(_ id: String, caption: String, at now: Date) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].isLive else { return }
        inFlight[id, default: 0] += 1
        rows[i].caption = caption
        rows[i].lastAction = now
    }

    public mutating func finished(_ id: String, at now: Date) {
        if let n = inFlight[id] { inFlight[id] = n > 1 ? n - 1 : nil }
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].lastAction = now
    }

    /// A caption more precise than the call's first one (the element's label arrived, during the call or just after).
    public mutating func refine(_ id: String, caption: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].isLive else { return }
        rows[i].caption = caption
    }

    public mutating func ended(_ id: String, _ end: AgentTabRow.End, at now: Date) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].isLive else { return }
        rows[i].ended = now
        rows[i].end = end
        rows[i].caption = nil
        inFlight[id] = nil
    }

    /// Every live row of a connection ends (it disconnected, or the person stopped its app).
    public mutating func sessionEnded(_ sessionKey: String, _ end: AgentTabRow.End, at now: Date) {
        for r in rows where r.sessionKey == sessionKey && r.isLive { ended(r.id, end, at: now) }
    }

    /// "Clear": the rows that ended go.
    public mutating func clearEnded() { rows.removeAll { !$0.isLive } }

    /// Rows that ended more than 30 minutes ago go. True when any went.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let before = rows.count
        rows.removeAll { r in r.ended.map { now.timeIntervalSince($0) > Self.keepFor } ?? false }
        return rows.count != before
    }

    public func state(_ r: AgentTabRow, now: Date) -> AgentRowState {
        if let ended = r.ended, let end = r.end {
            let age = now.timeIntervalSince(ended)
            return age < Self.justEndedFor ? .justEnded(end) : .faded(end, minutes: max(1, Int(age / 60)))
        }
        if inFlight[r.id] != nil { return .acting(r.caption) }
        if let last = r.lastAction, now.timeIntervalSince(last) < Self.actingTail { return .acting(r.caption) }
        return .idle
    }

    public func isActing(_ id: String, now: Date) -> Bool {
        guard let r = row(id) else { return false }
        if case .acting = state(r, now: now) { return true }
        return false
    }

    /// The rows a window shows: its current profile's (never another profile's: their sites aren't this one's).
    public func rows(profileID: String) -> [AgentTabRow] {
        rows.filter { $0.profileID == profileID }.sorted { ($0.isLive ? 0 : 1, $0.started) < ($1.isLive ? 0 : 1, $1.started) }
    }

    /// When the model next changes by itself (an acting tail ending, Done fading, a minute passing, a row going): the
    /// folder's timer runs only then, so nothing ticks while nothing is on screen to change.
    public func nextChange(after now: Date) -> Date? {
        var next: Date?
        func consider(_ d: Date) { if d > now, next.map({ d < $0 }) ?? true { next = d } }
        for r in rows {
            if let ended = r.ended {
                consider(ended.addingTimeInterval(Self.justEndedFor))
                let age = now.timeIntervalSince(ended)
                consider(now.addingTimeInterval(60 - age.truncatingRemainder(dividingBy: 60)))
                consider(ended.addingTimeInterval(Self.keepFor + 1))
            } else if inFlight[r.id] == nil, let last = r.lastAction {
                consider(last.addingTimeInterval(Self.actingTail))
            }
        }
        return next
    }
}

// MARK: - History (Settings › Agents › Activity)

/// A stretch of one app's work on one site: when, where (the host only) and what kinds of things it did.
public struct AgentHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public struct Count: Codable, Equatable, Sendable {
        public var summary: String
        public var count: Int
    }
    public var id: UUID
    public var client: String
    public var site: String
    public var start: Date
    public var end: Date
    public var actions: [Count]

    /// "Clicked 4×, Typed in a field 2×, Read the page".
    public var line: String {
        actions.map { $0.count > 1 ? "\($0.summary) \($0.count)×" : $0.summary }.joined(separator: ", ")
    }
}

/// The history file: per app and site, kept 7 days, 0600 in the data folder. Calls on the same site by the same app
/// within 5 minutes of each other join one entry.
public struct AgentHistory: Sendable {
    public static let keepFor: TimeInterval = 7 * 24 * 3600
    public static let joinWithin: TimeInterval = 5 * 60
    public static let maxEntries = 2000

    public private(set) var entries: [AgentHistoryEntry] = []
    public private(set) var dirty = false

    public init() {}

    public init(data: Data?, now: Date) {
        if let data, let list = try? Self.decoder.decode([AgentHistoryEntry].self, from: data) { entries = list }
        if prune(now: now) { dirty = true }
    }

    /// Records one call (nothing for calls without a summary: waits, listings).
    public mutating func record(client: String, site: String?, action: AgentAction, at now: Date) {
        guard let summary = AgentRedaction.summary(action) else { return }
        let site = site ?? "a blank page"
        dirty = true
        if let i = entries.lastIndex(where: { $0.client == client }), entries[i].site == site,
           now.timeIntervalSince(entries[i].end) <= Self.joinWithin {
            entries[i].end = now
            if let j = entries[i].actions.firstIndex(where: { $0.summary == summary }) { entries[i].actions[j].count += 1 }
            else { entries[i].actions.append(.init(summary: summary, count: 1)) }
            return
        }
        entries.append(AgentHistoryEntry(id: UUID(), client: client, site: site, start: now, end: now,
                                         actions: [.init(summary: summary, count: 1)]))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let before = entries.count
        entries.removeAll { now.timeIntervalSince($0.end) > Self.keepFor }
        if entries.count != before { dirty = true }
        return entries.count != before
    }

    public mutating func clear() {
        entries.removeAll()
        dirty = true
    }

    public struct Group: Identifiable, Equatable, Sendable {
        public let client: String
        public let entries: [AgentHistoryEntry]
        public var id: String { client }
    }

    /// The newest first, grouped by app (Settings shows a few per app).
    public func byClient(limit: Int = 8) -> [Group] {
        var order: [String] = []
        var groups: [String: [AgentHistoryEntry]] = [:]
        for e in entries.reversed() {
            if groups[e.client] == nil { order.append(e.client) }
            if groups[e.client, default: []].count < limit { groups[e.client, default: []].append(e) }
        }
        return order.map { Group(client: $0, entries: groups[$0] ?? []) }
    }

    /// The file's bytes (marks the history saved).
    public mutating func encoded() -> Data? {
        dirty = false
        return try? Self.encoder.encode(entries)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

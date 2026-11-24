// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

// What the person sees of agents at work (docs/user/agents.md, "Follow along"): the sidebar's Agents folder (one row
// per agent tab, acting or idle, then Done), Watch's caption of the current tool call, and Settings › Agents ›
// Activity, a short history per app. None of it ever holds page content, typed text or a field's value: a caption
// names at most the visible label of what is acted on ("Clicking ‘Archive’"), and the history not even that.

/// One kind of agent tool call, for captions and history.
public enum AgentActionKind: String, Codable, Sendable, CaseIterable {
    case open, navigate, click, type, key, scroll, drag, read, look, find, fill, wait, tab, other
    /// agentrecall: search_history, the person's history and tabs in the session's profile.
    case recall

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
        case "search_history": return .recall
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

    /// The Airc Agent's row title from the person's task: one line, at most 48 characters. Nil when empty.
    public static func taskTitle(_ task: String) -> String? {
        let one = task.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !one.isEmpty else { return nil }
        if one.count <= 48 { return one }
        var cut = String(one.prefix(47))
        // At a word's end when one is near (never mid-word "sho…").
        if one.dropFirst(47).first?.isWhitespace == false, let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= 24 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

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
        case .recall: return AgentRecall.runningCaption
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
        case .recall: return "Searched your history"
        case .wait, .other: return nil
        }
    }
}

// MARK: - What an agent did in a tab (the row's title)

extension AgentActionKind {
    /// Calls that do something a person would call work (not a look at a blank window, a listing or a wait).
    public var isActing: Bool {
        switch self {
        case .navigate, .click, .type, .key, .scroll, .drag, .fill: return true
        case .open, .read, .look, .find, .wait, .tab, .other, .recall: return false
        }
    }
}

extension AgentRiskCategory {
    /// A row title's words for an approved action: "paid (approved)".
    public var approvedWords: String {
        switch self {
        case .payment: return "paid (approved)"
        case .send: return "sent (approved)"
        case .post: return "posted (approved)"
        case .delete: return "deleted (approved)"
        case .account: return "changed the account (approved)"
        }
    }
}

/// Sites and kinds of actions of one agent tab, for its row's title, Arc-like: the main site and the kind of work
/// ("Gmail · read 3 pages", "cornershop.example · filled a form, paid (approved)"). It keeps hosts, short site names and
/// counts only: a page is remembered as a hash of its host and path, never its address, text or what was typed.
public struct AgentWorkSummary: Equatable, Sendable {
    /// Hosts in the order first seen, with how much happened there.
    public private(set) var hosts: [String] = []
    public private(set) var weight: [String: Int] = [:]
    /// The short site name per host ("Gmail" for mail.google.com), from its page titles (AgentRedaction.siteName).
    public private(set) var names: [String: String] = [:]
    public private(set) var pages: Set<Int> = []
    public private(set) var kinds: [AgentActionKind: Int] = [:]
    public private(set) var returns = 0
    public private(set) var approvals: [AgentRiskCategory] = []

    public init() {}

    private mutating func touch(_ host: String, _ n: Int) {
        if weight[host] == nil { hosts.append(host) }
        weight[host, default: 0] += n
    }

    /// A page the tab showed.
    public mutating func page(url: URL?, name: String) {
        guard let url, let host = AgentRedaction.site(url) else { return }
        var h = Hasher()
        h.combine(host)
        h.combine(url.path)
        if pages.insert(h.finalize()).inserted { touch(host, 1) }
        if name != host || names[host] == nil { names[host] = name }
    }

    /// A call that went through.
    public mutating func record(_ a: AgentAction, host: String?) {
        guard a.kind != .wait, a.kind != .other, a.kind != .tab, a.kind != .recall else { return }
        kinds[a.kind, default: 0] += 1
        if a.kind == .key, a.keyName == "Return" { returns += 1 }
        if let host, a.kind != .open { touch(host, 1) }
    }

    public mutating func approve(_ c: AgentRiskCategory) {
        if !approvals.contains(c) { approvals.append(c) }
    }

    /// The kinds of work, most telling first: "signed in", "searched" / "filled a form", "read 3 pages" …
    public var phrases: [String] {
        var out: [String] = []
        let typed = (kinds[.type] ?? 0)
        if kinds[.fill] != nil { out.append("signed in") }
        if typed == 1, returns > 0, (kinds[.click] ?? 0) <= 1 { out.append("searched") }
        else if typed > 0 { out.append("filled a form") }
        let reads = (kinds[.read] ?? 0) + (kinds[.look] ?? 0) + (kinds[.find] ?? 0)
        let n = pages.count
        if n >= 2 { out.append(reads > 0 ? "read \(n) pages" : "browsed \(n) pages") }
        else if reads > 0, out.isEmpty { out.append("read a page") }
        let clicks = kinds[.click] ?? 0
        if out.isEmpty, clicks > 0 { out.append(clicks == 1 ? "clicked once" : "clicked \(clicks)×") }
        if out.isEmpty, kinds[.scroll] != nil || kinds[.drag] != nil { out.append("scrolled") }
        // At most two kinds of work, and every approval (they matter most).
        let work = Array(out.prefix(approvals.isEmpty ? 2 : 1))
        return work + approvals.prefix(2).map(\.approvedWords)
    }

    /// The main site: the one with most pages and actions (the first seen on a tie).
    public var mainHost: String? {
        hosts.max { (weight[$0] ?? 0, -(hosts.firstIndex(of: $0) ?? 0)) < (weight[$1] ?? 0, -(hosts.firstIndex(of: $1) ?? 0)) }
    }

    /// "Gmail · read 3 pages"; "Gmail +2 · browsed 5 pages" when other sites had work too; only the site when nothing
    /// but the page happened. `current`: the shown page's site name, used when nothing was recorded yet.
    public func title(current: String?, currentHost: String?) -> String {
        let host = mainHost ?? currentHost
        var site = host.map { names[$0] ?? (host == currentHost ? current : nil) ?? $0 } ?? current ?? "New page"
        let others = hosts.filter { $0 != host }.count
        if others > 0 { site += " +\(others)" }
        let p = phrases
        return p.isEmpty ? site : site + " · " + p.joined(separator: ", ")
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
    /// Shown in the folder: only once the agent did something real in this tab (a page with a site, or an acting call).
    /// A connection that only opens a blank window, or never acts, gets no row.
    public var shown = false
    /// What the agent did in this tab, for the title ("Gmail · read 3 pages"): sites and kinds of actions only.
    public var work = AgentWorkSummary()
    /// The Airc Agent's task (the person's own words in the panel), its row's title.
    public var task: String?
    /// The last time an ended row was held on screen (watched, or its taken-over page shown): its time to go counts
    /// from then, so it never vanishes under the person.
    public var heldAt: Date?
    /// The page needs the person: "Sign in" (a sign-in page, a 401, an SSO step) or "Captcha". The row says "Needs
    /// you", the folder gets a badge, until the page no longer asks.
    public var needsYou: String?

    public init(id: String, sessionKey: String, clientKey: String?, client: String, profileID: String, window: Int, tab: Int,
                title: String = "", url: URL? = nil, started: Date) {
        self.id = id; self.sessionKey = sessionKey; self.clientKey = clientKey; self.client = client
        self.profileID = profileID; self.window = window; self.tab = tab; self.title = title; self.url = url; self.started = started
    }

    /// "Claude · Gmail" (Watch's header, the banner).
    public var label: String { client + " · " + AgentRedaction.siteName(title: title, url: url) }
    /// The folder row's title: what happened ("Gmail · read 3 pages", "cornershop.example · filled a form, paid
    /// (approved)"), or the Airc Agent's task. Never page content, typed text or a field's value.
    public var rowTitle: String {
        if let task, let t = AgentRedaction.taskTitle(task) { return t }
        return work.title(current: url.flatMap { AgentRedaction.site($0) } != nil ? AgentRedaction.siteName(title: title, url: url) : nil,
                          currentHost: AgentRedaction.site(url))
    }
    public var site: String? { AgentRedaction.site(url) }
    public var isLive: Bool { ended == nil }
}

/// What a row shows now.
public enum AgentRowState: Equatable, Sendable {
    case acting(String?)
    case idle
    /// "Needs you · Sign in": the agent's page waits for the person.
    case needsYou(String)
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
    /// How long a finished row stays by default (Settings › Agents › "Keep finished agents for"): 5 minutes.
    public static let defaultKeep: TimeInterval = 5 * 60
    /// How often held rows (watched, taken over) are looked at again once they ended.
    public static let holdRecheck: TimeInterval = 15

    public private(set) var rows: [AgentTabRow] = []
    private var inFlight: [String: Int] = [:]
    /// The Airc Agent's task per connection (rows opened later take it too).
    private var tasks: [String: String] = [:]
    /// How long finished rows stay after their end (or after they were last held); nil: until the person clears them.
    public var keepFinished: TimeInterval? = AgentActivityModel.defaultKeep

    public init() {}

    public func row(_ id: String) -> AgentTabRow? { rows.first { $0.id == id } }

    public static func rowID(window: Int, tab: Int) -> String { "agent-\(window)-\(tab)" }

    /// A call of this row is running now.
    public func isBusy(_ id: String) -> Bool { inFlight[id] != nil }

    /// A new agent tab. True when it's shown at once (it opened on a page with a site) as its connection's first shown
    /// row (the start banner). A blank tab stays hidden until `reveal`.
    @discardableResult
    public mutating func tabOpened(_ row: AgentTabRow) -> Bool {
        var row = row
        row.task = row.task ?? tasks[row.sessionKey]
        rows.removeAll { $0.id == row.id }
        rows.append(row)
        if AgentRedaction.site(row.url) != nil { return reveal(row.id) == true }
        return false
    }

    /// The tab's page changed. True when that revealed the row as its connection's first shown row (the banner).
    @discardableResult
    public mutating func update(_ id: String, title: String, url: URL?) -> Bool {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return false }
        rows[i].title = title
        rows[i].url = url
        guard rows[i].isLive, AgentRedaction.site(url) != nil else { return false }
        rows[i].work.page(url: url, name: AgentRedaction.siteName(title: title, url: url))
        return reveal(id) == true
    }

    /// The row shows from now on (the agent did something real). Nil when it already showed (or is gone or ended), true
    /// when it's its connection's first shown live row (the start banner), false otherwise.
    @discardableResult
    public mutating func reveal(_ id: String) -> Bool? {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].isLive, !rows[i].shown else { return nil }
        let first = !rows.contains { $0.sessionKey == rows[i].sessionKey && $0.isLive && $0.shown }
        rows[i].shown = true
        return first
    }

    public mutating func began(_ id: String, caption: String, at now: Date) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].isLive else { return }
        inFlight[id, default: 0] += 1
        rows[i].caption = caption
        rows[i].lastAction = now
    }

    /// A call's kind, for the row's title (counted when it went through). Acting calls reveal the row; true when that
    /// made it its connection's first shown row (the banner).
    @discardableResult
    public mutating func did(_ id: String, _ action: AgentAction) -> Bool {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].isLive else { return false }
        rows[i].work.record(action, host: action.host ?? rows[i].site)
        return action.kind.isActing ? reveal(id) == true : false
    }

    /// The person approved a risky action in this tab (the Airc Agent's approval card): "paid (approved)".
    public mutating func approved(_ id: String, _ category: AgentRiskCategory) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].isLive else { return }
        rows[i].work.approve(category)
    }

    /// The Airc Agent's task: its connection's rows take it as their title.
    public mutating func setTask(_ sessionKey: String, _ task: String) {
        tasks[sessionKey] = task
        for i in rows.indices where rows[i].sessionKey == sessionKey && rows[i].isLive { rows[i].task = task }
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
        // A row that never showed (no real action) leaves no trace in the folder.
        guard rows[i].shown else {
            rows.remove(at: i)
            inFlight[id] = nil
            return
        }
        rows[i].ended = now
        rows[i].end = end
        rows[i].caption = nil
        inFlight[id] = nil
    }

    /// Every live row of a connection ends (it disconnected, or the person stopped its app).
    public mutating func sessionEnded(_ sessionKey: String, _ end: AgentTabRow.End, at now: Date) {
        for r in rows where r.sessionKey == sessionKey && r.isLive { ended(r.id, end, at: now) }
        if !rows.contains(where: { $0.sessionKey == sessionKey && $0.isLive }) { tasks[sessionKey] = nil }
    }

    /// "Clear": the rows that ended go.
    /// The page needs the person (nil: not any more). True when that changed. A row that needs the person shows.
    @discardableResult
    public mutating func setNeedsYou(_ id: String, _ reason: String?) -> Bool {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].isLive, rows[i].needsYou != reason else { return false }
        rows[i].needsYou = reason
        if reason != nil { rows[i].shown = true }
        return true
    }

    /// Live rows that wait for the person (the folder's badge).
    public var needsYouCount: Int { rows.filter { $0.isLive && $0.shown && $0.needsYou != nil }.count }

    public mutating func clearEnded() { rows.removeAll { !$0.isLive } }

    /// Ended rows the person has on screen now (watching it, or its taken-over page shown) stay: their time to go
    /// starts again from now.
    public mutating func hold(_ ids: Set<String>, now: Date) {
        for i in rows.indices where !rows[i].isLive && ids.contains(rows[i].id) { rows[i].heldAt = now }
    }

    /// When an ended row goes by itself: `keepFinished` after its end or after it was last held; nil: it stays.
    public func goesAt(_ r: AgentTabRow) -> Date? { Self.goesAt(r, keep: keepFinished) }

    static func goesAt(_ r: AgentTabRow, keep: TimeInterval?) -> Date? {
        guard let ended = r.ended, let keep else { return nil }
        return max(ended, r.heldAt ?? ended).addingTimeInterval(keep)
    }

    /// Finished rows whose time is up go (Settings › Agents › "Keep finished agents for", 5 minutes by default). True
    /// when any went. Rows in `held` stay (see `hold`).
    @discardableResult
    public mutating func prune(now: Date, held: Set<String> = []) -> Bool {
        hold(held, now: now)
        let before = rows.count
        let keep = keepFinished
        rows.removeAll { r in Self.goesAt(r, keep: keep).map { now >= $0 } ?? false }
        return rows.count != before
    }

    public func state(_ r: AgentTabRow, now: Date) -> AgentRowState {
        if let ended = r.ended, let end = r.end {
            let age = now.timeIntervalSince(ended)
            return age < min(Self.justEndedFor, keepFinished.map { $0 / 2 } ?? Self.justEndedFor) ? .justEnded(end)
                : .faded(end, minutes: max(1, Int(age / 60)))
        }
        if inFlight[r.id] != nil { return .acting(r.caption) }
        if let last = r.lastAction, now.timeIntervalSince(last) < Self.actingTail { return .acting(r.caption) }
        // Once the agent stops acting (it may still fill a saved login itself).
        if let n = r.needsYou { return .needsYou(n) }
        return .idle
    }

    public func isActing(_ id: String, now: Date) -> Bool {
        guard let r = row(id) else { return false }
        if case .acting = state(r, now: now) { return true }
        return false
    }

    /// The rows a window shows: its current profile's (never another profile's: their sites aren't this one's), and only
    /// those that did something real.
    public func rows(profileID: String) -> [AgentTabRow] {
        rows.filter { $0.profileID == profileID && $0.shown }.sorted { ($0.isLive ? 0 : 1, $0.started) < ($1.isLive ? 0 : 1, $1.started) }
    }

    /// agentrows (2026-11-23): the Agents folder's rows, one per agent session rather than one per agent tab. A session
    /// is one task: an app with three pages open is one row, not three. Its row is the page that matters most: a live
    /// one over an ended one, then one that needs the person (so a click lands on it), then the latest to act. Rows of
    /// `excluding` (the Airc Agent's own runs, listed as their task) are left out: they'd be the same task twice.
    public func sessionRows(profileID: String, excluding clientKey: String? = nil) -> [AgentTabRow] {
        Self.perSession(rows(profileID: profileID), excluding: clientKey)
    }

    /// `rows` (in their order) cut to one per session, as `sessionRows` does. The All tasks page uses it on every profile's rows.
    public static func perSession(_ rows: [AgentTabRow], excluding clientKey: String? = nil) -> [AgentTabRow] {
        var best: [String: AgentTabRow] = [:]
        var order: [String] = []
        func rank(_ r: AgentTabRow) -> (Int, Int, Double) {
            (r.isLive ? 0 : 1, r.needsYou != nil && r.isLive ? 0 : 1, -(r.ended ?? r.lastAction ?? r.started).timeIntervalSinceReferenceDate)
        }
        for r in rows where r.shown && (clientKey == nil || r.clientKey != clientKey) {
            guard let b = best[r.sessionKey] else { best[r.sessionKey] = r; order.append(r.sessionKey); continue }
            if rank(r) < rank(b) { best[r.sessionKey] = r }
        }
        return order.compactMap { best[$0] }
    }

    /// When the model next changes by itself (an acting tail ending, Done fading, a minute passing, a row going): the
    /// folder's timer runs only then, so nothing ticks while nothing is on screen to change.
    public func nextChange(after now: Date) -> Date? {
        var next: Date?
        func consider(_ d: Date) { if d > now, next.map({ d < $0 }) ?? true { next = d } }
        for r in rows {
            if let ended = r.ended {
                consider(ended.addingTimeInterval(min(Self.justEndedFor, keepFinished.map { $0 / 2 } ?? Self.justEndedFor)))
                let age = now.timeIntervalSince(ended)
                consider(now.addingTimeInterval(60 - age.truncatingRemainder(dividingBy: 60)))
                if let goes = goesAt(r) { consider(goes) }
                // A row that may be held (watched, taken over) is looked at again now and then.
                if r.heldAt != nil, keepFinished != nil { consider(now.addingTimeInterval(Self.holdRecheck)) }
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

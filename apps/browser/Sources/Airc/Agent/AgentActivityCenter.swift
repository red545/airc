// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// Follow along (docs/user/agents.md): what agents do, for the person. It keeps the Agents folder's rows
/// (AircKit's AgentActivityModel: one per agent tab, acting or idle, then Done), shows the start banner in the window of
/// the agent's profile, feeds Watch (Sidebar/AgentWatchView.swift) the current call's caption, pointer and field, and
/// writes Settings › Agents › Activity's history (AgentActivity.json, 0600, 7 days, kinds of actions only).
///
/// Cost: nothing runs while no agent works. A timer is set only for the model's next change by itself (an acting
/// stretch ending, Done fading), and the page is asked for a label only while someone watches that tab.
final class AgentActivity {
    static let shared = AgentActivity()
    /// Posted (coalesced, main thread) whenever rows, states or the history change.
    static let changed = Notification.Name("AircAgentActivityChanged")

    /// A call in progress, from `began` to `finished`.
    struct Call {
        let row: String?
        var action: AgentAction
        let client: String
        let site: String?
    }

    /// What Watch draws over the page.
    enum WatchEvent {
        case caption(String)
        /// In the agent page's points (the screenshot's pixels).
        case pointer(CGPoint, click: Bool)
        case field(CGRect?, password: Bool)
    }

    private(set) var model = AgentActivityModel()
    private var historyStore: AgentHistory?
    private var saveWork: DispatchWorkItem?
    private var timer: Timer?
    private var posting = false
    private var watchers: [String: [UUID: (WatchEvent) -> Void]] = [:]
    /// Connections whose banner hasn't shown yet (it waits for the first page's site, at most 3 s).
    private var bannerPending: Set<String> = []
    /// The banners shown, newest last (checks read them).
    private(set) var banners: [String] = []
    /// A field's password flag, from Watch's look at the focused field, for that call's history line.
    private var passwordField: [String: Bool] = [:]
    /// A watched click's point, until the click is done and its label can be asked.
    private var pendingLabel: [String: (CGPoint, AgentWindow, EngineTab, URL?)] = [:]
    /// Counts calls per row: a label lookup is dropped when another call started since it was planned.
    private var callCount: [String: Int] = [:]

    var historyFile: URL { AppPaths.dataDirectory.appendingPathComponent("AgentActivity.json") }
    private var center: AgentCenter { .shared }

    private init() {
        // The last few seconds of history are written before quitting.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            AgentActivity.shared.saveNow()
        }
    }

    // MARK: Rows

    /// An agent window's tabs changed (opened, closed, a title or address): its rows follow.
    func windowChanged(_ w: AgentWindow) {
        let now = Date()
        for t in w.tabs {
            let id = AgentActivityModel.rowID(window: w.id, tab: t.id)
            if model.row(id) == nil {
                let row = AgentTabRow(id: id, sessionKey: w.ownerKey, clientKey: w.clientKey, client: w.clientName ?? w.client,
                                      profileID: w.profileID, window: w.id, tab: t.id, title: t.tab.title, url: t.tab.url, started: now)
                if model.tabOpened(row) {
                    bannerPending.insert(w.ownerKey)
                    let key = w.ownerKey
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.showBanner(key, force: true) }
                }
                if center.settings.showInFront {
                    DispatchQueue.main.async { [weak self] in self?.showInFront(id) }
                }
                center.onEvent?("row-open \(id)")
            } else {
                model.update(id, title: t.tab.title, url: t.tab.url)
            }
        }
        for r in model.rows where r.window == w.id && r.isLive && !w.tabs.contains(where: { $0.id == r.tab }) {
            model.ended(r.id, .done, at: now)
        }
        showBanner(w.ownerKey, force: false)
        changed()
    }

    func windowClosed(_ w: AgentWindow, _ end: AgentTabRow.End) {
        let now = Date()
        for r in model.rows where r.window == w.id && r.isLive { model.ended(r.id, end, at: now) }
        changed()
    }

    func sessionEnded(_ ownerKey: String, _ end: AgentTabRow.End) {
        bannerPending.remove(ownerKey)
        model.sessionEnded(ownerKey, end, at: Date())
        changed()
    }

    func ended(_ rowID: String, _ end: AgentTabRow.End) {
        model.ended(rowID, end, at: Date())
        changed()
    }

    /// "Clear" in the Agents folder: the rows that ended go.
    func clearEnded() {
        model.clearEnded()
        changed()
    }

    // MARK: Calls

    /// A tool call is about to run: its row acts, and Watch learns what it does.
    func began(_ tool: String, _ args: [String: Any], session s: AgentSession, center c: AgentCenter) -> Call? {
        let kind = AgentActionKind.of(tool: tool, action: args["action"] as? String)
        let windowID = (args["window"] as? Int) ?? s.currentWindow ?? c.mine(s).last?.id
        let w = windowID.flatMap { c.windows[$0] }.flatMap { $0.ownerKey == s.ownerKey ? $0 : nil }
        let rowID = w.flatMap { w in w.activeTabID.map { AgentActivityModel.rowID(window: w.id, tab: $0) } }
        var host: String?
        if kind == .open || kind == .navigate, let raw = args["url"] as? String { host = AgentRedaction.site(URL(string: raw)) }
        let keyName = kind == .key ? (args["text"] as? String).flatMap(AgentRedaction.keyName) : nil
        let action = AgentAction(kind: kind, keyName: keyName, host: host)
        let call = Call(row: rowID, action: action, client: s.clientName ?? s.client,
                        site: w?.activeTab.flatMap { AgentRedaction.site($0.url) } ?? host)
        guard kind != .other, let rowID, model.row(rowID)?.isLive == true, let w else { return call }
        let caption = AgentRedaction.caption(action)
        callCount[rowID, default: 0] += 1
        model.began(rowID, caption: caption, at: Date())
        if isWatched(rowID), let tab = w.activeTab { annotate(rowID, kind, args, w, tab, keyName: keyName) }
        emit(rowID, .caption(caption))
        changed()
        return call
    }

    func finished(_ call: Call, isError: Bool) {
        let now = Date()
        if let row = call.row {
            model.finished(row, at: now)
            describeClick(row)
            var action = call.action
            if action.kind == .type || (action.kind == .key && action.keyName == nil), passwordField.removeValue(forKey: row) == true {
                action.isPasswordField = true
            }
            if !isError { recordHistory(call.client, call.site, action, now) }
        } else if !isError, call.action.kind == .open || call.action.kind == .navigate {
            recordHistory(call.client, call.site, call.action, now)
        }
        changed()
    }

    /// Only while someone watches: where the pointer goes, and the label and frame of what is clicked or typed into.
    /// The page is asked for names and frames, never values (AgentPageScripts.describe / focusedField).
    private func annotate(_ rowID: String, _ kind: AgentActionKind, _ args: [String: Any], _ w: AgentWindow, _ tab: EngineTab,
                          keyName: String?) {
        let target = (args["coordinate"] as? [Any]).flatMap { a -> CGPoint? in
            guard a.count == 2, let x = (a[0] as? NSNumber)?.doubleValue, let y = (a[1] as? NSNumber)?.doubleValue else { return nil }
            return CGPoint(x: x, y: y)
        }
        switch kind {
        case .click, .drag, .scroll:
            let p = target ?? w.cursor
            emit(rowID, .pointer(p, click: kind == .click))
            guard kind == .click else { return }
            // Asked after the click has gone through (finished), never before it: the page reads it once the agent's
            // input is in, so watching adds nothing to the agent's click.
            pendingLabel[rowID] = (p, w, tab, tab.url)
        case .type, .key where keyName == nil:
            w.driver.evaluate(tab, AgentPageScripts.focusedField) { [weak self] value in
                guard let self, let d = agentJSON(value) else { return }
                let password = d["password"] as? Bool ?? false
                self.passwordField[rowID] = password
                self.emit(rowID, .field(Self.rect(d), password: password))
                let caption = AgentRedaction.caption(AgentAction(kind: .type, label: d["name"] as? String, isPasswordField: password))
                self.model.refine(rowID, caption: caption)
                self.emit(rowID, .caption(caption))
                self.changed()
            }
        default:
            break
        }
    }

    /// The clicked element's label and frame, asked once the click is done.
    private func describeClick(_ rowID: String) {
        guard let pending = pendingLabel.removeValue(forKey: rowID) else { return }
        // Only once the agent has paused (150 ms, no call since): the page never reads a label while the agent's input
        // is on its way, so watching costs the agent nothing. A run of quick clicks keeps "Clicking".
        let planned = callCount[rowID] ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.callCount[rowID] == planned, !self.model.isBusy(rowID) else { return }
            self.lookUpLabel(rowID, pending)
        }
    }

    private func lookUpLabel(_ rowID: String, _ pending: (CGPoint, AgentWindow, EngineTab, URL?)) {
        let (p, w, tab, url) = pending
        // A click that already led to another page would read that page's element: then the caption stays "Clicking".
        guard !tab.isClosed, isWatched(rowID), tab.url == url else { return }
        w.driver.evaluate(tab, AgentPageScripts.describe(x: p.x, y: p.y)) { [weak self] value in
            guard let self, let d = agentJSON(value), tab.url == url else { return }
            let isField = d["field"] as? Bool ?? false
            self.emit(rowID, .field(isField ? Self.rect(d) : nil, password: d["password"] as? Bool ?? false))
            if let name = AgentRedaction.label(d["name"] as? String) {
                let caption = AgentRedaction.caption(AgentAction(kind: .click, label: name))
                self.model.refine(rowID, caption: caption)
                self.emit(rowID, .caption(caption))
                self.changed()
            }
        }
    }

    private static func rect(_ d: [String: Any]) -> CGRect? {
        guard let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue,
              let w = (d["w"] as? NSNumber)?.doubleValue, let h = (d["h"] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Watch

    func watch(_ rowID: String, _ handler: @escaping (WatchEvent) -> Void) -> UUID {
        let token = UUID()
        watchers[rowID, default: [:]][token] = handler
        center.onEvent?("watch-start \(rowID)")
        return token
    }

    func unwatch(_ rowID: String, _ token: UUID) {
        watchers[rowID]?[token] = nil
        if watchers[rowID]?.isEmpty == true { watchers[rowID] = nil }
        center.onEvent?("watch-stop \(rowID)")
    }

    func isWatched(_ rowID: String) -> Bool { watchers[rowID]?.isEmpty == false }
    var watchedCount: Int { watchers.values.reduce(0) { $0 + $1.count } }

    private func emit(_ rowID: String, _ e: WatchEvent) {
        watchers[rowID]?.values.forEach { $0(e) }
    }

    // MARK: The start banner, "show in front"

    /// The browser windows showing a profile now (its Space is the current one), the main window first. Private
    /// windows are never among them.
    func windows(showing profileID: String) -> [WindowController] {
        let all = (center.app?.controllers ?? []).filter { $0.store.space($0.currentSpaceID)?.profileID == profileID }
        return all.filter { $0.window.isMainWindow } + all.filter { !$0.window.isMainWindow }
    }

    /// "Claude is using Airc · Gmail", once per connection, when its first page has a site (or after 3 s): a toast in
    /// the profile's windows. It never takes focus.
    private func showBanner(_ ownerKey: String, force: Bool) {
        guard bannerPending.contains(ownerKey) else { return }
        guard let row = model.rows.first(where: { $0.sessionKey == ownerKey && $0.isLive }) else {
            if force { bannerPending.remove(ownerKey) }
            return
        }
        // Named once the page has its title (a loading page's title is empty or its address).
        let named = row.site != nil && !row.title.isEmpty && !row.title.contains("/") && row.title != row.site
        guard named || force else { return }
        bannerPending.remove(ownerKey)
        let site = row.site != nil ? AgentRedaction.siteName(title: row.title, url: row.url) : nil
        let text = site.map { "\(row.client) is using Airc · \($0)" } ?? "\(row.client) is using Airc"
        banners.append(text)
        for c in windows(showing: row.profileID) { c.showToast(text) }
        center.onEvent?("banner \(text)")
    }

    private func showInFront(_ rowID: String) {
        guard let row = model.row(rowID), row.isLive, !isWatched(rowID), let c = windows(showing: row.profileID).first else { return }
        c.sidebar.agents.openWatch(rowID, takeKeys: false)
    }

    // MARK: History

    var history: AgentHistory {
        if historyStore == nil { historyStore = AgentHistory(data: try? Data(contentsOf: historyFile), now: Date()) }
        return historyStore!
    }

    private func recordHistory(_ client: String, _ site: String?, _ action: AgentAction, _ now: Date) {
        _ = history
        historyStore?.record(client: client, site: site, action: action, at: now)
        saveSoon()
    }

    func clearHistory() {
        _ = history
        historyStore?.clear()
        saveNow()
        changed()
    }

    private func saveSoon() {
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Writes the history now (also at quit, and before checks read the file).
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard var h = historyStore, h.dirty, let data = h.encoded() else { return }
        historyStore = h
        _ = AgentPaths.writePrivate(data, to: historyFile.path)
    }

    // MARK: Changes

    private func changed() {
        let now = Date()
        if model.prune(now: now) { center.onEvent?("rows-pruned") }
        timer?.invalidate()
        timer = nil
        if let next = model.nextChange(after: now) {
            let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in self?.changed() }
            t.tolerance = 0.25
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        guard !posting else { return }
        posting = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.posting = false
            NotificationCenter.default.post(name: AgentActivity.changed, object: self)
        }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import Combine
import UserNotifications

/// "Needs you", in one click (owner feedback 2026-11-20): everything an agent waits on the person for, oldest first, and
/// the one place that takes them there. Every entry point (the macOS notification, Airc's toast, the Agents folder row
/// and its badge, the ✦ button, the Dock icon, the "Claude is using Airc" row) calls `go`/`goNext`, which brings the
/// task's window to the front on its own Space and lands on the thing to answer:
/// - an approval ("Pay on …?"): the agent pane on that task, the approval card pinned above the composer with the keys
///   on its primary button (Return allows once, Esc denies);
/// - a page that waits for the person (a sign-in, a captcha: AgentNeedsYou): the agent's page itself in front (Watch over
///   the window's page), its Take over the primary button (Return takes over).
/// Several waiting: the first click goes to the oldest, each next click to the next one (then round again).
enum AgentAttention {
    enum Kind: Equatable {
        case approval
        /// "Sign in", "Captcha" or "Prompt" (an engine window that waits on the agent's page).
        case page(String)
        /// An agent page's passkey request (AgentPrompts), by its id.
        case prompt(String)
    }

    struct Item: Equatable {
        let id: String
        let kind: Kind
        let since: Date
        /// The Agents folder row (the page for `.page`, the run's page for `.approval`).
        let rowID: String?
        let client: String
        let profileID: String?
        /// "Pay on shop.example?" / "Sign in to Example Mail".
        let title: String
        /// agentparallel: the Airc Agent task it belongs to (an approval, or a page of that task).
        var taskID: String? = nil
    }

    static let changed = Notification.Name("AircAgentAttentionChanged")

    /// When each row's page started waiting (rows only know that they wait).
    private static var pageSince: [String: Date] = [:]
    /// When each waiting approval was asked (by request id).
    private static var approvalSince: [UUID: Date] = [:]
    /// The approvals announced so far (agentparallel: one per waiting task).
    private static var announced: [String: UUID] = [:]
    /// The item the last click landed on (the next click goes to the one after it).
    private static var lastLanded: String?
    private static var subs: [AnyCancellable] = []
    private static var installed = false

    /// What every check reads: the entry point, the item and the window of the last landing.
    private(set) static var lastLanding: (from: String, item: Item, window: WindowController?)?
    #if AIRC_TESTING
    static var onLand: ((String, Item) -> Void)?
    /// A check starts from nothing landed and nothing posted.
    static func resetForTesting() {
        lastLanded = nil
        lastLanding = nil
        Notifications.resetForTesting()
    }
    #endif

    /// From AgentCenter.launch: follow approvals and page needs; answer notification clicks.
    static func install() {
        guard !installed else { return }
        installed = true
        let isAutomated = (NSApp.delegate as? AppDelegate)?.options.isAutomated == true
        if !isAutomated { UNUserNotificationCenter.current().delegate = NotificationDelegate.shared }
        // Posted on the main thread already, one hop after the run's change (as the single run's approval was followed).
        subs.append(NotificationCenter.default.publisher(for: AgentTaskCenter.changed).sink { _ in approvalsChanged() })
        subs.append(NotificationCenter.default.publisher(for: AgentActivity.changed).receive(on: DispatchQueue.main).sink { _ in rowsChanged() })
    }

    /// Right before `AgentRunCenter.ask`, from every entry point: the task's window, Space and profile (on its run:
    /// agentparallel, each task lands in its own window).
    static func taskAsked(in c: WindowController, run: AgentRunCenter) {
        run.askedIn = c
        run.askedSpaceID = c.currentSpaceID
        run.askedProfileID = c.store.profile(ofSpace: c.currentSpaceID).id
        // The task's page opens in this window too (agentmainfix).
        AgentMainView.shared.asked(run, in: c)
    }

    #if AIRC_TESTING
    /// One-task checks: where the task started last was asked.
    static var taskWindow: WindowController? { AgentRunCenter.shared.askedIn }
    static var paneRowID: String? { paneRowID(for: AgentRunCenter.shared) }
    #endif

    /// The task an item belongs to: its approval's, or the task whose agent window holds its page.
    static func run(of it: Item) -> AgentRunCenter? {
        if let t = it.taskID, let r = AgentTaskCenter.shared.run(task: t) { return r }
        guard let row = it.rowID.flatMap({ AgentActivity.shared.model.row($0) }) else { return nil }
        return AgentTaskCenter.shared.run(agentWindow: row.window)
    }

    /// The task's recorded window, only while it is open and was asked from in the item's profile (an older record from
    /// another profile never takes a "needs you").
    private static func recordedWindow(for it: Item, in all: [WindowController]) -> WindowController? {
        guard let run = run(of: it), let c = run.askedIn, all.contains(where: { $0 === c }) else { return nil }
        if let p = it.profileID {
            guard run.askedProfileID == p, c.windowSpaces.contains(where: { $0.profileID == p }) else { return nil }
        }
        return c
    }

    // MARK: What waits

    static func items() -> [Item] {
        var out: [Item] = []
        // agentparallel: every task waiting for an OK.
        for run in AgentTaskCenter.shared.waiting {
            guard let a = run.approval else { continue }
            out.append(approvalItem(run, a))
        }
        for r in AgentActivity.shared.model.rows where r.isLive && r.shown {
            guard let why = r.needsYou, why != AgentPrompts.reason else { continue }
            let site = AgentRedaction.siteName(title: r.title, url: r.url)
            out.append(Item(id: "page-" + r.id, kind: .page(why), since: pageSince[r.id] ?? r.started, rowID: r.id, client: r.client,
                            profileID: r.profileID, title: why == "Captcha" ? "Captcha on \(site)" : why == "Prompt" ? "\(site) asks for you" : "Sign in to \(site)"))
        }
        // watchfix: a passkey request, on its row while the agent has the page, then on the page the person took over.
        for p in AgentPrompts.shared.prompts {
            let live = AgentActivity.shared.model.row(p.rowID)?.isLive == true
            out.append(Item(id: "prompt-" + p.id, kind: .prompt(p.id), since: p.since, rowID: live ? p.rowID : nil, client: p.client,
                            profileID: p.profileID, title: p.title))
        }
        return out.sorted { $0.since < $1.since }
    }

    static var count: Int { items().count }

    /// The oldest waiting, or the one after the item the last click landed on.
    static func next() -> Item? {
        let all = items()
        guard !all.isEmpty else { return nil }
        if let last = lastLanded, let i = all.firstIndex(where: { $0.id == last }) { return all[(i + 1) % all.count] }
        return all.first
    }

    static func item(row rowID: String) -> Item? {
        items().first { $0.rowID == rowID && $0.kind != .approval } ?? items().first { $0.rowID == rowID }
    }

    private static func approvalItem(_ run: AgentRunCenter, _ a: AgentApprovalRequest) -> Item {
        Item(id: "approval-" + a.id.uuidString, kind: .approval, since: approvalSince[a.id] ?? Date(), rowID: paneRowID(for: run),
             client: "Airc Agent", profileID: run.profileID, title: a.title, taskID: run.taskID)
    }

    /// A task's current page row.
    static func paneRowID(for run: AgentRunCenter) -> String? {
        guard let w = run.runWindowID else { return nil }
        let rows = AgentActivity.shared.model.rows.filter { $0.window == w && $0.isLive }
        let active = AgentCenter.shared.windows[w]?.activeTabID
        return (rows.first { $0.tab == active } ?? rows.last)?.id
    }

    // MARK: Going there

    /// A landing's focus passes take the keys back for a moment (a Space switch or a closing Watch hands them to the
    /// page a little later), but only until the person acts: their first click or key in Airc after the landing ends
    /// the passes. Otherwise a key meant for a page field could be taken back to the approval card, and its Return
    /// would allow the agent's action (review21). One monitor per landing, removed after its last pass.
    /// A newer landing ends the older one's passes too (tailreds): otherwise a Dock landing's 0.15 s pass took the
    /// keys back to the approval card right after ✦ had landed on a page, and Return allowed instead of taking over.
    final class LandingFocus {
        static let delays: [Double] = [0.0, 0.15, 0.4, 0.8, 1.5]
        private static var generation = 0
        /// Ends every earlier landing's remaining passes.
        static func supersede() { generation &+= 1 }
        private(set) var personActed = false
        private var monitor: Any?

        init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] e in
                self?.personActed = true
                return e
            }
        }

        func end() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }

        deinit { end() }

        /// `pass(delay)` at each delay while the person hasn't acted; the monitor goes after the last one.
        static func run(_ pass: @escaping (Double) -> Void) {
            supersede()
            let f = LandingFocus(), mine = generation
            for delay in delays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if !f.personActed && mine == generation { pass(delay) }
                    if delay == delays.last { f.end() }
                }
            }
        }
    }

    /// The next waiting item (see `next`). false: nothing waits, or the only one is already in front in `c` (the
    /// caller then does its usual thing, e.g. the ✦ button closes the pane).
    @discardableResult
    static func goNext(from: String, in c: WindowController? = nil) -> Bool {
        guard let it = next() else { return false }
        if let c, count == 1, isShown(it, in: c) { return false }
        go(it, from: from)
        return true
    }

    /// The row's need (its page, or the pane task's approval); false when it has none.
    @discardableResult
    static func go(row rowID: String, from: String) -> Bool {
        guard let it = item(row: rowID) else { return false }
        go(it, from: from)
        return true
    }

    /// Whether `c` shows the item now (the pane with its approval card, or Watch on its page).
    static func isShown(_ it: Item, in c: WindowController) -> Bool {
        guard c.window.isKeyWindow, NSApp.isActive else { return false }
        switch it.kind {
        case .approval:
            guard let p = AgentPaneController.pane(of: c) else { return false }
            return p.isShown && p.model.approvalFocused && (it.taskID == nil || p.model.run.taskID == it.taskID)
        case .page: return c.sidebar.agents.watch?.rowID == it.rowID
        case .prompt(let id):
            if let row = it.rowID { return c.sidebar.agents.watch?.rowID == row && c.sidebar.agents.watch?.promptShown?.id == id }
            return AgentPrompts.shared.pageOverlay(in: c)?.prompt.id == id
        }
    }

    static func go(_ it: Item, from: String) {
        lastLanded = it.id
        LandingFocus.supersede()
        guard let c = window(for: it) else {
            AgentCenter.shared.onEvent?("attention \(from) \(it.id): no window")
            return
        }
        switchSpace(c, for: it)
        bringToFront(c)
        switch it.kind {
        case .approval:
            if c.sidebar.agents.watch != nil { c.sidebar.agents.closeWatch() }
            c.sidebar.agents.closeApproval()
            let p = run(of: it).map { AgentPaneController.show(c, task: $0) } ?? AgentPaneController.show(c)
            p.focusApproval()
        case .page:
            guard let row = it.rowID else { break }
            // A pane task's own page: its pane too, on that task (Take over then keeps Hand back).
            if AgentUI.usesPane, let r = run(of: it) { AgentPaneController.show(c, task: r) }
            // agentmainview: the Airc Agent's page is a tab of this window: it comes into the main view, Return takes over.
            if let r = AgentActivity.shared.model.row(row), AgentMainView.shared.land(windowID: r.window, tab: r.tab, in: c) { break }
            c.sidebar.agents.openWatch(row)
            // After the pane's own focus (it queues one), and again for a moment (a Space switch hands the keys to
            // the page a little later), until the person clicks or types: the keys end on Watch's Take over.
            LandingFocus.run { _ in
                guard let wv = c.sidebar.agents.watch, wv.rowID == row else { return }
                if !wv.isLanded || c.window.firstResponder !== wv { wv.land() }
            }
        case .prompt(let id):
            // The prompt in front again (it may have been put off), over the agent's page in Watch, or over the page the
            // person took over. No button takes Return: allowing is always a deliberate click.
            AgentPrompts.shared.reopen(id)
            if let row = it.rowID {
                if AgentUI.usesPane, let r = run(of: it) { AgentPaneController.show(c, task: r) }
                c.sidebar.agents.openWatch(row)
                c.sidebar.agents.watch?.syncPrompt()
            } else if let tab = AgentPrompts.shared.page(id), let (_, tabID) = AgentPrompts.controller(holding: tab) {
                c.show(tabID)
            }
        }
        lastLanding = (from, it, c)
        AgentCenter.shared.onEvent?("attention \(from) \(it.id)")
        #if AIRC_TESTING
        onLand?(from, it)
        #endif
    }

    /// The window to answer in: the task's own window for its approval (or its page), while it is in the task's
    /// profile; else a window showing the profile, the key one first; else a window with a Space of that profile
    /// (switched to it); never a window of another profile. Without a profile: the key window.
    static func window(for it: Item) -> WindowController? {
        let all = AgentCenter.shared.app?.controllers ?? []
        if case .prompt(let id) = it.kind, it.rowID == nil, let tab = AgentPrompts.shared.page(id), let (c, _) = AgentPrompts.controller(holding: tab) { return c }
        let paneTask = it.kind == .approval || run(of: it) != nil
        if paneTask, let c = recordedWindow(for: it, in: all) { return c }
        if let p = it.profileID {
            let showing = AgentActivity.shared.windows(showing: p)
            if let c = showing.first(where: { $0.window.isKeyWindow }) ?? showing.first { return c }
            // Never another profile's window: none can show this profile, so nowhere to land.
            return all.first { c in c.windowSpaces.contains { $0.profileID == p } }
        }
        return all.first { $0.window.isKeyWindow } ?? all.first { $0.window.isMainWindow } ?? all.first
    }

    private static func switchSpace(_ c: WindowController, for it: Item) {
        let task = run(of: it)
        if it.kind == .approval, let s = task?.askedSpaceID, task?.askedIn === c, s != c.currentSpaceID,
           let space = c.windowSpaces.first(where: { $0.id == s }), it.profileID == nil || space.profileID == it.profileID {
            return c.switchToSpace(s, animated: false)
        }
        guard let p = it.profileID, c.store.space(c.currentSpaceID)?.profileID != p else { return }
        let target = c.lastShownSpace(ofProfile: p).flatMap { id in c.windowSpaces.first { $0.id == id } } ?? c.windowSpaces.first { $0.profileID == p }
        if let target { c.switchToSpace(target.id, animated: false) }
    }

    /// The window in front and key, from another app, a full-screen Space or another desktop: activation takes macOS to
    /// the Space the window is on.
    static func bringToFront(_ c: WindowController) {
        if NSApp.isHidden { NSApp.unhide(nil) }
        if c.window.isMiniaturized { c.window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
    }

    // MARK: Following approvals and pages

    /// agentparallel: each task's approval is announced once when it comes, and its notification withdrawn when it goes.
    private static func approvalsChanged() {
        var now: [String: (AgentRunCenter, AgentApprovalRequest)] = [:]
        for run in AgentTaskCenter.shared.waiting { if let a = run.approval { now[run.taskID] = (run, a) } }
        for (task, id) in announced where now[task]?.1.id != id {
            announced[task] = nil
            approvalSince[id] = nil
            Notifications.withdraw("agent-approval-" + task)
        }
        for (task, (run, a)) in now where announced[task] != a.id {
            announced[task] = a.id
            if approvalSince[a.id] == nil { approvalSince[a.id] = Date() }
            announce(approvalItem(run, a))
        }
        updateBadges()
    }

    /// A new passkey request: Airc's toast where it lands, unless that already shows it; a notification when Airc isn't in
    /// front (the prompt itself waits in Watch or in Needs you).
    static func promptAsked(_ p: AgentPrompts.Prompt) {
        let it = Item(id: "prompt-" + p.id, kind: .prompt(p.id), since: p.since, rowID: p.rowID, client: p.client, profileID: p.profileID, title: p.title)
        updateBadges()
        guard let c = window(for: it) else { return }
        if !(c.sidebar.agents.watch?.rowID == p.rowID) {
            c.toast.show(p.title, palette: c.currentPalette, in: c.card.frame, duration: 10, action: ("Show", { go(it, from: "toast") }),
                         symbol: "person.badge.key.fill")
            AgentCenter.shared.onEvent?("attention-toast \(it.id)")
        }
        if !(NSApp.isActive && c.window.isKeyWindow) {
            Notifications.post(id: "agent-prompt-" + p.id, title: p.title, body: "Click to answer in Airc. \(p.client) waits until you do.",
                               info: ["agentPrompt": it.id])
        }
    }

    /// Prompts came or went: badges and counts follow.
    static func promptsChanged() { updateBadges() }

    private static func rowsChanged() {
        let waiting = Set(AgentActivity.shared.model.rows.filter { $0.isLive && $0.needsYou != nil }.map(\.id))
        for id in waiting where pageSince[id] == nil {
            pageSince[id] = Date()
            if let it = items().first(where: { $0.id == "page-" + id }) { announce(it) }
        }
        for id in pageSince.keys where !waiting.contains(id) { pageSince[id] = nil }
        updateBadges()
    }

    private static var lastCount = -1
    private static func updateBadges() {
        let n = count
        guard n != lastCount else { return }
        lastCount = n
        AgentCenter.shared.updateIndicator()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// A new wait: Airc's own toast (with Show) in the window it lands in, unless that window already shows it; and the
    /// approval's notification when Airc isn't in front (the page's comes from AgentNeedsYou after 8 s).
    private static func announce(_ it: Item) {
        guard let c = window(for: it) else { return }
        let pane = AgentPaneController.pane(of: c)
        let shownThere = it.kind == .approval ? pane?.isShown == true && (it.taskID == nil || pane?.model.run.taskID == it.taskID) && c.window.isKeyWindow && NSApp.isActive
                                              : c.sidebar.agents.watch?.rowID == it.rowID
        if !shownThere {
            let text = it.kind == .approval ? "\(it.client) needs your OK · \(it.title)" : "\(it.client) needs you · \(it.title)"
            c.toast.show(text, palette: c.currentPalette, in: c.card.frame, duration: 8, action: ("Show", { go(it, from: "toast") }),
                         symbol: it.kind == .approval ? "hand.raised.fill" : "person.crop.circle.badge.exclamationmark")
            AgentCenter.shared.onEvent?("attention-toast \(it.id)")
        }
        if it.kind == .approval, !(NSApp.isActive && c.window.isKeyWindow) {
            let task = it.taskID.flatMap { id in AgentTaskRecorder.shared.tasks.first(where: { $0.id == id })?.title }
            Notifications.post(id: "agent-approval-" + (it.taskID ?? ""), title: "\(it.client) needs your OK",
                               body: (task.map { "\($0): " } ?? "") + it.title + " Click to answer.",
                               info: ["agentApproval": it.id])
        }
    }

    // MARK: Notifications

    /// Posting (when the person allows Airc's notifications; never in scripted runs, which record instead) and clicks.
    enum Notifications {
        private static var asked = false
        /// Scripted runs: what would have been posted (id, title).
        private(set) static var recorded: [(id: String, title: String, info: [String: String])] = []
        #if AIRC_TESTING
        static func resetForTesting() { recorded = [] }
        #endif

        static func post(id: String, title: String, body: String, info: [String: String]) {
            if (NSApp.delegate as? AppDelegate)?.options.isAutomated == true {
                recorded.append((id, title, info))
                AgentCenter.shared.onEvent?("notification \(id)")
                return
            }
            let center = UNUserNotificationCenter.current()
            let send = {
                let c = UNMutableNotificationContent()
                c.title = title
                c.body = body
                c.userInfo = info
                center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
            }
            center.getNotificationSettings { s in
                DispatchQueue.main.async {
                    switch s.authorizationStatus {
                    case .authorized, .provisional: send()
                    case .notDetermined where !asked:
                        asked = true
                        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in if ok { DispatchQueue.main.async(execute: send) } }
                    default: break
                    }
                }
            }
        }

        static func withdraw(_ id: String) {
            guard (NSApp.delegate as? AppDelegate)?.options.isAutomated != true else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }

        /// A click on one of ours: its task (the row's page, the approval), else whatever waits longest.
        static func clicked(_ info: [AnyHashable: Any]) {
            if let row = info["agentRow"] as? String, AgentAttention.go(row: row, from: "notification") { return }
            if let id = info["agentApproval"] as? String, let it = AgentAttention.items().first(where: { $0.id == id }) { return AgentAttention.go(it, from: "notification") }
            if let id = info["agentPrompt"] as? String, let it = AgentAttention.items().first(where: { $0.id == id }) { return AgentAttention.go(it, from: "notification") }
            AgentAttention.goNext(from: "notification")
        }
    }

    final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
        static let shared = NotificationDelegate()

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let info = response.notification.request.content.userInfo
            DispatchQueue.main.async {
                Notifications.clicked(info)
                completionHandler()
            }
        }

        /// In front, Airc's own toast says it; the notification stays in Notification Center only.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler(NSApp.isActive ? [.list] : [.banner, .list, .sound])
        }
    }
}

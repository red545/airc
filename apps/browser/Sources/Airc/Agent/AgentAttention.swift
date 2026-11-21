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
        /// "Sign in" or "Captcha".
        case page(String)
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
    }

    static let changed = Notification.Name("AircAgentAttentionChanged")

    /// When each row's page started waiting (rows only know that they wait).
    private static var pageSince: [String: Date] = [:]
    private static var approvalSince: (id: UUID, at: Date)?
    /// Where the pane's task was asked: its window and Space (the approval lands there).
    private(set) static weak var taskWindow: WindowController?
    private(set) static var taskSpaceID: String?
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
        subs.append(AgentRunCenter.shared.$approval.removeDuplicates().receive(on: DispatchQueue.main).sink { a in approvalChanged(a) })
        subs.append(NotificationCenter.default.publisher(for: AgentActivity.changed).receive(on: DispatchQueue.main).sink { _ in rowsChanged() })
    }

    /// AgentPaneModel.ask: the task's window and Space.
    static func taskAsked(in c: WindowController) {
        taskWindow = c
        taskSpaceID = c.currentSpaceID
    }

    // MARK: What waits

    static func items() -> [Item] {
        var out: [Item] = []
        let run = AgentRunCenter.shared
        if let a = run.approval {
            out.append(Item(id: "approval-" + a.id.uuidString, kind: .approval, since: approvalSince?.id == a.id ? approvalSince!.at : Date(),
                            rowID: paneRowID, client: "Airc Agent", profileID: run.profileID, title: a.title))
        }
        for r in AgentActivity.shared.model.rows where r.isLive && r.shown {
            guard let why = r.needsYou else { continue }
            let site = AgentRedaction.siteName(title: r.title, url: r.url)
            out.append(Item(id: "page-" + r.id, kind: .page(why), since: pageSince[r.id] ?? r.started, rowID: r.id, client: r.client,
                            profileID: r.profileID, title: why == "Captcha" ? "Captcha on \(site)" : "Sign in to \(site)"))
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

    /// The Airc Agent run's current page row.
    static var paneRowID: String? {
        guard let w = AgentRunCenter.shared.runWindowID else { return nil }
        let rows = AgentActivity.shared.model.rows.filter { $0.window == w && $0.isLive }
        let active = AgentCenter.shared.windows[w]?.activeTabID
        return (rows.first { $0.tab == active } ?? rows.last)?.id
    }

    // MARK: Going there

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
        case .approval: return AgentPaneController.pane(of: c)?.isShown == true && AgentPaneController.pane(of: c)?.model.approvalFocused == true
        case .page: return c.sidebar.agents.watch?.rowID == it.rowID
        }
    }

    static func go(_ it: Item, from: String) {
        lastLanded = it.id
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
            let p = AgentPaneController.show(c)
            p.focusApproval()
        case .page:
            guard let row = it.rowID else { break }
            // The pane task's own page: its pane too (Take over then keeps Hand back).
            if AgentActivity.shared.model.row(row)?.window == AgentRunCenter.shared.runWindowID, AgentUI.usesPane { AgentPaneController.show(c) }
            c.sidebar.agents.openWatch(row)
            // After the pane's own focus (it queues one), and again for a moment (a Space switch hands the keys to
            // the page a little later): the keys end on Watch's Take over.
            for delay in [0.0, 0.15, 0.4, 0.8, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let wv = c.sidebar.agents.watch, wv.rowID == row else { return }
                    if !wv.isLanded || c.window.firstResponder !== wv { wv.land() }
                }
            }
        }
        lastLanding = (from, it, c)
        AgentCenter.shared.onEvent?("attention \(from) \(it.id)")
        #if AIRC_TESTING
        onLand?(from, it)
        #endif
    }

    /// The window to answer in: the pane task's own window for its approval (or its page); else a window showing the
    /// page's profile, the key one first; else any browser window (switched to a Space of that profile).
    static func window(for it: Item) -> WindowController? {
        let all = AgentCenter.shared.app?.controllers ?? []
        let paneTask = it.kind == .approval || (it.rowID.flatMap { AgentActivity.shared.model.row($0)?.window } == AgentRunCenter.shared.runWindowID)
        if paneTask, let c = taskWindow, all.contains(where: { $0 === c }) { return c }
        if let p = it.profileID {
            let showing = AgentActivity.shared.windows(showing: p)
            if let c = showing.first(where: { $0.window.isKeyWindow }) ?? showing.first { return c }
            if let c = all.first(where: { c in c.windowSpaces.contains { $0.profileID == p } }) { return c }
        }
        return all.first { $0.window.isKeyWindow } ?? all.first { $0.window.isMainWindow } ?? all.first
    }

    private static func switchSpace(_ c: WindowController, for it: Item) {
        if it.kind == .approval, let s = taskSpaceID, taskWindow === c, s != c.currentSpaceID, c.windowSpaces.contains(where: { $0.id == s }) {
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

    private static func approvalChanged(_ a: AgentApprovalRequest?) {
        if let a {
            if approvalSince?.id != a.id { approvalSince = (a.id, Date()) }
            announce(Item(id: "approval-" + a.id.uuidString, kind: .approval, since: approvalSince!.at, rowID: paneRowID, client: "Airc Agent",
                          profileID: AgentRunCenter.shared.profileID, title: a.title))
        } else {
            approvalSince = nil
            Notifications.withdraw("agent-approval")
        }
        updateBadges()
    }

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
        let shownThere = it.kind == .approval ? AgentPaneController.pane(of: c)?.isShown == true && c.window.isKeyWindow && NSApp.isActive
                                              : c.sidebar.agents.watch?.rowID == it.rowID
        if !shownThere {
            let text = it.kind == .approval ? "\(it.client) needs your OK · \(it.title)" : "\(it.client) needs you · \(it.title)"
            c.toast.show(text, palette: c.currentPalette, in: c.card.frame, duration: 8, action: ("Show", { go(it, from: "toast") }),
                         symbol: it.kind == .approval ? "hand.raised.fill" : "person.crop.circle.badge.exclamationmark")
            AgentCenter.shared.onEvent?("attention-toast \(it.id)")
        }
        if it.kind == .approval, !(NSApp.isActive && c.window.isKeyWindow) {
            Notifications.post(id: "agent-approval", title: "\(it.client) needs your OK", body: it.title + " Click to answer.",
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

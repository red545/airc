// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import Combine

/// The Airc Agent works in the main view (owner decision 2026-11-23, agentmainview; docs/design/agent-ux.md §5).
///
/// - A task's page is a real tab of the person's window: in Today, titled with the page, selected when the task starts,
///   full size and live, with the glow and the bar (AgentMainChromeView). A task about the page the person is on ("this
///   page", "this form") works in that very tab.
/// - While the agent drives, the person's clicks and typing on that page stop at a shield with a hint; Take over gives
///   them the tab at once (the task waits; Hand back goes on), Stop ends it. Scrolling to look is allowed: the agent's
///   next click is refused until it has looked again (`staleLook`), so a scroll never sends a click to the wrong place.
/// - The agent's screenshots and coordinates are the real viewport at its real size (AgentWindow.size).
/// - When the person picks another tab, the page parks in the run's agent window (off screen, kept live, the same
///   viewport size) and the pane shows its small live card. The Today row, the card, the task row or Take over bring it
///   back: the same page moves back, nothing loads again.
/// - When the task ends, its tabs stay the person's ordinary tabs.
///
/// Only the Airc Agent's own runs (AgentBridge) are hosted; outside apps keep their own agent windows and Watch.
final class AgentMainView {
    static let shared = AgentMainView()
    static let changed = Notification.Name("AircAgentMainViewChanged")

    /// One hosted page: which person's tab it is.
    final class Hosted {
        weak var page: EngineTab?
        weak var controller: WindowController?
        weak var window: AgentWindow?
        let tabID: String
        /// The person's own tab (a task about the page they were on): the agent never closes it.
        var personOwned: Bool
        /// Bumped when the person scrolls it or its size changes; the agent's last look saw `seen`.
        var viewRevision = 0
        var seen = 0
        var closedByPerson = false
        var lastSize: CGSize = .zero
        /// The task's new tab before its first page: the card's own fill with "Starting…" over it (never a white page),
        /// and its Today row titled with the task, not "about:blank".
        var starting = false
        var taskTitle: String?
        init(page: EngineTab, controller: WindowController, window: AgentWindow, tabID: String, personOwned: Bool) {
            self.page = page
            self.controller = controller
            self.window = window
            self.tabID = tabID
            self.personOwned = personOwned
        }
    }

    /// Where the next run starts: the window the person asked in, and their tab when the task is about it.
    struct Start {
        weak var controller: WindowController?
        var tabID: String?
        /// agentparallel: started without looking at it (⌘T ⌥↩): its page is a row, parked, never selected.
        var background = false
    }

    private(set) var hosted: [Hosted] = []
    /// agentparallel: everything below is per task (its run's taskID), so tasks run side by side.
    /// Where each task's next run starts.
    private var starts: [String: Start] = [:]
    /// A run's page when its window closed (Stop, a budget stop): Continue goes on in the same tab.
    private var released: [String: (controller: WeakController, tabID: String)] = [:]
    /// The person's tab they took over (the pane's Take over), until Hand back or Stop.
    private var takenOvers: [String: (controller: WeakController, tabID: String)] = [:]
    /// Each window's task asked last in the foreground: only its page may take the main view when its agent window
    /// opens (agent windows of tasks asked back to back can open in any order; an earlier one's page is a parked row).
    private var latestAsk: [ObjectIdentifier: String] = [:]
    /// The tasks running at the last change: only a task that just ended drops its never-loaded pages.
    private var wasActive: Set<String> = []
    private var tasks: AgentTaskCenter { AgentTaskCenter.shared }
    private var chromes: [ObjectIdentifier: AgentMainChromeView] = [:]
    private var subs: [AnyCancellable] = []
    private var acting: [Int: Int] = [:]

    private final class WeakController { weak var c: WindowController?; init(_ c: WindowController) { self.c = c } }

    /// Checks: what happened ("present <tabID>", "park <tabID>", "reclaim <tabID>", "blocked click", …).
    var onEvent: ((String) -> Void)?

    private init() {}

    /// Follows the run once there is one (nothing at launch: the tab hooks call in for every window from the start).
    private func follow() {
        guard subs.isEmpty else { return }
        // Any task's state or approval (agentparallel: every task's chrome and rows follow their own run).
        subs.append(NotificationCenter.default.publisher(for: AgentTaskCenter.changed).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshAll(); self?.dropBlankPages() }
        })
    }

    /// The task whose run owns this agent window.
    private func run(of w: AgentWindow?) -> AgentRunCenter? { w.flatMap { tasks.run(agentWindow: $0.id) } }

    // MARK: Lookups

    func entry(_ page: EngineTab) -> Hosted? { hosted.first { $0.page === page } }
    func entry(tabID: String, in c: WindowController) -> Hosted? { hosted.first { $0.tabID == tabID && $0.controller === c } }
    func isHosted(_ tabID: String) -> Bool { hosted.contains { $0.tabID == tabID && $0.page != nil } }

    /// The task's current page, if hosted.
    func entry(for run: AgentRunCenter) -> Hosted? {
        guard let w = run.runWindowID.flatMap({ AgentCenter.shared.windows[$0] }), let p = w.activeTab else { return nil }
        return entry(p)
    }

    /// Whether the task's current page is the one this window shows now (the pane then needs no live card).
    func runShown(_ run: AgentRunCenter, in c: WindowController) -> Bool {
        guard let e = entry(for: run), e.controller === c, let page = e.page, let w = e.window else { return false }
        return c.shownTabID == e.tabID && !w.isParked(page)
    }

    /// The task whose page this window shows now (its glow, bar and shield), or whose page the person took over there.
    func shownRun(in c: WindowController) -> AgentRunCenter? {
        guard let id = c.shownTabID else { return nil }
        if let t = takenOvers.first(where: { $0.value.tabID == id && $0.value.controller.c === c }) { return tasks.run(task: t.key) }
        guard let e = entry(tabID: id, in: c) else { return nil }
        return run(of: e.window)
    }

    // MARK: Starting

    /// The size a new run's agent window starts at: the main view of the window it will show in (its card's page).
    func nextViewport(task: String?) -> CGSize? {
        guard let c = task.flatMap({ starts[$0]?.controller }) ?? Self.frontController else { return nil }
        let s = c.card.hostView?.bounds.size ?? c.card.bounds.size
        return s.width >= 320 && s.height >= 240 ? s : nil
    }

    /// The pane (every way to ask goes through it) says where the next run is asked. `page`: the person's tab, used by
    /// the agent itself when the task is about it.
    func willAsk(_ run: AgentRunCenter, in c: WindowController, page tabID: String?, background: Bool = false) {
        follow()
        starts[run.taskID] = Start(controller: c, tabID: tabID, background: background)
        if !background { latestAsk[ObjectIdentifier(c)] = run.taskID }
        released[run.taskID] = nil
        takenOvers[run.taskID] = nil
    }

    /// Every entry point that asks (the pane, ⌘T → Ask, a task view's reply, the old panel) records its window right
    /// before the run (AgentAttention.taskAsked): the next run's page goes there. The pane's own willAsk comes first and
    /// keeps its tab; any other window replaces an older ask's (agentmainfix: a task view's reply in window B after a pane
    /// task in A placed B's page in A and switched A to B's Space).
    func asked(_ run: AgentRunCenter, in c: WindowController) {
        if starts[run.taskID]?.controller === c { return }
        follow()
        starts[run.taskID] = Start(controller: c, tabID: nil)
        latestAsk[ObjectIdentifier(c)] = run.taskID
    }

    /// Whether a prompt is about the page the person is on (then the agent works in that tab rather than a new one).
    static func isAboutPage(_ prompt: String) -> Bool {
        let t = " " + prompt.lowercased() + " "
        let words = [" this page", " this site", " this article", " this form", " this tab", " this post", " this email",
                     " this listing", " this product", " this doc", " this one", " here ", " here.", " here?", " on it ",
                     "summari", " fill ", " fill in", " fill out", " the page", " this video", " this recipe", " this thread"]
        return words.contains { t.contains($0) }
    }

    /// The run's agent window opened (AgentBridge): its first page becomes the person's tab, shown in the main view.
    func windowOpened(_ w: AgentWindow) {
        let task = w.taskID ?? ""
        var start = starts.removeValue(forKey: task)
        // Continue after a stop: the same tab, which the person still has.
        if start == nil, let r = released[task], let c = r.controller.c, c.engineTab(for: r.tabID) != nil {
            start = Start(controller: c, tabID: r.tabID)
        }
        released[task] = nil
        follow()
        guard let c = start?.controller ?? AgentMainView.frontController else { return }
        w.hostsInMainView = true
        let blank = w.activeTabID
        // agentmainfix: the page shows in the main view only when the window is on a Space of the agent's profile now.
        // Otherwise it's a row of that profile's Space in this window, parked (live in the card) until the person picks
        // it: the window the person is in never changes Space by itself.
        // agentparallel: a task started in the background (⌥↩) is a row too, parked, never selected.
        let onProfile = c.store.space(c.currentSpaceID)?.profileID == w.profileID
        // A later task asked in this window since: its page has the main view (or will), this one is a row.
        let superseded = start?.controller != nil && latestAsk[ObjectIdentifier(c)].map { $0 != task } == true && start?.tabID == nil
        if !onProfile || start?.background == true || superseded, let b = blank, let page = w.tab(b), let space = space(for: w, in: c) {
            w.markHosted(b)
            guard let t = try? c.store.openTab(url: page.url?.absoluteString ?? "about:blank", inSpace: space,
                                               background: true, activate: false, title: page.title) else { return w.unmarkHosted(b) }
            let e = Hosted(page: page, controller: c, window: w, tabID: t.id, personOwned: false)
            e.lastSize = w.size
            hosted.append(e)
            beginStarting(e)
            c.scheduleReload()
            onEvent?("present \(t.id) away")
            refresh(c)
            changed()
            return
        }
        if let id = start?.tabID, let page = c.engineTab(for: id), !page.isClosed, page.profile === w.profile {
            // The task is about this page: the agent works in it.
            let e = Hosted(page: page, controller: c, window: w, tabID: id, personOwned: true)
            hosted.append(e)
            w.host(page)
            if let b = blank { w.closeTab(b) }
            if c.shownTabID != id { c.show(id) }
            onEvent?("present \(id) own")
        } else if let b = blank, let page = w.tab(b) {
            guard let space = space(for: w, in: c) else { return }
            w.markHosted(b)
            guard c.adoptMovedPage(page, inSpace: space), let id = c.tabID(for: page) else {
                w.unmarkHosted(b)
                return
            }
            let e = Hosted(page: page, controller: c, window: w, tabID: id, personOwned: false)
            hosted.append(e)
            beginStarting(e)
            w.unparked(page)
            onEvent?("present \(id)")
        }
        refresh(c)
        changed()
    }

    /// A follow-up or Continue in the same window: the run's page comes back into the main view.
    func runResumed(_ w: AgentWindow) {
        let asker = starts.removeValue(forKey: w.taskID ?? "")?.controller
        guard let p = w.activeTab, let e = entry(p), let c = e.controller else { return }
        // Asked from another window (its task view, its pane): that window isn't the page's; the page's own window keeps
        // its Space and tab (no surprise switch there).
        if let asker, asker !== c { return refresh(c) }
        if c.shownTabID != e.tabID { bringBack(e) }
        refresh(c)
    }

    static var frontController: WindowController? {
        let all = (NSApp.delegate as? AppDelegate)?.controllers ?? []
        return all.first { $0.window.isKeyWindow } ?? all.first { $0.window.isMainWindow } ?? all.first
    }

    /// The Space a new agent tab goes in: the current one when it has the agent's profile, else that profile's first.
    private func space(for w: AgentWindow, in c: WindowController) -> String? {
        if c.store.space(c.currentSpaceID)?.profileID == w.profileID { return c.currentSpaceID }
        return c.store.spaces(usingProfile: w.profileID).first?.id
    }

    // MARK: The agent's own tabs

    /// The agent opened a tab (open_tab, a link's new tab): it becomes a person's tab too, next to the run's page.
    func agentOpened(_ w: AgentWindow, _ id: Int, foreground: Bool) {
        guard w.hostsInMainView, let page = w.tab(id), entry(page) == nil else { return }
        let anchor = hosted.first { $0.window === w && $0.controller != nil }
        guard let c = anchor?.controller, let space = space(for: w, in: c) else { return }
        let shownNow = anchor.map { c.shownTabID == $0.tabID } ?? false
        w.markHosted(id)
        if foreground, shownNow {
            guard c.adoptMovedPage(page, inSpace: space), let tid = c.tabID(for: page) else { return w.unmarkHosted(id) }
            hosted.append(Hosted(page: page, controller: c, window: w, tabID: tid, personOwned: false))
            w.unparked(page)
        } else {
            // The person looks elsewhere: a row in Today, its page parked until they pick it.
            guard let t = try? c.store.openTab(url: page.url?.absoluteString ?? "about:blank", inSpace: space,
                                               background: true, activate: false, title: page.title) else { return w.unmarkHosted(id) }
            let e = Hosted(page: page, controller: c, window: w, tabID: t.id, personOwned: false)
            e.lastSize = w.size
            hosted.append(e)
            c.scheduleReload()
        }
        onEvent?("opened \(id)")
        refresh(c)
        changed()
    }

    /// A page the agent shows in the person's window opened a new tab or popup there (WindowController adopted it):
    /// it's the agent's too.
    func personWindowOpened(_ page: EngineTab, opener: EngineTab, tabID: String, in c: WindowController) {
        guard let o = entry(opener), let w = o.window, entry(page) == nil else { return }
        hosted.append(Hosted(page: page, controller: c, window: w, tabID: tabID, personOwned: false))
        w.host(page)
        onEvent?("popup \(tabID)")
        refresh(c)
        changed()
    }

    /// The agent picked another of its tabs (select_tab): the main view follows when it showed the agent's last one.
    func agentSelected(_ w: AgentWindow, _ page: EngineTab) {
        guard let e = entry(page), let c = e.controller else { return }
        let showingAgent = hosted.contains { $0.window === w && $0.controller === c && c.shownTabID == $0.tabID }
        if showingAgent, c.shownTabID != e.tabID { c.show(e.tabID, focus: false) }
        refresh(c)
    }

    /// A hosted page stops being the agent's (AgentWindow.unhost).
    func unhosted(_ w: AgentWindow, _ page: EngineTab, closing: Bool) {
        guard let i = hosted.firstIndex(where: { $0.page === page }) else { return }
        let e = hosted.remove(at: i)
        let c = e.controller
        if closing {
            if e.closedByPerson {
                if w.isParked(page), !page.isClosed { page.close() }
            } else if !e.personOwned, let c {
                // The agent closed its own tab: the person's row goes too.
                if w.isParked(page) { page.close() }
                c.closeTab(e.tabID)
            }
        } else if let c, let task = w.taskID, w.activeTab == nil || w.activeTab === page {
            released[task] = (WeakController(c), e.tabID)
        }
        if !closing, w.isParked(page), let c, !page.isClosed {
            // The run ended while its page was parked: it goes back to the person's window, as their tab, not shown.
            if (try? c.engineWindow.moveTab(page, profile: page.profile, to: c.engineWindow.hostView)) != nil {
                c.adopt(page, as: e.tabID)
                if let shown = c.shownTabID.flatMap({ c.engineTab(for: $0) }) { c.engineWindow.activateTab(shown) }
            } else {
                page.close()
            }
        }
        onEvent?("unhost \(e.tabID) \(closing ? "closing" : "kept")")
        if let c { refresh(c) }
        changed()
    }

    /// A parked page closed itself (window.close()): its row goes.
    func pageClosedItself(_ w: AgentWindow, _ page: EngineTab) {
        guard let e = entry(page), let c = e.controller else { return }
        e.closedByPerson = true
        if let id = w.hostedID(page) { w.unhost(id, closing: true) }
        c.closeTab(e.tabID)
    }

    // MARK: The person's window (WindowController hooks)

    /// `tabID` is going away in `c` (closed by the person, or its page closed): the agent loses it; if it was the run's
    /// page while the run worked, the run stops.
    func personDropping(_ tabID: String, in c: WindowController) {
        guard !hosted.isEmpty else { return }
        guard c.store.tab(tabID) == nil, let e = entry(tabID: tabID, in: c), let page = e.page, let w = e.window else { return }
        e.closedByPerson = true
        let run = run(of: w)
        let wasRun = run?.runWindowID == w.id && w.activeTab === page
        if let id = w.hostedID(page) { w.unhost(id, closing: true) }
        if wasRun, let run, run.state.isActive { run.stop("You closed the agent's tab.") }
        for (k, t) in takenOvers where t.tabID == tabID && t.controller.c === c { takenOvers[k] = nil }
        onEvent?("closed \(tabID)")
    }

    /// The person's window shows `shown` and stopped showing `hidden`.
    func visibilityChanged(in c: WindowController, hidden: String?, shown: String?) {
        guard !hosted.isEmpty || chromes[ObjectIdentifier(c)] != nil || !takenOvers.isEmpty else { return }
        let e = hidden.flatMap { entry(tabID: $0, in: c) }
        refresh(c)
        // After the show has finished (never inside it, and after it gave the page the keys).
        DispatchQueue.main.async { [weak self, weak c] in
            guard let self, let c else { return }
            if let e, let hidden, !c.visibleTabIDs.contains(hidden) { self.park(e, in: c) }
            self.refresh(c)
            self.chrome(c, create: false)?.reclaimKeys()
        }
    }

    private func park(_ e: Hosted, in c: WindowController) {
        guard let page = e.page, let w = e.window, !page.isClosed, !w.isParked(page), c.engineTab(for: e.tabID) === page else { return }
        let size = page.view.bounds.size
        guard c.releasePage(e.tabID) != nil else { return }
        if w.park(page, size: size) {
            e.lastSize = size
            onEvent?("park \(e.tabID)")
        } else {
            c.adopt(page, as: e.tabID)
            onEvent?("park-failed \(e.tabID)")
        }
        changed()
    }

    /// WindowController.ensurePage: a parked page of this window's tab comes back (the same page, live, no reload).
    func reclaim(_ tabID: String, into c: WindowController) -> EngineTab? {
        guard let e = entry(tabID: tabID, in: c), let page = e.page, let w = e.window, !page.isClosed, w.isParked(page) else { return nil }
        do { try c.engineWindow.moveTab(page, profile: page.profile, to: c.engineWindow.hostView) } catch {
            onEvent?("reclaim-failed \(tabID)")
            return nil
        }
        w.unparked(page)
        c.adopt(page, as: tabID)
        if e.lastSize != .zero, page.view.bounds.size != e.lastSize { e.viewRevision += 1 }
        onEvent?("reclaim \(tabID)")
        DispatchQueue.main.async { [weak self] in self?.changed() }
        return page
    }

    /// The card, the task row, a notification: the run's page into the main view of its window.
    @discardableResult
    func bringBack(windowID: Int?) -> Bool {
        let w = windowID.flatMap { AgentCenter.shared.windows[$0] }
        guard let page = w?.activeTab, let e = entry(page) else { return false }
        bringBack(e)
        return true
    }

    /// The task's page into the main view of its window.
    @discardableResult
    func bringBack(_ run: AgentRunCenter) -> Bool { bringBack(windowID: run.runWindowID) }

    /// "Needs you" on the run's page (a sign-in, a captcha): the page in the main view, Return takes over.
    func land(windowID: Int, tab: Int, in c: WindowController) -> Bool {
        guard let page = AgentCenter.shared.windows[windowID]?.tab(tab), let e = entry(page), e.controller === c else { return false }
        bringBack(e)
        DispatchQueue.main.async { [weak self, weak c] in
            guard let self, let c, let v = self.chrome(c, create: false) else { return }
            v.landed = true
            c.window.makeFirstResponder(v)
        }
        return true
    }

    private func bringBack(_ e: Hosted) {
        guard let c = e.controller else { return }
        if let space = c.store.tab(e.tabID)?.spaceID, space != c.currentSpaceID { c.switchToSpace(space, animated: false) }
        c.show(e.tabID, focus: false)
        c.window.makeKeyAndOrderFront(nil)
        onEvent?("bring-back \(e.tabID)")
    }

    // MARK: Take over, Hand back, Stop

    /// Take over: the run's page in the main view, the person's now (the run stops; Hand back starts it again).
    func takeOver(_ run: AgentRunCenter, in c: WindowController) -> (tabID: String, title: String, url: URL?, agentTabID: Int?)? {
        guard let e = entry(for: run), let page = e.page, e.controller === c else { return nil }
        bringBack(e)
        takenOvers[run.taskID] = (WeakController(c), e.tabID)
        let agentTab = e.window?.hostedID(page)
        // The page is theirs: their clicks and keys go to it at once.
        refresh(c)
        c.window.makeFirstResponder(page.view)
        page.focus()
        onEvent?("take-over \(e.tabID)")
        return (e.tabID, page.title, page.url, agentTab)
    }

    /// Hand back (the next run's window opened): the person's tab is the agent's again, where it is.
    func handBack(_ tabID: String, from c: WindowController, into w: AgentWindow, as agentTabID: Int?) -> String? {
        guard let page = c.engineTab(for: tabID), !page.isClosed else { return "The page is gone." }
        guard page.profile === w.profile else { return "The page is in another profile than the agent's." }
        let task = w.taskID ?? ""
        takenOvers[task] = nil
        starts[task] = nil
        released[task] = nil
        follow()
        w.hostsInMainView = true
        let blanks = w.tabs.filter { !$0.hosted }.map(\.id)
        if let e = entry(page), e.window === w, let id = w.hostedID(page) {
            // The run was done, not stopped: the page never left the agent's window.
            e.personOwned = true
            w.select(id)
        } else {
            if let old = entry(page) { hosted.removeAll { $0 === old } }
            hosted.append(Hosted(page: page, controller: c, window: w, tabID: tabID, personOwned: true))
            w.host(page, as: agentTabID)
        }
        blanks.forEach { w.closeTab($0) }
        if c.shownTabID != tabID { c.show(tabID, focus: false) }
        AgentCenter.shared.onEvent?("handed-back \(w.id) \(w.activeTabID ?? -1)")
        onEvent?("hand-back \(tabID)")
        refresh(c)
        changed()
        return nil
    }

    /// The pane's banner is gone (Stop, a new task): no Hand back over the page any more.
    func endTakeOver(_ run: AgentRunCenter) {
        let c = takenOvers.removeValue(forKey: run.taskID)?.controller.c
        if let c { refresh(c) }
    }

    func takenOverTabID(_ run: AgentRunCenter) -> String? { takenOvers[run.taskID]?.tabID }

    // MARK: The agent's calls (AgentBridge)

    /// Tools that look at the page: after them the agent's coordinates are fresh.
    static let looks: Set<String> = ["screenshot", "zoom", "read_page", "find_element"]
    /// Tools that act at a coordinate of the last look.
    static let pointed: Set<String> = ["left_click", "double_click", "triple_click", "left_click_drag", "mouse_move", "scroll"]

    /// Nil, or why a pointed call must wait for a new look (the person scrolled the page or it changed size).
    func staleLook(_ w: AgentWindow?, tool: String, args: [String: Any]) -> String? {
        guard Self.pointed.contains(tool), args["coordinate"] != nil || args["start_coordinate"] != nil,
              let w, let p = w.activeTab, let e = entry(p) else { return nil }
        noteSize(e)
        guard e.viewRevision != e.seen else { return nil }
        return "The page moved since your last look (the person scrolled it, or its window changed size), so that coordinate may point at something else. Take a screenshot (or read_page / find_element) and use its coordinates."
    }

    func willCall(_ w: AgentWindow?, tool: String, args: [String: Any]) {
        guard let w, let p = w.activeTab, let e = entry(p), let c = e.controller else { return }
        acting[w.id, default: 0] += 1
        // agentparallel: the glow breathes for the task whose page the window shows, not for a parked one.
        if c.shownTabID == e.tabID { chrome(c, create: false)?.setActing(true) }
        if Self.pointed.contains(tool), tool != "mouse_move", tool != "scroll",
           let xy = (args["coordinate"] ?? args["start_coordinate"]) as? [Any], xy.count == 2,
           let x = (xy[0] as? NSNumber)?.doubleValue, let y = (xy[1] as? NSNumber)?.doubleValue, c.shownTabID == e.tabID {
            chrome(c, create: false)?.pulse(at: CGPoint(x: x, y: y))
        }
    }

    func didCall(_ w: AgentWindow?, tool: String, ok: Bool) {
        guard let w else { return }
        acting[w.id] = max(0, (acting[w.id] ?? 1) - 1)
        guard let p = w.activeTab, let e = entry(p) else { return }
        if ok, Self.looks.contains(tool) { noteSize(e); e.seen = e.viewRevision }
        if let c = e.controller { chrome(c, create: false)?.reclaimKeys() }
        if let c = e.controller, acting[w.id] == 0 {
            // A short rest between calls keeps the glow from flickering on every step.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak c] in
                guard let self, let c, (self.acting[w.id] ?? 0) == 0 else { return }
                if let shown = c.shownTabID.flatMap({ self.entry(tabID: $0, in: c) }), let sw = shown.window, sw !== w, (self.acting[sw.id] ?? 0) > 0 { return }
                self.chrome(c, create: false)?.setActing(false)
            }
            refresh(c)
        }
    }

    private func noteSize(_ e: Hosted) {
        guard let p = e.page, let w = e.window else { return }
        let s = w.isParked(p) ? w.size : p.view.bounds.size
        if e.lastSize != .zero, s != e.lastSize { e.viewRevision += 1 }
        e.lastSize = s
    }

    /// The person scrolled the page the agent drives.
    private func personScrolled(in c: WindowController) {
        guard let id = c.shownTabID, let e = entry(tabID: id, in: c) else { return }
        e.viewRevision += 1
        onEvent?("person-scroll \(id)")
    }

    // MARK: Forwarded page changes (the person's window is a hosted page's delegate while it shows it)

    func pageURLChanged(_ page: EngineTab) {
        guard let e = entry(page), let w = e.window else { return }
        w.hostedURLChanged(page)
        if e.starting { followStart(e) }
    }

    func pageTitleChanged(_ page: EngineTab) {
        guard let e = entry(page) else { return }
        e.window?.hostedTitleChanged(page)
        if e.starting { followStart(e) }
    }

    // MARK: Before the first page (aidemo4, 2026-11-26)

    private static func isBlank(_ page: EngineTab) -> Bool {
        let u = page.url?.absoluteString ?? ""
        return u.isEmpty || u == "about:blank"
    }

    /// A task's new tab on its blank page: the cover and the task's title until the first page has loaded.
    private func beginStarting(_ e: Hosted) {
        guard let page = e.page, Self.isBlank(page) else { return }
        e.starting = true
        // agentparallel: the title of the task whose page this is.
        e.taskTitle = run(of: e.window)?.steps.first { $0.kind == .user }.map { AgentTaskTitle.make($0.text) }
        titleRow(e)
        onEvent?("starting \(e.tabID)")
        followStart(e)
    }

    /// While the page is blank, its row says the task's name (the person's window writes the page's address there).
    private func titleRow(_ e: Hosted) {
        guard let c = e.controller, let t = e.taskTitle, !t.isEmpty, c.store.tab(e.tabID)?.title != t else { return }
        c.store.updateTab(e.tabID, title: t)
        c.refreshRow(e.tabID)
    }

    /// Ends the starting state once the first page has loaded (its own pixels replace the cover), or after 20 s.
    private func followStart(_ e: Hosted, since: Date = Date()) {
        guard e.starting, let page = e.page, !page.isClosed else { return }
        if Self.isBlank(page) {
            titleRow(e)
            return
        }
        if page.isLoading, Date().timeIntervalSince(since) < 20 {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak e] in
                if let self, let e { self.followStart(e, since: since) }
            }
        }
        e.starting = false
        onEvent?("started \(e.tabID)")
        if let c = e.controller { refresh(c) }
    }

    /// A parked page's title or address changed: the person's row follows.
    func parkedTitleChanged(_ w: AgentWindow, _ page: EngineTab) {
        guard let e = entry(page), let c = e.controller, w.isParked(page) else { return }
        if e.starting { followStart(e) }
        if e.starting, Self.isBlank(page) { return titleRow(e) }
        c.store.updateTab(e.tabID, url: page.url?.absoluteString, title: page.title.isEmpty ? nil : page.title,
                          faviconURL: page.faviconURL?.absoluteString)
        c.refreshRow(e.tabID)
    }

    /// agentmainfix: a run that ended while its own page never loaded anything (its navigate was refused or failed, or it
    /// only answered) leaves no "about:blank" row in Today: the person never had that page. The person's own tabs, a page
    /// still loading and a taken-over tab stay.
    private func dropBlankPages() {
        let now = Set(tasks.active.map(\.taskID))
        let ended = wasActive.subtracting(now)
        wasActive = now
        guard !ended.isEmpty else { return }
        let taken = Set(takenOvers.values.map(\.tabID))
        for e in hosted where !e.personOwned && !taken.contains(e.tabID) && e.window?.taskID.map(ended.contains) == true {
            guard let page = e.page, !page.isClosed, !page.isLoading, let w = e.window, let id = w.hostedID(page) else { continue }
            let address = page.url?.absoluteString ?? ""
            guard address.isEmpty || address == "about:blank" else { continue }
            onEvent?("drop-blank \(e.tabID)")
            w.closeTab(id)
        }
    }

    // MARK: The chrome over the page

    private func refreshAll() {
        for c in (NSApp.delegate as? AppDelegate)?.controllers ?? [] { refresh(c) }
        changed()
    }

    @discardableResult
    private func chrome(_ c: WindowController, create: Bool) -> AgentMainChromeView? {
        let key = ObjectIdentifier(c)
        if let v = chromes[key] { return v }
        guard create else { return nil }
        let v = AgentMainChromeView(frame: .zero)
        // agentparallel: the bar acts on the task whose page it lies over, and opens the pane on that task.
        v.bar.onTakeOver = { [weak self, weak c] in
            guard let self, let c, let r = self.shownRun(in: c) else { return }
            AgentPaneController.show(c, task: r).model.takeOver()
        }
        v.bar.onStop = { [weak self, weak c] in
            guard let self, let c, let r = self.shownRun(in: c) else { return }
            AgentPaneController.show(c, task: r).model.stopTask()   // stops the run and clears a Take over's banner
            r.stop()
            self.endTakeOver(r)
        }
        v.bar.onHandBack = { [weak self, weak c] in
            guard let self, let c, let r = self.shownRun(in: c) else { return }
            AgentPaneController.show(c, task: r).model.handBack()
        }
        v.onPersonScroll = { [weak self, weak c] in if let c { self?.personScrolled(in: c) } }
        c.card.addPageOverlay(v)
        chromes[key] = v
        return v
    }

    /// What the window's card shows over its page now.
    func refresh(_ c: WindowController) {
        let mode = self.mode(c)
        guard mode != .off || chromes[ObjectIdentifier(c)] != nil else { return }
        guard let v = chrome(c, create: true) else { return }
        v.setTheme(c.currentPalette)
        v.bar.name = shownRun(in: c)?.cliKind.map { "\($0.name)" } ?? "Airc Agent"
        v.page = c.shownTabID.flatMap { c.engineTab(for: $0) }?.view
        v.set(mode)
        // Before the task's first page: the card's own fill and "Starting…", never the blank page's white.
        v.setStarting(mode != .off && c.shownTabID.flatMap { entry(tabID: $0, in: c) }?.starting == true)
        #if AIRC_TESTING
        lastMode[ObjectIdentifier(c)] = mode
        #endif
    }

    private func mode(_ c: WindowController) -> AgentMainChromeView.Mode {
        guard let id = c.shownTabID, c.store.split(containing: id) == nil || c.visibleTabIDs.count <= 1 else { return .off }
        if takenOvers.values.contains(where: { $0.tabID == id && $0.controller.c === c }) { return .takenOver }
        guard let e = entry(tabID: id, in: c), let w = e.window, let page = e.page, !w.isParked(page) else { return .off }
        guard let run = run(of: w), run.state.isActive, run.runWindowID == w.id else { return .off }
        return .working(waiting: run.approval != nil)
    }

    private func changed() { NotificationCenter.default.post(name: Self.changed, object: self) }

    #if AIRC_TESTING
    /// One-task checks: the task started last.
    func runShown(in c: WindowController) -> Bool { runShown(AgentRunCenter.shared, in: c) }
    @discardableResult
    func bringBack() -> Bool { bringBack(AgentRunCenter.shared) }
    var takenOverTabID: String? { takenOverTabID(AgentRunCenter.shared) }
    var runEntry: Hosted? { entry(for: AgentRunCenter.shared) }
    private(set) var lastMode: [ObjectIdentifier: AgentMainChromeView.Mode] = [:]
    func chromeView(_ c: WindowController) -> AgentMainChromeView? { chromes[ObjectIdentifier(c)] }
    func modeShown(_ c: WindowController) -> AgentMainChromeView.Mode { mode(c) }
    #endif
}

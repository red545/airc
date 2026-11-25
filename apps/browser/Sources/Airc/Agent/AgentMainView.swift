// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
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
    }

    private(set) var hosted: [Hosted] = []
    private var next: Start?
    /// The run's page when its window closed (Stop, a budget stop): Continue goes on in the same tab.
    private var lastReleased: (controller: WeakController, tabID: String)?
    /// The person's tab they took over (the pane's Take over), until Hand back or Stop.
    private var takenOver: (controller: WeakController, tabID: String)?
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
        let run = AgentRunCenter.shared
        subs.append(run.$state.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshAll() } })
        subs.append(run.$approval.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshAll() } })
    }

    // MARK: Lookups

    func entry(_ page: EngineTab) -> Hosted? { hosted.first { $0.page === page } }
    func entry(tabID: String, in c: WindowController) -> Hosted? { hosted.first { $0.tabID == tabID && $0.controller === c } }
    func isHosted(_ tabID: String) -> Bool { hosted.contains { $0.tabID == tabID && $0.page != nil } }

    /// The run's current page, if hosted.
    var runEntry: Hosted? {
        guard let w = AgentRunCenter.shared.runWindowID.flatMap({ AgentCenter.shared.windows[$0] }), let p = w.activeTab else { return nil }
        return entry(p)
    }

    /// Whether the run's current page is the one this window shows now (the pane then needs no live card).
    func runShown(in c: WindowController) -> Bool {
        guard let e = runEntry, e.controller === c, let page = e.page, let w = e.window else { return false }
        return c.shownTabID == e.tabID && !w.isParked(page)
    }

    // MARK: Starting

    /// The size a new run's agent window starts at: the main view of the window it will show in (its card's page).
    var nextViewport: CGSize? {
        guard let c = next?.controller ?? Self.frontController else { return nil }
        let s = c.card.hostView?.bounds.size ?? c.card.bounds.size
        return s.width >= 320 && s.height >= 240 ? s : nil
    }

    /// The pane (every way to ask goes through it) says where the next run is asked. `page`: the person's tab, used by
    /// the agent itself when the task is about it.
    func willAsk(in c: WindowController, page tabID: String?) {
        follow()
        next = Start(controller: c, tabID: tabID)
        lastReleased = nil
        takenOver = nil
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
        var start = next
        next = nil
        // Continue after a stop: the same tab, which the person still has.
        if start == nil, let r = lastReleased, let c = r.controller.c, c.engineTab(for: r.tabID) != nil {
            start = Start(controller: c, tabID: r.tabID)
        }
        lastReleased = nil
        follow()
        guard let c = start?.controller ?? AgentMainView.frontController else { return }
        w.hostsInMainView = true
        let blank = w.activeTabID
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
            hosted.append(Hosted(page: page, controller: c, window: w, tabID: id, personOwned: false))
            w.unparked(page)
            onEvent?("present \(id)")
        }
        refresh(c)
        changed()
    }

    /// A follow-up or Continue in the same window: the run's page comes back into the main view.
    func runResumed(_ w: AgentWindow) {
        let asker = next?.controller
        next = nil
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
        } else if let c, AgentRunCenter.shared.runWindowID == w.id || AgentRunCenter.shared.runWindowID == nil, w.activeTab == nil || w.activeTab === page {
            lastReleased = (WeakController(c), e.tabID)
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
        let wasRun = AgentRunCenter.shared.runWindowID == w.id && w.activeTab === page
        if let id = w.hostedID(page) { w.unhost(id, closing: true) }
        if wasRun, AgentRunCenter.shared.state.isActive { AgentRunCenter.shared.stop("You closed the agent's tab.") }
        if takenOver?.tabID == tabID { takenOver = nil }
        onEvent?("closed \(tabID)")
    }

    /// The person's window shows `shown` and stopped showing `hidden`.
    func visibilityChanged(in c: WindowController, hidden: String?, shown: String?) {
        guard !hosted.isEmpty || chromes[ObjectIdentifier(c)] != nil || takenOver != nil else { return }
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
    func bringBack(windowID: Int? = nil) -> Bool {
        let w = (windowID ?? AgentRunCenter.shared.runWindowID).flatMap { AgentCenter.shared.windows[$0] }
        guard let page = w?.activeTab, let e = entry(page) else { return false }
        bringBack(e)
        return true
    }

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
    func takeOver(in c: WindowController) -> (tabID: String, title: String, url: URL?, agentTabID: Int?)? {
        guard let e = runEntry, let page = e.page, e.controller === c else { return nil }
        bringBack(e)
        takenOver = (WeakController(c), e.tabID)
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
        takenOver = nil
        next = nil
        lastReleased = nil
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
    func endTakeOver() {
        let c = takenOver?.controller.c
        takenOver = nil
        if let c { refresh(c) }
    }

    var takenOverTabID: String? { takenOver?.tabID }

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
        chrome(c, create: false)?.setActing(true)
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
    }

    func pageTitleChanged(_ page: EngineTab) { entry(page)?.window?.hostedTitleChanged(page) }

    /// A parked page's title or address changed: the person's row follows.
    func parkedTitleChanged(_ w: AgentWindow, _ page: EngineTab) {
        guard let e = entry(page), let c = e.controller, w.isParked(page) else { return }
        c.store.updateTab(e.tabID, url: page.url?.absoluteString, title: page.title.isEmpty ? nil : page.title,
                          faviconURL: page.faviconURL?.absoluteString)
        c.refreshRow(e.tabID)
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
        v.bar.onTakeOver = { [weak c] in guard let c else { return }; AgentPaneController.show(c).model.takeOver() }
        v.bar.onStop = { [weak self, weak c] in
            guard let c else { return }
            AgentPaneController.show(c).model.stopTask()   // stops the run and clears a Take over's banner
            AgentRunCenter.shared.stop()
            self?.endTakeOver()
        }
        v.bar.onHandBack = { [weak c] in guard let c else { return }; AgentPaneController.show(c).model.handBack() }
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
        v.bar.name = AgentRunCenter.shared.cliKind.map { "\($0.name)" } ?? "Airc Agent"
        v.page = c.shownTabID.flatMap { c.engineTab(for: $0) }?.view
        v.set(mode)
        #if AIRC_TESTING
        lastMode[ObjectIdentifier(c)] = mode
        #endif
    }

    private func mode(_ c: WindowController) -> AgentMainChromeView.Mode {
        guard let id = c.shownTabID, c.store.split(containing: id) == nil || c.visibleTabIDs.count <= 1 else { return .off }
        if takenOver?.tabID == id, takenOver?.controller.c === c { return .takenOver }
        guard let e = entry(tabID: id, in: c), let w = e.window, let page = e.page, !w.isParked(page) else { return .off }
        let run = AgentRunCenter.shared
        guard run.state.isActive, run.runWindowID == w.id else { return .off }
        return .working(waiting: run.approval != nil)
    }

    private func changed() { NotificationCenter.default.post(name: Self.changed, object: self) }

    #if AIRC_TESTING
    private(set) var lastMode: [ObjectIdentifier: AgentMainChromeView.Mode] = [:]
    func chromeView(_ c: WindowController) -> AgentMainChromeView? { chromes[ObjectIdentifier(c)] }
    func modeShown(_ c: WindowController) -> AgentMainChromeView.Mode { mode(c) }
    #endif
}

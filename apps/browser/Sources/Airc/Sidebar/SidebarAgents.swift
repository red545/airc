// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import Combine
import SwiftUI

/// The sidebar's Agents folder (docs/user/agents.md, "Follow along"): above the tray, while an agent works in this
/// window's profile or finished in the last few minutes (Settings › Agents › "Keep finished agents for", 5 by default).
/// One row per task (agentrows, 2026-11-23): the Airc Agent's tasks (SidebarTaskRows.swift), then one row per other
/// app's session that did something real, titled by what happened ("Gmail · read 3 pages") with the site's icon and the
/// app under it ("Claude Code", "Claude · Clicking ‘Archive’", "Claude · Done · 3 min ago"); a spinner while it works,
/// ✋ when its page needs you; "Done" when it ends, then faded, then gone. Click a row to Watch it (AgentWatchView);
/// its menu has Take over and Stop. It folds like a folder and remembers that.
/// Private windows have their own sidebar, which never shows it. With no rows it takes no space and runs nothing.
final class SidebarAgentsView: NSView {
    static let headerHeight: CGFloat = 30
    static let rowPitch: CGFloat = 34
    static let rowHeight: CGFloat = 32
    static let topInset: CGFloat = 6
    static let bottomInset: CGFloat = 4
    static let expandedKey = "AgentsFolderExpanded"

    private(set) var height: CGFloat = 0
    let model = AgentsFolderModel()
    private var host: AircFirstClickHostingView<AgentsFolderContent>?
    private(set) weak var controller: WindowController?
    private var target: CGFloat = 0
    private var observers: [NSObjectProtocol] = []
    private var taskSub: AnyCancellable?
    /// Watch over this window's page, while open.
    private(set) var watch: AgentWatchView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func connect(_ c: WindowController) {
        controller = c
        model.view = self
        guard host == nil else { return }
        let h = AircFirstClickHostingView(rootView: AgentsFolderContent(model: model))
        h.safeAreaRegions = []
        addSubview(h)
        host = h
        for name in [AgentActivity.changed, AgentCenter.changed, AgentAttention.changed, AgentTaskCenter.changed] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // asidepass: the Space's tasks (AgentTaskRecorder) as rows.
        taskSub = AgentTaskRecorder.shared.$tasks.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        refresh()
    }

    /// The window's chrome changed (WindowController.refreshChrome: a Space switch, a theme, a shown tab).
    func chromeChanged() {
        guard let c = controller else { return }
        setTheme(c.currentPalette.resolved)
        if let watch, watch.shownTabAtOpen != c.shownTabID { closeWatch() }   // the person picked one of their tabs
        if model.profileID != c.store.space(c.currentSpaceID)?.profileID || model.spaceID != c.currentSpaceID { refresh() }
        let shown = AgentTasksURL.taskID(c.shownTabID.flatMap { c.store.tab($0)?.url })
        if model.shownTaskID != shown { model.shownTaskID = shown }
    }

    /// spaceswitch: closed (no rows, nothing on screen), the folder keeps the theme for later instead of re-rendering
    /// its SwiftUI view in every Space switch (~1 ms of each switch's frame); `refresh` applies it in the same turn
    /// as the rows that open it, so its first frame has the right colours.
    private var pendingTheme: ResolvedTheme?
    private var isClosed: Bool { target == 0 && height == 0 && model.items.isEmpty && model.tasks.isEmpty }

    private func setTheme(_ theme: ResolvedTheme) {
        if Self.defersClosedTheme, isClosed {
            pendingTheme = model.theme == theme ? nil : theme
            return
        }
        pendingTheme = nil
        if model.theme != theme { model.theme = theme }
    }

    /// Test builds can re-render it on every switch the old way (`AIRC_SPACE_SWITCH_BASELINE=1`), to compare both in one binary.
    static let defersClosedTheme: Bool = {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_SPACE_SWITCH_BASELINE"] != "1"
        #else
        return true
        #endif
    }()

    /// Rows and height from the activity model.
    func refresh() {
        guard let c = controller else { return }
        let profile = c.store.space(c.currentSpaceID)?.profileID
        model.profileID = profile
        let activity = AgentActivity.shared
        let now = Date()
        // agentrows: one row per session; with the pane, the Airc Agent's runs are their task's row (asidepass listed
        // the run's page as a second row under it: the same task twice).
        let pane = AgentUI.usesPane
        let rows = profile.map { activity.model.sessionRows(profileID: $0, excluding: pane ? AgentBridge.clientKey : nil) } ?? []
        let tasks = pane ? SidebarTaskList.lines(SidebarTaskList.tasks(spaceID: c.currentSpaceID, profileID: profile)) : []
        model.spaceID = c.currentSpaceID
        if tasks != model.tasks { model.tasks = tasks }
        let items = rows.map { r in AgentsFolderModel.Item(row: r, state: activity.model.state(r, now: now),
                                                           stopped: r.clientKey.map(AgentCenter.shared.isStopped) ?? false) }
        if let theme = pendingTheme, !items.isEmpty || !tasks.isEmpty {
            pendingTheme = nil
            if model.theme != theme { model.theme = theme }
        }
        if items != model.items { model.items = items }
        if model.watchingID != watch?.rowID { model.watchingID = watch?.rowID }
        if let watch, let row = activity.model.row(watch.rowID) { watch.update(row: row, state: activity.model.state(row, now: now)) }
        layoutHeight()
    }

    // MARK: Tasks (asidepass)

    func openTask(_ id: String) {
        guard let c = controller else { return }
        if let run = AgentTaskCenter.shared.run(task: id) {
            // agentux3: a running task waits for the person: straight to it (its page's sign-in, else its OK).
            if let row = model.tasks.first(where: { $0.id == id })?.liveRowID, AgentAttention.go(row: row, from: "taskRow") { return }
            if let it = AgentAttention.items().first(where: { $0.kind == .approval && $0.taskID == id }) { return AgentAttention.go(it, from: "taskRow") }
            // agentmainview: a running task's page is a tab of this window: back into the main view, the pane beside it
            // on that task (agentparallel: the others keep running, parked).
            if run.state.isActive, AgentMainView.shared.bringBack(run) {
                if AgentUI.usesPane { AgentPaneController.show(c, task: run) }
                return
            }
        }
        AgentTasksPage.openTask(id, in: c)
    }

    func taskIcon(_ line: SidebarTaskLine) -> NSImage? {
        guard let id = line.liveRowID, let row = AgentActivity.shared.model.row(id) else { return nil }
        return AgentCenter.shared.windows[row.window]?.tab(row.tab)?.favicon
    }

    func newTask() {
        guard let c = controller else { return }
        AgentUI.newTask(c)
    }

    func showAllTasks() {
        guard let c = controller else { return }
        AgentTasksPage.open(in: c)
    }

    func stopTask(_ id: String) {
        AgentTaskCenter.shared.run(task: id)?.stop()
    }

    func setExpanded(_ on: Bool) {
        model.expanded = on
        UserDefaults.standard.set(on, forKey: Self.expandedKey)
        layoutHeight()
    }

    private func layoutHeight() {
        let n = model.items.count
        // asidepass: New Task, the tasks and Show all, over the other apps' rows (agentrows: a task row with a line under
        // it is taller).
        let taskHeight = model.tasks.isEmpty ? 0 : 2 * SidebarTaskList.rowPitch + model.tasks.reduce(0) { $0 + SidebarTaskList.pitch($1) }
        let h: CGFloat = n + model.tasks.count == 0 ? 0 : Self.topInset + Self.headerHeight
            + (model.expanded ? CGFloat(n) * Self.rowPitch + taskHeight : 0) + Self.bottomInset
        guard h != target else { return }
        target = h
        guard let c = controller, window != nil, !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return setHeight(h) }
        c.animator.spring("agents-folder", from: Double(height), to: Double(h), velocity: 0, spring: Spring(AircSpring.row),
                          update: { [weak self] v in self?.setHeight(CGFloat(v)) }, completion: { [weak self] in self?.setHeight(h) })
    }

    private func setHeight(_ h: CGFloat) {
        height = max(0, h)
        needsLayout = true
        superview?.needsLayout = true
        superview?.layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        // Laid out at full height from the top, shown as the section opens over it.
        host?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(target, bounds.height))
    }

    // MARK: Watch, Take over, Stop

    func openWatch(_ rowID: String, takeKeys: Bool = true) {
        guard let c = controller, let row = AgentActivity.shared.model.row(rowID), row.isLive else { return }
        if watch?.rowID == rowID { return }
        closeWatch()
        let v = AgentWatchView(rowID: rowID, controller: c)
        watch = v
        v.start(takeKeys: takeKeys)
        if !model.expanded { setExpanded(true) }
        refresh()
    }

    // MARK: The pane task's approval, on its row (agentux, docs/design/agent-ux.md §6)

    private var approvalPopover: NSPopover?
    private var approvalSub: AnyCancellable?

    /// "✋ Pay on …?" with Open task / Deny / Allow once, pointing at the row. An AppKit popover on a first-click hosting
    /// view, so the first press on an inactive popover answers (SwiftUI's popover spent it on activation). It closes when
    /// the approval is answered anywhere (one answer clears all).
    func showApproval(_ run: AgentRunCenter, at rowFrame: CGRect, open: @escaping () -> Void) {
        guard approvalPopover?.isShown != true, let host, window != nil, rowFrame.height > 0, let a = run.approval else { return }
        // Never again for an approval the person was just taken to (a needs-you landing closed every row popover for
        // it, AgentAttention.go): re-opened on another window right after the landing, e.g. a full-screen one, it kept
        // macOS on that Space (tailreds, agentpane2 "✦ / notification from a full-screen window").
        if AgentAttention.landed(onApproval: a.id) {
            AgentCenter.shared.onEvent?("attention-row-approval not shown in #\(window?.windowNumber ?? 0): landed on it")
            return
        }
        let p = NSPopover()
        p.behavior = .applicationDefined
        p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.appearance = NSAppearance(named: model.theme.isDark ? .darkAqua : .aqua)
        let v = AircFirstClickHostingView(rootView: AgentRowApproval(run: run, request: a, open: { [weak self] in self?.closeApproval(); open() },
                                                                    close: { [weak self] in self?.closeApproval() }).testAnchorRoot())
        v.frame.size = v.fittingSize
        let vc = NSViewController()
        vc.view = v
        p.contentViewController = vc
        p.contentSize = v.fittingSize
        approvalPopover = p
        p.show(relativeTo: rowFrame, of: host, preferredEdge: controller?.sidebarOnRight == true ? .minX : .maxX)
        AgentCenter.shared.onEvent?("attention-row-approval shown in #\(window?.windowNumber ?? 0)")
        approvalSub = run.$approval.dropFirst().sink { [weak self] new in if new?.id != a.id { self?.closeApproval() } }
    }

    func closeApproval() {
        if approvalPopover != nil { AgentCenter.shared.onEvent?("attention-row-approval closed in #\(window?.windowNumber ?? 0)") }
        approvalSub = nil
        approvalPopover?.close()
        approvalPopover = nil
    }

    #if AIRC_TESTING
    var approvalPopoverView: NSView? { approvalPopover?.isShown == true ? approvalPopover?.contentViewController?.view : nil }
    #endif

    func closeWatch() {
        guard let w = watch else { return }
        watch = nil
        w.stop()
        refresh()
    }

    /// Take over: the page becomes this window's tab. Shows why not in a toast when it can't.
    func takeOver(_ rowID: String) {
        guard let c = controller, let row = AgentActivity.shared.model.row(rowID), row.isLive else { return }
        if watch?.rowID == rowID { closeWatch() }
        if let why = AgentCenter.shared.takeOver(window: row.window, tab: row.tab, into: c) { c.showToast(why) }
    }

    func stop(_ rowID: String) {
        guard let row = AgentActivity.shared.model.row(rowID) else { return }
        if watch?.rowID == rowID { closeWatch() }
        // agentparallel: an Airc Agent page's Stop ends its own task; the others keep running.
        if row.clientKey == AgentBridge.clientKey, let run = AgentTaskCenter.shared.run(agentWindow: row.window) {
            return run.stop("Stopped from the Agents folder.")
        }
        if let key = row.clientKey { AgentCenter.shared.stopClient(key) }
        else { AgentCenter.shared.closeSessionWindows(row.sessionKey) }
    }

    func allowAgain(_ rowID: String) {
        guard let key = AgentActivity.shared.model.row(rowID)?.clientKey else { return }
        AgentCenter.shared.allowAgain(key)
        refresh()
    }

    func icon(_ item: AgentsFolderModel.Item) -> NSImage? {
        AgentCenter.shared.windows[item.window]?.tab(item.tab)?.favicon
    }
}

extension AgentCenter {
    /// Stop for a connection without an app identity (test transports): its windows close.
    func closeSessionWindows(_ ownerKey: String) {
        for w in windows.values where w.ownerKey == ownerKey { closeWindow(w, end: .stopped) }
        AgentActivity.shared.sessionEnded(ownerKey, .stopped)
    }
}

final class AgentsFolderModel: ObservableObject {
    struct Item: Equatable, Identifiable {
        let id: String
        /// "Claude · Gmail" (Watch, the demos).
        let label: String
        /// What happened: "Gmail · read 3 pages", or the Airc Agent's task.
        let title: String
        let client: String
        let clientKey: String?
        let window: Int
        let tab: Int
        let live: Bool
        let acting: Bool
        let status: String
        /// What the agent does now ("Clicking ‘Archive’"), while it acts.
        let caption: String?
        let needsYou: Bool
        let faded: Bool
        let stopped: Bool

        init(row r: AgentTabRow, state: AgentRowState, stopped: Bool) {
            id = r.id; label = r.label; title = r.rowTitle; client = r.client; clientKey = r.clientKey; window = r.window; tab = r.tab; live = r.isLive
            self.stopped = stopped
            needsYou = { if case .needsYou = state { return true } else { return false } }()
            switch state {
            case .acting(let c): acting = true; faded = false; status = c ?? "Working"; caption = c
            case .idle: acting = false; faded = false; status = "Waiting"; caption = nil
            case .needsYou(let why): acting = false; faded = false; status = "Needs you · " + why; caption = nil
            case .justEnded(let end): acting = false; faded = false; status = Item.words(end); caption = nil
            case .faded(let end, let minutes): acting = false; faded = true; status = Item.words(end) + " · \(minutes) min ago"; caption = nil
            }
        }

        /// What follows the app's name under the title, only when it says more than the row's icon: what it does now,
        /// what it waits for, how it ended. Nil while it just works or waits for its app ("Waiting" said nothing).
        var detail: String? {
            if !live || needsYou { return status }
            return caption
        }

        /// The line under the title: the app (and its device), then `detail`.
        var subtitle: String { client + (detail.map { " · " + $0 } ?? "") }

        static func words(_ end: AgentTabRow.End) -> String {
            switch end { case .done: return "Done"; case .stopped: return "Stopped"; case .takenOver: return "Yours now" }
        }
    }

    @Published var items: [Item] = []
    @Published var expanded = UserDefaults.standard.object(forKey: SidebarAgentsView.expandedKey) as? Bool ?? true
    @Published var watchingID: String?
    @Published var theme = DesignTheme.default.resolved(systemIsDark: false)
    /// asidepass: this Space's Airc Agent tasks, and the one the window shows in its task view.
    @Published var tasks: [SidebarTaskLine] = []
    @Published var shownTaskID: String?
    var spaceID = ""
    var profileID: String?
    weak var view: SidebarAgentsView?

    var hasEnded: Bool { items.contains { !$0.live } }
    var actingCount: Int { items.filter(\.acting).count + tasks.filter { $0.status == .spinner }.count }
}

struct AgentsFolderContent: View {
    static let space = "agentsFolder"
    @ObservedObject var model: AgentsFolderModel
    @State private var headerHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.expanded, !model.tasks.isEmpty {
                VStack(spacing: SidebarTaskList.rowPitch - SidebarTaskList.rowHeight) {
                    SidebarNewTaskRow { model.view?.newTask() }
                    ForEach(model.tasks) { t in
                        AgentTaskFolderRow(line: t, model: model)
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                    SidebarShowAllRow { model.view?.showAllTasks() }
                }
                .padding(.bottom, SidebarTaskList.rowPitch - SidebarTaskList.rowHeight)
            }
            if model.expanded {
                VStack(spacing: SidebarAgentsView.rowPitch - SidebarAgentsView.rowHeight) {
                    ForEach(model.items) { item in
                        AgentFolderRow(item: item, model: model, watching: model.watchingID == item.id)
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SidebarAgentsView.topInset)
        .padding(.horizontal, AircMetrics.Sidebar.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: Self.space)
        .animation(AircSpring.row.animation, value: model.items.map(\.id))
        .animation(AircSpring.row.animation, value: model.tasks.map(\.id))
        .testAnchorRoot()
        .aircTheme(model.theme)
    }

    private var header: some View {
        AgentsFolderHeader(model: model, hovered: $headerHovered)
            .frame(height: SidebarAgentsView.headerHeight)
            .testAnchor("agents-header")
    }
}

private struct AgentsFolderHeader: View {
    @ObservedObject var model: AgentsFolderModel
    @ObservedObject private var tasks = AgentTaskCenter.shared
    @Binding var hovered: Bool
    @Environment(\.aircTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(model.expanded ? 90 : 0))
                .foregroundStyle(theme.textTertiary.color)
                .frame(width: 12)
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary.color)
            Text("Agents")
                .aircFont(AircFont.callout.weight(.semibold))
                .foregroundStyle(theme.textSecondary.color)
            if AgentActivity.shared.model.needsYouCount > 0 || !tasks.waiting.isEmpty {
                // An agent waits for the person (a sign-in, a captcha: AgentNeedsYou.swift; an approval): one click goes
                // there, the next to the next one waiting (AgentAttention).
                Button { AgentAttention.goNext(from: "folderBadge") } label: {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("An agent needs you: go there")
                .accessibilityLabel("An agent needs you")
                .accessibilityHint("Goes to what it waits for")
                .testAnchor("agents-needs-you")
            }
            if !model.expanded, model.actingCount > 0 {
                AgentPulseDot(acting: true, color: theme.accent.nsColor, reduceMotion: reduceMotion)
                    .frame(width: 8, height: 8)
            }
            Spacer(minLength: 4)
            if model.hasEnded, hovered || !model.items.contains(where: \.live) {
                Button("Clear") { AgentActivity.shared.clearEnded() }
                    .buttonStyle(.plain)
                    .aircFont(AircFont.caption)
                    .foregroundStyle(theme.textTertiary.color)
                    .accessibilityLabel("Clear finished agent tabs")
                    .testAnchor("agents-clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AircMetrics.Row.plateRadius, style: .continuous)
            .fill(hovered ? theme.hoverFill.color : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { withAnimation(reduceMotion ? nil : AircSpring.row.animation) { model.view?.setExpanded(!model.expanded) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents, \(model.items.count + model.tasks.count) task\(model.items.count + model.tasks.count == 1 ? "" : "s")")
        .accessibilityValue(model.expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.view?.setExpanded(!model.expanded) }
    }
}

/// A task's row in the folder, with its live page's approval popover (agentux, docs/design/agent-ux.md §6; it was on
/// the page's own row before agentrows): "✋ Pay on …?" points at the task row when the pane isn't showing the task.
private struct AgentTaskFolderRow: View {
    let line: SidebarTaskLine
    @ObservedObject var model: AgentsFolderModel
    /// agentparallel: every task row follows its own run.
    @ObservedObject private var tasks = AgentTaskCenter.shared
    @State private var frameInFolder: CGRect = .zero

    private var run: AgentRunCenter? { tasks.run(task: line.id) }
    private var waiting: Bool { run?.approval != nil }
    /// The pane is open on this very task.
    private var paneShown: Bool {
        guard let p = model.view?.controller.flatMap({ AgentPaneController.pane(of: $0) }) else { return false }
        return p.isShown && p.model.run === run
    }
    private var live: Bool { line.liveRowID != nil && (line.task.status == .running || line.task.status == .waiting || line.task.status == .takenOver) }

    var body: some View {
        let t = line.task
        let page = live ? line.liveRowID : nil
        SidebarTaskRow(line: line, selected: model.shownTaskID == t.id, open: { model.view?.openTask(t.id) },
                       stop: t.status == .running || t.status == .waiting ? { model.view?.stopTask(t.id) } : nil,
                       watch: page.map { id in { model.view?.openWatch(id) } },
                       takeOver: page.map { id in { model.view?.takeOver(id) } },
                       icon: model.view?.taskIcon(line))
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { frameInFolder = g.frame(in: .named(AgentsFolderContent.space)) }
                    .onChange(of: g.frame(in: .named(AgentsFolderContent.space))) { _, f in frameInFolder = f }
            })
            .onChange(of: run?.approval) { _, a in
                if a != nil, waiting, !paneShown, let run { model.view?.showApproval(run, at: frameInFolder, open: { model.view?.openTask(t.id) }) }
            }
            .onAppear { if waiting && !paneShown, let run { model.view?.showApproval(run, at: frameInFolder, open: { model.view?.openTask(t.id) }) } }
    }
}

private struct AgentFolderRow: View {
    let item: AgentsFolderModel.Item
    @ObservedObject var model: AgentsFolderModel
    let watching: Bool
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // agentux: the pane's own task (docs/design/agent-ux.md §7): it opens in the pane, and a waiting approval shows on
    // the row (✋, "Waiting for your OK") and as a popover when the pane isn't showing the task.
    @ObservedObject private var tasks = AgentTaskCenter.shared
    /// agentparallel: the Airc Agent task whose window this row's page is in.
    private var run: AgentRunCenter? { item.live ? tasks.run(agentWindow: item.window) : nil }

    private var paneTask: Bool { AgentUI.usesPane && run != nil && (item.client == AgentBridge.clientName || item.clientKey == "airc-panel") }
    private var waiting: Bool { paneTask && run?.approval != nil }
    private var paneShown: Bool {
        guard let p = model.view?.controller.flatMap({ AgentPaneController.pane(of: $0) }) else { return false }
        return p.isShown && p.model.run === run
    }

    private func open() {
        // agentux3: a row that waits for the person goes straight to the answer (the approval card, or its page in front).
        if item.live, AgentAttention.go(row: item.id, from: "row") { return }
        if paneTask, let run, let c = model.view?.controller { AgentPaneController.show(c, task: run) } else if item.live { model.view?.openWatch(item.id) }
    }

    @State private var frameInFolder: CGRect = .zero

    var body: some View {
        row
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { frameInFolder = g.frame(in: .named(AgentsFolderContent.space)) }
                    .onChange(of: g.frame(in: .named(AgentsFolderContent.space))) { _, f in frameInFolder = f }
            })
            .onChange(of: run?.approval) { _, a in
                if a != nil, waiting, !paneShown, let run { model.view?.showApproval(run, at: frameInFolder, open: { open() }) }
            }
            .onAppear { if waiting && !paneShown, let run { model.view?.showApproval(run, at: frameInFolder, open: { open() }) } }
    }

    private var row: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .aircFont(AircFont.body)
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .testAnchor("agents-title-\(item.id)")
                // The app, then its state: a long device name gives way before "Done · 3 min ago" does; while it
                // works, the caption ("Typing in ‘Search mail’") gives way before the app's name does.
                HStack(spacing: 0) {
                    Text(item.client).lineLimit(1).truncationMode(.middle).layoutPriority(item.live ? 1 : 0)
                    if let d = waiting ? "Waiting for your OK" : item.detail {
                        Text(" · " + d).lineLimit(1).truncationMode(.tail).layoutPriority(item.live ? 0 : 1)
                    }
                }
                .aircFont(AircFont.caption)
                .foregroundStyle(theme.textTertiary.color)
            }
            Spacer(minLength: 2)
            if waiting || item.needsYou, !hovered {
                Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(.orange).padding(.trailing, 2)
                    .accessibilityLabel(waiting ? "Waiting for your OK" : item.status)
                    .testAnchor("agents-waiting-\(item.id)")
            } else if hovered, item.live {
                // agentux: Watch is one click on any working row (a background agent's page is off screen otherwise).
                TrayButton(symbol: "eye", help: "Watch the agent's page") { model.view?.openWatch(item.id) }
                    .accessibilityLabel("Watch \(item.client)")
                    .testAnchor("agents-watch-\(item.id)")
                TrayButton(symbol: "stop.fill", help: "Stop \(item.client)") { model.view?.stop(item.id) }
                    .accessibilityLabel("Stop \(item.client)")
                    .testAnchor("agents-stop-\(item.id)")
            } else if item.live, item.acting {
                // agentrows: one status, as on task rows: a spinner while its app works with the page; nothing while
                // it is connected but quiet (a session left open would spin for ever).
                AgentTaskSpinner(size: 12, color: theme.textTertiary.nsColor).frame(width: 12, height: 12)
                    .padding(.trailing, 2)
                    .testAnchor("agents-dot-\(item.id)")
                    .testAnchor("agents-spinner-\(item.id)")
            }
        }
        .padding(.leading, AircMetrics.Row.folderIndent)
        .padding(.trailing, 6)
        .frame(height: SidebarAgentsView.rowHeight)
        .background(RoundedRectangle(cornerRadius: AircMetrics.Row.plateRadius, style: .continuous)
            .fill((watching ? theme.selectedFill : hovered ? theme.hoverFill : AircColor.clear).color))
        .opacity(item.faded ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { open() }
        .contextMenu { menu }
        .testAnchor("agents-row-\(item.id)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.client + ", " + (item.live ? (item.acting ? "Working: \(item.status)" : "Waiting") : item.status))
        .accessibilityHint(paneTask ? "Open the task in the agent pane" : item.live ? "Watch what the agent does" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if item.live { model.view?.openWatch(item.id) } }
        .accessibilityAction(named: "Watch") { model.view?.openWatch(item.id) }
        .accessibilityAction(named: "Take over") { model.view?.takeOver(item.id) }
        .accessibilityAction(named: "Stop \(item.client)") { model.view?.stop(item.id) }
    }

    @ViewBuilder private var icon: some View {
        if let image = model.view?.icon(item) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .testAnchor("agents-favicon-\(item.id)")
        } else {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary.color).frame(width: 16, height: 16)
                .testAnchor("agents-sparkle-\(item.id)")
        }
    }

    @ViewBuilder private var menu: some View {
        if item.live {
            Button("Watch") { model.view?.openWatch(item.id) }
            Button("Take Over") { model.view?.takeOver(item.id) }
            Divider()
            Button("Stop \(item.client)") { model.view?.stop(item.id) }
        } else if item.stopped {
            Button("Allow \(item.client) Again") { model.view?.allowAgain(item.id) }
        }
        if !item.live { Button("Clear Finished") { AgentActivity.shared.clearEnded() } }
    }
}

/// The acting dot: a soft pulse on Core Animation (the render server runs it; the app does nothing per frame), a solid
/// dot under Reduce Motion, a quiet ring while the agent waits.
struct AgentPulseDot: NSViewRepresentable {
    let acting: Bool
    let color: NSColor
    let reduceMotion: Bool

    final class DotView: NSView {
        let dot = CALayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dot)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            dot.frame = bounds
            dot.cornerRadius = bounds.width / 2
        }
        /// Whether the pulse runs (checks read it).
        var pulsing: Bool { dot.animation(forKey: "pulse") != nil }
    }

    func makeNSView(context: Context) -> DotView { DotView(frame: .zero) }

    func updateNSView(_ v: DotView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if acting {
            v.dot.backgroundColor = color.cgColor
            v.dot.borderWidth = 0
        } else {
            v.dot.backgroundColor = NSColor.clear.cgColor
            v.dot.borderColor = color.withAlphaComponent(0.55).cgColor
            v.dot.borderWidth = 1.5
        }
        CATransaction.commit()
        let pulse = acting && !reduceMotion
        if pulse, v.dot.animation(forKey: "pulse") == nil {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.3
            a.duration = 0.7
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.dot.add(a, forKey: "pulse")
            AgentPulseDot.pulsing.insert(ObjectIdentifier(v))
        } else if !pulse, v.dot.animation(forKey: "pulse") != nil {
            v.dot.removeAnimation(forKey: "pulse")
            AgentPulseDot.pulsing.remove(ObjectIdentifier(v))
        }
    }

    static func dismantleNSView(_ v: DotView, coordinator: ()) { pulsing.remove(ObjectIdentifier(v)) }

    /// The dots pulsing now (checks count them).
    static var pulsing: Set<ObjectIdentifier> = []
}

/// The popover's content: what the agent wants to do, and the three answers. Nothing is pre-selected.
private struct AgentRowApproval: View {
    let run: AgentRunCenter
    let request: AgentApprovalRequest
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(request.title).aircFont(AircFont.body.weight(.semibold))
            }
            Text(request.risk.reason).aircFont(AircFont.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Open task", action: open).buttonStyle(.airc(.secondary, size: .small)).testAnchor("agents-popover-open")
                Spacer()
                Button("Deny") { close(); run.answerApproval(allow: false) }.buttonStyle(.airc(.secondary, size: .small))
                    .testAnchor("agents-popover-deny")
                Button("Allow once") { close(); run.answerApproval(allow: true) }.buttonStyle(.airc(.secondary, size: .small))
                    .testAnchor("agents-popover-allow")
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

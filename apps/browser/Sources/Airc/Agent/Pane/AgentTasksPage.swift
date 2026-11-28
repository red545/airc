// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import Combine
import SwiftUI

/// Keeps a task record (AircKit's AgentTaskRecord, `<data folder>/Agent/Tasks/<id>.json`) for each pane conversation:
/// title, state, provider, steps, sites and the answer's first line. Never page text, typed values or keys; its pictures
/// are AgentTaskThumbs' own files (agentrecall), deleted with it. agentparallel: one record per running task, each
/// following its own run (AgentTaskCenter).
final class AgentTaskRecorder: ObservableObject {
    static let shared = AgentTaskRecorder()

    let store = AgentTaskStore(folder: AppPaths.dataDirectory.appendingPathComponent("Agent/Tasks", isDirectory: true))
    @Published private(set) var tasks: [AgentTaskRecord] = []
    /// Each run's record (run → record id), while its conversation has one.
    private var live: [ObjectIdentifier: String] = [:]
    private var subs: [ObjectIdentifier: [AnyCancellable]] = [:]
    private var saveQueued: Set<ObjectIdentifier> = []

    private init() {
        // A task can't be running when Airc starts (its run lives in this process): a record a quit or crash left
        // running, waiting or queued says Stopped.
        var loaded = store.all()
        for i in loaded.indices where [.running, .waiting, .takenOver, .queued].contains(loaded[i].status) {
            loaded[i].status = .stopped
            loaded[i].endedAt = loaded[i].endedAt ?? loaded[i].updatedAt
            try? store.save(loaded[i])
        }
        tasks = AgentTaskRecord.ordered(loaded)
        let ids = Set(loaded.map(\.id))
        DispatchQueue.main.async { AgentTaskThumbs.shared.prune(keeping: ids) }
    }

    /// From AgentTaskCenter.make: follow this run.
    func attach(_ run: AgentRunCenter) {
        let key = ObjectIdentifier(run)
        guard subs[key] == nil else { return }
        var s: [AnyCancellable] = []
        s.append(run.$steps.sink { [weak self, weak run] steps in
            DispatchQueue.main.async { if let run { self?.stepsChanged(run, steps) } }
        })
        s.append(run.$queuedPrompt.sink { [weak self, weak run] q in
            DispatchQueue.main.async { if let run, q != nil { self?.queued(run) } }
        })
        s.append(run.$state.sink { [weak self, weak run] _ in DispatchQueue.main.async { if let run { self?.queueSave(run) } } })
        s.append(run.$approval.sink { [weak self, weak run] _ in DispatchQueue.main.async { if let run { self?.queueSave(run) } } })
        subs[key] = s
    }

    func detach(_ run: AgentRunCenter) {
        let key = ObjectIdentifier(run)
        subs[key] = nil
        live[key] = nil
    }

    /// The pane starts a task in this Space (now on the run itself: AgentAttention.taskAsked).
    func willAsk(spaceID: String, profileID: String) {}

    /// The record this run writes now.
    func recordID(_ run: AgentRunCenter) -> String? { live[ObjectIdentifier(run)] }

    private func makeRecord(_ run: AgentRunCenter, prompt: String, status: AgentTaskRecord.Status) {
        let v = AgentModelSettings.shared.values
        let provider = v.backend.cli?.name ?? v.provider.name + " API key"
        let r = AgentTaskRecord(id: run.taskID, title: AgentTaskTitle.make(prompt), spaceID: run.askedSpaceID ?? "",
                                profileID: run.askedProfileID ?? run.profileID ?? "", provider: provider, status: status)
        live[ObjectIdentifier(run)] = r.id
        upsert(r)
    }

    /// Past the person's limit: the task shows as Queued until it starts.
    private func queued(_ run: AgentRunCenter) {
        guard live[ObjectIdentifier(run)] == nil, !run.privateWindow, let q = run.queuedPrompt else { return }
        makeRecord(run, prompt: q, status: .queued)
    }

    private func stepsChanged(_ run: AgentRunCenter, _ steps: [AgentStep]) {
        let key = ObjectIdentifier(run)
        if steps.isEmpty {
            // A new conversation leaves the old task where it was; one still marked working or queued was cut off.
            if let id = live[key], var r = tasks.first(where: { $0.id == id }), [.running, .waiting, .takenOver, .queued].contains(r.status) {
                r.status = .stopped
                r.endedAt = Date()
                r.updatedAt = Date()
                upsert(r)
            }
            live[key] = nil
            return
        }
        // A private window's conversation is never a task (docs/design/agent-ux.md §1): no record, no pictures.
        if live[key] == nil, run.privateWindow { return }
        if live[key] == nil, let first = steps.first(where: { $0.kind == .user && !$0.midRun }) { makeRecord(run, prompt: first.text, status: .running) }
        queueSave(run)
    }

    private func queueSave(_ run: AgentRunCenter) {
        let key = ObjectIdentifier(run)
        guard live[key] != nil, !saveQueued.contains(key) else { return }
        saveQueued.insert(key)
        // Coalesced: a streaming run changes its steps many times a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak run] in
            self?.saveQueued.remove(key)
            if let run { self?.saveNow(run) }
        }
    }

    private func saveNow(_ run: AgentRunCenter) {
        guard let id = live[ObjectIdentifier(run)], var r = tasks.first(where: { $0.id == id }) else { return }
        let timeline = run.timeline
        r.updatedAt = Date()
        r.steps = run.steps.filter { $0.kind == .action }.count
        var sites: [String] = []
        for s in run.steps where s.kind == .action { if let h = timeline.host(s.id), !sites.contains(h) { sites.append(h) } }
        r.sites = sites
        if let a = run.steps.last(where: { $0.kind == .final })?.text {
            r.answer = AgentTaskRecord.answerLine(a)
            r.answerHead = AgentTaskRecord.answerHead(a)
        }
        r.entries = AgentTaskRecord.capped(Self.entries(run.steps, timeline: timeline))
        r.endedAt = run.isBusy ? nil : (r.endedAt ?? Date())
        let before = r.status
        switch run.state {
        case .running: r.status = .running
        case .waiting: r.status = .waiting
        case .done: r.status = .done
        case .stopped: r.status = .stopped
        case .failed: r.status = .failed
        case .idle: if run.queuedPrompt != nil { r.status = .queued }
        }
        if before != r.status, r.status == .done { r.unread = !AgentUI.paneShows(run) }
        upsert(r)
    }

    /// The task view's timeline from the conversation: what the pane shows, nothing more (the attached page's line
    /// stays out of the prompt; captions are AgentRedaction's).
    static func entries(_ steps: [AgentStep], timeline: AgentPaneTimeline) -> [AgentTaskRecord.Entry] {
        steps.compactMap { s -> AgentTaskRecord.Entry? in
            switch s.kind {
            case .user: return .init(kind: .prompt, text: AgentPaneItem.promptText(s.text))
            // agentrecall: the step's picture key (its id) and a history search's results.
            case .action: return .init(kind: .step, text: s.text, host: s.found == nil ? timeline.host(s.id) : nil, detail: s.detail,
                                       key: s.id.uuidString, found: s.found)
            case .say: return .init(kind: .text, text: s.text)
            case .final: return .init(kind: .answer, text: s.text)
            case .approval, .decision: return .init(kind: .approval, text: s.text, detail: s.detail)
            case .warning, .error, .info: return .init(kind: .note, text: s.text, detail: s.detail)
            case .memory: return nil
            }
        }
    }

    /// The task started last, while it has a record (the old panel and one-task checks; every live task has its own run:
    /// AgentTaskCenter.run(task:)).
    var currentID: String? { AgentTaskCenter.shared.runs.last(where: { live[ObjectIdentifier($0)] != nil }).flatMap { live[ObjectIdentifier($0)] } }
    var current: AgentTaskRecord? { currentID.flatMap { id in tasks.first { $0.id == id } } }

    private func upsert(_ r: AgentTaskRecord) {
        if let i = tasks.firstIndex(where: { $0.id == r.id }) { tasks[i] = r } else { tasks.append(r) }
        tasks = AgentTaskRecord.ordered(tasks)
        try? store.save(r)
    }

    func markSeen(_ id: String) {
        guard var r = tasks.first(where: { $0.id == id }), r.unread else { return }
        r.unread = false
        upsert(r)
    }

    func archive(_ id: String) { delete(id) }

    #if AIRC_TESTING
    /// Marketing shots: a finished task the person hasn't seen.
    func markUnreadForTesting(_ id: String) {
        guard var r = tasks.first(where: { $0.id == id }) else { return }
        r.unread = true
        upsert(r)
    }
    #endif

    /// Delete: the record goes; the current conversation's agent window closes with it.
    func delete(_ id: String) {
        if let run = AgentTaskCenter.shared.run(task: id) {
            run.newConversation()
            AgentTaskCenter.shared.forget(run)
        }
        tasks.removeAll { $0.id == id }
        store.delete(id)
        AgentTaskThumbs.shared.forget(task: id)
    }
}

extension AgentUI {
    /// A pane is open in the key window (the person sees the task end).
    static var anyPaneShows: Bool {
        guard let c = (NSApp.keyWindow?.delegate as? WindowController) ?? (NSApp.delegate as? AppDelegate)?.controller else { return false }
        return AgentPaneController.pane(of: c)?.isShown == true && NSApp.isActive
    }

    /// agentparallel: the key window's pane is open on this task (the person sees it end; else it's unread).
    static func paneShows(_ run: AgentRunCenter) -> Bool {
        guard NSApp.isActive, let c = (NSApp.keyWindow?.delegate as? WindowController) ?? (NSApp.delegate as? AppDelegate)?.controller,
              let p = AgentPaneController.pane(of: c) else { return false }
        return p.isShown && p.model.run === run
    }
}

/// `airc://agents`: every pane task and every external app's session, with search, status chips and a Space filter
/// (docs/design/agent-ux.md §7, M5). A native page in the card, like What's New.
/// asidepass: `airc://agents/<task id>` shows that task in the same tab (AgentTaskView.swift): the sidebar's task rows,
/// the Recent tasks cards and Show all open tasks here.
final class AgentTasksPage: CardDocument {
    let tabID: String
    let model: AgentTasksPageModel
    let host: AgentTasksPageView
    let task: AgentTaskViewModel

    init(tabID: String, theme: ResolvedTheme) {
        self.tabID = tabID
        model = AgentTasksPageModel(theme: theme)
        task = AgentTaskViewModel(taskID: "", theme: theme)
        task.tabID = tabID
        host = AgentTasksPageView(model: model, task: task)
    }

    var cardView: NSView { host }
    func focus() { host.window?.makeFirstResponder(host) }

    func prepare(for c: WindowController) {
        model.controller = c
        model.spaceID = c.currentSpaceID
        model.theme = c.currentPalette.resolved
        task.controller = c
        task.theme = c.currentPalette.resolved
        let id = AgentTasksURL.taskID(c.store.tab(tabID)?.url)
        if model.taskID != id { model.taskID = id }
        if let id, task.taskID != id { task.taskID = id; task.text = ""; task.attached = []; task.folded = []; task.toggled = [] }
        host.cornerRadius = c.card.cornerRadius
        host.applyTheme()
    }

    /// A task in this Space's agents tab (reused if open, else a new tab), shown. agentflow: a task of this launch whose
    /// page is a tab of this window opens there instead, with the pane on the task, so a task never has two rows.
    /// `view`: always the task view (the All tasks list opens it in that same tab; checks of the view itself).
    @discardableResult
    static func openTask(_ id: String, in c: WindowController, view: Bool = false) -> String? {
        if !view, AgentUI.usesPane, let run = AgentTaskCenter.shared.run(task: id), let tab = AgentMainView.shared.taskTab(run, in: c) {
            AgentTaskRecorder.shared.markSeen(id)
            if c.shownTabID != tab { c.show(tab) }
            AgentPaneController.show(c, task: run)
            AgentCenter.shared.onEvent?("task opens its own tab \(tab)")
            return tab
        }
        let title = AgentTaskRecorder.shared.tasks.first { $0.id == id }?.title ?? AgentTasksURL.title
        let url = AgentTasksURL.task(id)
        let tabID: String
        if let t = c.store.state.tabs.values.first(where: { $0.spaceID == c.currentSpaceID && AgentTasksURL.isPage($0.url) }) {
            tabID = t.id
            c.store.updateTab(t.id, url: url, title: title)
        } else {
            guard let t = try? c.store.openTab(url: url, inSpace: c.currentSpaceID, title: title) else { return nil }
            tabID = t.id
        }
        AgentTaskRecorder.shared.markSeen(id)
        existing(tabID).map { $0.prepare(for: c) }
        c.show(tabID)
        return tabID
    }

    /// Back to the list (Show all) in the same tab.
    static func showList(in c: WindowController) {
        guard let t = c.store.state.tabs.values.first(where: { $0.spaceID == c.currentSpaceID && AgentTasksURL.isPage($0.url) }) else { return }
        c.store.updateTab(t.id, url: AgentTasksURL.prefix, title: AgentTasksURL.title)
        existing(t.id).map { $0.prepare(for: c) }
    }

    /// The tab follows the task its view shows now (a reply to an older task starts a new one).
    static func retitle(_ task: AgentTaskViewModel, in c: WindowController) {
        guard let page = pages.values.first(where: { $0.task === task }) else { return }
        c.store.updateTab(page.tabID, url: AgentTasksURL.task(task.taskID), title: task.title)
        page.model.taskID = task.taskID
    }

    private static var pages: [String: AgentTasksPage] = [:]

    static func page(forTab tabID: String, store: SpacesStore, theme: ResolvedTheme) -> AgentTasksPage? {
        guard AgentTasksURL.isPage(store.tab(tabID)?.url) else { return nil }
        pages = pages.filter { store.tab($0.key) != nil }
        if let p = pages[tabID] { return p }
        let p = AgentTasksPage(tabID: tabID, theme: theme)
        pages[tabID] = p
        return p
    }

    static func existing(_ tabID: String?) -> AgentTasksPage? { tabID.flatMap { pages[$0] } }

    /// History ◷ and "Show all": the Space's All tasks tab (reused if open, back on its list).
    @discardableResult
    static func open(in c: WindowController) -> String? {
        let store = c.store
        let id: String
        if let t = store.state.tabs.values.first(where: { $0.spaceID == c.currentSpaceID && AgentTasksURL.isPage($0.url) }) {
            id = t.id
            if t.url != AgentTasksURL.prefix {
                store.updateTab(t.id, url: AgentTasksURL.prefix, title: AgentTasksURL.title)
                existing(t.id).map { $0.prepare(for: c) }
            }
        } else {
            guard let t = try? store.openTab(url: AgentTasksURL.prefix, inSpace: c.currentSpaceID, title: AgentTasksURL.title) else { return nil }
            id = t.id
        }
        c.show(id)
        return id
    }
}

final class AgentTasksPageModel: ObservableObject {
    @Published var theme: ResolvedTheme
    @Published var query = ""
    @Published var chip: String?
    @Published var allSpaces = false
    /// The task the tab shows (nil: the list).
    @Published var taskID: String?
    weak var controller: WindowController?
    var spaceID = ""

    init(theme: ResolvedTheme) { self.theme = theme }

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let status: String
        let chip: String
        let when: Date
        let external: Bool
        let unread: Bool
    }

    func rows(tasks: [AgentTaskRecord], sessions: [AgentTabRow]) -> [Row] {
        var out: [Row] = []
        let profileID = controller.map { $0.store.profile(ofSpace: $0.currentSpaceID).id }
        for t in tasks where (allSpaces || t.spaceID == spaceID || t.spaceID.isEmpty) && t.matches(query) {
            let sub = [t.answer, t.sites.isEmpty ? nil : t.sites.prefix(3).joined(separator: ", "), "\(t.steps) steps", t.provider]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            out.append(Row(id: t.id, title: t.title, subtitle: sub, status: t.status.label, chip: t.status.chip, when: t.updatedAt, external: false, unread: t.unread))
        }
        // Other apps' sessions (the Activity data): one row per session (agentrows: not per page). The Airc Agent's own runs
        // are their task above, whatever app runs them ("Codex (in Airc)"), so they never get a second row here.
        let others = AgentActivityModel.perSession(sessions.filter { allSpaces || $0.profileID == profileID }, excluding: AgentBridge.clientKey)
        for s in others where s.client != AgentBridge.clientName {
            let title = "\(s.client) · \(s.url?.host.map(AgentPaneTimeline.trimmed) ?? "a page")"
            guard query.isEmpty || title.localizedCaseInsensitiveContains(query) || (s.caption ?? "").localizedCaseInsensitiveContains(query) else { continue }
            let status: (String, String) = s.end == nil ? ("Running", "Running") : (s.end == .takenOver ? ("You took over", "Stopped") : (s.end == .stopped ? ("Stopped", "Stopped") : ("Done", "Done")))
            out.append(Row(id: "session-" + s.id, title: title, subtitle: s.caption ?? "", status: status.0, chip: status.1,
                           when: s.ended ?? s.lastAction ?? s.started, external: true, unread: false))
        }
        if let chip { out = out.filter { $0.chip == chip } }
        return out
    }

    func open(_ row: Row) {
        guard let c = controller else { return }
        if row.external {
            c.sidebar.agents.openWatch(String(row.id.dropFirst("session-".count)))
            return
        }
        // asidepass: the task opens in this tab, as a full task view.
        AgentTasksPage.openTask(row.id, in: c, view: true)
    }
}

final class AgentTasksPageView: NSView {
    let model: AgentTasksPageModel
    let task: AgentTaskViewModel
    private let hosting: NSHostingView<AnyView>

    init(model: AgentTasksPageModel, task: AgentTaskViewModel) {
        self.model = model
        self.task = task
        hosting = NSHostingView(rootView: AnyView(AgentTasksPageSwitch(model: model, task: task).testAnchorRoot()))
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.cornerRadius = AircMetrics.Window.cardRadius
        layer?.cornerCurve = .circular
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        setAccessibilityIdentifier("agent-tasks-page")
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { if layer?.cornerRadius != newValue { layer?.cornerRadius = newValue } }
    }

    func applyTheme() {
        let t = model.theme
        layer?.backgroundColor = t.surface.nsColor.cgColor
        layer?.borderColor = t.isDark ? NSColor.white.withAlphaComponent(0.06).cgColor : NSColor.black.withAlphaComponent(0.08).cgColor
        appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
    }
}

/// The list, or one task.
struct AgentTasksPageSwitch: View {
    @ObservedObject var model: AgentTasksPageModel
    @ObservedObject var task: AgentTaskViewModel

    var body: some View {
        if model.taskID != nil {
            AgentTaskViewRoot(model: task).environment(\.aircTheme, model.theme).id(task.taskID)
        } else {
            AgentTasksPageRoot(model: model)
        }
    }
}

struct AgentTasksPageRoot: View {
    @ObservedObject var model: AgentTasksPageModel
    @ObservedObject private var recorder = AgentTaskRecorder.shared
    @State private var sessions: [AgentTabRow] = AgentActivity.shared.model.rows

    var body: some View {
        AgentTasksPageContent(model: model, recorder: recorder, sessions: sessions).environment(\.aircTheme, model.theme)
            .onReceive(NotificationCenter.default.publisher(for: AgentActivity.changed)) { _ in sessions = AgentActivity.shared.model.rows }
    }
}

private struct AgentTasksPageContent: View {
    @ObservedObject var model: AgentTasksPageModel
    @ObservedObject var recorder: AgentTaskRecorder
    let sessions: [AgentTabRow]
    @Environment(\.aircTheme) private var theme

    var body: some View {
        let rows = model.rows(tasks: recorder.tasks, sessions: sessions)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Agent tasks").aircFont(AircFont.title2).foregroundStyle(theme.surfaceText.color)
                HStack(spacing: 8) {
                    TextField("Search tasks", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 260).testAnchor("agenttasks.search")
                    ForEach(["Running", "Waiting", "Done", "Stopped"], id: \.self) { c in
                        Button(c) { model.chip = model.chip == c ? nil : c }
                            .buttonStyle(.airc(model.chip == c ? .primary : .secondary, size: .small))
                            .testAnchor("agenttasks.chip.\(c)")
                    }
                    Spacer()
                    Picker("", selection: $model.allSpaces) {
                        Text("This Space").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().testAnchor("agenttasks.spaces")
                }
                if rows.isEmpty {
                    Text(model.query.isEmpty && model.chip == nil ? "No agent tasks yet. Ask Airc to do something with ⌥⌘A." : "No tasks match.")
                        .aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color).padding(.top, 20)
                        .testAnchor("agenttasks.empty")
                }
                VStack(spacing: 0) {
                    ForEach(rows) { r in row(r); Divider().opacity(0.4) }
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme.surface.color)
        .testAnchor("agenttasks")
    }

    private func row(_ r: AgentTasksPageModel.Row) -> some View {
        HStack(spacing: 10) {
            Group {
                if r.chip == "Running" { AgentTaskSpinner(size: 11) }
                else if r.chip == "Waiting" { Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(.orange) }
                else { Circle().fill(r.unread ? theme.accent.color : Color.clear).frame(width: 7, height: 7) }
            }
            .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).aircFont(AircFont.body).fontWeight(.medium).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                if !r.subtitle.isEmpty {
                    Text(r.subtitle).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(r.status).aircFont(AircFont.caption).foregroundStyle(r.chip == "Waiting" ? .orange : theme.surfaceTextSecondary.color)
            Text(r.when, style: .relative).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).frame(width: 90, alignment: .trailing)
            if !r.external {
                Menu {
                    Button("Archive") { AgentTaskRecorder.shared.archive(r.id) }
                    Button("Delete…", role: .destructive) { confirmDelete(r) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .testAnchor("agenttasks.menu")
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { model.open(r) }
        .testAnchor("agenttasks.row")
        .testAnchor("agenttasks.row.\(r.id)")
    }

    private func confirmDelete(_ r: AgentTasksPageModel.Row) {
        let a = NSAlert()
        a.messageText = "Delete “\(r.title)”?"
        a.informativeText = "The task leaves your history. Pages it left open close."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        AgentTaskRecorder.shared.delete(r.id)
    }
}

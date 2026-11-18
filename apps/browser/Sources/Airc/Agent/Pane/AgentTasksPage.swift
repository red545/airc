// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import Combine
import SwiftUI

/// Keeps a task record (AircKit's AgentTaskRecord, `<data folder>/Agent/Tasks/<id>.json`) for each pane conversation:
/// title, state, provider, steps, sites and the answer's first line. Never page text, typed values, keys or pictures.
final class AgentTaskRecorder: ObservableObject {
    static let shared = AgentTaskRecorder()

    let store = AgentTaskStore(folder: AppPaths.dataDirectory.appendingPathComponent("Agent/Tasks", isDirectory: true))
    @Published private(set) var tasks: [AgentTaskRecord] = []
    /// The conversation the pane shows now.
    private(set) var currentID: String?
    private var space: (id: String, profile: String)?
    private var subs: [AnyCancellable] = []
    private var saveQueued = false

    private init() {
        tasks = AgentTaskRecord.ordered(store.all())
        let run = AgentRunCenter.shared
        subs.append(run.$steps.sink { [weak self] s in DispatchQueue.main.async { self?.stepsChanged(s) } })
        subs.append(run.$state.sink { [weak self] _ in DispatchQueue.main.async { self?.queueSave() } })
        subs.append(run.$approval.sink { [weak self] _ in DispatchQueue.main.async { self?.queueSave() } })
    }

    /// The pane starts a task in this Space.
    func willAsk(spaceID: String, profileID: String) { space = (spaceID, profileID) }

    private func stepsChanged(_ steps: [AgentStep]) {
        if steps.isEmpty { currentID = nil; return }
        if currentID == nil, let first = steps.first(where: { $0.kind == .user }) {
            let v = AgentModelSettings.shared.values
            let provider = v.backend.cli?.name ?? v.provider.name + " API key"
            let r = AgentTaskRecord(title: AgentTaskTitle.make(first.text), spaceID: space?.id ?? "", profileID: space?.profile ?? AgentRunCenter.shared.profileID ?? "",
                                    provider: provider)
            currentID = r.id
            upsert(r)
        }
        queueSave()
    }

    private func queueSave() {
        guard currentID != nil, !saveQueued else { return }
        saveQueued = true
        // Coalesced: a streaming run changes its steps many times a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveQueued = false
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard let id = currentID, var r = tasks.first(where: { $0.id == id }) else { return }
        let run = AgentRunCenter.shared
        let timeline = AgentPaneTimeline.shared
        r.updatedAt = Date()
        r.steps = run.steps.filter { $0.kind == .action }.count
        var sites: [String] = []
        for s in run.steps where s.kind == .action { if let h = timeline.host(s.id), !sites.contains(h) { sites.append(h) } }
        r.sites = sites
        if let a = run.steps.last(where: { $0.kind == .final })?.text { r.answer = AgentTaskRecord.answerLine(a) }
        let before = r.status
        switch run.state {
        case .running: r.status = .running
        case .waiting: r.status = .waiting
        case .done: r.status = .done
        case .stopped: r.status = .stopped
        case .failed: r.status = .failed
        case .idle: break
        }
        if before != r.status, r.status == .done { r.unread = !AgentUI.anyPaneShows }
        upsert(r)
    }

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

    /// Delete: the record goes; the current conversation's agent window closes with it.
    func delete(_ id: String) {
        if id == currentID { AgentRunCenter.shared.newConversation() }
        tasks.removeAll { $0.id == id }
        store.delete(id)
    }
}

extension AgentUI {
    /// A pane is open in the key window (the person sees the task end).
    static var anyPaneShows: Bool {
        guard let c = (NSApp.keyWindow?.delegate as? WindowController) ?? (NSApp.delegate as? AppDelegate)?.controller else { return false }
        return AgentPaneController.pane(of: c)?.isShown == true && NSApp.isActive
    }
}

/// `airc://agents`: every pane task and every external app's session, with search, status chips and a Space filter
/// (docs/design/agent-ux.md §7, M5). A native page in the card, like What's New.
final class AgentTasksPage: CardDocument {
    let tabID: String
    let model: AgentTasksPageModel
    let host: AgentTasksPageView

    init(tabID: String, theme: ResolvedTheme) {
        self.tabID = tabID
        model = AgentTasksPageModel(theme: theme)
        host = AgentTasksPageView(model: model)
    }

    var cardView: NSView { host }
    func focus() { host.window?.makeFirstResponder(host) }

    func prepare(for c: WindowController) {
        model.controller = c
        model.spaceID = c.currentSpaceID
        model.theme = c.currentPalette.resolved
        host.cornerRadius = c.card.cornerRadius
        host.applyTheme()
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

    /// History ◷ and "Show all": the Space's All tasks tab (reused if open).
    @discardableResult
    static func open(in c: WindowController) -> String? {
        let store = c.store
        let id: String
        if let t = store.state.tabs.values.first(where: { $0.spaceID == c.currentSpaceID && AgentTasksURL.isPage($0.url) }) {
            id = t.id
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
        // External apps' sessions (the Activity data): one row per agent page.
        for s in sessions where (allSpaces || s.profileID == profileID) && s.client != AgentBridge.clientName {
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
        AgentTaskRecorder.shared.markSeen(row.id)
        // The pane shows the conversation it has (one at a time in phase 1).
        AgentPaneController.show(c)
    }
}

final class AgentTasksPageView: NSView {
    let model: AgentTasksPageModel
    private let hosting: NSHostingView<AnyView>

    init(model: AgentTasksPageModel) {
        self.model = model
        hosting = NSHostingView(rootView: AnyView(AgentTasksPageRoot(model: model).testAnchorRoot()))
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
            Circle().fill(r.unread ? theme.accent.color : Color.clear).frame(width: 7, height: 7)
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

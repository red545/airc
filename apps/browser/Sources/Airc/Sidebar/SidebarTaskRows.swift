// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// asidepass: the Agents folder as a task list (docs/design/agent-ux.md §7; docs/user/agents.md, "Your tasks in the
/// sidebar"). "New Task" first, then this Space's Airc Agent tasks, one line each, with their state at the end: a
/// spinner while it works, an amber hand while it waits for you, a blue dot when it finished and you haven't looked;
/// then other apps' agents (one row per session) and "Show all". A task row opens the task view.
/// agentrows (2026-11-23): one row per task. The run's own page is not a second row any more (it was "Compare the Pour
/// a… · Codex (in Airc) · Waiting" under the task): the task row takes its icon, its Needs you, and its Watch.
enum SidebarTaskList {
    static let rowHeight: CGFloat = 28
    static let rowPitch: CGFloat = 30
    /// A row with a line under it ("Waiting for your OK", "Sign in to Gmail").
    static let tallRowHeight: CGFloat = 32
    static let tallRowPitch: CGFloat = 34
    /// Rows the folder lists: everything waiting, running or unread, then the newest others up to `recent`.
    static let recent = 3
    static let cap = 6

    static func tasks(spaceID: String, profileID: String? = nil) -> [AgentTaskRecord] {
        let mine = AgentTaskRecorder.shared.tasks.filter { $0.spaceID == spaceID || $0.spaceID.isEmpty }
        let hot = mine.filter { $0.status == .running || $0.status == .waiting || $0.status == .takenOver || $0.unread }
        let rest = mine.filter { !hot.contains($0) }
        var out = Array((hot + rest.prefix(max(0, recent - hot.count))).prefix(cap))
        // The running task always has its row (its page has no other one), also in the profile's other Spaces while it
        // works or waits: its page's row used to show there, and with it the folder and its Needs you badge.
        if let id = AgentTaskRecorder.shared.currentID, !out.contains(where: { $0.id == id }),
           let t = AgentTaskRecorder.shared.tasks.first(where: { $0.id == id }),
           mine.contains(where: { $0.id == id }) || (t.profileID == profileID && [.running, .waiting, .takenOver].contains(t.status)) {
            out.insert(t, at: 0)
        }
        return out
    }

    /// The folder's lines for `tasks`: the running one with its live page (icon, Needs you, Watch).
    static func lines(_ tasks: [AgentTaskRecord]) -> [SidebarTaskLine] {
        let current = AgentTaskRecorder.shared.currentID
        let pageRow = AgentAttention.paneRowID
        let waits = AgentAttention.items()
        return tasks.map { t in
            let live = t.id == current ? pageRow : nil
            let row = live.flatMap { AgentActivity.shared.model.row($0) }
            let need = live.flatMap { id in waits.first { $0.rowID == id && $0.kind != .approval } }
            let icon = row.flatMap { AgentCenter.shared.windows[$0.window]?.tab($0.tab)?.favicon }
            return SidebarTaskLine(task: t, liveRowID: live, need: need?.title, pageURL: row?.url?.absoluteString, pageIcon: icon.map { ObjectIdentifier($0) })
        }
    }

    static func pitch(_ l: SidebarTaskLine) -> CGFloat { l.subtitle == nil ? rowPitch : tallRowPitch }
}

/// One task row's state, as the folder shows it.
struct SidebarTaskLine: Equatable, Identifiable {
    enum Status: Equatable { case spinner, needsYou, unread, failed, none }

    let task: AgentTaskRecord
    /// The running task's live page (its Agents row in the activity model): Watch, Take over, Needs you.
    let liveRowID: String?
    /// What its page waits for ("Sign in to Gmail"), from AgentAttention.
    let need: String?
    let pageURL: String?
    let pageIcon: ObjectIdentifier?
    var id: String { task.id }

    var status: Status {
        if task.status == .waiting || need != nil { return .needsYou }
        switch task.status {
        case .running, .takenOver: return .spinner
        case .failed: return .failed
        default: return task.unread ? .unread : .none
        }
    }

    /// A line under the title only when it says something the icon doesn't.
    var subtitle: String? {
        if task.status == .waiting { return "Waiting for your OK" }
        return need
    }
}

struct SidebarNewTaskRow: View {
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil").font(.system(size: 12, weight: .medium)).frame(width: 16)
            Text("New Task").aircFont(AircFont.body).lineLimit(1)
            Spacer(minLength: 4)
            if hovered { Text("⇧⌥⌘A").aircFont(AircFont.caption).foregroundStyle(theme.textTertiary.color) }
        }
        .foregroundStyle(theme.textSecondary.color)
        .padding(.leading, AircMetrics.Row.folderIndent).padding(.trailing, 8)
        .frame(height: SidebarTaskList.rowHeight)
        .background(RoundedRectangle(cornerRadius: AircMetrics.Row.plateRadius, style: .continuous).fill(hovered ? theme.hoverFill.color : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New agent task")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .testAnchor("agents-newtask")
    }
}

struct SidebarTaskRow: View {
    let line: SidebarTaskLine
    let selected: Bool
    let open: () -> Void
    let stop: (() -> Void)?
    /// The live page's Watch (the running task only).
    var watch: (() -> Void)? = nil
    var takeOver: (() -> Void)? = nil
    /// The page's favicon (the running task's page, else its first site's cached icon).
    var icon: NSImage? = nil
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme
    private var task: AgentTaskRecord { line.task }

    var body: some View {
        styled
            .contextMenu {
                Button("Open") { open() }
                if let watch { Button("Watch the Page") { watch() } }
                if let takeOver { Button("Take Over the Page") { takeOver() } }
                if let stop { Button("Stop") { stop() } }
                Divider()
                Button("Archive") { AgentTaskRecorder.shared.archive(task.id) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(task.title)
            .accessibilityValue(stateWords + (task.unread ? ", unread" : ""))
            .accessibilityHint("Open the task")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .accessibilityAction(named: "Watch the page") { watch?() }
            .testAnchor("agents-task")
            .testAnchor("agents-task-\(task.id)")
            // The page's row id too: what used to be its own row (AgentAttention, Watch and the checks address it so).
            .testAnchor(line.liveRowID.map { "agents-row-\($0)" } ?? "agents-task-nopage")
    }

    private var plate: Color { (selected ? theme.selectedFill : hovered ? theme.hoverFill : AircColor.clear).color }
    private var edge: Color { selected ? theme.text.color.opacity(0.06) : Color.clear }

    private var styled: some View {
        content
            .padding(.leading, AircMetrics.Row.folderIndent).padding(.trailing, 8)
            .frame(height: line.subtitle == nil ? SidebarTaskList.rowHeight : SidebarTaskList.tallRowHeight)
            .background(RoundedRectangle(cornerRadius: AircMetrics.Row.plateRadius, style: .continuous).fill(plate))
            .overlay(RoundedRectangle(cornerRadius: AircMetrics.Row.plateRadius, style: .continuous).strokeBorder(edge))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: open)
            .help(tooltip)
    }

    private var content: some View {
        HStack(spacing: 8) {
            SidebarTaskIcon(image: icon, host: task.sites.first)
            VStack(alignment: .leading, spacing: 0) {
                Text(task.title)
                    .aircFont(AircFont.body)
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1).truncationMode(.tail)
                    .testAnchor("agents-task-title")
                if let sub = line.subtitle {
                    Text(sub)
                        .aircFont(AircFont.caption)
                        .foregroundStyle(theme.textTertiary.color)
                        .lineLimit(1).truncationMode(.tail)
                        .testAnchor("agents-task-subtitle")
                }
            }
            Spacer(minLength: 4)
            if hovered, let watch {
                TrayButton(symbol: "eye", help: "Watch the agent's page", action: watch)
                    .accessibilityLabel("Watch the page")
                    .testAnchor(line.liveRowID.map { "agents-watch-\($0)" } ?? "agents-task-watch")
            }
            trailing.frame(width: 16, height: 16)
        }
    }

    @ViewBuilder private var trailing: some View {
        if hovered, let stop {
            Button(action: stop) { Image(systemName: "stop.fill").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(theme.textTertiary.color).help("Stop").accessibilityLabel("Stop \(task.title)")
                .testAnchor("agents-task-stop")
        } else {
            switch line.status {
            case .spinner:
                AgentTaskSpinner(size: 12, color: theme.textTertiary.nsColor).frame(width: 12, height: 12).testAnchor("agents-task-spinner")
            case .needsYou:
                Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    .testAnchor("agents-task-waiting")
                    .testAnchor(line.liveRowID.map { "agents-waiting-\($0)" } ?? "agents-task-waiting-nopage")
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red.opacity(0.8))
            case .unread:
                Circle().fill(theme.accent.color).frame(width: 7, height: 7).testAnchor("agents-task-unread")
            case .none:
                EmptyView()
            }
        }
    }

    private var stateWords: String {
        if let need = line.need { return "Needs you: " + need }
        switch task.status {
        case .running, .takenOver: return "Working"
        case .waiting: return "Waiting for your OK"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .done: return "Done"
        }
    }

    private var tooltip: String {
        if let s = task.lastSteps(1).first, task.status == .running { return task.title + "\n" + s.text }
        if let a = task.answer, task.status == .done { return task.title + "\n" + a }
        return task.title
    }
}

/// A task row's icon: its page's favicon (live, or its first site's from the favicon cache), else ✦.
struct SidebarTaskIcon: View {
    let image: NSImage?
    let host: String?
    @State private var cached: NSImage?
    @Environment(\.aircTheme) private var theme

    var body: some View {
        Group {
            if let img = image ?? cached {
                Image(nsImage: img).resizable().interpolation(.high).frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .testAnchor("agents-task-favicon")
            } else {
                Image(systemName: "sparkle").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary.color)
                    .testAnchor("agents-task-sparkle")
            }
        }
        .frame(width: 16, height: 16)
        .onAppear(perform: load)
        .onChange(of: host) { _, _ in load() }
    }

    private func load() {
        guard image == nil, let host, let key = FaviconCache.guess(for: "https://\(host)/") else { return }
        if let img = FaviconCache.shared.cached(key) { cached = img; return }
        FaviconCache.shared.stored(key) { img in DispatchQueue.main.async { if let img { cached = img } } }
    }
}

struct SidebarShowAllRow: View {
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack {
            Text("Show all").aircFont(AircFont.body).foregroundStyle(theme.textTertiary.color)
            Spacer()
        }
        .padding(.leading, AircMetrics.Row.folderIndent).padding(.trailing, 8)
        .frame(height: SidebarTaskList.rowHeight)
        .background(RoundedRectangle(cornerRadius: AircMetrics.Row.plateRadius, style: .continuous).fill(hovered ? theme.hoverFill.color : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Show all agent tasks")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .testAnchor("agents-showall")
    }
}

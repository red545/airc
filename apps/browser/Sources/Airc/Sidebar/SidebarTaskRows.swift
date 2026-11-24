// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// asidepass: the Agents folder as a task list (docs/design/agent-ux.md §7; docs/user/agents.md, "Your tasks in the
/// sidebar"). "New Task" first, then this Space's Airc Agent tasks, one line each, with their state at the end: a
/// spinner while it works, an amber hand while it waits for your OK, a blue dot when it finished and you haven't looked;
/// then other apps' agent tabs (as before) and "Show all". A task row opens the task view.
enum SidebarTaskList {
    static let rowHeight: CGFloat = 28
    static let rowPitch: CGFloat = 30
    /// Rows the folder lists: everything waiting, running or unread, then the newest others up to `recent`.
    static let recent = 3
    static let cap = 6

    static func tasks(spaceID: String) -> [AgentTaskRecord] {
        let mine = AgentTaskRecorder.shared.tasks.filter { $0.spaceID == spaceID || $0.spaceID.isEmpty }
        let hot = mine.filter { $0.status == .running || $0.status == .waiting || $0.status == .takenOver || $0.unread }
        let rest = mine.filter { !hot.contains($0) }
        return Array((hot + rest.prefix(max(0, recent - hot.count))).prefix(cap))
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
    let task: AgentTaskRecord
    let selected: Bool
    let open: () -> Void
    let stop: (() -> Void)?
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme

    var body: some View {
        styled
            .contextMenu {
                Button("Open") { open() }
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
            .testAnchor("agents-task")
            .testAnchor("agents-task-\(task.id)")
    }

    private var plate: Color { (selected ? theme.selectedFill : hovered ? theme.hoverFill : AircColor.clear).color }
    private var edge: Color { selected ? theme.text.color.opacity(0.06) : Color.clear }

    private var styled: some View {
        content
            .padding(.leading, AircMetrics.Row.folderIndent).padding(.trailing, 8)
            .frame(height: SidebarTaskList.rowHeight)
            .background(RoundedRectangle(cornerRadius: AircMetrics.Row.plateRadius, style: .continuous).fill(plate))
            .overlay(RoundedRectangle(cornerRadius: AircMetrics.Row.plateRadius, style: .continuous).strokeBorder(edge))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: open)
            .help(tooltip)
    }

    private var content: some View {
        HStack(spacing: 8) {
            Text(task.title)
                .aircFont(AircFont.body)
                .foregroundStyle(theme.text.color)
                .lineLimit(1).truncationMode(.tail)
                .testAnchor("agents-task-title")
            Spacer(minLength: 4)
            trailing.frame(width: 16, height: 16)
        }
    }

    @ViewBuilder private var trailing: some View {
        if hovered, let stop {
            Button(action: stop) { Image(systemName: "stop.fill").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(theme.textTertiary.color).help("Stop").accessibilityLabel("Stop \(task.title)")
                .testAnchor("agents-task-stop")
        } else {
            switch task.status {
            case .running, .takenOver:
                AgentTaskSpinner(size: 12, color: theme.textTertiary.nsColor).frame(width: 12, height: 12).testAnchor("agents-task-spinner")
            case .waiting:
                Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(.orange).testAnchor("agents-task-waiting")
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red.opacity(0.8))
            default:
                if task.unread { Circle().fill(theme.accent.color).frame(width: 7, height: 7).testAnchor("agents-task-unread") }
            }
        }
    }

    private var stateWords: String {
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

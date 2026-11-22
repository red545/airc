// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import Combine
import SwiftUI

/// One line of a task's timeline, from the live conversation (AgentRunCenter) or a finished task's record.
struct AgentTaskLine: Identifiable, Equatable {
    enum Kind: Equatable { case prompt, steps, text, answer, note, approval }
    struct Step: Identifiable, Equatable {
        let id: String
        /// The live step's id (its picture, its page); nil for a record's line.
        let stepID: UUID?
        var caption: String
        var host: String?
        var detail: String?
        var count = 1
        /// agentrecall: the step's picture key (the live step's id, a record line's `key`), and what a history search
        /// found.
        var key: String?
        var found: [AgentTaskRecord.Entry.Found]?
    }
    let id: String
    let kind: Kind
    var text = ""
    var detail: String?
    var steps: [Step] = []
    /// A run's header over its steps: "Worked for 2m 14s · 18 steps" (nil while it runs).
    var summary: String?
    var running = false

    /// Groups consecutive steps; reads in a row become "Read 3 pages".
    typealias Raw = (id: String, stepID: UUID?, kind: AgentTaskRecord.Entry.Kind, text: String, host: String?, detail: String?,
                     key: String?, found: [AgentTaskRecord.Entry.Found]?)

    static func make(_ raw: [Raw], live: Bool, summaries: [String: String]) -> [AgentTaskLine] {
        var out: [AgentTaskLine] = []
        var lastPrompt: String?
        for r in raw {
            switch r.kind {
            case .step:
                let step = Step(id: r.id, stepID: r.stepID, caption: r.text, host: r.host, detail: r.detail, key: r.key, found: r.found)
                if var last = out.last, last.kind == .steps {
                    if step.caption.hasPrefix("Reading"), let prev = last.steps.last, prev.caption.hasPrefix("Read"), prev.detail == nil, prev.host == step.host {
                        var merged = prev
                        merged.count += 1
                        merged.caption = "Read \(merged.count) pages"
                        last.steps[last.steps.count - 1] = merged
                    } else {
                        last.steps.append(step)
                    }
                    out[out.count - 1] = last
                } else {
                    out.append(AgentTaskLine(id: "steps-" + r.id, kind: .steps, steps: [step], summary: lastPrompt.flatMap { summaries[$0] }))
                }
            case .prompt:
                lastPrompt = r.id
                out.append(AgentTaskLine(id: r.id, kind: .prompt, text: r.text))
            case .text: out.append(AgentTaskLine(id: r.id, kind: .text, text: r.text))
            case .answer: out.append(AgentTaskLine(id: r.id, kind: .answer, text: r.text))
            case .note: out.append(AgentTaskLine(id: r.id, kind: .note, text: r.text, detail: r.detail))
            case .approval: out.append(AgentTaskLine(id: r.id, kind: .approval, text: r.text, detail: r.detail))
            }
        }
        // The last step group of a live run is the running one; it has no summary yet.
        if live, let i = out.lastIndex(where: { $0.kind == .steps }), !out[i...].contains(where: { $0.kind == .answer }) {
            out[i].running = true
            out[i].summary = nil
        }
        return out
    }
}

/// The task view's state for one tab: which task, the reply field, attached tabs, folded runs and steps.
final class AgentTaskViewModel: ObservableObject {
    @Published var taskID: String
    @Published var text = ""
    @Published var attached: [AgentAskContext] = []
    /// Step groups the person folded, and steps the person opened or closed (their inline result).
    @Published var folded: Set<String> = []
    @Published var toggled: Set<String> = []
    @Published var theme: ResolvedTheme
    weak var controller: WindowController?
    let recorder = AgentTaskRecorder.shared
    let run = AgentRunCenter.shared

    init(taskID: String, theme: ResolvedTheme) {
        self.taskID = taskID
        self.theme = theme
    }

    var record: AgentTaskRecord? { recorder.tasks.first { $0.id == taskID } }
    /// This is the conversation the agent has now (one at a time): it streams here and the composer replies to it.
    var isCurrent: Bool { recorder.currentID == taskID }
    var live: Bool { isCurrent && run.state.isActive }

    var title: String { record?.title ?? "Task" }

    var lines: [AgentTaskLine] {
        if isCurrent {
            let timeline = AgentPaneTimeline.shared
            var summaries: [String: String] = [:]
            var raw: [AgentTaskLine.Raw] = []
            var runs: [[AgentStep]] = []
            for s in run.steps {
                if s.kind == .user || runs.isEmpty { runs.append([s]) } else { runs[runs.count - 1].append(s) }
            }
            for r in runs {
                if let p = r.first(where: { $0.kind == .user }) {
                    let actions = r.filter { $0.kind == .action }
                    summaries[p.id.uuidString] = AgentPaneItem.summaryLine(r, prompt: p, actions: actions, timeline: timeline)
                        .replacingOccurrences(of: "Done in ", with: "Worked for ")
                }
            }
            for s in run.steps {
                let e: AgentTaskRecord.Entry.Kind
                switch s.kind {
                case .user: e = .prompt
                case .action: e = .step
                case .say: e = .text
                case .final: e = .answer
                case .approval, .decision: e = .approval
                case .warning, .error, .info: e = .note
                case .memory: continue
                }
                let action = s.kind == .action
                raw.append((s.id.uuidString, action ? s.id : nil, e, e == .prompt ? AgentPaneItem.promptText(s.text) : s.text,
                            action && s.found == nil ? timeline.host(s.id) : nil, s.detail, action ? s.id.uuidString : nil, s.found))
            }
            return AgentTaskLine.make(raw, live: run.state.isActive, summaries: summaries)
        }
        guard let r = record, let entries = r.entries else { return [] }
        var summaries: [String: String] = [:]
        let firstPrompt = entries.indices.first { entries[$0].kind == .prompt }
        if let i = firstPrompt, let end = r.endedAt {
            let n = entries.filter { $0.kind == .step }.count
            summaries["e\(i)"] = "Worked for " + AgentPaneItem.duration(end.timeIntervalSince(r.createdAt)) + " · \(n) step\(n == 1 ? "" : "s")"
        }
        let raw: [AgentTaskLine.Raw] = entries.enumerated().map {
            (id: "e\($0.offset)", stepID: UUID?.none, kind: $0.element.kind, text: $0.element.text, host: $0.element.host,
             detail: $0.element.detail, key: $0.element.key, found: $0.element.found)
        }
        return AgentTaskLine.make(raw, live: false, summaries: summaries)
    }

    var placeholder: String {
        if isCurrent, run.approval != nil { return "Or tell it what to change…" }
        if live { return "Tell it something while it works…" }
        return "Reply, @ for context"
    }

    var canReply: Bool { !live || run.approval != nil }

    func send() {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, let c = controller else { return }
        // Not connected, or another task is the agent's now: the pane takes it (its Connect card, or the field).
        guard AgentRunCenter.shared.hasKey, isCurrent || !run.state.isActive else {
            text = ""
            return AgentUI.ask(c, typed)
        }
        if isCurrent, run.approval != nil {
            run.answerApproval(allow: false)
            text = ""
            return after { self.ask(c, "Not like that: " + typed) }
        }
        guard run.canSend else { return }
        text = ""
        ask(c, typed)
    }

    /// A reply to this task: the same conversation if it's the agent's now; a finished older task can't be resumed
    /// (one conversation at a time), so the reply starts a new task that names it.
    private func ask(_ c: WindowController, _ typed: String) {
        let p = c.store.profile(ofSpace: c.currentSpaceID)
        var prompt = typed + AgentAskContext.promptLine(attached)
        attached = []
        if !isCurrent {
            if let r = record {
                let before = [r.title, r.answerHead].compactMap { $0 }.joined(separator: " — ")
                prompt += "\n\nEarlier task: " + before
            }
            run.newConversation()
        }
        AgentTaskRecorder.shared.willAsk(spaceID: c.currentSpaceID, profileID: p.id)
        run.ask(prompt, profileID: p.id, profileName: p.name)
        if !isCurrent {
            // The new conversation's record appears with its first step; follow it in this tab.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let id = AgentTaskRecorder.shared.currentID else { return }
                self.taskID = id
                AgentTasksPage.retitle(self, in: c)
            }
        }
    }

    private func after(_ then: @escaping () -> Void) {
        var tries = 0
        func check() {
            if run.canSend { return then() }
            tries += 1
            if tries < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check) }
        }
        check()
    }

    func stop() { if isCurrent { run.stop() } }

    func takeOver() {
        guard let c = controller else { return }
        AgentPaneController.show(c).model.takeOver()
    }

    func openWatch() {
        guard let c = controller, let w = run.runWindowID else { return }
        let rows = AgentActivity.shared.model.rows.filter { $0.window == w && $0.isLive }
        let active = AgentCenter.shared.windows[w]?.activeTabID
        if let id = (rows.first { $0.tab == active } ?? rows.last)?.id { c.sidebar.agents.openWatch(id) }
    }

    func openSite(_ host: String) {
        guard let c = controller, let url = URL(string: "https://\(host)") else { return }
        c.navigate(to: url, newTab: true)
    }

    /// agentrecall: a history search's result row: the page in a new tab of this Space (http(s) only).
    func openPage(_ address: String) {
        guard let c = controller, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        c.navigate(to: url, newTab: true)
    }

    func copyAnswer() {
        let t = isCurrent ? run.steps.last(where: { $0.kind == .final })?.text : record?.entries?.last(where: { $0.kind == .answer })?.text
        guard let t else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    func openInPane() {
        guard let c = controller else { return }
        AgentPaneController.show(c)
    }

    /// The tab this view is in: a task counts as seen only while that tab is the window's shown one.
    var tabID = ""

    func seen() {
        guard let c = controller, c.shownTabID == tabID, c.window.isVisible else { return }
        recorder.markSeen(taskID)
    }
}

/// The task view (asidepass; docs/design/agent-ux.md §3 "Expand"): the task in the content area at reading width, its
/// steps as a timeline with what each one found, the answer as it streams, the agent's page as a floating live card at
/// the side, and a composer with the Ask chips at the bottom. The pane stays the compact form of the same task.
struct AgentTaskViewRoot: View {
    @ObservedObject var model: AgentTaskViewModel
    @ObservedObject private var recorder = AgentTaskRecorder.shared
    @ObservedObject private var run = AgentRunCenter.shared
    @ObservedObject private var timeline = AgentPaneTimeline.shared
    @ObservedObject private var thumbs = AgentTaskThumbs.shared
    @Environment(\.aircTheme) private var theme

    static let column: CGFloat = 680
    static let cardWidth: CGFloat = 300

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width >= Self.column + Self.cardWidth + 96
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    transcript(wide: wide)
                    composer.frame(maxWidth: Self.column).padding(.horizontal, 24).padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity)
                // The floating card takes the right side of a wide window; the column centres in what's left.
                .padding(.trailing, wide && model.live && run.runWindowID != nil ? Self.cardWidth + 30 : 0)
                if wide, model.live, run.runWindowID != nil {
                    AgentTaskLiveCard(model: model).frame(width: Self.cardWidth).padding(.top, 64).padding(.trailing, 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.live)
        }
        .background(theme.surface.color)
        .onAppear { model.seen() }
        .onChange(of: recorder.tasks.first(where: { $0.id == model.taskID })?.unread) { _, u in if u == true { model.seen() } }
        .testAnchor("agenttask")
    }

    private func transcript(wide: Bool) -> some View {
        // Made once per update (a streaming answer updates the view every 50 ms).
        let lines = model.lines
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !wide, model.live, run.runWindowID != nil { AgentTaskLiveCard(model: model) }
                    if lines.isEmpty, !model.isCurrent {
                        Text("This task was kept before Airc saved its steps: only its result is left.")
                            .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                        if let a = model.record?.answer { AgentPaneMarkdown(text: a) }
                    }
                    ForEach(lines) { line in AgentTaskLineView(line: line, model: model).id(line.id) }
                    if model.isCurrent {
                        if !run.partial.isEmpty {
                            Text(run.partial).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                                .fixedSize(horizontal: false, vertical: true).id("partial")
                                .overlay(alignment: .bottomTrailing) { AgentTaskCaret().offset(x: 6) }
                                .testAnchor("agenttask.partial")
                        } else if run.state == .running, lines.last?.kind != .steps {
                            AgentPaneThinking().padding(.leading, 26).id("thinking")
                        }
                    }
                    if !model.live, lines.contains(where: { $0.kind == .answer }) { footer }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: Self.column, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
            // The task reads from the top (its title, then its steps); new steps scroll into view once it's longer.
            .onChange(of: run.steps.count) { _, _ in if model.isCurrent { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } } }
            .onChange(of: run.partial.count / 80) { _, _ in if model.isCurrent { proxy.scrollTo("bottom") } }
        }
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.surfaceTextTertiary.color)
            Text(model.title).aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color).lineLimit(1).truncationMode(.tail)
                .textSelection(.enabled).testAnchor("agenttask.title")
            Menu {
                Button("Open in the Agent Pane") { model.openInPane() }
                Button("Copy Answer") { model.copyAnswer() }
                Divider()
                Button("Archive") { AgentTaskRecorder.shared.archive(model.taskID); model.controller.map { AgentTasksPage.showList(in: $0) } }
            } label: { Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 22) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(theme.surfaceTextTertiary.color)
            .testAnchor("agenttask.menu")
            Spacer(minLength: 0)
            statusPill
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private var statusPill: some View {
        if model.live {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 5) {
                    AgentTaskSpinner(size: 10).frame(width: 10, height: 10)
                    Text("Working for " + AgentPaneItem.duration(ctx.date.timeIntervalSince(run.startedAt ?? ctx.date))).monospacedDigit()
                }
            }
            .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color)
            .testAnchor("agenttask.working")
        } else if let r = model.record {
            Text(r.status == .done ? "Done · " + AgentTaskCard.ago(r.endedAt ?? r.updatedAt) : r.status.label)
                .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button("Copy") { model.copyAnswer() }.buttonStyle(.airc(.secondary, size: .small)).testAnchor("agenttask.copy")
            if let sites = model.record?.sites, !sites.isEmpty {
                ForEach(sites.prefix(4), id: \.self) { s in
                    Button { model.openSite(s) } label: {
                        HStack(spacing: 4) { AgentPaneSiteIcon(host: s, size: 12); Text(s).aircFont(AircFont.caption).lineLimit(1) }
                            .foregroundStyle(theme.surfaceTextSecondary.color)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(theme.tileFill.color))
                    }
                    .buttonStyle(.plain).help("Open \(s) in a new tab")
                }
            }
            Spacer()
            if model.isCurrent { Text(run.usageLine).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(1) }
        }
        .padding(.top, 2)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if model.isCurrent, let a = run.approval { AgentTaskApproval(request: a).transition(.move(edge: .bottom).combined(with: .opacity)) }
            AgentTaskComposer(model: model)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: run.approval)
    }
}

/// One timeline line.
struct AgentTaskLineView: View {
    let line: AgentTaskLine
    @ObservedObject var model: AgentTaskViewModel
    @Environment(\.aircTheme) private var theme

    var body: some View {
        switch line.kind {
        case .prompt:
            HStack {
                Spacer(minLength: 80)
                Text(line.text).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.selectedFill.color))
            }
            .testAnchor("agenttask.prompt")
        case .text:
            AgentPaneMarkdown(text: line.text).foregroundStyle(theme.surfaceTextSecondary.color).testAnchor("agenttask.say")
        case .answer:
            AgentPaneMarkdown(text: line.text).padding(.top, 2).testAnchor("agenttask.answer")
        case .note, .approval:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: line.kind == .approval ? (line.text.hasPrefix("Allowed") ? "checkmark.circle" : "hand.raised") : "info.circle")
                    .font(.system(size: 11)).foregroundStyle(line.kind == .approval ? Color.orange : theme.surfaceTextTertiary.color).frame(width: 18)
                Text(line.text + (line.detail.map { " · " + $0 } ?? "")).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .testAnchor(line.kind == .approval ? "agenttask.decision" : "agenttask.note")
        case .steps:
            AgentTaskSteps(line: line, model: model)
        }
    }
}

/// A run's steps on a rail: a header that folds them ("Worked for 2m 14s · 18 steps"), then one row per step; a step
/// that found something shows it inline (the page it opened, the saved login it used) under a disclosure.
struct AgentTaskSteps: View {
    let line: AgentTaskLine
    @ObservedObject var model: AgentTaskViewModel
    @Environment(\.aircTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var folded: Bool { model.folded.contains(line.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = line.summary {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                        if folded { model.folded.remove(line.id) } else { model.folded.insert(line.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock").font(.system(size: 11)).frame(width: 18)
                        Text(s).aircFont(AircFont.callout)
                        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).rotationEffect(.degrees(folded ? -90 : 0))
                    }
                    .foregroundStyle(theme.surfaceTextTertiary.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, folded ? 0 : 6)
                .accessibilityLabel(s + (folded ? ", folded" : ""))
                .testAnchor("agenttask.summary")
            }
            if !folded {
                ForEach(Array(line.steps.enumerated()), id: \.element.id) { n, step in
                    AgentTaskStepRow(step: step, first: n == 0, last: n == line.steps.count - 1,
                                     running: line.running && n == line.steps.count - 1, model: model)
                }
            }
        }
        .testAnchor("agenttask.steps")
    }
}

struct AgentTaskStepRow: View {
    let step: AgentTaskLine.Step
    let first: Bool
    let last: Bool
    let running: Bool
    @ObservedObject var model: AgentTaskViewModel
    @ObservedObject private var thumbs = AgentTaskThumbs.shared
    @Environment(\.aircTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Result { case page(AgentTaskThumbs.Shot?), login, found([AgentTaskRecord.Entry.Found]) }

    private var result: Result? {
        _ = thumbs.revision
        if let found = step.found, !found.isEmpty { return .found(found) }
        if step.caption.hasPrefix("Opening") {
            // agentrecall: the picture comes back from disk after a relaunch (by the step's key).
            let shot = step.key.flatMap { thumbs.step($0, task: model.taskID) }
            // No picture and no site: nothing to show.
            if shot == nil, step.host == nil { return nil }
            return .page(shot)
        }
        if step.caption.hasPrefix("Filling a saved login") { return .login }
        return nil
    }

    /// Open by default when there's something worth seeing (a picture); the person's toggle flips it.
    private var open: Bool {
        guard let r = result else { return false }
        let byDefault: Bool
        switch r { case .page(let s): byDefault = s != nil; case .login, .found: byDefault = true }
        return byDefault != model.toggled.contains(step.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentTaskStepGlyph(caption: step.caption, host: step.host, size: 14)
                .frame(width: 20, height: 20)
                .background(Circle().fill(theme.surface.color))
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if running {
                        AgentPaneShimmerText(text: step.caption, on: true)
                    } else {
                        Text(captionText).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1).truncationMode(.middle)
                    }
                    if result != nil {
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                                if model.toggled.contains(step.id) { model.toggled.remove(step.id) } else { model.toggled.insert(step.id) }
                            }
                        } label: {
                            Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).rotationEffect(.degrees(open ? 180 : 0))
                                .frame(width: 18, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(theme.surfaceTextTertiary.color)
                        .accessibilityLabel(open ? "Hide what it found" : "Show what it found")
                        .testAnchor("agenttask.step.toggle")
                    }
                }
                .frame(minHeight: 26)
                if let d = step.detail, !d.isEmpty {
                    Text(d).aircFont(AircFont.caption).foregroundStyle(Color.red.opacity(0.8)).lineLimit(2)
                }
                if open, let r = result { inline(r).transition(.opacity.combined(with: .offset(y: -4))).padding(.bottom, 6) }
            }
        }
        // The rail: a hairline through the glyphs, from the first glyph to the last.
        .background(alignment: .topLeading) {
            VStack(spacing: 0) {
                Rectangle().fill(first ? Color.clear : theme.separator.color).frame(width: 1, height: 13)
                Rectangle().fill(last ? Color.clear : theme.separator.color).frame(width: 1).frame(maxHeight: .infinity)
            }
            .padding(.leading, 9.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step: \(step.caption)")
        .testAnchor(running ? "agenttask.step.running" : "agenttask.step")
    }

    /// "Opened shop.example.com" once it's done; the site name in the accent colour like a link.
    private var captionText: AttributedString {
        var caption = step.caption
        if caption.hasPrefix("Opening ") { caption = "Opened " + caption.dropFirst("Opening ".count) }
        var a = AttributedString(caption)
        if let host = step.host, let r = a.range(of: host) { a[r].swiftUI.foregroundColor = theme.accentText.color }
        return a
    }

    @ViewBuilder private func inline(_ r: Result) -> some View {
        switch r {
        case .page(let shot):
            Button { if let h = step.host ?? shot?.host { model.openSite(h) } } label: {
                VStack(alignment: .leading, spacing: 0) {
                    if let shot {
                        Image(decorative: shot.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 320, height: 200, alignment: .top).clipped()
                            .testAnchor("agenttask.result.picture")
                    }
                    HStack(spacing: 6) {
                        AgentPaneSiteIcon(host: step.host ?? shot?.host, size: 13)
                        Text(shot?.title.isEmpty == false ? shot!.title : (step.host ?? shot?.host ?? "")).aircFont(AircFont.caption.weight(.medium))
                            .foregroundStyle(theme.surfaceText.color).lineLimit(1)
                        Text(step.host ?? shot?.host ?? "").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).frame(height: 28)
                }
                .frame(width: 320)
                .background(theme.tileFill.color.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.surfaceBorder.color))
                .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.06), radius: 6, y: 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(step.host ?? "the page") in a new tab")
            .testAnchor("agenttask.result.page")
        case .login:
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 11)).foregroundStyle(theme.surfaceTextTertiary.color)
                Text("Your saved login").aircFont(AircFont.caption.weight(.medium)).foregroundStyle(theme.surfaceText.color)
                if let h = step.host { Text(h).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color) }
                Spacer(minLength: 8)
                Text("Passwords").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
            }
            .padding(.horizontal, 10).frame(height: 32).frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.tileFill.color.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.surfaceBorder.color))
            .accessibilityLabel("Used your saved login for \(step.host ?? "the site"). Airc filled it; the agent never saw it.")
            .help("Airc filled it in; the agent never sees passwords")
            .testAnchor("agenttask.result.login")
        case .found(let rows):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { n, f in
                    AgentTaskFoundRow(found: f) { model.openPage(f.url) }.testAnchor("agenttask.result.found.\(n)")
                }
            }
            .padding(4)
            .frame(maxWidth: 460, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.tileFill.color.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.surfaceBorder.color))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What it found in your history and tabs")
            .testAnchor("agenttask.result.found")
        }
    }
}

/// One page a history search found: site icon, title, site and where it is (open tab, pinned tab, Favorite, history).
/// A click opens it in a new tab.
struct AgentTaskFoundRow: View {
    let found: AgentTaskRecord.Entry.Found
    let open: () -> Void
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme

    private var host: String? { AgentRedaction.site(URL(string: found.url)) }
    private var place: String {
        switch found.place {
        case .openTab: return "Open tab"
        case .pinnedTab: return "Pinned"
        case .favorite: return "Favorite"
        case .history: return "History"
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                AgentPaneSiteIcon(host: host, size: 14)
                Text(found.title.isEmpty ? (host ?? found.url) : found.title).aircFont(AircFont.caption.weight(.medium))
                    .foregroundStyle(theme.surfaceText.color).lineLimit(1).truncationMode(.tail)
                if let host { Text(host).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(1) }
                Spacer(minLength: 8)
                Text(place).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? theme.selectedFill.color : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open \(host ?? "the page") in a new tab")
        .accessibilityLabel("\(found.title), \(host ?? ""), \(place). Opens in a new tab.")
    }
}

/// The agent's page beside the task: live (the engine's own output on Chromium, frame copies on WebKit), its site and
/// step, Watch and Take over.
struct AgentTaskLiveCard: View {
    @ObservedObject var model: AgentTaskViewModel
    @ObservedObject private var run = AgentRunCenter.shared
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme

    private var window: AgentWindow? { run.runWindowID.flatMap { AgentCenter.shared.windows[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                AgentPaneSiteIcon(host: window?.activeTab?.url?.host.map(AgentPaneTimeline.trimmed), size: 14)
                Text(window?.activeTab?.title.isEmpty == false ? window!.activeTab!.title : (window?.activeTab?.url?.host ?? "Starting…"))
                    .aircFont(AircFont.caption.weight(.medium)).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
                Spacer(minLength: 4)
                if hovered {
                    Button("Take over") { model.takeOver() }.buttonStyle(.airc(.secondary, size: .small)).testAnchor("agenttask.takeover")
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            AgentPaneLivePicture()
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding([.horizontal, .bottom], 5)
                .onTapGesture { model.openWatch() }
                .help("Watch the agent's page")
                .accessibilityLabel("The agent's page, live")
                .accessibilityAddTraits(.isButton)
                .testAnchor("agenttask.live.picture")
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(theme.surfaceBorder.color))
        .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.12), radius: 18, y: 6)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovered = h } }
        .testAnchor("agenttask.live")
    }
}

/// Pay, send, post, delete, in the task view: the same answer as the pane's card (Airc's approval rule), above the
/// composer. Nothing is pre-selected; Esc denies.
struct AgentTaskApproval: View {
    let request: AgentApprovalRequest
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "hand.raised.fill").font(.system(size: 14)).foregroundStyle(.orange)
                .frame(width: 30, height: 30).background(Circle().fill(Color.orange.opacity(theme.isDark ? 0.2 : 0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).aircFont(AircFont.body.weight(.semibold)).foregroundStyle(theme.surfaceText.color)
                    .testAnchor("agenttask.approval.title")
                Text(request.risk.reason).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Deny") { AgentRunCenter.shared.answerApproval(allow: false) }.buttonStyle(.airc(.secondary, size: .small))
                .keyboardShortcut(.cancelAction)
                .testAnchor("agenttask.deny")
            Button("Allow once") { AgentRunCenter.shared.answerApproval(allow: true) }.buttonStyle(.airc(.secondary, size: .small))
                .testAnchor("agenttask.allow")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(theme.isDark ? 0.14 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.4)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waiting for your OK: \(request.title)")
        .testAnchor("agenttask.approval")
    }
}

/// "Reply, @ for context", the chips under it, and Send ↑ / Stop ■.
struct AgentTaskComposer: View {
    @ObservedObject var model: AgentTaskViewModel
    @ObservedObject private var run = AgentRunCenter.shared
    @FocusState private var focused: Bool
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(model.placeholder, text: $model.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .aircFont(AircFont.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { model.send() }
                    .onChange(of: model.text) { _, t in
                        // "@": the + menu's tabs (the shown page first).
                        if t.hasSuffix("@"), let c = model.controller, let p = AgentAskContext.shownPage(of: c), !model.attached.contains(p) {
                            model.text.removeLast()
                            model.attached.append(p)
                        }
                    }
                    .padding(.vertical, 6)
                    .testAnchor("agenttask.field")
                button
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.fieldFill.color))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(focused ? theme.focusRing.color.opacity(0.55) : theme.surfaceBorder.color))
            .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.05), radius: 8, y: 2)
            AgentAskChips(attached: $model.attached, tabs: { model.controller.map(AgentAskContext.spaceTabs) ?? [] },
                          profileName: model.controller.map { $0.store.profile(ofSpace: $0.currentSpaceID).name } ?? "",
                          compact: false)
                .padding(.horizontal, 6)
        }
        .testAnchor("agenttask.composer")
    }

    @ViewBuilder private var button: some View {
        if model.live && run.approval == nil {
            Button { model.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.surface.color)
                    .frame(width: 30, height: 30).background(Circle().fill(theme.surfaceText.color))
            }
            .buttonStyle(.plain).keyboardShortcut(".", modifiers: .command).help("Stop (⌘.)").accessibilityLabel("Stop")
            .testAnchor("agenttask.stop")
        } else {
            let empty = model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button { model.send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.onAccent.color)
                    .frame(width: 30, height: 30).background(Circle().fill(theme.accent.color.opacity(empty ? 0.35 : 1)))
            }
            .buttonStyle(.plain).disabled(empty).help("Send (↩)").accessibilityLabel("Send")
            .testAnchor("agenttask.send")
        }
    }
}

/// A small spinner on Core Animation (the render server turns it; the app does nothing per frame). Reduce Motion: a
/// still ring.
struct AgentTaskSpinner: NSViewRepresentable {
    var size: CGFloat = 12
    var color: NSColor? = nil

    final class SpinView: NSView {
        let arc = CAShapeLayer()
        var tint: NSColor = .secondaryLabelColor
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            arc.fillColor = nil
            arc.lineWidth = 1.6
            arc.lineCap = .round
            arc.strokeStart = 0
            arc.strokeEnd = 0.72
            layer?.addSublayer(arc)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.frame = bounds
            let r = min(bounds.width, bounds.height) / 2 - arc.lineWidth
            arc.path = CGPath(ellipseIn: CGRect(x: bounds.midX - r, y: bounds.midY - r, width: 2 * r, height: 2 * r), transform: nil)
            arc.strokeColor = tint.cgColor
            CATransaction.commit()
            spin()
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); spin() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
        func spin() {
            guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, arc.animation(forKey: "spin") == nil, bounds.width > 0 else { return }
            arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -2 * Double.pi
            a.duration = 0.9
            a.repeatCount = .infinity
            arc.add(a, forKey: "spin")
        }
        /// Checks read it.
        var spinning: Bool { arc.animation(forKey: "spin") != nil }
    }

    func makeNSView(context: Context) -> SpinView { SpinView(frame: NSRect(x: 0, y: 0, width: size, height: size)) }
    func updateNSView(_ v: SpinView, context: Context) {
        let t = color ?? .secondaryLabelColor
        if v.tint != t { v.tint = t; v.needsLayout = true }
    }
}

/// The streaming answer's caret: a soft blink on Core Animation.
struct AgentTaskCaret: NSViewRepresentable {
    final class CaretView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
            layer?.cornerRadius = 1
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, layer?.animation(forKey: "blink") == nil else { return }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.1
            a.duration = 0.55
            a.autoreverses = true
            a.repeatCount = .infinity
            layer?.add(a, forKey: "blink")
        }
        override var intrinsicContentSize: NSSize { NSSize(width: 2, height: 15) }
    }
    func makeNSView(context: Context) -> CaretView { CaretView(frame: NSRect(x: 0, y: 0, width: 2, height: 15)) }
    func updateNSView(_ v: CaretView, context: Context) {}
}

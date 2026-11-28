// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import Combine

/// agentparallel: every Airc Agent task of this launch, each its own `AgentRunCenter` (conversation, agent window,
/// approval, Stop), so tasks run side by side (docs/design/agent-ux.md §1). Views that show one task bind to that run;
/// views about all of them (the ✦ button, the Agents folder, "needs you", the Dock) follow `changed`.
final class AgentTaskCenter: ObservableObject {
    static let shared = AgentTaskCenter()
    /// Any task started, ended, queued, or started or stopped waiting for an OK.
    static let changed = Notification.Name("AircAgentTasksChanged")

    /// Oldest first. Finished conversations stay (a follow-up goes on in the same conversation) until `keepFinished`.
    @Published private(set) var runs: [AgentRunCenter] = []
    @Published private(set) var revision = 0
    /// The task started or made last (the old panel and one-task checks).
    private var last: AgentRunCenter?
    private var queue: [(run: AgentRunCenter, start: () -> Void)] = []
    private var subs: [ObjectIdentifier: AnyCancellable] = [:]
    /// Finished conversations kept for follow-ups beyond the running ones; older ones end (their agent windows close,
    /// their tabs stay the person's), their records stay in history.
    static let keepFinished = 8

    private init() {}

    /// A new, empty task (the pane's ✎ New, ⌘T → Ask, a task view's reply to an older task).
    func make() -> AgentRunCenter {
        let r = AgentRunCenter()
        // Checks follow every task with the closure they gave the last one.
        r.onEvent = last?.onEvent
        _ = r.timeline   // stamps from the first step on
        runs.append(r)
        last = r
        AgentTaskRecorder.shared.attach(r)
        AgentTaskThumbs.shared.attach(r)
        // Its state, approval or place in the queue: everything that follows all tasks hears of it.
        let changes = Publishers.Merge3(r.$queuedPrompt.dropFirst().map { _ in () }, r.$state.dropFirst().map { _ in () },
                                        r.$approval.dropFirst().map { _ in () })
        subs[ObjectIdentifier(r)] = changes.sink { [weak self, weak r] in if let r { self?.runChanged(r) } }
        prune()
        bump()
        return r
    }

    /// A task was asked (it becomes `latest`).
    func started(_ r: AgentRunCenter) {
        if !runs.contains(where: { $0 === r }) { runs.append(r) }
        last = r
    }

    /// The task started or made last; one is made if there is none.
    var latest: AgentRunCenter { last ?? make() }

    /// The empty task to type into: an empty one no pane shows yet, else a new one.
    func draft() -> AgentRunCenter {
        if let r = runs.last(where: { $0.steps.isEmpty && !$0.isBusy && !AgentPaneController.shows($0) }) { return r }
        return make()
    }

    func run(task id: String?) -> AgentRunCenter? {
        guard let id else { return nil }
        return runs.first { $0.taskID == id }
    }

    /// The task whose run owns this agent window (outside apps' windows: nil).
    func run(agentWindow id: Int?) -> AgentRunCenter? {
        guard let id, let task = AgentCenter.shared.windows[id]?.taskID else { return runs.first { $0.runWindowID == id && id != 0 } }
        return run(task: task)
    }

    var active: [AgentRunCenter] { runs.filter { $0.state.isActive } }
    var busy: [AgentRunCenter] { runs.filter(\.isBusy) }
    var anyActive: Bool { runs.contains { $0.state.isActive } }
    /// Tasks waiting for an OK, oldest request first.
    var waiting: [AgentRunCenter] { runs.filter { $0.approval != nil } }

    /// Dock › Stop Agents, the Agents folder's Stop for Airc's own rows: every task.
    func stopAll(_ reason: String = "You stopped it.") {
        for r in runs where r.isBusy { r.stop(reason) }
    }

    // MARK: How many at once

    /// The person's limit of tasks running at once (Settings › AI › Agent; 0 = no limit).
    var limit: Int { AgentModelSettings.shared.values.maxParallel }

    func hasSlot(for r: AgentRunCenter) -> Bool {
        let n = limit
        guard n > 0 else { return true }
        return runs.filter { $0 !== r && $0.state.isActive }.count < n
    }

    func enqueue(_ r: AgentRunCenter, start: @escaping () -> Void) {
        queue.removeAll { $0.run === r }
        queue.append((r, start))
        bump()
    }

    func dequeue(_ r: AgentRunCenter) {
        queue.removeAll { $0.run === r }
        bump()
    }

    /// Queued tasks start in order as running ones end.
    private func pump() {
        while let first = queue.first, hasSlot(for: first.run) {
            queue.removeFirst()
            first.start()
        }
    }

    // MARK: Changes

    /// From the run: its state or approval changed.
    func runChanged(_ r: AgentRunCenter) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !r.state.isActive { self.pump() }
            self.bump()
        }
    }

    private func bump() {
        revision += 1
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private func prune() {
        let finished = runs.filter { !$0.isBusy && !$0.steps.isEmpty }
        guard finished.count > Self.keepFinished else { return }
        for r in finished.prefix(finished.count - Self.keepFinished) {
            r.newConversation()
            forget(r)
        }
        // Empty drafts nobody shows: only the newest stays.
        let drafts = runs.filter { $0.steps.isEmpty && !$0.isBusy && $0 !== last }
        for r in drafts where !AgentPaneController.shows(r) { forget(r) }
    }

    /// A task deleted, or an old one let go.
    func forget(_ r: AgentRunCenter) {
        runs.removeAll { $0 === r }
        subs[ObjectIdentifier(r)] = nil
        queue.removeAll { $0.run === r }
        AgentTaskRecorder.shared.detach(r)
        AgentTaskThumbs.shared.detach(r)
        if last === r { last = runs.last }
    }
}

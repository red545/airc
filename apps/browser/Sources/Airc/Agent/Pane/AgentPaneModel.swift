// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import Combine
import SwiftUI

/// When each line of the conversation appeared, and which site and page each step was on, for the pane's step rows,
/// "Done in …" summaries and site chips. One for the app (the conversation is AgentRunCenter's, one at a time); it starts
/// with the first pane and follows the run from then on.
final class AgentPaneTimeline: ObservableObject {
    static let shared = AgentPaneTimeline()

    struct Stamp { var at: Date; var host: String?; var url: URL? }
    private(set) var stamps: [UUID: Stamp] = [:]
    /// A run's end (its prompt's id → when the run stopped being active).
    private(set) var ends: [UUID: Date] = [:]
    /// Site icons by host, from the agent's pages.
    private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var revision = 0
    private var subs: [AnyCancellable] = []
    private var lastState: AgentRunCenter.State = .idle

    private init() {
        let run = AgentRunCenter.shared
        stamp(run.steps)
        subs.append(run.$steps.sink { [weak self] steps in self?.stamp(steps) })
        subs.append(run.$state.sink { [weak self] s in self?.stateChanged(s) })
    }

    private func stamp(_ steps: [AgentStep]) {
        let now = Date()
        var changed = false
        let window = AgentRunCenter.shared.runWindowID.flatMap { AgentCenter.shared.windows[$0] }
        let pageURL = window?.activeTab?.url
        for s in steps where stamps[s.id] == nil {
            var host: String?
            var url: URL?
            if s.kind == .action {
                host = Self.host(in: s.text) ?? pageURL?.host.map(Self.trimmed)
                if let pageURL, pageURL.host.map(Self.trimmed) == host { url = pageURL }
                if url == nil, let host { url = URL(string: "https://\(host)") }
            }
            stamps[s.id] = Stamp(at: now, host: host, url: url)
            changed = true
        }
        if let window {
            for t in window.tabs {
                if let h = t.tab.url?.host.map(Self.trimmed), let icon = t.tab.favicon, icons[h] == nil { icons[h] = icon; changed = true }
            }
        }
        if changed { revision += 1 }
    }

    private func stateChanged(_ s: AgentRunCenter.State) {
        defer { lastState = s }
        guard lastState.isActive, !s.isActive, let prompt = AgentRunCenter.shared.steps.last(where: { $0.kind == .user }) else { return }
        ends[prompt.id] = Date()
        revision += 1
    }

    func at(_ id: UUID) -> Date? { stamps[id]?.at }
    func host(_ id: UUID) -> String? { stamps[id]?.host }
    func url(_ id: UUID) -> URL? { stamps[id]?.url }
    func end(_ promptID: UUID) -> Date? { ends[promptID] }
    func icon(_ host: String?) -> NSImage? { host.flatMap { icons[$0] } }

    static func trimmed(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

    /// The site named in a step caption ("Opening shop.example.com", "Opening 127.0.0.1:8080").
    static func host(in caption: String) -> String? {
        for word in caption.split(whereSeparator: { $0 == " " || $0 == "‘" || $0 == "’" || $0 == "“" || $0 == "”" }) {
            let w = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()"))
            guard w.contains("."), !w.hasPrefix("."), w.first?.isLetter == true || w.first?.isNumber == true else { continue }
            let parts = w.split(separator: ".")
            guard parts.count >= 2, let tld = parts.last?.split(separator: ":").first, tld.count >= 2,
                  w.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }) else { continue }
            // "1.5" or "3.2s" isn't a site; an IP address is.
            if parts.count == 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) { continue }
            return trimmed(w.lowercased())
        }
        return nil
    }
}

/// One line of the pane's transcript, made from AgentRunCenter's steps.
enum AgentPaneItem: Identifiable, Equatable {
    struct StepRow: Identifiable, Equatable {
        let id: UUID
        var caption: String
        var host: String?
        var detail: String?
        var count = 1
    }

    case prompt(UUID, String)
    case text(UUID, String, final: Bool)
    /// Step rows of a run that's still going; the last row of the last group is the running one.
    case steps(UUID, [StepRow], running: Bool)
    /// A finished run's steps, folded: "Done in 2m 14s · 18 steps · 3 sites".
    case summary(UUID, String, [StepRow])
    case note(UUID, AgentStep.Kind, String, String?)
    case memory(UUID, AgentStep)
    /// The sites a finished run used, under its answer (the answer's id).
    case sites(UUID, [Site])

    struct Site: Equatable, Hashable { let host: String; let url: URL? }

    var id: String {
        switch self {
        case .prompt(let id, _), .text(let id, _, _), .steps(let id, _, _), .summary(let id, _, _), .note(let id, _, _, _),
             .memory(let id, _): return id.uuidString
        case .sites(let id, _): return "sites-" + id.uuidString
        }
    }

    /// The transcript for `steps`: runs split at each prompt; a finished run's steps fold into one summary line.
    static func make(_ steps: [AgentStep], active: Bool, timeline: AgentPaneTimeline) -> [AgentPaneItem] {
        var items: [AgentPaneItem] = []
        var runs: [[AgentStep]] = []
        for s in steps {
            if s.kind == .user || runs.isEmpty { runs.append([s]) } else { runs[runs.count - 1].append(s) }
        }
        for (n, run) in runs.enumerated() {
            let live = active && n == runs.count - 1
            let prompt = run.first(where: { $0.kind == .user })
            let actions = run.filter { $0.kind == .action }
            var folded = false
            var group: [StepRow] = []
            var groupID: UUID?
            func flush() {
                guard let id = groupID, !group.isEmpty else { return }
                items.append(.steps(id, collapseReads(group, keepLast: live), running: live))
                group = []
                groupID = nil
            }
            for s in run {
                switch s.kind {
                case .user:
                    items.append(.prompt(s.id, promptText(s.text)))
                case .action:
                    if live {
                        if groupID == nil { groupID = s.id }
                        group.append(StepRow(id: s.id, caption: s.text, host: timeline.host(s.id), detail: s.detail))
                    } else if !folded {
                        folded = true
                        let rows = collapseReads(actions.map { StepRow(id: $0.id, caption: $0.text, host: timeline.host($0.id), detail: $0.detail) }, keepLast: false)
                        items.append(.summary(s.id, summaryLine(run, prompt: prompt, actions: actions, timeline: timeline), rows))
                    }
                default:
                    flush()
                    switch s.kind {
                    case .say: items.append(.text(s.id, s.text, final: false))
                    case .final: items.append(.text(s.id, s.text, final: true))
                    case .memory: items.append(.memory(s.id, s))
                    default: items.append(.note(s.id, s.kind, s.text, s.detail))
                    }
                }
            }
            flush()
            // The sites the run used, under its answer (once it's over).
            if !live, let last = run.last(where: { $0.kind == .final }) {
                var seen = Set<String>()
                let sites = actions.compactMap { a -> Site? in
                    guard let h = timeline.host(a.id), !seen.contains(h) else { return nil }
                    seen.insert(h)
                    return Site(host: h, url: timeline.url(a.id))
                }
                if !sites.isEmpty, let i = items.lastIndex(where: { $0.id == last.id.uuidString }) {
                    items.insert(.sites(last.id, sites), at: i + 1)
                }
            }
        }
        return items
    }

    /// The prompt as the person wrote it (the attached page's line goes to the model, not into the bubble).
    static let pageLine = "\n\nThe page I'm looking at: "
    static func promptText(_ t: String) -> String {
        guard let r = t.range(of: pageLine) else { return t }
        return String(t[..<r.lowerBound])
    }

    /// Consecutive reads become one row ("Read 3 pages"); the running row stays as it is.
    static func collapseReads(_ rows: [StepRow], keepLast: Bool) -> [StepRow] {
        var out: [StepRow] = []
        for (i, r) in rows.enumerated() {
            let isRead = r.caption.hasPrefix("Reading")
            let isLast = i == rows.count - 1
            if isRead, !(keepLast && isLast), let prev = out.last, prev.caption.hasPrefix("Read"), prev.detail == nil, r.detail == nil {
                var merged = prev
                merged.count += 1
                merged.caption = "Read \(merged.count) pages"
                out[out.count - 1] = merged
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func summaryLine(_ run: [AgentStep], prompt: AgentStep?, actions: [AgentStep], timeline: AgentPaneTimeline) -> String {
        let stopped = run.contains { $0.kind == .info && ($0.text.hasPrefix("Stopped") || $0.text.contains("stopped")) }
            || run.contains { $0.kind == .error }
        var parts: [String] = []
        if let p = prompt, let start = timeline.at(p.id) {
            let end = timeline.end(p.id) ?? run.compactMap { timeline.at($0.id) }.max() ?? start
            parts.append((stopped ? "Stopped after " : "Done in ") + duration(end.timeIntervalSince(start)))
        } else {
            parts.append(stopped ? "Stopped" : "Done")
        }
        parts.append("\(actions.count) step\(actions.count == 1 ? "" : "s")")
        let sites = Set(actions.compactMap { timeline.host($0.id) })
        if !sites.isEmpty { parts.append("\(sites.count) site\(sites.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// "48s", "2m 14s", "1h 3m".
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// A provider row: the pane's first-run card and its provider menu (docs/design/agent-ux.md §8), in the design's order:
/// the person's own Claude Code and Codex (agentcli's AgentCLIDetector says whether each is ready), then the API keys.
struct AgentPaneProvider: Identifiable, Equatable {
    enum Group { case plan, key }
    let id: String
    let name: String
    let subtitle: String
    let status: String
    let ready: Bool
    let group: Group
    /// The button when not ready ("Install…", "Sign in…", "Update…", "Add key…").
    let fix: String?
    /// What to do about it, in words (the CLI's own install or login step).
    let hint: String?
    let selected: Bool

    static func all() -> [AgentPaneProvider] {
        let s = AgentModelSettings.shared
        let backend = s.values.backend
        let current = s.values.provider
        var out: [AgentPaneProvider] = AgentCLIKind.allCases.map { k in
            let st = AgentCLIDetector.shared.status(k)
            let fix: String?
            switch st {
            case .ready?: fix = nil
            case .notInstalled?: fix = "Install…"
            case .notLoggedIn?: fix = "Sign in…"
            case .tooOld?: fix = "Update…"
            case .broken?: fix = "Fix…"
            case .checking?, nil: fix = "Check"
            }
            let status = st.map { $0 == .checking ? "Checking…" : $0.summary(k).replacingOccurrences(of: k.name + " ", with: "").replacingOccurrences(of: k.name + ": ", with: "") } ?? "Not checked yet"
            return AgentPaneProvider(id: "cli-\(k.rawValue)", name: k.name, subtitle: k == .claudeCode ? "Your own Claude Code" : "Your own Codex",
                                     status: status, ready: st?.isReady == true, group: .plan, fix: fix, hint: st?.fix(k),
                                     selected: backend.cli == k)
        }
        out += AgentProvider.allCases.map { p in
            let has = s.hasKey(p)
            let model = p == current ? s.model.name : p.defaultModel.name
            return AgentPaneProvider(id: "api-\(p.rawValue)", name: "\(p.name) API key", subtitle: "Billed to your key",
                                     status: has ? "Key \(s.keyHint(p) ?? "") · \(model)" : "No key yet", ready: has, group: .key,
                                     fix: has ? nil : "Add key…", hint: nil, selected: backend == .apiKey && has && p == current)
        }
        return out
    }

    var cli: AgentCLIKind? { AgentCLIKind.allCases.first { "cli-\($0.rawValue)" == id } }

    /// Makes this provider the one the next run uses.
    func choose() {
        let s = AgentModelSettings.shared
        if let k = cli { return s.update { $0.backend = k == .claudeCode ? .claudeCode : .codex } }
        if let p = AgentProvider.allCases.first(where: { "api-\($0.rawValue)" == id }) { s.update { $0.backend = .apiKey; $0.provider = p } }
    }

    /// Its set-up step. A CLI's Install… and Sign in… happen in the pane (`model.setUp`): the install command from its
    /// docs, the CLI's own sign-in; "Check" looks again. An API key's field is in Settings › AI › Agent.
    func setUp(in model: AgentPaneModel? = nil) {
        if let k = cli, fix == "Check" { return AgentCLIDetector.shared.check(k, maxAge: 0) }
        if let k = cli, let model, fix == "Install…" || fix == "Sign in…" { return model.setUp(k) }
        // An API key: pasted right in the pane (Keychain), Settings › AI › Agent stays the full page.
        if let p = AgentProvider.allCases.first(where: { "api-\($0.rawValue)" == id }), let model, fix != nil { return model.enterKey(p) }
        if let k = cli { AgentCLIDetector.shared.check(k, maxAge: 5) }
        (NSApp.delegate as? AppDelegate)?.showSettings(page: .ai)
    }

    /// Detection runs when the pane opens (never at launch or per keystroke); cached by the detector.
    static func refresh() { AgentCLIKind.allCases.forEach { AgentCLIDetector.shared.check($0) } }
}

/// The pane's state for one window: the field, the attached page, which summaries are open, and what it shows.
final class AgentPaneModel: ObservableObject {
    weak var pane: AgentPaneController?
    @Published var theme: ResolvedTheme?
    @Published var text = ""
    /// The page attached to the next prompt (the window's page when the pane opened; ✕ removes it).
    @Published var page: PageChip?
    @Published var armedStop = false
    @Published var expanded: Set<UUID> = []
    /// The person took the agent's page (Take over): the run is paused for them until Hand back.
    @Published var takenOver: TakenOver?
    @Published var providerRevision = 0
    /// Installing or signing in to Claude Code / Codex, in the pane (nil: not shown).
    @Published var setup: Setup?
    /// Pasting an API key in the pane (nil: not shown).
    @Published var keyEntry: AgentProvider?
    @Published var keyError: String?
    /// The task to send once that provider is ready (typed before it was, or the one that failed signed out).
    private(set) var pendingTask: String?
    private var login: AgentCLILogin?
    /// The field's text on the last send (↑ recalls it; Try again sends it again).
    private(set) var lastPrompt: String?
    private var removedChipForTab: String?
    private var subs: [AnyCancellable] = []

    struct PageChip: Equatable { let tabID: String; let title: String; let url: URL }
    struct TakenOver: Equatable {
        let title: String
        let url: URL?
        /// The person's tab the page became, and the agent tab it was (Hand back moves the same page back).
        var tabID: String? = nil
        var agentTabID: Int? = nil
    }

    /// The pane's Install… / Sign in… card for one CLI.
    struct Setup: Equatable {
        enum Step: Equatable {
            /// Not installed: the documented command, Copy, Open Terminal with this command, Check again.
            case install
            /// It's on this Mac now: Use it.
            case found
            /// Signed out: Sign in… starts the CLI's own sign-in.
            case signIn
            /// The CLI's sign-in is open (in Terminal, or its page in a tab): waiting for it to report ready.
            case waiting(browser: URL?)
            case failed(String)
        }
        let kind: AgentCLIKind
        var step: Step
    }

    let run = AgentRunCenter.shared
    let timeline = AgentPaneTimeline.shared

    init() {
        subs.append(NotificationCenter.default.publisher(for: AgentModelSettings.changed).sink { [weak self] _ in self?.providerRevision += 1 })
        subs.append(NotificationCenter.default.publisher(for: AgentCLIDetector.changed).sink { [weak self] _ in
            self?.providerRevision += 1
            self?.setupStatusChanged()
        })
        // Back from Terminal or the CLI's sign-in page: look again (design §8: re-check when Airc becomes active).
        subs.append(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in self?.recheckSetup() })
        subs.append(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification).sink { [weak self] n in
            guard let self, let w = n.object as? NSWindow, w === self.controller?.window else { return }
            self.recheckSetup()
        })
    }

    var controller: WindowController? { pane?.controller }

    /// Shown or re-shown in a window: the window's page becomes the chip (unless removed for this tab).
    func windowOpened(from c: WindowController) {
        AgentPaneProvider.refresh()
        guard let id = c.shownTabID, let tab = c.store.tab(id), let url = URL(string: tab.url), ["http", "https", "file"].contains(url.scheme ?? "") else {
            page = nil
            return
        }
        if removedChipForTab == id { return }
        page = PageChip(tabID: id, title: tab.title.isEmpty ? (url.host ?? url.absoluteString) : tab.title, url: url)
    }

    func paneHidden() { armedStop = false }

    func removeChip() {
        removedChipForTab = page?.tabID
        page = nil
    }

    // MARK: State

    enum Mode: Equatable { case connect, newTask, conversation }

    var connected: Bool { _ = providerRevision; return run.hasKey }

    var mode: Mode {
        if !run.steps.isEmpty { return .conversation }
        return connected ? .newTask : .connect
    }

    var title: String {
        guard let first = run.steps.first(where: { $0.kind == .user })?.text else { return connected ? "New task" : "Airc Agent" }
        return AgentTaskTitle.make(first)
    }

    var placeholder: String {
        if run.approval != nil { return "Or tell it what to change…" }
        if run.state.isActive { return "Tell it something while it works…" }
        if run.steps.isEmpty { return "Ask Airc to…" }
        return "Reply…"
    }

    /// The error banner's text and actions, for a run that failed or hit a limit.
    struct Problem: Equatable { let message: String; let detail: String?; let retry: Bool; let continues: Bool; let settings: Bool }

    var problem: Problem? {
        switch run.state {
        case .failed(let m):
            let lower = m.lowercased()
            let settings = lower.contains("settings") || lower.contains("key") || lower.contains("connect") || lower.contains("log")
            return Problem(message: m, detail: "The task is kept. Try again, or use another provider.", retry: lastPrompt != nil || lastUserText != nil,
                           continues: false, settings: settings)
        case .stopped(let why) where why.contains("limit") || why.contains("Continue"):
            return Problem(message: why, detail: nil, retry: false, continues: true, settings: false)
        default:
            return nil
        }
    }

    private var lastUserText: String? { run.steps.last(where: { $0.kind == .user })?.text }

    var items: [AgentPaneItem] {
        AgentPaneItem.make(run.steps, active: run.state.isActive, timeline: timeline)
    }

    /// The transcript ends in step rows (no "Thinking…" under them).
    var lastItemIsSteps: Bool {
        if case .steps? = items.last { return true }
        return false
    }

    /// Suggestions for a new task (static rules on the attached page; no model call).
    var suggestions: [String] {
        if let p = page, let host = p.url.host.map(AgentPaneTimeline.trimmed) {
            return ["Summarize this page", "Find the contact details on \(host)", "Compare this with two alternatives"]
        }
        return ["Find a quiet café near me that's open now", "Compare three noise-cancelling headphones under €300",
                "Check the weather for the weekend and suggest a hike"]
    }

    /// "1m 12s · 14 steps" while running.
    var progress: String? {
        guard run.state.isActive, let start = run.startedAt else { return nil }
        return AgentPaneItem.duration(Date().timeIntervalSince(start)) + " · \(run.stepCount) step\(run.stepCount == 1 ? "" : "s")"
    }

    var providers: [AgentPaneProvider] { _ = providerRevision; return AgentPaneProvider.all() }

    /// The pill's label: "Anthropic · Claude Opus 5.5".
    var providerLabel: String {
        _ = providerRevision
        guard let p = providers.first(where: \.selected) else { return "Connect your AI" }
        if p.cli != nil { return p.name }
        return p.name.replacingOccurrences(of: " API key", with: "") + " · " + AgentModelSettings.shared.model.name
    }

    // MARK: Actions

    func newTask() {
        cancelSetup()
        run.newConversation()
        takenOver = nil
        expanded = []
        if let c = controller { removedChipForTab = nil; windowOpened(from: c) }
    }

    /// Send the field (or `override`). Not connected: the text stays and the top provider's setup opens.
    func send(_ override: String? = nil) {
        let typed = (override ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        guard connected else {
            if override != nil { text = typed }
            pendingTask = typed
            // The selected CLI if it's the one that isn't ready, else the top row (design §3: Send opens its Set up).
            let p = providers.first { $0.selected && !$0.ready } ?? providers.first
            p?.setUp(in: self)
            return
        }
        // A pending approval: sending is Deny plus this text (sent once the run has stopped).
        if run.approval != nil {
            run.answerApproval(allow: false)
            text = ""
            return after { self.ask("Not like that: " + typed) }
        }
        guard run.canSend else { return }
        text = ""
        ask(typed)
    }

    /// The Command Bar's task: sent now if the agent is free and connected, else left in the field.
    func ask(_ typed: String) {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard connected, run.canSend, let p = pane?.profile() else { text = t; return }
        lastPrompt = t
        var prompt = t
        if let chip = page, run.steps.isEmpty {
            // The page the person looks at: its title and address (the agent opens its own copy).
            prompt += AgentPaneItem.pageLine + "“\(chip.title)” — \(chip.url.absoluteString)"
        }
        takenOver = nil
        if let c = controller { AgentTaskRecorder.shared.willAsk(spaceID: c.currentSpaceID, profileID: p.id) }
        run.ask(prompt, profileID: p.id, profileName: p.name)
    }

    func stop() { run.stop() }

    func retry() {
        guard let t = lastPrompt ?? lastUserText else { return }
        ask(t)
    }

    /// Another provider for the next run, then the same task again.
    func switchProvider(_ p: AgentPaneProvider, retrying: Bool) {
        if setup?.kind == p.cli || p.cli == nil { cancelSetup() }
        p.choose()
        providerRevision += 1
        if retrying { retry() }
    }

    /// ↑ in an empty field.
    func recall() { if text.isEmpty, let t = lastPrompt { text = t } }

    /// Runs `then` once the run has settled (after a Stop or Deny).
    private func after(_ then: @escaping () -> Void) {
        var tries = 0
        func check() {
            tries += 1
            if run.canSend || tries > 40 { return then() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check)
        }
        check()
    }

    // MARK: Install and sign in (Claude Code, Codex)

    /// The pane's card for `kind`: install when it isn't on this Mac, sign in when it's signed out.
    func setUp(_ kind: AgentCLIKind) {
        keyEntry = nil
        let st = AgentCLIDetector.shared.status(kind)
        switch st {
        case .notLoggedIn?: setup = Setup(kind: kind, step: .signIn)
        case .ready?: setup = Setup(kind: kind, step: .found)
        default: setup = Setup(kind: kind, step: .install)
        }
        AgentCenter.shared.onEvent?("cli-setup \(kind.rawValue) \(setup.map { "\($0.step)" } ?? "")")
    }

    var setupCommand: String? { setup.map { $0.kind.install.command } }

    func copySetupCommand() {
        guard let c = setupCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c, forType: .string)
    }

    func openSetupInTerminal() {
        guard let k = setup?.kind else { return }
        if !AgentCLISetupFiles.openInstall(k) { setup?.step = .failed("Couldn't open Terminal. Copy the command and run it in Terminal.") }
    }

    func openSetupDocs() {
        guard let k = setup?.kind, let c = controller else { return }
        c.navigate(to: k.install.docs, newTab: true)
    }

    /// Check again (and on focus): the CLI's status, read fresh.
    func recheckSetup() {
        guard let s = setup else { return }
        switch s.step {
        case .install, .found, .signIn, .failed: AgentCLIDetector.shared.check(s.kind, maxAge: 0, freshPATH: true)
        case .waiting: break
        }
    }

    private func setupStatusChanged() {
        guard var s = setup, let st = AgentCLIDetector.shared.status(s.kind), st != .checking else { return }
        switch s.step {
        case .install:
            if st != .notInstalled { s.step = .found }
        case .found, .failed:
            if st == .notInstalled { s.step = .install }
        case .signIn, .waiting:
            break
        }
        if s != setup { setup = s }
    }

    /// Use it: the CLI becomes the agent's backend; signed out, its sign-in comes next; ready, the waiting task goes.
    func useSetup() {
        guard let k = setup?.kind else { return }
        AgentModelSettings.shared.update { $0.backend = k == .claudeCode ? .claudeCode : .codex }
        providerRevision += 1
        switch AgentCLIDetector.shared.status(k) {
        case .ready?: setupDone()
        case .notLoggedIn?: setup = Setup(kind: k, step: .signIn)
        default: AgentCLIDetector.shared.check(k, maxAge: 0)
        }
    }

    /// Sign in…: the CLI's own sign-in (Terminal for Claude Code; Codex's page in a normal tab). Airc never sees it.
    func signIn() {
        guard let k = setup?.kind else { return }
        guard let path = AgentCLIDetector.shared.status(k)?.path else {
            // Still checking (the banner's Sign in… looks again): go on once the CLI's path is known.
            AgentCLIDetector.shared.check(k, maxAge: 0) { [weak self] s in
                guard let self, self.setup?.kind == k else { return }
                if s.path != nil { self.signIn() } else { self.setup = Setup(kind: k, step: .install) }
            }
            return
        }
        login?.cancel()
        let l = AgentCLILogin(kind: k, executable: path)
        login = l
        l.onRoute = { [weak self] route in
            guard let self, self.login === l else { return }
            if case .browser(let url) = route {
                self.setup = Setup(kind: k, step: .waiting(browser: url))
                self.controller?.navigate(to: url, newTab: true)
            } else {
                self.setup = Setup(kind: k, step: .waiting(browser: nil))
            }
        }
        l.onDone = { [weak self] ok, why in
            guard let self, self.login === l else { return }
            self.login = nil
            if ok { return self.setupDone() }
            self.setup = why.map { Setup(kind: k, step: .failed($0)) } ?? Setup(kind: k, step: .signIn)
        }
        setup = Setup(kind: k, step: .waiting(browser: nil))
        AgentModelSettings.shared.update { $0.backend = k == .claudeCode ? .claudeCode : .codex }
        l.start()
    }

    /// "Open the sign-in page again" (Codex's page in a tab).
    func reopenSignInPage() {
        guard case .waiting(let url?)? = setup?.step else { return }
        controller?.navigate(to: url, newTab: true)
    }

    func cancelSetup() {
        login?.cancel()
        login = nil
        setup = nil
        keyEntry = nil
        keyError = nil
        pendingTask = nil
    }

    // MARK: An API key, in the pane

    /// "Add key…": the key field in the pane (the task typed so far waits for it).
    func enterKey(_ p: AgentProvider) {
        login?.cancel()
        login = nil
        setup = nil
        keyError = nil
        keyEntry = p
        AgentCenter.shared.onEvent?("key-entry \(p.rawValue)")
    }

    /// Save: into the Keychain (memory only in scripted runs), that provider becomes the agent's, the waiting task goes.
    func saveKey(_ raw: String) {
        guard let p = keyEntry else { return }
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count >= 20, !k.contains(" ") else { keyError = "That doesn't look like a \(p.name) API key."; return }
        guard AgentModelSettings.shared.setKey(k, for: p) else { keyError = "The Keychain didn't save it. Try again, or use Settings › AI."; return }
        AgentModelSettings.shared.update { $0.backend = .apiKey; $0.provider = p }
        keyEntry = nil
        keyError = nil
        providerRevision += 1
        AgentCenter.shared.onEvent?("key-saved \(p.rawValue)")
        guard let t = pendingTask else { return }
        pendingTask = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == t { text = "" }
        if !run.state.isActive { ask(t) }
    }

    /// "Get a key": the provider's key page in a tab.
    func openKeyPage() {
        guard let p = keyEntry, let u = URL(string: p.keyPage) else { return }
        controller?.navigate(to: u, newTab: true)
    }

    /// Ready: the card goes, and the task that waited for it starts.
    private func setupDone() {
        guard let k = setup?.kind else { return }
        setup = nil
        AgentModelSettings.shared.update { $0.backend = k == .claudeCode ? .claudeCode : .codex }
        providerRevision += 1
        AgentCenter.shared.onEvent?("cli-setup-done \(k.rawValue)")
        guard let t = pendingTask else { return }
        pendingTask = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == t { text = "" }
        if run.state.isActive { return }
        ask(t)
    }

    /// The error banner's Sign in…: the failed task is sent again once signed in.
    func signInAfterFailure(_ kind: AgentCLIKind) {
        pendingTask = lastPrompt ?? lastUserText.map(AgentPaneItem.promptText)
        setup = Setup(kind: kind, step: .signIn)
        AgentCLIDetector.shared.check(kind, maxAge: 0)
    }

    /// The CLI a failed run needs signed in (its run ended signed out).
    var signInNeeded: AgentCLIKind? {
        guard case .failed(let m) = run.state, let k = AgentModelSettings.shared.values.backend.cli else { return nil }
        if m == k.loginHint || AgentCLIAuth.looksLikeLogin(m) || m.contains("signed out") { return k }
        if case .notLoggedIn? = AgentCLIDetector.shared.status(k) { return k }
        return nil
    }

    // MARK: The live page

    /// The Agents folder row of the run's current page.
    var liveRowID: String? {
        guard let w = run.runWindowID else { return nil }
        let rows = AgentActivity.shared.model.rows.filter { $0.window == w && $0.isLive }
        let active = AgentCenter.shared.windows[w]?.activeTabID
        return (rows.first { $0.tab == active } ?? rows.last)?.id
    }

    func openWatch() {
        guard let id = liveRowID else { return }
        controller?.sidebar.agents.openWatch(id)
    }

    /// Take over: the agent's page becomes this window's tab; the task waits for Hand back.
    func takeOver() {
        guard let id = liveRowID, let c = controller, let row = AgentActivity.shared.model.row(id) else { return }
        let url = row.url
        let title = row.title.isEmpty ? (url?.host ?? "the page") : row.title
        let before = c.shownTabID
        c.sidebar.agents.takeOver(id)
        // The page is this window's shown tab now (AgentCenter.takeOver shows it); nil if it couldn't move.
        let tab = c.shownTabID != before ? c.shownTabID : nil
        takenOver = TakenOver(title: title, url: url, tabID: tab, agentTabID: row.tab)
        if run.state.isActive { run.stop("You took over the page.") }
    }

    /// Hand back: the same page (its history, scroll and typed text) goes back into the agent's window, and the agent
    /// goes on from it as the person left it.
    func handBack() {
        guard let t = takenOver else { return }
        let extra = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        takenOver = nil
        var msg: String
        if let tabID = t.tabID, let c = controller, c.engineTab(for: tabID) != nil {
            let agentTab = t.agentTabID
            run.handBack = { [weak self, weak c] w in
                guard let c else { return }
                if let why = AgentCenter.shared.handBack(tab: tabID, from: c, into: w, as: agentTab) {
                    c.showToast(why)
                    self?.handBackFailed = why
                }
            }
            msg = "I used the page myself and handed it back: it's the current tab of your window again, as I left it"
            if let u = t.url { msg += " (it was \(u.absoluteString))" }
            msg += ". Read it again (read_page or a screenshot) before continuing; don't open its address again."
        } else {
            // The person closed the tab: the agent opens the address again.
            msg = "I used the page myself and handed it back"
            if let u = t.url { msg += " (\(u.absoluteString))" }
            msg += ". Open it again and read it before continuing."
        }
        if !extra.isEmpty { msg += " " + extra }
        after { self.ask(msg) }
    }

    /// Why the last Hand back couldn't move the page (checks).
    private(set) var handBackFailed: String?

    func stopTask() {
        takenOver = nil
        run.stop()
    }

    /// A site chip: that site in a normal tab of this Space.
    func open(_ site: AgentPaneItem.Site) {
        guard let c = controller, let url = site.url ?? URL(string: "https://\(site.host)") else { return }
        c.navigate(to: url, newTab: true)
    }

    func openAllTasks() { controller.map { AgentTasksPage.open(in: $0) } }

    func copyAnswer() {
        guard let t = run.steps.last(where: { $0.kind == .final })?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }
}

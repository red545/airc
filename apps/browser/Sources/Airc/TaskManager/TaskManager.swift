// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import Darwin

/// P20d: Help › Troubleshooting › Open Task Manager. Arc opens Chrome's: every process of the browser with its memory,
/// CPU and network, and End Process. Chromium's tasks come from its own task manager model (EngineTaskSource); a page
/// in Safari's engine from its web content process (EngineTabProcess), measured with proc_pid_rusage. It samples once a
/// second while the window is open and stops when it closes.
///
/// Private windows: a regular window's Task Manager shows their processes as "Private tab" or "Private window
/// process", without a title or URL, and can't end them. Opened from a private window, it names the pages of that
/// window's own session (its windows share one) and can end their processes; never another session's.
final class TaskManager {
    struct Row: Equatable {
        enum Target: Equatable { case task(Int64), page(ObjectIdentifier), app }
        /// Selection survives a refresh by this.
        let key: String
        let title: String
        let symbol: String
        let profile: String
        let memory: Int64?
        let cpu: Double?
        let network: Int64?
        let pid: pid_t
        /// A process's memory and CPU show on its first row only (its other tasks share them), as in Chrome.
        let firstOfProcess: Bool
        let canEnd: Bool
        let isPrivate: Bool
        let target: Target
    }

    weak var app: AppDelegate?
    /// The private window it was opened from; nil for a main or Little Arc window. Its session is the one named.
    weak var viewer: PrivateWindowController?
    private(set) var rows: [Row] = []
    /// What isn't listed, said plainly (shown under the table).
    private(set) var note = ""
    var onChange: (() -> Void)?

    private var engineTasks: [EngineTask] = []
    private var timer: Timer?
    private var sampler = ProcessSampler()
    private var pagesByKey: [ObjectIdentifier: EngineTab] = [:]
    private var source: EngineTaskSource? { app?.engine as? EngineTaskSource }
    var isRunning: Bool { timer != nil }

    init(app: AppDelegate?) { self.app = app }

    func start() {
        guard timer == nil else { return }
        if let source, source.tasksUnavailableReason == nil {
            source.observeTasks(every: 1) { [weak self] tasks in
                guard let self, self.isRunning else { return }
                let first = self.engineTasks.isEmpty
                self.engineTasks = tasks
                if first { self.refresh() }
            }
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        source?.observeTasks(every: 1, handler: nil)
        engineTasks = []
        pagesByKey = [:]
        sampler = ProcessSampler()
    }

    /// End Process for these rows: each one's process once. Rows that can't be ended are skipped.
    @discardableResult func end(_ ended: [Row]) -> Int {
        var pids = Set<pid_t>(), count = 0
        for row in ended where row.canEnd && pids.insert(row.pid).inserted {
            switch row.target {
            case .task(let id): if source?.endTask(id) == true { count += 1 }
            case .page(let key): if pagesByKey[key]?.endDeveloperProcess() == true { count += 1 }
            case .app: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
        return count
    }

    // MARK: Rows

    /// An open page of Airc's: its profile's name and, for a private window's, that window.
    private struct Owner { let page: EngineTab; let profile: String; let privateWindow: PrivateWindowController? }

    private func owners() -> [Owner] {
        guard let app else { return [] }
        let name = { (page: EngineTab) -> String in
            app.store.profile(app.profiles?.profileID(for: page.profile))?.name ?? ""
        }
        var out: [Owner] = []
        for c in app.controllers { for page in c.pages.values { out.append(Owner(page: page, profile: name(page), privateWindow: nil)) } }
        for l in app.littleArcs { if let page = l.page { out.append(Owner(page: page, profile: name(page), privateWindow: nil)) } }
        for w in PrivateBrowsing.shared.windows {
            for p in w.pages { out.append(Owner(page: p.tab, profile: "Private", privateWindow: w)) }
        }
        return out.filter { !$0.page.isClosed }
    }

    func refresh() {
        guard isRunning else { return }
        let owners = owners()
        var byTabID: [Int: Owner] = [:]
        for o in owners where o.page.developerProcess == .engineTasks { byTabID[o.page.tabID] = o }
        var rows: [Row] = []
        var notes: [String] = []
        var seen = Set<pid_t>()

        if let source {
            if let why = source.tasksUnavailableReason { notes.append(why) }
            for t in engineTasks { rows.append(row(for: t, owner: t.tabID.flatMap { byTabID[$0] }, first: seen.insert(t.pid).inserted)) }
        } else {
            // Safari's engine: Airc's own process is the browser.
            let pid = getpid(), use = sampler.sample(pid)
            rows.append(Row(key: "self", title: "Browser", symbol: "macwindow", profile: "", memory: use.memory, cpu: use.cpu,
                            network: nil, pid: pid, firstOfProcess: seen.insert(pid).inserted, canEnd: false, isPrivate: false,
                            target: .app))
        }

        // Pages in Safari's engine (all of them in a WebKit build; DRM services' in a Chromium one).
        var webKitPages = 0
        var unnamed = Set<String>()
        var map: [ObjectIdentifier: EngineTab] = [:]
        var byProcess: [(pid: pid_t, owners: [Owner])] = []
        for o in owners {
            switch o.page.developerProcess {
            case .engineTasks, .notRunning: continue
            case .unnamed(let why): unnamed.insert(why)
            case .process(let pid):
                webKitPages += 1
                if let i = byProcess.firstIndex(where: { $0.pid == pid }) { byProcess[i].owners.append(o) }
                else { byProcess.append((pid, [o])) }
            }
        }
        for (pid, group) in byProcess {
            let use = sampler.sample(pid)
            for o in group {
                let key = ObjectIdentifier(o.page)
                map[key] = o.page
                let isPrivate = o.privateWindow != nil, own = isPrivate && isViewers(o)
                let shows = !isPrivate || own
                let first = seen.insert(pid).inserted
                rows.append(Row(key: "page-\(pid)-\(o.page.tabID)", title: shows ? Self.tabTitle(o.page.title, private: isPrivate) : "Private tab",
                                symbol: isPrivate ? "eyeglasses" : "doc.richtext", profile: o.profile,
                                memory: first ? use.memory : nil, cpu: first ? use.cpu : nil, network: nil, pid: pid,
                                firstOfProcess: first, canEnd: shows, isPrivate: isPrivate, target: .page(key)))
            }
        }
        pagesByKey = map
        sampler.forget(except: Set(byProcess.map(\.pid)).union([getpid()]))
        if webKitPages > 0 || source == nil {
            notes.append("Safari's engine doesn't report network use per page, and its shared network and GPU processes aren't listed.")
        }
        notes.append(contentsOf: unnamed.sorted())
        if viewer == nil, rows.contains(where: \.isPrivate) {
            notes.append("Private windows' processes show without their pages. Open the Task Manager from a private window to see and end its own.")
        }
        let note = notes.joined(separator: " ")
        guard rows != self.rows || note != self.note else { return }
        self.rows = rows
        self.note = note
        onChange?()
    }

    private func row(for t: EngineTask, owner: Owner?, first: Bool) -> Row {
        let isPrivate = t.offTheRecord || owner?.privateWindow != nil
        // Its own session's pages only: a private task without one of their tabs stays nameless (a worker could be
        // any session's).
        let own = isPrivate && owner.map(isViewers) == true
        let title: String
        if !isPrivate { title = t.title }
        else if own { title = t.title.hasPrefix("Incognito Tab: ") ? "Private Tab: " + t.title.dropFirst(15) : t.title }
        else { title = t.tabID != nil ? "Private tab" : "Private window process" }
        return Row(key: "task-\(t.id)", title: title, symbol: isPrivate ? "eyeglasses" : Self.symbol(t.kind),
                   profile: isPrivate ? "Private" : owner?.profile ?? t.profileName,
                   memory: first ? t.memory : nil, cpu: first ? t.cpu : nil, network: t.network, pid: t.pid,
                   firstOfProcess: first, canEnd: t.killable && (!isPrivate || own), isPrivate: isPrivate,
                   target: .task(t.id))
    }

    /// A page of the viewer's private session.
    private func isViewers(_ o: Owner) -> Bool {
        guard let viewer, o.privateWindow != nil else { return false }
        return o.page.profile === viewer.profile
    }

    static func tabTitle(_ title: String, private isPrivate: Bool) -> String {
        (isPrivate ? "Private Tab: " : "Tab: ") + (title.isEmpty ? "Untitled" : title)
    }

    private static func symbol(_ kind: EngineTask.Kind) -> String {
        switch kind {
        case .browser: return "macwindow"
        case .gpu: return "cpu"
        case .utility: return "gearshape"
        case .renderer, .guest: return "doc.richtext"
        case .extension: return "puzzlepiece.extension"
        case .worker: return "gearshape.2"
        case .other: return "square.dashed"
        }
    }
}

/// Memory footprint and CPU of a process of ours (proc_pid_rusage, public libproc), as Chrome's Task Manager shows
/// them: footprint bytes, and CPU as a percentage of one core since the last sample.
struct ProcessSampler {
    private var last: [pid_t: (cpu: UInt64, at: UInt64)] = [:]

    mutating func sample(_ pid: pid_t) -> (memory: Int64?, cpu: Double?) {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        } == 0
        guard ok else { last[pid] = nil; return (nil, nil) }
        // CPU times and mach_absolute_time are in the same units (Mach ticks on Apple silicon, ns on Intel), so their
        // ratio needs no timebase.
        let cpu = info.ri_user_time + info.ri_system_time, now = mach_absolute_time()
        defer { last[pid] = (cpu, now) }
        guard let l = last[pid], now > l.at, cpu >= l.cpu else { return (Int64(info.ri_phys_footprint), nil) }
        return (Int64(info.ri_phys_footprint), Double(cpu - l.cpu) / Double(now - l.at) * 100)
    }

    mutating func forget(except kept: Set<pid_t>) { last = last.filter { kept.contains($0.key) } }
}

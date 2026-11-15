// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// cbfirstkey: the menu bar's commands for the Command Bar, prepared before a key needs them.
///
/// Finding them means walking every menu, updating it (its delegate titles items, AppKit adds its own) and asking each
/// item whether it would do something here (ParityCommandCatalog). That was 20–170 ms of main-thread work, done on the
/// first keystroke of every opening (the list was kept for one second). Menus and their validation are AppKit's and
/// main-thread only, so the index does that work at idle instead, in slices of at most `sliceBudget`, after anything
/// that could change it; the text the bar matches is folded off the main thread.
///
/// The bar uses a prepared list only while it is the one the synchronous path would make: built in the last second
/// (what the old one-second cache allowed), or with nothing that could change it since its build began. Otherwise the
/// key finishes the work itself, as before. Callers other than the bar's keys (checks, `/`) get the synchronous path.
/// Main thread only, like the window controller it belongs to.
final class CommandIndex {
    /// The menu bar's commands as `WindowController.makeMenuCommandActions()` made them, and when that began.
    private(set) var actions: [WindowController.CommandAction]?
    private var builtAt: CFTimeInterval = 0
    /// Bumped by anything that may change which commands work, their titles or the menus: a store change or a shown
    /// tab (the spare bar's refresh triggers), the window becoming key or not, a menu item added or removed.
    private(set) var generation = 0
    private var builtGeneration = -1
    private var job: Job?
    private var scheduled = false
    private weak var controller: WindowController?

    /// One main-thread slice of a rebuild: one 120 Hz frame has 8.3 ms; a slice leaves most of it.
    static let sliceBudget: CFTimeInterval = 0.002

    init(controller: WindowController) {
        self.controller = controller
        Self.observeMenus()
        Self.all.add(self)
    }

    // MARK: Use

    /// The bar's list, prepared, if it is still the one the synchronous path would make now; nil when it isn't.
    func preparedActions(now: CFTimeInterval = CACurrentMediaTime()) -> [WindowController.CommandAction]? {
        guard let actions else { return nil }
        if builtGeneration == generation || now - builtAt < 1 { return actions }
        return nil
    }

    /// The list made now, synchronously (the bar's key when nothing valid is prepared): kept as the prepared one.
    func store(_ list: [WindowController.CommandAction], startedAt: CFTimeInterval) {
        job = nil   // a rebuild under way would only make the same list again
        actions = list
        builtAt = startedAt
        builtGeneration = generation
        Self.prepareSearchText(list)
    }

    // MARK: The bar's command candidates (cbrows)

    /// The Command Bar's commands as ranking candidates, and which of them the last query matched (`narrowing`). Made
    /// again whenever the list a key makes differs from the one it was made from in a title or a word: a store change,
    /// another tab or Space, a menu rebuilt, a setting. That comparison is the invalidation, so nothing that changes
    /// the commands can leave a stale candidate. Rows are never kept: they are made from each key's own list.
    final class CommandBlock {
        let candidates: [CommandSearch.Candidate]
        /// Each candidate's id → the index of the last command with that title, whose row it shows (the old
        /// dictionary's last-write rule for two commands of one title).
        let lastIndex: [String: Int]
        private let titles: [String]
        private let keywords: [[String]]
        /// What the last query matched among `candidates` (CommandSearch.rank's narrowing): reset with the block.
        var narrowing: CommandSearch.Narrowing?

        init(_ list: [WindowController.CommandAction]) {
            var c: [CommandSearch.Candidate] = [], last: [String: Int] = [:]
            c.reserveCapacity(list.count)
            last.reserveCapacity(list.count)
            for (i, a) in list.enumerated() {
                let id = "action:" + a.title
                c.append(.init(id: id, kind: .action, title: a.title, keywords: a.keywords))
                last[id] = i
            }
            candidates = c
            lastIndex = last
            titles = list.map(\.title)
            keywords = list.map(\.keywords)
        }

        func matches(_ list: [WindowController.CommandAction]) -> Bool {
            guard list.count == titles.count else { return false }
            for (i, a) in list.enumerated() where a.title != titles[i] || a.keywords != keywords[i] { return false }
            return true
        }
    }
    private var block: CommandBlock?
    /// Blocks made (cbperf reports it: one per change of the commands, not one per key).
    private(set) var blocksMade = 0

    /// The block for this key's commands: the last one while they are the same, else a new one.
    func commandBlock(for list: [WindowController.CommandAction]) -> CommandBlock {
        if let block, block.matches(list) { return block }
        let made = CommandBlock(list)
        block = made
        blocksMade += 1
        return made
    }

    // MARK: Invalidation and rebuilding

    /// Something may have changed the commands: the prepared list stays usable for the rest of its second, and a
    /// rebuild runs at the next idle moment (a rebuild under way finishes first, then another starts).
    func invalidate() {
        generation &+= 1
        schedule(after: 0.15)
    }

    /// A rebuild soon, at idle (launch: after the first frames; then after each invalidation).
    func schedule(after delay: TimeInterval) {
        guard !scheduled, job == nil else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.step()
        }
    }

    /// One slice of the rebuild; then the next, a run-loop turn (and a frame) later.
    private func step() {
        guard let c = controller, c.window.isVisible || c.window.isMiniaturized else { job = nil; return }
        if job == nil {
            // Up to date already: nothing changed since the last build began.
            if actions != nil, builtGeneration == generation { return }
            job = Job(controller: c, generation: generation)
        }
        guard let j = job else { return }
        // Not while the sidebar pages, the window resizes or something animates: those frames are spoken for.
        if c.isBusyForIdleWork {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.step() }
            return
        }
        if !Self.spellingPanelReady {
            // Once per process, a slice of its own: AppKit's spelling panel. Validating Edit › Show Spelling and Grammar
            // (a text view or a page has it: Show or Hide) makes the panel, a nib and a SwiftUI layout: 140–160 ms the
            // first time, which every first keystroke in the bar used to pay (cbfirstkey's profile). AppKit makes it
            // the first time anything validates that item; here that happens at idle, at a moment of Airc's choosing.
            Self.spellingPanelReady = true
            let t0 = CACurrentMediaTime()
            Perf.time("cb.index.spelling") { _ = NSSpellChecker.shared.spellingPanel }
            stats.spellingPanelMs = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in self?.step() }
            return
        }
        let t0 = CACurrentMediaTime()
        let deadline = t0 + Self.sliceBudget
        Self.rebuilding = true
        let done = Perf.time("cb.index.slice") { j.run(until: deadline) }
        Self.rebuilding = false
        let ms = (CACurrentMediaTime() - t0) * 1000
        stats.slices += 1
        stats.maxSliceMs = max(stats.maxSliceMs, ms)
        guard job === j else { return }
        guard done else {
            // A timer, not `async`: the main queue drains before the run loop's Core Animation commit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in self?.step() }
            return
        }
        job = nil
        // Usable for its second even if something changed meanwhile; then rebuilt again.
        let changed = j.generation != generation
        actions = j.result
        builtAt = j.startedAt
        builtGeneration = j.generation
        stats.builds += 1
        // The next slice: every command's words folded off the main thread, and (once) the bar's first-key paths.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self, weak c] in
            guard let self, let c, self.job == nil else { return }
            let t0 = CACurrentMediaTime()
            Perf.time("cb.index.warm") {
                if !Self.pathsWarm {
                    Self.pathsWarm = true
                    c.warmCommandBarPaths()
                }
                Self.prepareSearchText(c.commandActions(prepared: true))
            }
            self.stats.maxSliceMs = max(self.stats.maxSliceMs, (CACurrentMediaTime() - t0) * 1000)
            if changed { self.schedule(after: 0.15) }
        }
    }

    /// What the idle rebuilds cost on the main thread (cbperf reports it).
    struct Stats { var builds = 0, slices = 0, maxSliceMs = 0.0, spellingPanelMs = -1.0 }
    private(set) var stats = Stats()
    private static var spellingPanelReady = false
    private static var pathsWarm = false

    /// The rebuild, resumable: the walk, then each menu's update, then each item's validation, in the same order and
    /// with the same per-item code as `WindowController.makeMenuCommandActions()`.
    private final class Job {
        let generation: Int
        let startedAt = CACurrentMediaTime()
        private weak var controller: WindowController?
        private var entries: [ParityCommandCatalog.Entry]?
        private var menus: [NSMenu] = []
        private var nextMenu = 0
        private var nextEntry = 0
        private(set) var result: [WindowController.CommandAction] = []

        init(controller: WindowController, generation: Int) {
            self.controller = controller
            self.generation = generation
        }

        /// Works until `deadline` (at least one unit); true when the list is complete.
        func run(until deadline: CFTimeInterval) -> Bool {
            guard let c = controller else { return true }
            repeat {
                guard let entries else {
                    let e = ParityCommandCatalog.entries(of: NSApp.mainMenu)
                    entries = e
                    var seen = Set<ObjectIdentifier>()
                    menus = e.compactMap(\.item.menu).filter { seen.insert(ObjectIdentifier($0)).inserted }
                    continue
                }
                if nextMenu < menus.count {
                    menus[nextMenu].update()
                    nextMenu += 1
                    continue
                }
                guard nextEntry < entries.count else { return true }
                if let a = c.menuCommandAction(entries[nextEntry]) { result.append(a) }
                nextEntry += 1
            } while CACurrentMediaTime() < deadline
            return entries.map { nextMenu >= menus.count && nextEntry >= $0.count } ?? false
        }
    }

    // MARK: Menus

    private static let all = NSHashTable<CommandIndex>.weakObjects()
    private static var observing = false
    /// A slice is updating menus: items AppKit or a delegate adds then are part of this build, not a change after it.
    private static var rebuilding = false

    /// A menu item added or removed anywhere (a Space renamed in Spaces, a Live Folder, the system's own items):
    /// every window's list may change.
    private static func observeMenus() {
        guard !observing else { return }
        observing = true
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                // Menus are changed on the main thread, which posts these there.
                guard Thread.isMainThread, !rebuilding else { return }
                for i in all.allObjects { i.invalidate() }
            }
        }
    }

    // MARK: Off the main thread

    /// The titles and words the bar matches, folded once off the main thread, so the first key doesn't fold them.
    private static func prepareSearchText(_ list: [WindowController.CommandAction]) {
        let texts = list.flatMap { [$0.title] + $0.keywords }
        DispatchQueue.global(qos: .utility).async { CommandSearch.prepare(texts) }
    }
}

extension WindowController {
    private static var commandIndexKey: UInt8 = 0

    /// Once per process, at idle: what the bar's first keystroke would otherwise do for the first time. A dry run of its
    /// results for a query (Swift metadata and conformances, the actions' builders, ranking), and the official-site
    /// mark drawn for the window's theme (an SF Symbol's first rendering: 1–2 ms in cbfirstkey's profile).
    func warmCommandBarPaths() {
        _ = barCommandResults(for: "a", mode: .newTab, inline: nil, inlineSite: nil, suggestions: [], history: [])
        let scale = window.backingScaleFactor
        if let seal = LayerImage.symbol("checkmark.seal.fill", size: 12, weight: .semibold, color: currentPalette.resolved.accent.nsColor) {
            _ = seal.layerContents(forContentsScale: seal.recommendedLayerContentsScale(scale))
        }
    }

    /// This window's prepared commands (CommandIndex).
    var commandIndex: CommandIndex {
        if let i = objc_getAssociatedObject(self, &Self.commandIndexKey) as? CommandIndex { return i }
        let i = CommandIndex(controller: self)
        objc_setAssociatedObject(self, &Self.commandIndexKey, i, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return i
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

/// Tidy Tabs (Arc's broom, audit row A06, docs/user/ai.md): "Tidy" in the Today header, or "Tidy Tabs" in the Command
/// Bar, sorts the Space's Today tabs into folders by topic, named by Apple's on-device model, in one step that ⌘Z puts
/// back (also after a relaunch). AircKit's TidyTabs.swift has the rules, the planner and the undo record.
///
/// - No Apple Intelligence, no Tidy (owner decision 2026-11-09): the header has no Tidy and the Command Bar no entry.
/// - Only the Space's Today web pages are read: their titles (counts and email addresses out) and hosts. Pinned tabs,
///   folders, Favorites and splits are never read, moved or renamed. Private windows have their own sidebar (no Today
///   header, no store), so their pages never reach any of this.
/// - The folders go at the top of Today, as in Arc (Today folders, AircKit's TodayFolders.swift): the tidied tabs stay
///   Today tabs, so they still auto-archive and Clear still clears them, and a folder goes with its last tab.
/// - Nothing changes until the model has answered for the whole list. "Tidying…" (the label while it works) stops it,
///   as does Stop Tidying Tabs in the Command Bar; a stopped tidy changes nothing.
@MainActor
enum TidyTabsFeature {
    /// Scripted runs (Debug/ParityP18bCheck.swift): whether Apple Intelligence counts as on, and the model to use.
    static var testOverride: (available: Bool, model: (any TidyTabsModel)?)? {
        didSet { refreshAllDividers() }
    }
    static var options = TidyTabsPlanner.Options()

    /// A tidy under way, per Space (one at a time each).
    private static var running: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// What each Space's last tidy ended with, and the last message shown (the scripted check reads them).
    private(set) static var lastOutcome: [String: TidyTabsOutcome] = [:]
    private(set) static var lastMessage: String?
    private static var prewarmed = false

    static var isAvailable: Bool {
        testOverride.map(\.available) ?? AppleIntelligence.availability.isAvailable
    }

    private static func model() -> (any TidyTabsModel)? {
        if let o = testOverride { return o.available ? o.model : nil }
        return TidyTabsModels.onDevice()
    }

    static func isRunning(_ spaceID: String) -> Bool { running[spaceID] != nil }

    /// Whether the Space has two different web pages in Today, so a tidy could make a folder. Cheap: no titles read.
    static func hasEnoughTabs(_ store: SpacesStore, spaceID: String) -> Bool {
        hasEnoughTabs(in: store.todayRows(ofSpace: spaceID))
    }

    /// Render already has the ordered entries. Eligibility needs neither another
    /// sort nor titles; reuse that snapshot for the divider and subsequent hover.
    static func hasEnoughTabs<S: Sequence>(in entries: S) -> Bool where S.Element == SidebarEntry {
        // Loose Today tabs only: tabs in Today folders don't count (AircKit's TidyTabsRules.hasEnoughPages), read from the
        // same rows, no scan of their own.
        TidyTabsRules.hasEnoughPages(in: entries)
    }

    /// The Tidy label's click: starts a tidy of the Space's Today, or stops the one under way.
    static func toggle(in c: WindowController, spaceID: String) {
        if isRunning(spaceID) { cancel(spaceID: spaceID) } else { start(in: c, spaceID: spaceID) }
    }

    static func start(in c: WindowController, spaceID: String) {
        guard running[spaceID] == nil, c.store.space(spaceID) != nil else { return }
        guard let model = model() else {
            return say("Tidy Tabs needs Apple Intelligence", in: c)
        }
        let candidates = c.store.tidyCandidates(inSpace: spaceID)
        let opts = Self.options
        let token = UUID()
        weak var window = c
        let task = Task { @MainActor in
            let planned = await TidyTabsPlanner.plan(spaceID: spaceID, candidates: candidates, model: model, options: opts)
            // Stopped after the model answered, or the window closed meanwhile: nothing changes either.
            let outcome: TidyTabsOutcome = Task.isCancelled || window == nil ? .cancelled : planned
            guard running[spaceID]?.token == token else { return }
            running[spaceID] = nil
            finish(outcome, spaceID: spaceID, in: window)
        }
        running[spaceID] = (token, task)
        refreshDividers(spaceID)
    }

    /// Stops the Space's tidy: the model's answer, when it comes, is dropped and nothing changes.
    static func cancel(spaceID: String) {
        guard let r = running.removeValue(forKey: spaceID) else { return }
        r.task.cancel()
        lastOutcome[spaceID] = .cancelled
        refreshDividers(spaceID)
    }

    private static func finish(_ outcome: TidyTabsOutcome, spaceID: String, in c: WindowController?) {
        lastOutcome[spaceID] = outcome
        defer { refreshDividers(spaceID) }
        guard let c else { return }
        switch outcome {
        case .plan(let plan):
            do {
                guard let record = try c.store.applyTidyTabs(plan) else {
                    return say("Your tabs changed while tidying, so nothing was moved", in: c)
                }
                // The new folders are at the top of Today; the tabs in them are still Today tabs.
                let n = record.moved.count, f = record.folderIDs.count
                say("Grouped \(n) \(n == 1 ? "tab" : "tabs") into \(f) \(f == 1 ? "folder" : "folders"). ⌘Z to undo", in: c)
            } catch {
                say("Couldn’t tidy tabs", in: c)
            }
        case .tooFewTabs:
            say("Open a few more tabs to tidy", in: c)
        case .noFolders:
            say("No tab groups found", in: c)   // Arc's words
        case .declined:
            say("Apple Intelligence couldn’t sort these tabs", in: c)
        case .failed, .timeout:
            say("Couldn’t tidy tabs. Try again", in: c)
        case .cancelled:
            break
        }
    }

    private static func say(_ message: String, in c: WindowController) {
        lastMessage = message
        c.showToast(message)
    }

    /// Loads the model once a Tidy label first shows, so the click doesn't wait for it.
    static func prewarmOnce() {
        guard !prewarmed, testOverride == nil else { return }
        prewarmed = true
        TidyTabsModels.prewarm()
    }

    // MARK: The Today header

    /// The Tidy labels showing this Space (every window) follow its state.
    static func refreshDividers(_ spaceID: String) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        for w in app.controllers {
            guard let d = w.pageView(for: spaceID)?.rows["divider"] as? DividerRowView else { continue }
            d.tidy.refresh(hovered: d.sidebarHovered, divider: d)
            d.needsLayout = true
        }
    }

    static func refreshAllDividers() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        for w in app.controllers {
            for id in w.store.state.spaces.keys { refreshDividers(id) }
        }
    }
}

/// "Tidy" in the Today header, left of Clear (Arc's place and tooltip, "Organize Today Tabs"): shown with Clear while
/// the pointer is over the sidebar, when Apple Intelligence is on and Today has two web pages or more. While the model
/// works it reads "Tidying…" (pulsing, shown without the pointer too) and a click stops it.
final class TidyTabsLabel: NSView {
    private let text = NSTextField(labelWithString: "Tidy")
    private weak var divider: DividerRowView?
    private var pointerOver = false
    private(set) var isWorking = false
    /// A tracking area of its own: the divider's tracks the row for Clear.
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        text.font = AircFont.micro.appFont
        addSubview(text)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// From the divider's configure and hover, and from the feature when a tidy starts or ends.
    func refresh(hovered: Bool, divider d: DividerRowView) {
        divider = d
        let sid = d.spaceID
        isWorking = TidyTabsFeature.isRunning(sid)
        let show = isWorking || (hovered && TidyTabsFeature.isAvailable
                                 && (d.tidyHasEnoughPages ?? d.controller.map { TidyTabsFeature.hasEnoughTabs($0.store, spaceID: sid) } ?? false))
        if show, !isWorking { TidyTabsFeature.prewarmOnce() }
        let title = isWorking ? "Tidying…" : "Tidy"
        if text.stringValue != title { text.stringValue = title; text.sizeToFit() }
        toolTip = isWorking ? "Stop tidying" : "Organize Today Tabs"
        setAccessibilityLabel(isWorking ? "Stop tidying tabs" : "Tidy Today tabs")
        if isHidden == show { isHidden = !show }
        recolor()
        if isWorking, text.layer?.animation(forKey: "pulse") == nil {
            text.wantsLayer = true
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.35
            a.duration = 0.7
            a.autoreverses = true
            a.repeatCount = .infinity
            text.layer?.add(a, forKey: "pulse")
        } else if !isWorking {
            text.layer?.removeAnimation(forKey: "pulse")
        }
    }

    private func recolor() {
        guard let p = divider?.palette else { return }
        let ink = pointerOver || isWorking ? p.clearHover : p.clearIdle
        if text.textColor != ink { text.textColor = ink }
    }

    /// Puts the label just left of `right` (the divider's x where Clear starts), centred on `midY`; returns where the
    /// divider's line now ends.
    func place(right: CGFloat, midY: CGFloat) -> CGFloat {
        guard !isHidden else { return right }
        text.sizeToFit()
        let s = text.frame.size
        frame = NSRect(x: right - s.width, y: midY - s.height / 2, width: s.width, height: s.height)
        text.frame = NSRect(origin: .zero, size: s)
        return frame.minX - 8
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let sv = superview else { return nil }
        let p = convert(point, from: sv)
        return bounds.insetBy(dx: -4, dy: -4).contains(p) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let d = divider, let c = d.controller else { return }
        TidyTabsFeature.toggle(in: c, spaceID: d.spaceID)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let d = divider, let c = d.controller else { return false }
        TidyTabsFeature.toggle(in: c, spaceID: d.spaceID)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds.insetBy(dx: -4, dy: -4), options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { pointerOver = true; recolor() }
    override func mouseExited(with event: NSEvent) { pointerOver = false; recolor() }
}

extension WindowController {
    /// The Command Bar's Tidy Tabs (registered by ParityCommandCatalog, as P20c's blocking commands are): "Tidy Tabs" for
    /// the Space on screen, or "Stop Tidying Tabs" while it's being tidied. None without Apple Intelligence.
    func tidyTabsCommandActions() -> [CommandAction] {
        MainActor.assumeIsolated {
            let sid = currentSpaceID
            if TidyTabsFeature.isRunning(sid) {
                return [CommandAction(title: "Stop Tidying Tabs", symbol: "xmark.circle", hint: "",
                                      keywords: ["tidy", "cancel", "stop", "organize"]) { TidyTabsFeature.cancel(spaceID: sid) }]
            }
            guard TidyTabsFeature.isAvailable, TidyTabsFeature.hasEnoughTabs(store, spaceID: sid) else { return [] }
            return [CommandAction(title: "Tidy Tabs", symbol: "sparkles", hint: "",
                                  keywords: ["tidy", "organize", "organise", "group", "sort", "folders", "clean up", "today", "ai",
                                             "apple intelligence"]) { [weak self] in
                guard let self else { return }
                TidyTabsFeature.start(in: self, spaceID: sid)
            }]
        }
    }

    /// ⌘Z when the store's own undo has nothing (after a relaunch): puts back the Space's last tidy, if one of its
    /// folders still holds one of its tabs. False when there's none (⌘Z beeps as before).
    func undoTidyTabsFromRecord() -> Bool {
        MainActor.assumeIsolated {
            guard let r = store.tidyUndo(inSpace: currentSpaceID),
                  let restored = try? store.undoTidyTabs(r), !restored.isEmpty else { return false }
            showToast("Undid Tidy Tabs")
            return true
        }
    }
}

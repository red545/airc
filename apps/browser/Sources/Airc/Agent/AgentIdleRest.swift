// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// agentparkcpu: an agent page nobody sees and nothing uses rests at the engine's hidden-page rate.
///
/// The agent's pages are kept visible for the engine although nothing shows them (WebKit: occlusion detection off;
/// Chromium: focus emulation and its visible capturer), so they animate and paint at full rate in their off-screen
/// agent window: three parked tasks on animating pages cost the app ~9 % and WebKit's page processes ~13 % CPU, and
/// Chromium's helpers ~40 % (agentparallel's "three tasks parked, idle", MEM-6). A page in an agent window (parked, or
/// an outside app's) that no tool call, agent input, Watch or card copy has needed for `idleAfter` seconds goes back to
/// the engine's own behaviour for a window off screen (no frames, no rAF). Whatever needs it again (AgentCenter's tool
/// calls, the drivers' input and copies, Watch's keepLive) wakes it first, so the agent's own work is never slowed.
/// A page in a person's window (shown in the main view) is never rested.
final class AgentIdleRest {
    static var enabled = true
    static var idleAfter: Double = 5
    /// Rests the page (the engine's hidden behaviour); wakes it (kept visible again).
    private let rest: (EngineTab) -> Void
    private let wake: (EngineTab) -> Void
    /// Pages that must draw, by id: until when, and the page.
    private var needed: [ObjectIdentifier: (until: CFTimeInterval, tab: () -> EngineTab?)] = [:]
    private var resting: Set<ObjectIdentifier> = []
    private var timer: Timer?
    #if AIRC_TESTING
    /// Checks: pages rested and woken since launch.
    private(set) var rests = 0
    private(set) var wakes = 0
    #endif

    init(rest: @escaping (EngineTab) -> Void, wake: @escaping (EngineTab) -> Void) {
        self.rest = rest
        self.wake = wake
    }

    func isResting(_ tab: EngineTab) -> Bool { resting.contains(ObjectIdentifier(tab)) }

    /// The page must draw now and for `seconds` + `idleAfter` more (a kept-visible page only: the driver asks).
    func need(_ tab: EngineTab, for seconds: Double = 0) {
        let id = ObjectIdentifier(tab)
        let until = CACurrentMediaTime() + max(0, seconds) + Self.idleAfter
        if resting.remove(id) != nil {
            wake(tab)
            #if AIRC_TESTING
            wakes += 1
            #endif
        }
        if let n = needed[id], n.until >= until { return }
        weak var page = tab
        needed[id] = (until, { page })
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The page stops being kept (released, handed back, closed): nothing of it is tracked any more.
    func forget(_ tab: EngineTab) {
        needed[ObjectIdentifier(tab)] = nil
        resting.remove(ObjectIdentifier(tab))
    }

    private func tick() {
        // Off (checks' A arm): pages stay tracked, so turning it on rests them.
        guard Self.enabled else { return }
        let now = CACurrentMediaTime()
        for (id, n) in needed where n.until <= now {
            needed[id] = nil
            guard let tab = n.tab(), !tab.isClosed, tab.view.window is AgentHostWindow else { continue }
            resting.insert(id)
            rest(tab)
            #if AIRC_TESTING
            rests += 1
            #endif
        }
        if needed.isEmpty { timer?.invalidate(); timer = nil }
    }
}

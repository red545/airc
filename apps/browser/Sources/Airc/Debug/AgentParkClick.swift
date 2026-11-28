// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// agentparkclick (docs/design/agent-ux.md §5): opt-in case `AIRC_AGENTPARALLEL_ONLY=askswitch` of `--script
/// agentparallel`. A task asked in Space A, and the window switched to Space B at once (before the task's agent window
/// opens): the task's page is a Today row of Space A (the Space it was asked in), parked, and the window stays in B; the
/// agent's two clicks while it's parked both count, none is refused; back in A, picking the row brings the same page
/// (no reload, its count kept).
extension AgentParallelCheck {
    func caseAskSwitch(_ done: @escaping () -> Void) {
        events = []
        let a = home!
        let aSpace = a.currentSpaceID
        let profile = a.store.profile(ofSpace: aSpace)
        guard let made = try? a.store.createSpace(name: "Ask other", icon: nil, theme: a.store.selectedSpace.theme, profileID: profile.id, after: aSpace) else {
            check(false, "askswitch: a second Space of the window's profile"); return done()
        }
        let bSpace = made.id
        a.window.makeKeyAndOrderFront(nil)
        var log: [String] = []
        let mainBefore = main.onEvent
        main.onEvent = { e in log.append(e); mainBefore?(e) }
        func finish() { main.onEvent = mainBefore; after(0.4, done) }
        after(0.6) { [self] in
            guard let r = start("q1", tally(1, "q1 done.", holds: 3), task: "Count on tally page 1", in: a) else {
                check(false, "askswitch: task q1 starts in Space A"); return finish()
            }
            // At once, in the same turn of the run loop: the agent window can't have opened yet (⌥⌘→'s own code path).
            let openedBefore = main.entry(for: r) != nil
            a.switchSpace(offset: 1)
            check(!openedBefore && a.currentSpaceID == bSpace, "askswitch: asked in Space A, the window is in Space B before the task's page exists (page \(openedBefore ? "already there" : "not yet"))")
            wait({ self.main.entry(for: r) != nil }, 8) { [self] in
                let e = main.entry(for: r)
                let tabSpace = e.flatMap { a.store.tab($0.tabID)?.spaceID }
                check(tabSpace == aSpace, "askswitch: the task's page is a tab of Space A, where it was asked (\(tabSpace == aSpace ? "A" : tabSpace == bSpace ? "B" : tabSpace.map { String($0.prefix(6)) } ?? "no tab"); \(log.filter { $0.hasPrefix("present") }))")
                check(a.currentSpaceID == bSpace, "askswitch: … and the window stays in Space B (no switch by itself)")
                let parked = e.flatMap { h in h.page.map { h.window?.isParked($0) == true } } ?? false
                check(parked && a.shownTabID != e?.tabID, "askswitch: … parked, not in B's main view (parked \(parked))")
                wait({ !r.isBusy }, 30) { [self] in
                    let answer = r.steps.last { $0.kind == .final }?.text ?? ""
                    check(r.state == .done && answer == "q1 done.", "askswitch: q1 runs to its own answer while parked (\(r.state), “\(answer)”)")
                    let refused = r.steps.filter { $0.detail?.contains("The page moved since your last look") == true }.count
                    read("window.counts||0", on: page(r) ?? tabPage(r)) { [self] n in
                        check(n == 2 && refused == 0, "askswitch: both of its clicks reached the parked page (count \(n), \(refused) refused)")
                        toSpace(a, aSpace, "cmd+opt+left") { [self] how in
                            guard let id = e?.tabID, a.store.tab(id) != nil else {
                                check(false, "askswitch: back in Space A, the task's row is there [\(how)]"); return finish()
                            }
                            a.show(id)
                            after(0.8) { [self] in
                                let same = a.engineTab(for: id) === (page(r) ?? tabPage(r))
                                read("window.counts||0", on: a.engineTab(for: id)) { [self] n in
                                    check(a.shownTabID == id && same && n == 2, "askswitch: back in Space A, picking its row brings the same page, not reloaded (count \(n), same page \(same)) [\(how)]")
                                    finish()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// agentmainfix, part of `--script agentmain` (`AIRC_AGENTMAIN_ONLY=rows`): finished tasks leave proper rows and pictures.
/// Three tasks after each other (the third one's navigate is refused, so its page never loads) from ⌘T → Ask (as the agent-tasks-ask marketing shot runs them: navigate, read, answer):
/// Today never keeps an "about:blank" row of an agent task, each task's row is its page (address and title), and each
/// finished task has its card picture (Recent tasks show the page, not the globe placeholder).
extension AgentMainCheck {
    func caseRows(_ done: @escaping () -> Void) {
        k.extraPages["/am-park.html"] = Self.colour("Parks of Brightport", "#2e9e5b")
        k.extraPages["/am-audio.html"] = Self.colour("Headphones", "#d05a2e")
        let space = c.currentSpaceID
        let before = Set(c.store.todayTabs(ofSpace: space).map(\.id))
        var tasks: [(id: String, path: String)] = []
        func rows() -> String {
            c.store.todayTabs(ofSpace: space).map { t in
                "\(t.id.prefix(6)) \(t.url.isEmpty ? "-" : t.url) “\(t.title)” page \(c.engineTab(for: t.id)?.url?.absoluteString ?? "none")"
            }.joined(separator: " | ")
        }
        /// `refused`: the navigate goes to a relative address (refused: the page never loads), as the agent-tasks-ask
        /// shot's first two tasks did.
        func task(_ name: String, _ prompt: String, _ path: String, refused: Bool = false, _ next: @escaping () -> Void) {
            k.fake.begin(name, [.tool("navigate", ["url": refused ? path : "\(base)\(path)"]), .tool("read_page", ["mode": "text"]), .text("Done with \(path).")])
            k.setKeys(anthropic: true)
            run.newConversation()
            CommandBarView.startAgentTask(prompt, attached: [], in: c)
            wait({ !self.run.state.isActive && self.run.steps.contains { $0.kind == .final } }, 30) { [self] in
                if !refused, let id = AgentTaskRecorder.shared.currentID { tasks.append((id, path)) }
                note("agentmain \(engine): rows after \(name): \(rows()); events \(mainEvents.suffix(6))")
                after(0.6, next)
            }
        }
        task("rows1", "Find the largest park", "/am-park.html") { [self] in
            task("rows2", "Compare headphones", "/am-audio.html") { [self] in
              task("rows3", "Open a page that never loads", "/am-nowhere.html", refused: true) { [self] in
                check(mainEvents.contains { $0.hasPrefix("drop-blank") }, "rows: a task whose page never loaded drops its blank tab when it ends (\(mainEvents.filter { $0.hasPrefix("drop-blank") }.count))")
                run.newConversation()
                after(2.5) { [self] in
                    note("agentmain \(engine): rows at the end: \(rows())")
                    let new = c.store.todayTabs(ofSpace: space).filter { !before.contains($0.id) }
                    let blank = new.filter { $0.url.isEmpty || $0.url == "about:blank" || $0.title == "about:blank" }
                    check(blank.isEmpty, "rows: no about:blank row of an agent task in Today (\(blank.count) of \(new.count) new rows)")
                    for t in tasks {
                        let row = new.first { $0.url.hasSuffix(t.path) }
                        check(row != nil, "rows: the task's row is its page (\(t.path): \(row.map { "“\($0.title)”" } ?? "missing"))")
                    }
                    check(new.count == tasks.count, "rows: one row per task (\(new.count) new rows, \(tasks.count) tasks)")
                    wait({ tasks.allSatisfy { AgentTaskThumbs.shared.task($0.id) != nil } }, 4) { [self] in
                        for t in tasks {
                            let shot = AgentTaskThumbs.shared.task(t.id)
                            check(shot != nil, "rows: the finished task has its card picture (\(t.path): \(shot.map { "\($0.image.width)x\($0.image.height)" } ?? "none, the globe"))")
                        }
                        done()
                    }
                }
              }
            }
        }
    }
}
#endif

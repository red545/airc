// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// agentrows (2026-11-23): "one sidebar row per agent task", counted the same way by agenttasks (the Airc Agent's own
/// tasks: running, waiting, done) and parityagentrows (other apps' sessions), in the Agents folder and on the All tasks
/// page ("Show all"). The owner saw a running task twice: its task row, and its page as a second row ("Compare the Pour
/// a… · Codex (in Airc) · Waiting").
enum AgentRowsCensus {
    /// The folder lists the task exactly once, as a task row, and no row for its run's pages; the page's row id (what
    /// Watch and AgentAttention address) is on that task row.
    static func folderTask(_ c: WindowController, task id: String) -> (ok: Bool, detail: String) {
        let f = c.sidebar.agents
        f.refresh()
        c.root.layoutSubtreeIfNeeded()
        let lines = f.model.tasks.filter { $0.id == id }
        let runWindow = AgentRunCenter.shared.runWindowID
        let pageRows = f.model.items.filter { $0.clientKey == AgentBridge.clientKey || (runWindow != nil && $0.window == runWindow) }
        var detail = "task rows \(lines.count), page rows \(pageRows.map(\.subtitle)), drawn \(TestAnchors.view("agents-task-\(id)", in: f) != nil)"
        var ok = lines.count == 1 && pageRows.isEmpty && TestAnchors.view("agents-task-\(id)", in: f) != nil
        if let live = lines.first?.liveRowID {
            let a = TestAnchors.frame("agents-row-\(live)", in: f), b = TestAnchors.frame("agents-task-\(id)", in: f)
            ok = ok && a != nil && a == b
            detail += ", its page's anchor on the task row \(a != nil && a == b)"
        }
        return (ok, detail)
    }

    /// The folder lists the session exactly once (one row, whatever its number of pages).
    static func folderSession(_ c: WindowController, session key: String) -> (ok: Bool, detail: String, row: String?) {
        let f = c.sidebar.agents
        f.refresh()
        c.root.layoutSubtreeIfNeeded()
        let model = AgentActivity.shared.model
        let pages = model.rows.filter { $0.sessionKey == key && $0.shown }
        let items = f.model.items.filter { item in model.row(item.id)?.sessionKey == key }
        let drawn = items.first.map { TestAnchors.view("agents-row-\($0.id)", in: f) != nil } ?? false
        return (items.count == 1 && drawn, "\(items.count) row(s) for \(pages.count) page(s), drawn \(drawn)", items.first?.id)
    }

    /// What the All tasks page lists in `c`'s Space (its own row builder, on a fresh model).
    static func pageRows(_ c: WindowController) -> [AgentTasksPageModel.Row] {
        let m = AgentTasksPageModel(theme: c.currentPalette.resolved)
        m.controller = c
        m.spaceID = c.currentSpaceID
        return m.rows(tasks: AgentTaskRecorder.shared.tasks, sessions: AgentActivity.shared.model.rows)
    }

    /// The page lists the task once, and no "session" row for any of its run's pages.
    static func pageTask(_ c: WindowController, task id: String) -> (ok: Bool, detail: String) {
        let rows = pageRows(c)
        let mine = rows.filter { $0.id == id }
        let runPages = rows.filter { r in
            guard r.external, let row = AgentActivity.shared.model.row(String(r.id.dropFirst("session-".count))) else { return false }
            return row.clientKey == AgentBridge.clientKey
        }
        return (mine.count == 1 && runPages.isEmpty, "\(mine.count) task row(s) (\(mine.first?.chip ?? "-")), \(runPages.count) for its pages, \(rows.count) in all")
    }

    /// The page lists the session once.
    static func pageSession(_ c: WindowController, session key: String) -> (ok: Bool, detail: String, row: String?) {
        let rows = pageRows(c).filter { r in
            r.external && AgentActivity.shared.model.row(String(r.id.dropFirst("session-".count)))?.sessionKey == key
        }
        return (rows.count == 1, "\(rows.count) row(s) for the session", rows.first?.id)
    }
}
#endif

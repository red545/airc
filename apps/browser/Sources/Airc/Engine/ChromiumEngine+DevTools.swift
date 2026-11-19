// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
#if canImport(AircCore)
import AircCore

extension ChromiumTab {
    private var developerCommandsAvailable: Bool {
        core.responds(to: #selector(AircTab.showDevToolsPanel(_:completion:)))
    }
    func showDevTools(panel: EngineDevToolsPanel, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        guard !isClosed else { completion(.failure(.failed("The tab is closed."))); return }
        guard developerCommandsAvailable else {
            completion(.failure(.unavailable("This engine build does not support panel selection. Update the engine."))); return
        }
        let generation = toolsGeneration
        core.showDevToolsPanel(panel.rawValue) { [weak self] error in
            guard let self, !self.isClosed, self.toolsGeneration == generation else {
                completion(.failure(.failed("Developer tools were closed before the command finished."))); return
            }
            if let error { completion(.failure(.failed(error))); return }
            self.attachDeveloperTools(completion: completion)
        }
    }
    func inspectElement(at point: CGPoint, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        guard !isClosed, core.responds(to: #selector(AircTab.inspectElement(at:completion:))) else {
            completion(.failure(.unavailable("Inspect Element requires a live tab and an updated engine."))); return
        }
        let generation = toolsGeneration
        core.inspectElement(at: point) { [weak self] error in
            guard let self, !self.isClosed, self.toolsGeneration == generation else {
                completion(.failure(.failed("Developer tools were closed before inspection finished."))); return
            }
            if let error { completion(.failure(.failed(error))); return }
            self.attachDeveloperTools(completion: completion)
        }
    }
    /// The frontend docked in this page's window (ChromiumDevToolsDock lays it out next to the page), or undocked in
    /// Chrome's DevTools window if the person chose that (⋮ › Dock side).
    fileprivate func attachDeveloperTools(completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        guard let owner, core.devToolsView != nil || isDevToolsUndocked else {
            completion(.failure(.unavailable("The docked developer tools view is unavailable."))); return
        }
        focusToolsWhenDocked = owner.window.isKeyWindow
        owner.devToolsDock.watch()
        completion(.success(()))
    }
    func closeDevTools() { dismissDevTools() }
    func dismissDevTools() {
        toolsGeneration += 1
        focusToolsWhenDocked = false
        core.closeDevTools()
        if let tools = dockedTools {
            ChromiumDevToolsDock.docked.remove(tools)
            if tools.superview === core.view.superview { tools.removeFromSuperview() }
            dockedTools = nil
            ChromiumDevToolsDock.restore(core.view)
        }
        undockedTools = nil
        owner?.devToolsDock.watch()
    }
    /// ⌥⌘I (Developer Tools), ⌥⌘J (JavaScript Console) and ⌥⌘C (Inspect Elements) are Chrome's own commands, so they
    /// behave as in Chrome: each opens DevTools (docked or in its own window, as the person left it), or closes the
    /// docked DevTools when they're open; ⌥⌘J opens the Console, ⌥⌘C starts the element picker.
    func showDevTools(console: Bool) -> Bool {
        runDevToolsCommand(console ? 40005 : 40004)   // IDC_DEV_TOOLS_CONSOLE, IDC_DEV_TOOLS
    }
    @discardableResult func runDevToolsCommand(_ command: Int32) -> Bool {
        guard !isClosed, let owner else { return false }
        toolsGeneration += 1
        focusToolsWhenDocked = owner.window.isKeyWindow
        // Chrome's commands act on the Browser's active tab: a split's focused pane, or Little Airc's page, is made it.
        if core.pageVisible { owner.core.activate(core) }
        guard core.executeChromeCommand(command) else { return false }
        owner.devToolsDock.watch()
        return true
    }
    func siteDataDomain(completion: @escaping (Result<String, EngineDeveloperError>) -> Void) {
        guard !isClosed, core.responds(to: NSSelectorFromString("siteDataDomain")), let domain = core.siteDataDomain else {
            completion(.failure(.unavailable("Site data commands require an updated engine and a regular HTTP or HTTPS tab. Private windows are untouched."))); return
        }
        completion(.success(domain))
    }
    func clearSiteDataAndReload(completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        guard !isClosed, core.responds(to: #selector(AircTab.clearSiteDataAndReload(_:))) else {
            completion(.failure(.unavailable("Clearing site data requires a live tab and an updated engine."))); return
        }
        core.clearSiteDataAndReload { error in
            if let error {
                if error.hasPrefix("partial:") { completion(.failure(.partial(String(error.dropFirst(8))))) }
                else if error.hasPrefix("unavailable:") { completion(.failure(.unavailable(String(error.dropFirst(12))))) }
                else { completion(.failure(.failed(error))) }
            } else { completion(.success(())) }
        }
    }
    // P20d: Inspect Elements (⌥⌘C) as Chrome's: Elements, then its element picker (IDC_DEV_TOOLS_INSPECT).
    func inspectElements(completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        completion(runDevToolsCommand(40023) ? .success(())   // IDC_DEV_TOOLS_INSPECT
                   : .failure(.unavailable("The engine could not open the element picker.")))
    }
    // P20d: View › Clear Cookies and Refresh / Clear Cache and Refresh. A private tab clears its own session's data:
    // the engine uses the tab's own storage partition.
    func developerSiteDomain(completion: @escaping (Result<String, EngineDeveloperError>) -> Void) {
        guard !isClosed, core.responds(to: NSSelectorFromString("developerSiteDomain")), let domain = core.developerSiteDomain else {
            completion(.failure(.unavailable("This needs an HTTP or HTTPS page and an updated engine."))); return
        }
        completion(.success(domain))
    }
    func clearSiteData(_ types: Set<EngineSiteDataType>, reload: Bool, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        guard !isClosed, core.responds(to: #selector(AircTab.clearSiteData(_:reload:completion:))) else {
            completion(.failure(.unavailable("Clearing a site's cookies or cache needs a live tab and an updated engine."))); return
        }
        core.clearSiteData(EngineSiteDataType.allCases.filter(types.contains).map(\.rawValue), reload: reload) { error in
            guard let error else { return completion(.success(())) }
            if error.hasPrefix("partial:") { completion(.failure(.partial(String(error.dropFirst(8))))) }
            else if error.hasPrefix("unavailable:") { completion(.failure(.unavailable(String(error.dropFirst(12))))) }
            else { completion(.failure(.failed(error))) }
        }
    }
}

// P20d: Chromium's task manager model (engine/core/airc_task_manager.mm); the window is the app's (TaskManager/).
extension ChromiumEngine: EngineTaskSource {
    var tasksUnavailableReason: String? {
        (AircEngine.self as AnyObject).responds(to: NSSelectorFromString("observeTasksEvery:handler:"))
            ? nil : "This engine build has no task manager. Update the engine."
    }
    func observeTasks(every interval: TimeInterval, handler: (([EngineTask]) -> Void)?) {
        guard tasksUnavailableReason == nil else { return }
        guard let handler else { return AircEngine.observeTasks(every: interval, handler: nil) }
        AircEngine.observeTasks(every: interval) { tasks in handler(tasks.compactMap(EngineTask.init(chromium:))) }
    }
    func endTask(_ id: Int64) -> Bool { tasksUnavailableReason == nil && AircEngine.endTask(id) }
}

private extension EngineTask {
    init?(chromium d: [String: Any]) {
        guard let id = (d["taskID"] as? NSNumber)?.int64Value else { return nil }
        let number = { (key: String) in d[key] as? NSNumber }
        self.init(id: id, rootID: number("rootTaskID")?.int64Value ?? id, title: d["title"] as? String ?? "",
                  kind: Kind(rawValue: d["kind"] as? String ?? "") ?? .other, pid: number("pid")?.int32Value ?? 0,
                  tabID: number("tabId")?.intValue, profileName: d["profileName"] as? String ?? "",
                  offTheRecord: number("offTheRecord")?.boolValue ?? false, cpu: number("cpu")?.doubleValue,
                  memory: number("memory")?.int64Value, network: number("network")?.int64Value,
                  killable: number("killable")?.boolValue ?? false)
    }
}
// The engine's docked-DevTools callback (when an engine reports it): lay out now instead of on the next frame.
extension ChromiumWindow {
    @objc(window:devToolsDidChangeForTab:view:)
    func window(_ window: AircWindow, devToolsDidChangeFor tab: AircTab, view: NSView?) {
        DispatchQueue.main.async { [weak self] in self?.devToolsDock.watch() }
    }
}
#endif

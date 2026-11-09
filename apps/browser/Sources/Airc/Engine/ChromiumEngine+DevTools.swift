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
    fileprivate func attachDeveloperTools(completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        guard let owner, let view = core.devToolsView else {
            completion(.failure(.unavailable("The docked developer tools view is unavailable."))); return
        }
        if toolsPanel == nil {
            let panel = ChromiumToolsPanel(tab: core, parent: owner.window)
            toolsPanel = panel
            panel.onClose = { [weak self, weak panel] in
                if self?.toolsPanel === panel { self?.toolsGeneration += 1; self?.toolsPanel = nil }
            }
        }
        toolsPanel?.show(view)
        completion(.success(()))
    }
    func closeDevTools() { dismissDevTools() }
    func dismissDevTools() {
        toolsGeneration += 1
        toolsPanel?.panel.close()
        toolsPanel = nil
        core.closeDevTools()
    }
    /// Compatibility shortcut: Inspect toggles; Console is always an idempotent show.
    func showDevTools(console: Bool) -> Bool {
        guard !isClosed, developerCommandsAvailable else { return false }
        if !console, toolsPanel != nil { dismissDevTools(); return true }
        let generation = toolsGeneration
        showDevTools(panel: console ? .console : .elements) { [weak self] result in
            // An intentional close cancels the legacy request. Do not leave a
            // modal error sheet over the next action after that cancellation.
            guard let self, !self.isClosed, self.toolsGeneration == generation else { return }
            if case .failure(let error) = result { self.reportDeveloperError(error) }
            else if !console, !self.core.executeChromeCommand(40023) { // IDC_DEV_TOOLS_INSPECT
                self.reportDeveloperError(.unavailable("The engine could not enter element selection mode."))
            }
        }
        return true
    }
    private func reportDeveloperError(_ error: EngineDeveloperError) {
        // Legacy Bool callers cannot receive an asynchronous failure. Present it on
        // their own window only; never activate the application to show an alert.
        guard let window = owner?.window else { NSLog("Developer tools: %@", error.localizedDescription); return }
        let alert = NSAlert(); alert.messageText = "Developer tools unavailable"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
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
        showDevTools(panel: .elements) { [weak self] result in
            guard case .success = result, let self else { return completion(result) }
            completion(self.core.executeChromeCommand(40023) ? .success(())
                       : .failure(.partial("Developer tools opened, but the element picker didn't start.")))
        }
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
// Native frontend close/undock events also retire the app-owned host. Otherwise
// closing from DevTools' own toolbar can leave an empty utility window behind.
extension ChromiumWindow {
    @objc(window:devToolsDidChangeForTab:view:)
    func window(_ window: AircWindow, devToolsDidChangeFor tab: AircTab, view: NSView?) {
        guard let page = tab.delegate as? ChromiumTab else { return }
        let generation = page.toolsGeneration
        let hadView = view != nil
        DispatchQueue.main.async { [weak page, weak view] in
            guard let page, !page.isClosed, page.toolsGeneration == generation else { return }
            if hadView, let view, page.core.devToolsView === view {
                page.attachDeveloperTools { result in
                    if case .failure(let error) = result { NSLog("Developer tools host: %@", error.localizedDescription) }
                }
            } else if !hadView, page.core.devToolsView == nil, let host = page.toolsPanel {
                page.toolsGeneration += 1
                host.onClose = nil
                host.panel.parent?.removeChildWindow(host.panel)
                host.panel.delegate = nil
                host.panel.close()
                page.toolsPanel = nil
            }
        }
    }
}
#endif

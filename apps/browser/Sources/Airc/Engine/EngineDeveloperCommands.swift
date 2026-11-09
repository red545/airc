// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

enum EngineDevToolsPanel: String, CaseIterable { case console, network, elements }

/// P20d: what View › Clear Cookies and Refresh and Clear Cache and Refresh remove for the page's site.
enum EngineSiteDataType: String, CaseIterable { case cookies, cache }

enum EngineDeveloperError: Error, LocalizedError {
    case unavailable(String)
    case failed(String)
    /// Data was removed but the operation did not finish completely. Show this to the user.
    case partial(String)
    var errorDescription: String? {
        switch self { case .unavailable(let text), .failed(let text), .partial(let text): return text }
    }
}

/// Main-thread commands on the target tab (including private and hybrid/WebKit tabs).
/// Completion means the engine accepted the action, not that a navigation finished.
protocol EngineDeveloperCommands: AnyObject {
    func showDevTools(panel: EngineDevToolsPanel, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void)
    /// Point in viewport points/DIPs from its top left. Convert AppKit's bottom-left coordinates first.
    func inspectElement(at point: CGPoint, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void)
    func closeDevTools()
    /// Registrable domain, or host/IP for local pages. Use in the action label:
    /// "Clear data for <domain> and its subdomains and reload". Private tabs return .unavailable.
    func siteDataDomain(completion: @escaping (Result<String, EngineDeveloperError>) -> Void)
    /// Clears the current site's cookies, storage and caches in this profile and reloads.
    /// Another site's data and every private profile remain untouched.
    func clearSiteDataAndReload(completion: @escaping (Result<Void, EngineDeveloperError>) -> Void)
    func showTaskManager(completion: @escaping (Result<Void, EngineDeveloperError>) -> Void)
    /// P20d: the site the two View commands clear, as `siteDataDomain`, but private tabs too: theirs is their own
    /// session's data.
    func developerSiteDomain(completion: @escaping (Result<String, EngineDeveloperError>) -> Void)
    /// P20d: removes only `types` for the page's site (its registrable domain and subdomains) from this tab's own
    /// store, then reloads (past the cache when it was cleared). A private tab clears its own session's data, never
    /// the regular profile's. Completion after the reload started.
    func clearSiteData(_ types: Set<EngineSiteDataType>, reload: Bool, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void)
    /// P20d: Arc's Inspect Elements (⌥⌘C), as Chrome's: DevTools on Elements, picking an element where it can.
    func inspectElements(completion: @escaping (Result<Void, EngineDeveloperError>) -> Void)
    /// P20d: where the Task Manager finds the process showing this tab.
    var developerProcess: EngineTabProcess { get }
    /// P20d: End Process for an engine whose tabs name their own process (`.process`); false otherwise.
    func endDeveloperProcess() -> Bool
}

/// P20d: a tab's process, as its engine tells it.
enum EngineTabProcess: Equatable {
    /// In the engine's own task list (EngineTaskSource), matched by tabID: Chromium's.
    case engineTasks
    /// Its own process, which the engine names: WebKit's web content process.
    case process(pid_t)
    /// None now: it ended, or the page hasn't started one.
    case notRunning
    /// The engine doesn't say which; the reason, for the window.
    case unnamed(String)
}

/// P20d: one task of the engine's task manager (Chrome's Task Manager rows). Tasks on one process share its memory and
/// CPU; `rootID` groups them.
struct EngineTask: Equatable {
    enum Kind: String { case browser, gpu, utility, renderer, `extension`, guest, worker, other }
    let id: Int64
    let rootID: Int64
    let title: String
    let kind: Kind
    let pid: pid_t
    /// EngineTab.tabID of the tab it shows.
    let tabID: Int?
    let profileName: String
    /// On a private window's processes.
    let offTheRecord: Bool
    /// Percent of one core; nil until sampled.
    let cpu: Double?
    let memory: Int64?
    /// Bytes per second.
    let network: Int64?
    let killable: Bool
}

/// P20d: an engine's own process list for Help › Troubleshooting › Open Task Manager. It samples only while observed.
protocol EngineTaskSource: AnyObject {
    /// nil when it lists tasks; otherwise the reason, said plainly in the window.
    var tasksUnavailableReason: String? { get }
    /// `handler` on the main thread every `interval` s; nil stops sampling.
    func observeTasks(every interval: TimeInterval, handler: (([EngineTask]) -> Void)?)
    /// Ends the task's process (its pages show the crashed state). false: unknown or not allowed.
    func endTask(_ id: Int64) -> Bool
}

extension EngineDeveloperCommands {
    func showDevTools(panel: EngineDevToolsPanel, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        completion(.failure(.unavailable("This engine cannot select a developer tools panel.")))
    }
    func inspectElement(at point: CGPoint, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        completion(.failure(.unavailable("This engine cannot inspect an element at a point.")))
    }
    func closeDevTools() {}
    func siteDataDomain(completion: @escaping (Result<String, EngineDeveloperError>) -> Void) {
        completion(.failure(.unavailable("This engine cannot determine the site's data scope.")))
    }
    func clearSiteDataAndReload(completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        completion(.failure(.unavailable("This engine cannot clear this site's data.")))
    }
    func showTaskManager(completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        completion(.failure(.unavailable("A profile-scoped task manager is unavailable. Chromium's task manager lists processes across all profiles and private windows.")))
    }
    func developerSiteDomain(completion: @escaping (Result<String, EngineDeveloperError>) -> Void) {
        completion(.failure(.unavailable("This engine cannot determine the site's data scope.")))
    }
    func clearSiteData(_ types: Set<EngineSiteDataType>, reload: Bool, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        completion(.failure(.unavailable("This engine cannot clear only this site's cookies or cache.")))
    }
    func inspectElements(completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        showDevTools(panel: .elements, completion: completion)
    }
    var developerProcess: EngineTabProcess { .engineTasks }
    func endDeveloperProcess() -> Bool { false }
}

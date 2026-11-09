// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import Darwin
import WebKit

extension WebKitTab {
    func showDevTools(panel: EngineDevToolsPanel, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        guard !isClosed else { completion(.failure(.failed("The tab is closed."))); return }
        // The supported private selectors can show the inspector or Console but
        // cannot reliably select Network or Elements in an existing frontend.
        guard panel == .console else {
            completion(.failure(.unavailable("WebKit can open Web Inspector and Console, but cannot reliably select \(panel.rawValue). Use Web Inspector's tabs."))); return
        }
        completion(showDevTools(console: true) ? .success(()) : .failure(.unavailable("WebKit's local Console selector is unavailable.")))
    }
    func closeDevTools() {
        guard webView.responds(to: NSSelectorFromString("_inspector")),
              let inspector = webView.value(forKey: "_inspector") as? NSObject,
              inspector.responds(to: NSSelectorFromString("close")) else { return }
        inspector.perform(NSSelectorFromString("close"))
    }
    func inspectElement(at point: CGPoint, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        completion(.failure(.unavailable("WebKit does not expose a supported point-inspection API. Use the page's Inspect Element context menu.")))
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        developerNavigationGeneration += 1
    }
    func siteDataDomain(completion: @escaping (Result<String, EngineDeveloperError>) -> Void) {
        developerSiteRecords { result in completion(result.map { $0.domain }) }
    }
    /// WebKit's own data records supply its public-suffix-aware grouping. Never guess
    /// the last two host labels (that would erase neighbors on co.uk or private suffixes).
    /// P20d: `ownSession` lets a private tab use its own session's store (never the regular profile's).
    private func developerSiteRecords(ownSession: Bool = false, completion: @escaping (Result<(domain: String, records: [WKWebsiteDataRecord]), EngineDeveloperError>) -> Void) {
        guard !isClosed, ownSession || !webKitProfile.privateSession,
              let url, ["http", "https"].contains(url.scheme ?? ""), let host = url.host?.lowercased() else {
            completion(.failure(.unavailable("Clear site data requires a regular HTTP or HTTPS tab. Private windows are untouched."))); return
        }
        let generation = developerNavigationGeneration
        var finished = false
        func finish(_ result: Result<(domain: String, records: [WKWebsiteDataRecord]), EngineDeveloperError>) {
            guard !finished else { return }; finished = true; completion(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            finish(.failure(.unavailable("WebKit did not return the site's data records.")))
        }
        webKitProfile.dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            guard let self, !self.isClosed, self.developerNavigationGeneration == generation else {
                finish(.failure(.failed("The tab navigated or closed before its site data scope was resolved."))); return
            }
            let matches = records.filter { record in
                let domain = record.displayName.lowercased()
                return host == domain || host.hasSuffix("." + domain)
            }
            guard let domain = matches.map({ $0.displayName.lowercased() }).min(by: { $0.count < $1.count }) else {
                finish(.failure(.unavailable("WebKit has no data record for this site, so its deletion scope cannot be resolved. No data was removed."))); return
            }
            finish(.success((domain, matches)))
        }
    }
    func clearSiteDataAndReload(completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        let generation = developerNavigationGeneration
        developerSiteRecords { [weak self] result in
            guard let self, !self.isClosed, self.developerNavigationGeneration == generation else {
                completion(.failure(.failed("The tab navigated or closed before data removal began."))); return
            }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let scope):
                var finished = false
                func finish(_ result: Result<Void, EngineDeveloperError>) {
                    guard !finished else { return }; finished = true; completion(result)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    finish(.failure(.partial("Site data removal timed out; no reload will be performed.")))
                }
                // All types includes HTTP disk/memory caches and cookies; the selected
                // records belong only to this registrable domain and this profile's store.
                self.webKitProfile.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: scope.records) { [weak self] in
                    guard !finished else { return }
                    guard let self, !self.isClosed, self.developerNavigationGeneration == generation else {
                        finish(.failure(.partial("Site data cleared, but the tab navigated or closed; no reload performed."))); return
                    }
                    self.webView.reloadFromOrigin()
                    finish(.success(()))
                }
            }
        }
    }

    // MARK: P20d

    func developerSiteDomain(completion: @escaping (Result<String, EngineDeveloperError>) -> Void) {
        developerSiteRecords(ownSession: true) { result in completion(result.map { $0.domain }) }
    }
    /// Cookies → WebKit's cookies; cache → its HTTP disk and memory caches, as Chromium's HTTP cache (the Cache API and
    /// other site storage stay). From this tab's own store: a private window's session store is its own.
    func clearSiteData(_ types: Set<EngineSiteDataType>, reload: Bool, completion: @escaping (Result<Void, EngineDeveloperError>) -> Void) {
        let kinds = Set(types.flatMap { type -> [String] in
            switch type {
            case .cookies: return [WKWebsiteDataTypeCookies]
            case .cache: return [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
            }
        })
        let generation = developerNavigationGeneration
        var finished = false
        func finish(_ result: Result<Void, EngineDeveloperError>) {
            guard !finished else { return }; finished = true; completion(result)
        }
        func reloaded() {
            guard !isClosed, developerNavigationGeneration == generation else {
                return finish(.failure(.partial("Cleared, but the tab navigated or closed; no reload performed.")))
            }
            if reload { if types.contains(.cache) { webView.reloadFromOrigin() } else { webView.reload() } }
            finish(.success(()))
        }
        developerSiteRecords(ownSession: true) { [weak self] result in
            guard let self else { return finish(.failure(.failed("The tab closed."))) }
            switch result {
            // No record for the site: nothing of it is stored, so there's nothing to remove.
            case .failure(.unavailable(let text)) where text.hasPrefix("WebKit has no data record"): reloaded()
            case .failure(let error): finish(.failure(error))
            case .success(let scope):
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    finish(.failure(.partial("Removal timed out; no reload will be performed.")))
                }
                self.webKitProfile.dataStore.removeData(ofTypes: kinds, for: scope.records) { reloaded() }
            }
        }
    }
    /// SPI, behind responds(to:): WKWebView's `_webProcessIdentifier`. No public API names the process showing a tab,
    /// and the Task Manager shows each tab's memory and CPU (proc_pid_rusage, public libproc) and ends it (SIGKILL).
    var developerProcess: EngineTabProcess {
        let key = "_webProcessIdentifier"
        guard webView.responds(to: NSSelectorFromString(key)) else {
            return .unnamed("This macOS's WebKit doesn't say which process shows a tab.")
        }
        guard !isClosed, let pid = (webView.value(forKey: key) as? NSNumber)?.int32Value, pid > 0 else { return .notRunning }
        return .process(pid)
    }
    /// End Process: SIGKILL to the tab's own web content process (WebKit then reports
    /// webViewWebContentProcessDidTerminate and the page shows it ended). Only a WebKit content process, checked by its
    /// executable's name, so a reused process number is never hit.
    func endDeveloperProcess() -> Bool {
        guard case .process(let pid) = developerProcess else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(cString: path).contains("com.apple.WebKit.WebContent") else { return false }
        return kill(pid, SIGKILL) == 0
    }
}

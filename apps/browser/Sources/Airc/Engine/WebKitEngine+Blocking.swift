// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import WebKit
import AircKit

extension WebKitEngine: EngineBlocking {
    func configureBlocking(text: String, policy: EngineBlockingPolicy, profile: EngineProfile,
                           completion: @escaping (Bool) -> Void) {
        guard let profile = profile as? WebKitProfile else { return completion(false) }
        let current = BlockingInstallation.begin(profile)
        WebKitBlocking.prepare(text: text, policy: policy, privateSession: profile.privateSession) { prepared in
            guard current(), let prepared else { return completion(false) }
            WebKitBlocking.install(prepared, profile: profile); completion(true)
        }
    }
    func blockedRequests(in tab: EngineTab) -> Int? { (tab as? WebKitTab).flatMap(WebKitBlocking.count) }
}

/// Disk caches contain only converted public lists, never site exceptions.
/// The per-navigation SPI changes the enabled identifiers in memory; it also
/// keeps the independent cookie rule enabled when ads are bypassed for a site.
final class WebKitBlocking {
    struct Prepared {
        let ads: WKContentRuleList?
        let cookies: WKContentRuleList?
        let policy: EngineBlockingPolicy
    }
    private final class ProfileState {
        weak var profile: WebKitProfile?
        var prepared: Prepared
        init(_ profile: WebKitProfile, _ prepared: Prepared) { self.profile = profile; self.prepared = prepared }
    }
    private final class PageState {
        weak var tab: WebKitTab?
        var count = 0
        init(_ tab: WebKitTab) { self.tab = tab }
    }
    private static var profiles: [ObjectIdentifier: ProfileState] = [:]
    private static var pages: [ObjectIdentifier: PageState] = [:]
    private static let queue = DispatchQueue(label: "org.airc.blocking-converter", qos: .userInitiated)
    private enum Compilation { case rules(WKContentRuleList), empty, failed }
    private static var compiling: [String: [(Compilation) -> Void]] = [:]
    private static let prefix = "airc-blocking-v2-"
    private static let cookiesID = prefix + "third-party-cookies"
    private static let enableSelector = NSSelectorFromString("_setContentRuleListsEnabled:exceptions:")
    static var supportsPerPagePolicy: Bool { WKWebpagePreferences().responds(to: enableSelector) }
    static var supportsCounts: Bool { (NSClassFromString("_WKContentRuleListAction") as? NSObject.Type)?.instancesRespond(to: NSSelectorFromString("blockedLoad")) == true }

    static func prepare(text: String, policy: EngineBlockingPolicy, privateSession: Bool,
                        completion: @escaping (Prepared?) -> Void) {
        guard supportsPerPagePolicy else { return completion(nil) }
        func cookies(_ ads: WKContentRuleList?) {
            guard policy.blockThirdPartyCookies else { return completion(Prepared(ads: ads, cookies: nil, policy: policy)) }
            compile(identifier: cookiesID, makeJSON: {
                Data(#"[{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block-cookies"}}]"#.utf8)
            }) { result in
                guard case .rules(let cookies) = result else { return completion(nil) }
                completion(Prepared(ads: ads, cookies: cookies, policy: policy))
            }
        }
        guard policy.enabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return cookies(nil) }
        let id = prefix + BlockingListStore.digest(Data(text.utf8))
        compile(identifier: id, makeJSON: { try BlockingFilter.webKitRules(text) }) { result in
            switch result {
            case .rules(let ads): cookies(ads)
            case .empty: cookies(nil)
            case .failed: completion(nil)
            }
        }
    }
    private static func compile(identifier: String, makeJSON: @escaping () throws -> Data,
                                completion: @escaping (Compilation) -> Void) {
        if compiling[identifier] != nil { compiling[identifier]!.append(completion); return }
        compiling[identifier] = [completion]
        let directory = AppPaths.dataDirectory.appendingPathComponent("Blocking/WebKit", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return finish(identifier, .failed) }
        guard let store = WKContentRuleListStore(url: directory) else { return finish(identifier, .failed) }
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            if let list { return finish(identifier, .rules(list)) }
            queue.async {
                let json = try? makeJSON()
                DispatchQueue.main.async {
                    guard let json, let text = String(data: json, encoding: .utf8) else { return finish(identifier, .failed) }
                    // Our converter serializes an empty result as this compact
                    // array. WebKit rejects it, but it is a valid selection:
                    // cosmetics and native-only network rules still apply.
                    if json == Data("[]".utf8) { return finish(identifier, .empty) }
                    store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: text) { list, _ in
                        finish(identifier, list.map(Compilation.rules) ?? .failed)
                    }
                }
            }
        }
    }
    private static func finish(_ id: String, _ result: Compilation) {
        let callbacks = compiling.removeValue(forKey: id) ?? []
        callbacks.forEach { $0(result) }
    }
    static func install(_ prepared: Prepared, profile: WebKitProfile) {
        profiles = profiles.filter { $0.value.profile != nil }
        let id = ObjectIdentifier(profile)
        if let previous = profiles[id]?.prepared {
            if let ads = previous.ads { profile.userContent.remove(ads) }
            if let cookies = previous.cookies { profile.userContent.remove(cookies) }
        }
        if let ads = prepared.ads { profile.userContent.add(ads) }
        if let cookies = prepared.cookies { profile.userContent.add(cookies) }
        profiles[id] = ProfileState(profile, prepared)
    }
    static func navigation(_ tab: WebKitTab, action: WKNavigationAction, preferences: WKWebpagePreferences) {
        guard preferences.responds(to: enableSelector),
              let state = profiles[ObjectIdentifier(tab.webKitProfile)] else { return }
        let topURL = (action.targetFrame?.isMainFrame ?? true) ? action.request.url : tab.url
        let excepted = topURL.flatMap(BlockingProfileConfiguration.host).map { state.prepared.policy.exceptions.contains($0) } ?? false
        let ids = excepted ? [state.prepared.ads?.identifier].compactMap { $0 } : []
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, NSSet) -> Void
        let call = unsafeBitCast(preferences.method(for: enableSelector), to: SetEnabled.self)
        call(preferences, enableSelector, true, NSSet(array: ids))
    }
    static func committed(_ tab: WebKitTab) { page(tab).count = 0 }
    static func count(for tab: WebKitTab) -> Int? { supportsCounts ? page(tab).count : nil }
    private static func page(_ tab: WebKitTab) -> PageState {
        pages = pages.filter { $0.value.tab != nil }
        let id = ObjectIdentifier(tab)
        if let old = pages[id] { return old }
        let value = PageState(tab); pages[id] = value; return value
    }
    static func performed(_ tab: WebKitTab, identifier: String, action: NSObject) {
        guard identifier.hasPrefix(prefix), identifier != cookiesID,
              action.responds(to: NSSelectorFromString("blockedLoad")),
              (action.value(forKey: "blockedLoad") as? NSNumber)?.boolValue == true else { return }
        // Only WebKit-confirmed blocked loads. CSS hides and failed resource
        // loads are never used as estimates. No URL is retained.
        page(tab).count += 1
    }
}

extension WebKitTab {
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func blockingAction(_ view: WKWebView, identifier: String, action: NSObject, url: URL) {
        WebKitBlocking.performed(self, identifier: identifier, action: action)
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import WebKit
import Compression
import AircKit

extension WebKitEngine: EngineBlocking {
    func configureBlocking(text: String, policy: EngineBlockingPolicy, profile: EngineProfile,
                           ready: (() -> Void)?, completion: @escaping (Bool) -> Void) {
        guard let profile = profile as? WebKitProfile else { return completion(false) }
        let current = BlockingInstallation.begin(profile)
        // linklaunch: before the profile's first install its pages may already be made (WKWebView, web process: ~0.3 s
        // of first-page work right after launch) while their navigations wait for these rules (WebKitBlocking holds).
        var early = false
        #if AIRC_TESTING
        if !LinkLaunchBaseline.enabled { early = WebKitBlocking.holdNavigations(profile) }
        #else
        early = WebKitBlocking.holdNavigations(profile)
        #endif
        if early { ready?() }
        let wkStep = LaunchTimeline.begin("blocking webkit rules \(profile.directory)")
        LinkLaunchBaseline.afterTestDelay {
        WebKitBlocking.prepare(text: text, policy: policy, privateSession: profile.privateSession) { prepared in
            wkStep()
            guard current() else { return completion(false) }
            guard let prepared else { WebKitBlocking.releaseNavigations(profile); return completion(false) }
            let videoStep = LaunchTimeline.begin("blocking video scriptlets \(profile.directory)")
            WebKitBlocking.prepareVideo(text: text, prepared: prepared) { prepared in
                videoStep()
                guard current() else { return completion(false) }
                guard let prepared else { WebKitBlocking.releaseNavigations(profile); return completion(false) }
                WebKitBlocking.install(prepared, profile: profile); completion(true)
            }
        }
        }
    }
    func blockedRequests(in tab: EngineTab) -> Int? { (tab as? WebKitTab).flatMap(WebKitBlocking.count) }
    func holdNavigationsForCosmetics(profile: EngineProfile) -> (() -> Void)? {
        guard let profile = profile as? WebKitProfile, WebKitBlocking.holdNavigations(profile, reason: "cosmetics") else { return nil }
        return { WebKitBlocking.releaseNavigations(profile, reason: "cosmetics") }
    }
}

/// Disk caches contain only converted public lists, never site exceptions.
/// The per-navigation SPI changes the enabled identifiers in memory; it also
/// keeps the independent cookie rule enabled when ads are bypassed for a site.
final class WebKitBlocking {
    struct Prepared {
        let ads: WKContentRuleList?
        let cookies: WKContentRuleList?
        let policy: EngineBlockingPolicy
        var videoScript: WKUserScript? = nil
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
    private final class Hold {
        weak var profile: WebKitProfile?
        var reasons: Set<String> = []
        var waiters: [() -> Void] = []
        init(_ profile: WebKitProfile) { self.profile = profile }
    }
    /// linklaunch: profiles whose pages may exist while their first rules (or the cosmetic filter their pages ask) are
    /// still coming: right after launch, so the page and its web process start meanwhile. Their navigations wait here
    /// (`whenNavigable`), never unprotected.
    private static var holds: [ObjectIdentifier: Hold] = [:]

    /// Holds the profile's navigations for `reason` until `releaseNavigations(_:reason:)` (or, for "rules", `install`).
    /// Only before the profile's first install: an update keeps the previous rules in force until the new ones replace
    /// them. Returns whether it holds.
    @discardableResult
    static func holdNavigations(_ profile: WebKitProfile, reason: String = "rules") -> Bool {
        let id = ObjectIdentifier(profile)
        holds = holds.filter { $0.value.profile != nil }
        guard profiles[id]?.profile == nil else { return false }
        let hold = holds[id] ?? Hold(profile)
        hold.reasons.insert(reason); holds[id] = hold
        return true
    }
    /// Ends `reason`'s hold (a failed preparation too: navigations then go ahead with whatever the profile has, as the
    /// profile gate does on a failed install; BlockingCenter shows the failure).
    static func releaseNavigations(_ profile: WebKitProfile, reason: String = "rules") {
        let id = ObjectIdentifier(profile)
        guard let hold = holds[id] else { return }
        hold.reasons.remove(reason)
        guard hold.reasons.isEmpty else { return }
        holds.removeValue(forKey: id)
        if !hold.waiters.isEmpty { LaunchTimeline.mark("webkit navigation released \(profile.directory)") }
        hold.waiters.forEach { $0() }
    }
    /// Runs `block` once the profile's navigations may start: at once unless a hold is on.
    static func whenNavigable(_ profile: WebKitProfile, _ block: @escaping () -> Void) {
        guard let hold = holds[ObjectIdentifier(profile)], hold.profile != nil else { return block() }
        if hold.waiters.isEmpty { LaunchTimeline.mark("webkit navigation held (\(hold.reasons.sorted().joined(separator: ", "))) \(profile.directory)") }
        hold.waiters.append(block)
    }
    private static let queue = DispatchQueue(label: "org.airc.blocking-converter", qos: .userInitiated)
    private enum Compilation { case rules(WKContentRuleList), empty, failed }
    private static var compiling: [String: [(Compilation) -> Void]] = [:]
    /// v3 (ganalytics): a top-level page is blocked only by rules that name documents (`$document`), as on Chromium;
    /// the converter's output changed, so lists compiled as v2 aren't used again (removeOldLists).
    private static let prefix = "airc-blocking-v3-"
    private static var oldListsRemoved = false
    /// Each profile's v2 compiled list is ~38 MB that nothing looks up any more: removed once per launch.
    private static func removeOldLists(_ store: WKContentRuleListStore) {
        guard !oldListsRemoved else { return }
        oldListsRemoved = true
        store.getAvailableContentRuleListIdentifiers { ids in
            for id in ids ?? [] where id.hasPrefix("airc-blocking-v2-") {
                store.removeContentRuleList(forIdentifier: id) { _ in }
            }
        }
    }
    private static let cookiesID = prefix + "third-party-cookies"
    private static let enableSelector = NSSelectorFromString("_setContentRuleListsEnabled:exceptions:")
    static var supportsPerPagePolicy: Bool { WKWebpagePreferences().responds(to: enableSelector) }
    static var supportsCounts: Bool { (NSClassFromString("_WKContentRuleListAction") as? NSObject.Type)?.instancesRespond(to: NSSelectorFromString("blockedLoad")) == true }

    static func prepareVideo(text: String, prepared: Prepared, completion: @escaping (Prepared?) -> Void) {
        var hosts = ["youtube.com", "www.youtube.com", "m.youtube.com",
                     "youtube-nocookie.com", "www.youtube-nocookie.com"]
        #if AIRC_TESTING
        if LaunchOptions.current.script == "ytads" ||
            (LaunchOptions.current.script == "marketing" && ProcessInfo.processInfo.environment["AIRC_MARKETING_PART"] == "video-blocking") {
            hosts += ["localhost", "127.0.0.1"]
        }
        #endif
        let sites = hosts
        Task { @MainActor in
            var result = prepared
            do {
                if prepared.policy.enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let digest = BlockingListStore.digest(Data(text.utf8))
                    let scripts: [String: String]
                    // linklaunch: the scriptlets depend only on the list text and the hosts, so they are kept on disk by
                    // digest. A launch reads a few KB instead of compiling the whole adblock engine (~0.1–0.5 s).
                    if let cached = await VideoScriptletCache.read(digest: digest, hosts: sites) {
                        LaunchTimeline.mark("blocking video scriptlets cached")
                        scripts = cached
                    } else {
                        LaunchTimeline.mark("blocking video scriptlets not cached")
                        let filter = try await SharedBlockingFilters.filter(text: text, digest: digest)
                        scripts = try await Task.detached(priority: .userInitiated) {
                            Dictionary(uniqueKeysWithValues: sites.map {
                                ($0, filter.scriptlet(url: "https://" + $0 + "/"))
                            })
                        }.value
                        VideoScriptletCache.write(scripts, digest: digest, hosts: sites)
                    }
                    let branches = scripts.keys.sorted().filter { !prepared.policy.exceptions.contains($0) }.map { host in
                        "if (host === '\(host)') { \(scripts[host]!)\n }"
                    }.joined(separator: "\n")
                    let source = """
                    (() => {
                      if (window.top !== window || !/^https?:$/.test(location.protocol)) return;
                      const host = location.hostname.toLowerCase().replace(/\\.$/, '');
                      \(branches)
                    })();
                    """
                    result.videoScript = WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                      forMainFrameOnly: true, in: .page)
                }
                completion(result)
            } catch { completion(nil) }
        }
    }
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
        compile(identifier: id, source: text, makeJSON: { try BlockingFilter.webKitRules(text) }) { result in
            switch result {
            case .rules(let ads): cookies(ads)
            case .empty: cookies(nil)
            case .failed: completion(nil)
            }
        }
    }
    /// `source`: the list text, compiled in a child process (BlockingRuleCompiler) when given; `makeJSON` is the
    /// in-process path (the small cookie rule, and the fallback when the child can't run).
    // MARK: linklaunch: the last launch's rule lists, looked up as the process starts

    /// A lookup maps and checks the compiled file (30+ MB for EasyList + EasyPrivacy): ~0.25 s before the first page
    /// could load. The lists installed last time are looked up from `main` instead, while the app and engine start.
    private static var prefetched: [String: WKContentRuleList] = [:]
    private static var prefetching: [String: [(WKContentRuleList?) -> Void]] = [:]
    private static var launchListsFile: URL {
        AppPaths.dataDirectory.appendingPathComponent("Blocking/WebKit/launch-rule-lists.json")
    }
    private static var recordedLaunchLists: [String]?

    /// From main.swift (the WebKit engine), right after the data folder is known. Unused results go after 60 s.
    static func prefetchLaunchRules() {
        #if AIRC_TESTING
        if LinkLaunchBaseline.enabled { return }
        #endif
        guard let data = try? Data(contentsOf: launchListsFile),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return }
        recordedLaunchLists = ids
        let directory = launchListsFile.deletingLastPathComponent()
        guard !ids.isEmpty, let store = WKContentRuleListStore(url: directory) else { return }
        for id in ids.prefix(4) where id.hasPrefix(prefix) && id != cookiesID && prefetching[id] == nil {
            prefetching[id] = []
            let step = LaunchTimeline.begin("blocking webkit prefetch")
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in
                step()
                let waiters = prefetching.removeValue(forKey: id) ?? []
                if let list, waiters.isEmpty { prefetched[id] = list }
                waiters.forEach { $0(list) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { prefetched.removeAll() }
    }

    /// Records the rule lists in use now, for the next launch's prefetch (only when they changed).
    private static func recordLaunchLists() {
        let ids = Array(Set(profiles.values.filter { $0.profile != nil }.compactMap { $0.prepared.ads?.identifier })).sorted()
        if recordedLaunchLists == nil {   // the Chromium engine doesn't prefetch: what the file says now
            recordedLaunchLists = (try? Data(contentsOf: launchListsFile)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        }
        guard ids != recordedLaunchLists else { return }
        recordedLaunchLists = ids
        let file = launchListsFile
        queue.async {
            guard let data = try? JSONEncoder().encode(ids) else { return }
            try? data.write(to: file, options: [.atomic])
        }
    }

    private static func compile(identifier: String, source: String? = nil, makeJSON: @escaping () throws -> Data,
                                completion: @escaping (Compilation) -> Void) {
        if compiling[identifier] != nil { compiling[identifier]!.append(completion); return }
        compiling[identifier] = [completion]
        if let list = prefetched.removeValue(forKey: identifier) { return finish(identifier, .rules(list)) }
        if prefetching[identifier] != nil {
            prefetching[identifier]!.append { list in
                if let list { finish(identifier, .rules(list)) } else { lookUpOrCompile(identifier: identifier, source: source, makeJSON: makeJSON) }
            }
            return
        }
        lookUpOrCompile(identifier: identifier, source: source, makeJSON: makeJSON)
    }
    private static func lookUpOrCompile(identifier: String, source: String?, makeJSON: @escaping () throws -> Data) {
        let directory = AppPaths.dataDirectory.appendingPathComponent("Blocking/WebKit", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return finish(identifier, .failed) }
        guard let store = WKContentRuleListStore(url: directory) else { return finish(identifier, .failed) }
        removeOldLists(store)
        func inProcess() {
            queue.async {
                // The conversion and its text (megabytes) off the main thread.
                let json = try? makeJSON()
                let text = json.flatMap { String(data: $0, encoding: .utf8) }
                let empty = json == Data("[]".utf8)
                DispatchQueue.main.async {
                    guard let text else { return finish(identifier, .failed) }
                    // Our converter serializes an empty result as this compact
                    // array. WebKit rejects it, but it is a valid selection:
                    // cosmetics and native-only network rules still apply.
                    if empty { return finish(identifier, .empty) }
                    store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: text) { list, _ in
                        finish(identifier, list.map(Compilation.rules) ?? .failed)
                    }
                }
            }
        }
        func compileInChild(_ source: String) {
            BlockingRuleCompiler.compile(text: source, identifier: identifier, directory: directory) { outcome in
                switch outcome {
                case .compiled:
                    // The child wrote it to the store; this process only maps the compiled file.
                    store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                        if let list { finish(identifier, .rules(list)) } else { inProcess() }
                    }
                case .empty: finish(identifier, .empty)
                // Not compiled there (an invalid list, or no child): the previous path decides, so the result is the
                // same as before either way.
                case .failed, .unavailable: inProcess()
                }
            }
        }
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            if let list { return finish(identifier, .rules(list)) }
            guard let source else { return inProcess() }
            // wkrules: the app's own default lists come compiled with the app (first launch ever); anything else, or a
            // bundled copy this WebKit can't read, is compiled as before.
            BundledRuleLists.install(identifier: identifier, into: directory) { installed in
                guard installed else { return compileInChild(source) }
                store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                    if let list {
                        LaunchTimeline.mark("blocking webkit bundled rules in use")
                        return finish(identifier, .rules(list))
                    }
                    LaunchTimeline.mark("blocking webkit bundled rules rejected")
                    BundledRuleLists.reject(identifier: identifier, in: directory)
                    compileInChild(source)
                }
            }
        }
    }
    private static func finish(_ id: String, _ result: Compilation) {
        let callbacks = compiling.removeValue(forKey: id) ?? []
        // After a compile here (or a child's, or a lookup): what it freed goes back to macOS (AllocatorCacheFlush).
        AllocatorCacheFlush.afterCompile()
        callbacks.forEach { $0(result) }
    }
    static func install(_ prepared: Prepared, profile: WebKitProfile) {
        profiles = profiles.filter { $0.value.profile != nil }
        let id = ObjectIdentifier(profile)
        if let previous = profiles[id]?.prepared {
            if let ads = previous.ads { profile.userContent.remove(ads) }
            if let cookies = previous.cookies { profile.userContent.remove(cookies) }
            if let script = previous.videoScript {
                let others = profile.userContent.userScripts.filter { $0 !== script }
                profile.userContent.removeAllUserScripts()
                others.forEach(profile.userContent.addUserScript)
            }
        }
        if let script = prepared.videoScript { profile.userContent.addUserScript(script) }
        if let ads = prepared.ads { profile.userContent.add(ads) }
        if let cookies = prepared.cookies { profile.userContent.add(cookies) }
        profiles[id] = ProfileState(profile, prepared)
        releaseNavigations(profile)
        if !profile.privateSession { recordLaunchLists() }
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

/// wkrules: the default lists (the bundled EasyList + EasyPrivacy seeds, as a fresh profile selects them) compiled into a
/// WKContentRuleList at build time (scripts/build-app.sh, `precompile_rules`), so the first launch ever looks the list up
/// (~0.3 s) instead of compiling it (~4.4 s) before any page may load. Contents/Resources/BlockingRules holds
/// `rules.json` ({"lists": [{"identifier", "file", "size", "webkitFileVersion"}]}) and each list's WebKit store file,
/// LZFSE-compressed (37.7 → 15.8 MB, 0.05 s to expand).
///
/// The file is expanded into the data folder's store under WebKit's own file name, then looked up there like any
/// compiled list, so the next launch's prefetch and every later list update work as before (an update has another
/// identifier: it compiles in the child, with the previous rules in force). A WebKit that can't read it (another
/// rule-list format version, after a macOS update) fails the lookup: the file is removed and the list compiled as before.
enum BundledRuleLists {
    private struct Manifest: Decodable {
        struct List: Decodable { let identifier: String; let file: String; let size: Int }
        let lists: [List]
    }
    private static let queue = DispatchQueue(label: "org.airc.blocking-bundled-rules", qos: .userInitiated)
    private static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent("BlockingRules", isDirectory: true) }
    private static var disabled: Bool {
        #if AIRC_TESTING
        // Before/after on one test binary (artifacts/wkrules): AIRC_WKRULES_BASELINE=1 compiles as 0.1.24 did.
        return ProcessInfo.processInfo.environment["AIRC_WKRULES_BASELINE"] == "1"
        #else
        return false
        #endif
    }
    private static func storeFile(_ identifier: String, in directory: URL) -> URL {
        directory.appendingPathComponent("ContentRuleList-" + identifier)
    }

    /// Expands the bundled compiled list for `identifier` into the store at `directory` (off the main thread);
    /// `completion(true)` on the main queue once it is there, false when the app has none for it (or it can't be written).
    static func install(identifier: String, into directory: URL, completion: @escaping (Bool) -> Void) {
        guard !disabled, let folder, identifier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return completion(false) }
        let step = LaunchTimeline.begin("blocking webkit bundled rules")
        queue.async {
            let ok = expand(identifier: identifier, folder: folder, directory: directory)
            DispatchQueue.main.async { step(); completion(ok) }
        }
    }
    static func reject(identifier: String, in directory: URL) {
        try? FileManager.default.removeItem(at: storeFile(identifier, in: directory))
    }

    private final class Count { var bytes = 0 }
    private static func expand(identifier: String, folder: URL, directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("rules.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              let entry = manifest.lists.first(where: { $0.identifier == identifier }),
              !entry.file.contains("/") else { return false }
        let fm = FileManager.default
        let target = storeFile(identifier, in: directory)
        let temporary = directory.appendingPathComponent(".bundled-\(UUID().uuidString)")
        do {
            // Mapped, and expanded in 1 MB pieces straight to the file: no 38 MB buffer in this process.
            let input = try Data(contentsOf: folder.appendingPathComponent(entry.file), options: .alwaysMapped)
            guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return false }
            let output = try FileHandle(forWritingTo: temporary)
            let count = Count()
            let filter = try OutputFilter(.decompress, using: .lzfse, bufferCapacity: 1 << 20) { piece in
                guard let piece else { return }
                try output.write(contentsOf: piece); count.bytes += piece.count
            }
            var offset = input.startIndex
            while offset < input.endIndex {
                let end = min(offset + (1 << 20), input.endIndex)
                try filter.write(input[offset..<end]); offset = end
            }
            try filter.finalize()
            try output.close()
            guard count.bytes == entry.size else { try? fm.removeItem(at: temporary); return false }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: temporary, to: target)
            return true
        } catch {
            try? fm.removeItem(at: temporary)
            return false
        }
    }
}

/// The YouTube scriptlets per list text (WebKitBlocking.prepareVideo), next to the compiled WebKit rule lists:
/// Blocking/WebKit/scriptlets-<list digest>-<app build + hosts digest>.json, written atomically; the newest 8 are kept. A file that
/// can't be read or doesn't match is ignored (the scriptlets are made again).
enum VideoScriptletCache {
    private static let queue = DispatchQueue(label: "org.airc.blocking-scriptlets", qos: .userInitiated)
    private static var directory: URL { AppPaths.dataDirectory.appendingPathComponent("Blocking/WebKit", isDirectory: true) }
    #if AIRC_TESTING
    private static var disabled: Bool { LinkLaunchBaseline.enabled }
    #else
    private static let disabled = false
    #endif
    private static func file(digest: String, hosts: [String]) -> URL {
        // The scriptlet resources ship with the app: another build makes them again.
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + "/" + (Bundle.main.infoDictionary?["AircRevision"] as? String ?? "")
        let key = BlockingListStore.digest(Data(([build] + hosts).joined(separator: "\n").utf8)).prefix(16)
        return directory.appendingPathComponent("scriptlets-\(digest)-\(key).json")
    }
    static func read(digest: String, hosts: [String]) async -> [String: String]? {
        guard !disabled else { return nil }
        let url = file(digest: digest, hosts: hosts)
        return await withCheckedContinuation { resume in
            queue.async {
                let value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                resume.resume(returning: value.flatMap { Set($0.keys) == Set(hosts) ? $0 : nil })
            }
        }
    }
    static func write(_ scripts: [String: String], digest: String, hosts: [String]) {
        guard !disabled else { return }
        let url = file(digest: digest, hosts: hosts), dir = directory
        queue.async {
            guard let data = try? JSONEncoder().encode(scripts) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
            let fm = FileManager.default
            let old = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("scriptlets-") }
                .sorted { a, b in
                    let d = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
                    return d(a) > d(b)
                }
            for u in old.dropFirst(8) where u != url { try? fm.removeItem(at: u) }
        }
    }
}

extension WebKitTab {
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func blockingAction(_ view: WKWebView, identifier: String, action: NSObject, url: URL) {
        WebKitBlocking.performed(self, identifier: identifier, action: action)
    }
}

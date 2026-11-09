// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import Combine
import AircKit

@MainActor final class BlockingCenter: ObservableObject {
    static private(set) var shared: BlockingCenter?
    let settings: BlockingSettings
    let lists: BlockingListStore
    private weak var app: AppDelegate?
    private let engine: BrowserEngine
    private let blocking: EngineBlocking?
    @Published private(set) var failures: [String: String] = [:]
    private var contexts: [ObjectIdentifier: Context] = [:]
    private var filters: [String: BlockingFilter] = [:]
    private var compiling: [String: Task<BlockingFilter, Error>] = [:]
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private final class Context {
        weak var profile: EngineProfile?
        let id: String
        let privatePolicy: PrivateBlockingPolicy?
        var filter: BlockingFilter?
        var revision = 0
        var waiters: [() -> Void] = []
        init(_ profile: EngineProfile, id: String, isPrivate: Bool) {
            self.profile = profile; self.id = id
            privatePolicy = isPrivate ? PrivateBlockingPolicy() : nil
        }
    }

    init(app: AppDelegate) {
        self.app = app; engine = app.engine; blocking = app.engine as? EngineBlocking
        settings = BlockingSettings(directory: AppPaths.dataDirectory,
            existingProfiles: app.store.orderedProfiles.map(\.id))
        // Every scripted run, including parityp20c, disables list-host traffic.
        // The check injects local fixture lists instead.
        lists = BlockingListStore(directory: AppPaths.dataDirectory,
            seeds: Bundle.main.resourceURL?.appendingPathComponent("BlockingLists"),
            networkAllowed: !app.options.isAutomated && !app.options.isScripted)
        #if AIRC_TESTING
        // Install identical fixture inputs before either isolated memory run's
        // first profile gate. The on run compiles its final rules exactly once;
        // the off run never warms a blocking engine before its baseline sample.
        if ["parityp20c-memory-off", "parityp20c-memory-on"].contains(app.options.script) {
            lists.installCheckRules(BlockingCheckFixtures.rules)
            for id in app.store.orderedProfiles.map(\.id) {
                settings.update(id) {
                    $0.enabled = app.options.script == "parityp20c-memory-on"
                    $0.selectedLists = ["easylist", "easyprivacy", "check-fixture"]
                }
            }
        }
        #endif
        Self.shared = self
        settings.didChange = { [weak self] id in
            Task { @MainActor in self?.applyAll(id) }
        }
        lists.didChange = { [weak self] in
            guard let self else { return }
            for id in Set(self.contexts.values.map(\.id)) { self.applyAll(id) }
        }
        lists.validate = { [weak self] id, text in
            guard let self else { throw BlockingFilter.Failure.unavailable }
            // Validate each affected combined selection before committing a new
            // source snapshot. Per-list success alone can exceed aggregate
            // engine/WK limits and otherwise leave the next launch unprotected.
            var selections = Set(self.settings.profiles.values.map(\.selectedLists).filter { $0.contains(id) })
            selections.insert([id])
            for selection in selections {
                try await Self.validateRules(self.lists.text(for: selection, replacing: (id, text)))
            }
        }
        subscription = settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        BlockingCosmetics.start(engine: engine, center: self)
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }
    deinit { timer?.invalidate() }

    func prepare(profile: EngineProfile, id: String, isPrivate: Bool = false, completion: @escaping () -> Void) {
        contexts = contexts.filter { $0.value.profile != nil }
        let key = ObjectIdentifier(profile)
        if contexts[key] == nil { contexts[key] = Context(profile, id: id, isPrivate: isPrivate) }
        apply(contexts[key]!, completion: completion)
    }
    func release(profile: EngineProfile) {
        contexts.removeValue(forKey: ObjectIdentifier(profile))
        pruneFilters()
    }
    func profileName(_ id: String) -> String { app?.store.profile(id)?.name ?? "this profile" }
    func contextID(for profile: EngineProfile) -> String? { contexts[ObjectIdentifier(profile)]?.id }
    func isPrivate(_ profile: EngineProfile) -> Bool { contexts[ObjectIdentifier(profile)]?.privatePolicy != nil }
    func enabled(for tab: EngineTab) -> Bool {
        guard let url = tab.url, let context = contexts[ObjectIdentifier(tab.profile)] else { return false }
        let config = settings.configuration(context.id)
        return context.privatePolicy?.enabled(for: url, regular: config) ?? config.blocks(url)
    }
    func profileEnabled(for tab: EngineTab) -> Bool {
        contextID(for: tab.profile).map { settings.configuration($0).enabled } ?? false
    }
    func count(for tab: EngineTab) -> Int? { blocking?.blockedRequests(in: tab) }
    func setSiteEnabled(_ enabled: Bool, tab: EngineTab, completion: (() -> Void)? = nil) {
        guard let url = tab.url, let context = contexts[ObjectIdentifier(tab.profile)] else { completion?(); return }
        if let policy = context.privatePolicy {
            policy.setEnabled(enabled, for: url)
            apply(context) { tab.reload(); completion?() }
        } else {
            // The regular setting change schedules applyAll; reload only after
            // this tab's profile is installed, avoiding an unprotected reload.
            let previous = settings.didChange; settings.didChange = nil
            settings.setException(!enabled, url: url, profile: context.id)
            settings.didChange = previous
            applyAll(context.id, reload: tab, completion: completion)
        }
        objectWillChange.send()
    }
    func setList(_ id: String, selected: Bool, profile: String) async -> Bool {
        if selected && !lists.has(id) {
            do { try await lists.downloadOptional(id) } catch { return false }
        }
        // If another list changed while compilation ran, revalidate the actual
        // combined selection instead of overwriting the newer user choice.
        while true {
            let original = settings.configuration(profile).selectedLists
            var next = original
            if selected { next.insert(id) } else { next.remove(id) }
            do { try await Self.validateRules(lists.text(for: next)) } catch { return false }
            guard settings.configuration(profile).selectedLists == original else { continue }
            settings.update(profile) { $0.selectedLists = next }
            return true
        }
    }
    private static func validateRules(_ text: String) async throws {
        _ = try await Task.detached(priority: .utility) { try BlockingFilter.compile(text) }.value
        let policy = EngineBlockingPolicy(enabled: true, exceptions: [], blockThirdPartyCookies: false)
        let good = await withCheckedContinuation { resume in
            WebKitBlocking.prepare(text: text, policy: policy, privateSession: false) { resume.resume(returning: $0 != nil) }
        }
        if !good { throw BlockingFilter.Failure.invalidRules }
    }
    func refresh(force: Bool = false) async {
        let selected = settings.profiles.values.reduce(into: Set<String>()) { $0.formUnion($1.selectedLists) }
        await lists.refresh(selected: selected, force: force)
    }
    func cosmeticsEnabled(for tab: EngineTab, url: String, isMainFrame: Bool) -> Bool {
        guard let context = contexts[ObjectIdentifier(tab.profile)],
              context.filter != nil,
              let topURL = isMainFrame ? URL(string: url) : tab.url else { return false }
        let config = settings.configuration(context.id)
        return context.privatePolicy?.enabled(for: topURL, regular: config) ?? config.blocks(topURL)
    }
    func selectors(for tab: EngineTab, url: String, tokens: String?, isMainFrame: Bool) -> [String] {
        guard cosmeticsEnabled(for: tab, url: url, isMainFrame: isMainFrame),
              let context = contexts[ObjectIdentifier(tab.profile)] else { return [] }
        return context.filter?.cosmetics(url: url, tokens: tokens) ?? []
    }
    func blockers(profile id: String) -> [(id: String, name: String)] {
        guard let profile = app?.profiles.engineProfile(for: id) else { return [] }
        return engine.installedExtensions(for: profile).compactMap { value in
            guard value["enabled"] as? Bool == true, let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
            let lower = name.lowercased()
            guard ["ublock", "adblock", "adguard", "ghostery", "privacy badger"].contains(where: lower.contains) else { return nil }
            return (id, name)
        }
    }
    func disableOtherBlockers(profile id: String, extensions: [String]) -> Bool {
        guard let profile = app?.profiles.engineProfile(for: id), let blocking else { return false }
        // The notice lists these exact IDs. Recheck that they are still blocker
        // candidates; never disable an arbitrary extension from a page message.
        let candidates = Set(blockers(profile: id).map(\.id))
        var good = true
        for ext in extensions where candidates.contains(ext) {
            if !blocking.disableBlockerExtension(ext, profile: profile) { good = false }
        }
        if good { settings.dismissCoexistence(profile: id, extensionIDs: extensions) }
        objectWillChange.send(); return good
    }
    #if AIRC_TESTING
    /// Only synthetic check lists; a scripted process cannot contact list hosts.
    func installCheckRules(_ rules: String, profile id: String, enabled: Bool = true, includeDefaults: Bool = false, completion: @escaping () -> Void) {
        guard app?.options.isScripted == true else { completion(); return }
        lists.installCheckRules(rules)
        let previous = settings.didChange; settings.didChange = nil
        settings.update(id) {
            $0.enabled = enabled
            $0.selectedLists = includeDefaults ? ["easylist", "easyprivacy", "check-fixture"] : ["check-fixture"]
            $0.exceptions = []
        }
        settings.didChange = previous
        applyAll(id, completion: completion)
    }
    func setCheckEnabled(_ enabled: Bool, profile id: String, completion: @escaping () -> Void) {
        let previous = settings.didChange; settings.didChange = nil
        settings.setEnabled(enabled, profile: id); settings.didChange = previous
        applyAll(id, completion: completion)
    }
    #endif

    private func applyAll(_ id: String, reload: EngineTab? = nil, completion: (() -> Void)? = nil) {
        let targets = contexts.values.filter { $0.id == id && $0.profile != nil }
        guard !targets.isEmpty else { completion?(); return }
        var remaining = targets.count
        for context in targets {
            apply(context) {
                remaining -= 1
                if remaining == 0 { reload?.reload(); completion?() }
            }
        }
    }
    private func apply(_ context: Context, completion: @escaping () -> Void) {
        guard let profile = context.profile, let blocking else { completion(); return }
        // A newer update supersedes the work, but must still hold every initial
        // navigation/reload gate until its policy installation finishes.
        context.revision += 1
        let revision = context.revision
        context.waiters.append(completion)
        let config = settings.configuration(context.id)
        let policy = EngineBlockingPolicy(enabled: config.enabled,
            exceptions: context.privatePolicy?.exceptions(regular: config) ?? config.exceptions,
            blockThirdPartyCookies: config.blockThirdPartyCookies)
        let text: String
        do { text = config.enabled ? try lists.text(for: config.selectedLists) : "" }
        catch { failures[context.id] = "Blocking lists couldn’t be loaded."; finishApply(context, revision: revision); return }
        let digest = BlockingListStore.digest(Data(text.utf8))
        Task { @MainActor in
            let filter: BlockingFilter
            do {
                if let cached = filters[digest] { filter = cached }
                else {
                    let task = compiling[digest] ?? Task.detached(priority: .userInitiated) { try BlockingFilter.compile(text) }
                    compiling[digest] = task
                    do { filter = try await task.value } catch { compiling[digest] = nil; throw error }
                    filters[digest] = filter; compiling[digest] = nil
                }
            } catch {
                guard context.revision == revision else { return }
                failures[context.id] = "Protection couldn’t start. Your previous rules are still in use."
                finishApply(context, revision: revision); return
            }
            guard context.revision == revision else { return }
            guard contexts[ObjectIdentifier(profile)] === context else { finishApply(context, revision: revision); return }
            blocking.configureBlocking(text: text, policy: policy, profile: profile) { [weak self, weak context] ok in
                MainActor.assumeIsolated {
                    guard let self, let context, context.revision == revision else { return }
                    if ok { context.filter = filter; self.failures[context.id] = blocking.blockingConfigurationWarning(in: profile) }
                    else { self.failures[context.id] = "Protection couldn’t be updated. Your previous rules are still in use." }
                    self.pruneFilters(); self.objectWillChange.send(); self.finishApply(context, revision: revision)
                }
            }
        }
    }
    private func finishApply(_ context: Context, revision: Int) {
        guard context.revision == revision else { return }
        let waiters = context.waiters; context.waiters.removeAll()
        waiters.forEach { $0() }
    }
    private func pruneFilters() {
        let live = Set(contexts.values.compactMap { $0.filter }.map(ObjectIdentifier.init))
        filters = filters.filter { live.contains(ObjectIdentifier($0.value)) }
    }
}

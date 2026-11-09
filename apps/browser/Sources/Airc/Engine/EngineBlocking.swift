// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

struct EngineBlockingPolicy {
    var enabled: Bool
    var exceptions: Set<String>
    var blockThirdPartyCookies: Bool
}

/// Small engine boundary. UI never imports WebKit or AircCore for protection.
protocol EngineBlocking: AnyObject {
    func configureBlocking(text: String, policy: EngineBlockingPolicy, profile: EngineProfile,
                           completion: @escaping (Bool) -> Void)
    func blockingConfigurationWarning(in profile: EngineProfile) -> String?
    func blockedRequests(in tab: EngineTab) -> Int?
    func disableBlockerExtension(_ id: String, profile: EngineProfile) -> Bool
}
extension EngineBlocking {
    func blockingConfigurationWarning(in profile: EngineProfile) -> String? { nil }
    func disableBlockerExtension(_ id: String, profile: EngineProfile) -> Bool { false }
}

#if canImport(AircCore)
import AircCore
extension ChromiumEngine: EngineBlocking {
    func configureBlocking(text: String, policy: EngineBlockingPolicy, profile: EngineProfile,
                           completion: @escaping (Bool) -> Void) {
        guard let native = core(of: profile), let wk = webKitProfile(for: profile) else { return completion(false) }
        let current = BlockingInstallation.begin(profile)
        // Prepare WK rules before applying either side's new policy. A failed
        // conversion leaves both sides on their previous compiled snapshot.
        WebKitBlocking.prepare(text: text, policy: policy, privateSession: native.offTheRecord) { [self] prepared in
            guard current(), let prepared else { return completion(false) }
            core.setBlockingLists(text, enabled: policy.enabled, profile: native) { [self] installed in
                guard current(), installed else { return completion(false) }
                let old = ChromiumBlockingPolicy.state(for: profile)
                for host in old.exceptions.subtracting(policy.exceptions) {
                    _ = core.setBlockingException(false, site: "https://" + host + "/", profile: native)
                }
                for host in policy.exceptions {
                    _ = core.setBlockingException(true, site: "https://" + host + "/", profile: native)
                }
                old.exceptions = policy.exceptions
                old.cookieManaged = !core.setThirdPartyCookiesBlocked(policy.blockThirdPartyCookies, profile: native)
                WebKitBlocking.install(prepared, profile: wk)
                completion(true)
            }
        }
    }
    func blockingConfigurationWarning(in profile: EngineProfile) -> String? {
        ChromiumBlockingPolicy.state(for: profile).cookieManaged ? "Your browser policy manages third-party cookies. Ad and tracker blocking is active according to this profile’s setting." : nil
    }
    func blockedRequests(in tab: EngineTab) -> Int? {
        if let wk = tab as? WebKitTab { return WebKitBlocking.count(for: wk) }
        return core(of: tab).map { Int($0.blockedRequestCount) }
    }
    func disableBlockerExtension(_ id: String, profile: EngineProfile) -> Bool {
        guard let p = core(of: profile) else { return false }
        return core.disableBlockingExtension(id, profile: p)
    }
}
private final class ChromiumBlockingPolicy {
    weak var profile: EngineProfile?
    var exceptions: Set<String> = []
    var cookieManaged = false
    static private var states: [ObjectIdentifier: ChromiumBlockingPolicy] = [:]
    init(profile: EngineProfile) { self.profile = profile }
    static func state(for profile: EngineProfile) -> ChromiumBlockingPolicy {
        states = states.filter { $0.value.profile != nil }
        let key = ObjectIdentifier(profile)
        if let old = states[key] { return old }
        let state = ChromiumBlockingPolicy(profile: profile); states[key] = state; return state
    }
}
#endif

/// Async compilation may finish out of order. Only the most recent request for
/// a still-live profile may replace the policy on either engine.
final class BlockingInstallation {
    weak var profile: EngineProfile?
    var generation = 0
    static private var entries: [ObjectIdentifier: BlockingInstallation] = [:]
    init(_ profile: EngineProfile) { self.profile = profile }
    static func begin(_ profile: EngineProfile) -> () -> Bool {
        entries = entries.filter { $0.value.profile != nil }
        let key = ObjectIdentifier(profile)
        let state = entries[key] ?? BlockingInstallation(profile)
        entries[key] = state; state.generation += 1
        let generation = state.generation
        return { [weak state] in state?.profile != nil && state?.generation == generation }
    }
}

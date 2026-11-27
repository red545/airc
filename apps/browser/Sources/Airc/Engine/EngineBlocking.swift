// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

struct EngineBlockingPolicy {
    var enabled: Bool
    var exceptions: Set<String>
    var blockThirdPartyCookies: Bool
}

/// Small engine boundary. UI never imports WebKit or AircCore for protection.
protocol EngineBlocking: AnyObject {
    /// Installs `text` with `policy` for `profile`; `completion` once every page kind of the profile has it (false:
    /// the previous rules stay). `ready`, at most once and before `completion`: the profile's pages may start loading
    /// now. Every page kind is protected from its first request (linklaunch: on Chromium the hybrid WebKit pages'
    /// navigations wait for their own rules, WebKitBlocking.holdNavigations), but not every one has the new rules yet.
    func configureBlocking(text: String, policy: EngineBlockingPolicy, profile: EngineProfile,
                           ready: (() -> Void)?, completion: @escaping (Bool) -> Void)
    func blockingConfigurationWarning(in profile: EngineProfile) -> String?
    func blockedRequests(in tab: EngineTab) -> Int?
    func disableBlockerExtension(_ id: String, profile: EngineProfile) -> Bool
    /// The page script's element-hiding selectors from the engine's own installed rules (the same library and lists as
    /// BlockingFilter), or nil when the engine has none (WebKit). linklaunch: they answer while the app's filter compiles.
    func engineCosmetics(for tab: EngineTab, url: String, tokens: String?) -> [String]?
    var answersCosmetics: Bool { get }
    /// Before a profile's first install, when the engine can't answer cosmetic requests itself: holds its pages'
    /// navigations until the returned closure runs (the app's filter is ready), so the first page never paints before
    /// its element hiding. Nil: no hold needed.
    func holdNavigationsForCosmetics(profile: EngineProfile) -> (() -> Void)?
}
extension EngineBlocking {
    func engineCosmetics(for tab: EngineTab, url: String, tokens: String?) -> [String]? { nil }
    var answersCosmetics: Bool { false }
    func holdNavigationsForCosmetics(profile: EngineProfile) -> (() -> Void)? { nil }
    func configureBlocking(text: String, policy: EngineBlockingPolicy, profile: EngineProfile,
                           completion: @escaping (Bool) -> Void) {
        configureBlocking(text: text, policy: policy, profile: profile, ready: nil, completion: completion)
    }
    func blockingConfigurationWarning(in profile: EngineProfile) -> String? { nil }
    func disableBlockerExtension(_ id: String, profile: EngineProfile) -> Bool { false }
}

#if canImport(AircCore)
import AircCore
extension ChromiumEngine: EngineBlocking {
    func configureBlocking(text: String, policy: EngineBlockingPolicy, profile: EngineProfile,
                           ready: (() -> Void)?, completion: @escaping (Bool) -> Void) {
        guard let native = core(of: profile) else { return completion(false) }
        #if AIRC_TESTING
        if LinkLaunchBaseline.enabled {
            guard let wk = webKitProfile(for: profile) else { return completion(false) }
            return configureBlockingSerially(text: text, policy: policy, profile: profile, native: native, wk: wk, completion: completion)
        }
        #endif
        let current = BlockingInstallation.begin(profile)
        let state = ChromiumBlockingPolicy.state(for: profile)
        // linklaunch: before the profile's first install its pages may already be made (WebContents, renderer) while
        // the engine holds their navigations (AircProfile's navigation hold: a NavigationThrottle defers each request
        // until released) for Chromium's rules. The hold is the original profile's, so a private profile (its
        // off-the-record child) waits for its install as before instead.
        if !state.installed, !state.holding, !native.offTheRecord {
            state.holding = true
            native.holdNavigations(untilRulesetsOf: "airc-blocking-lists")
            LaunchTimeline.mark("blocking chromium navigations held \(profile.directory)")
        }
        let early = state.holding
        var chromium: Bool?, webKit: Bool?
        var webKitHeld = false
        func settle() {
            guard let c = chromium, let w = webKit else { return }
            completion(c && w)
        }
        // The two engines' rules install side by side, and a Chromium page needs only Chromium's. Before,
        // every Chromium page (a link at launch too) waited for the hybrid WebKit pages' rules first: a lookup and the
        // YouTube scriptlets (~0.4 s), or a whole WebKit compile (~4.4 s) when it wasn't cached.
        func installChromium() {
            let coreStep = LaunchTimeline.begin("blocking chromium lists \(profile.directory)")
            LinkLaunchBaseline.afterTestDelay { [self] in
            core.setBlockingLists(text, enabled: policy.enabled, profile: native) { [self] installed in
                coreStep()
                guard current() else { chromium = false; return settle() }
                guard installed else {
                    // As the profile gate did on a failed install: pages go ahead with what the profile has (the notice).
                    if state.holding { state.holding = false; native.releaseNavigationHold("airc blocking lists failed") }
                    chromium = false; return settle()
                }
                let old = state
                for host in old.exceptions.subtracting(policy.exceptions) {
                    _ = core.setBlockingException(false, site: "https://" + host + "/", profile: native)
                }
                for host in policy.exceptions {
                    _ = core.setBlockingException(true, site: "https://" + host + "/", profile: native)
                }
                old.exceptions = policy.exceptions
                old.cookieManaged = !core.setThirdPartyCookiesBlocked(policy.blockThirdPartyCookies, profile: native)
                chromium = true
                state.installed = true
                if state.holding { state.holding = false; native.releaseNavigationHoldReady() }
                LaunchTimeline.mark("blocking chromium ready \(profile.directory)")
                // A page may load only once the hybrid WebKit side holds its navigations too (below, this same turn;
                // the engine replies on a later one).
                if !early, webKitHeld { ready?() }
                settle()
            }
            }
        }
        // launchtails: Chromium's lists start compiling first. Making the profile's WebKit side (its website data
        // store, 46–56 ms on main at launch on the build Mac) used to come before, on the link-at-launch page's critical path.
        let chromiumFirst = !LaunchTailsBaseline.enabled
        if chromiumFirst { installChromium() }
        // littleaircfast: a profile without a WebKit side yet doesn't make one here (its website data store, ~50 ms on
        // main at launch, before the launch's first window). Its WebKit rules are prepared all the same; the side is
        // made when a page (or its site data) first needs it, and then holds its navigations until those rules are in
        // (HybridProfileState.webKitSideMade), so no WebKit request ever goes out before its rules.
        if LittleAircFast.lazyWebKitSide, let hybrid = (profile as? ChromiumProfile)?.hybrid, hybrid.webKit == nil {
            LaunchTimeline.mark("blocking webkit side deferred \(profile.directory)")
            hybrid.webKitRulesPreparing = true
            webKitHeld = true
            if early { ready?() } else if chromium == true { ready?() }
            if !chromiumFirst { installChromium() }
            let wkStep = LaunchTimeline.begin("blocking webkit rules \(profile.directory)")
            LittleAircFast.afterWebKitTestDelay {
            WebKitBlocking.prepare(text: text, policy: policy, privateSession: native.offTheRecord) { prepared in
                wkStep()
                guard current() else { webKit = false; return settle() }
                guard let prepared else { hybrid.webKitRulesFinished(nil); webKit = false; return settle() }
                let videoStep = LaunchTimeline.begin("blocking video scriptlets \(profile.directory)")
                WebKitBlocking.prepareVideo(text: text, prepared: prepared) { prepared in
                    videoStep()
                    guard current() else { webKit = false; return settle() }
                    hybrid.webKitRulesFinished(prepared)
                    webKit = prepared != nil
                    settle()
                }
            }
            }
            return
        }
        let wkProfileStep = LaunchTimeline.begin("blocking webkit profile \(profile.directory)")
        let wkProfile = webKitProfile(for: profile)
        wkProfileStep()
        guard let wk = wkProfile else {
            // No WebKit side (as before: nothing installed). Chromium's install, if started, settles its own part.
            webKit = false; webKitHeld = true
            if !chromiumFirst { installChromium() }
            if early { ready?() } else if chromium == true { ready?() }
            return settle()
        }
        // WebKit pages of the profile hold their navigations until their own rules are in (only before the first
        // install; an update keeps the previous rules in force until the new ones replace them).
        WebKitBlocking.holdNavigations(wk)
        webKitHeld = true
        if early { ready?() } else if chromium == true { ready?() }
        if !chromiumFirst { installChromium() }
        let wkStep = LaunchTimeline.begin("blocking webkit rules \(profile.directory)")
        WebKitBlocking.prepare(text: text, policy: policy, privateSession: native.offTheRecord) { prepared in
            wkStep()
            guard current() else { webKit = false; return settle() }
            guard let prepared else { WebKitBlocking.releaseNavigations(wk); webKit = false; return settle() }
            let videoStep = LaunchTimeline.begin("blocking video scriptlets \(profile.directory)")
            WebKitBlocking.prepareVideo(text: text, prepared: prepared) { prepared in
                videoStep()
                guard current() else { webKit = false; return settle() }
                // A failure keeps the WebKit side's previous rules, as before.
                if let prepared { WebKitBlocking.install(prepared, profile: wk) } else { WebKitBlocking.releaseNavigations(wk) }
                webKit = prepared != nil
                settle()
            }
        }
    }
    #if AIRC_TESTING
    /// 0.1.18's order (AIRC_LINKLAUNCH_BASELINE=1, the before/after on one binary): WebKit rules, then the scriptlets,
    /// then Chromium's lists; pages wait for all three.
    private func configureBlockingSerially(text: String, policy: EngineBlockingPolicy, profile: EngineProfile,
                                           native: AircProfile, wk: WebKitProfile, completion: @escaping (Bool) -> Void) {
        let current = BlockingInstallation.begin(profile)
        let wkStep = LaunchTimeline.begin("blocking webkit rules \(profile.directory)")
        WebKitBlocking.prepare(text: text, policy: policy, privateSession: native.offTheRecord) { [self] prepared in
            wkStep()
            guard current(), let prepared else { return completion(false) }
            let videoStep = LaunchTimeline.begin("blocking video scriptlets \(profile.directory)")
            WebKitBlocking.prepareVideo(text: text, prepared: prepared) { [self] prepared in
                videoStep()
                guard current(), let prepared else { return completion(false) }
                let coreStep = LaunchTimeline.begin("blocking chromium lists \(profile.directory)")
                core.setBlockingLists(text, enabled: policy.enabled, profile: native) { [self] installed in
                    coreStep()
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
    }
    #endif
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
    var answersCosmetics: Bool { true }
    func engineCosmetics(for tab: EngineTab, url: String, tokens: String?) -> [String]? {
        guard let p = core(of: tab.profile) else { return nil }
        if let tokens { return core.blockingGenericCosmetics(forURL: url, tokens: tokens, profile: p) }
        return core.blockingCosmetics(forURL: url, profile: p)["hide_selectors"] as? [String] ?? []
    }
}
private final class ChromiumBlockingPolicy {
    weak var profile: EngineProfile?
    var exceptions: Set<String> = []
    var cookieManaged = false
    /// linklaunch: Chromium's rules were installed once; until then the engine holds the profile's navigations.
    var installed = false
    var holding = false
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

/// linklaunch's before/after switch on one test binary: AIRC_LINKLAUNCH_BASELINE=1 is 0.1.18's launch blocking path.
/// AIRC_LINKLAUNCH_SLOW_RULES=<s> starts each profile's first rule install that much later (launchtimeline's proof
/// that pages made meanwhile don't send a request before their rules are in force). Both test builds only.
enum LinkLaunchBaseline {
    #if AIRC_TESTING
    static let enabled = ProcessInfo.processInfo.environment["AIRC_LINKLAUNCH_BASELINE"] == "1"
    static let testDelay = Double(ProcessInfo.processInfo.environment["AIRC_LINKLAUNCH_SLOW_RULES"] ?? "") ?? 0
    private static var delayed = false
    #endif
    static func afterTestDelay(_ work: @escaping () -> Void) {
        #if AIRC_TESTING
        if testDelay > 0, !delayed {
            delayed = true
            LaunchTimeline.mark("blocking rules delayed \(testDelay) s (test)")
            DispatchQueue.main.asyncAfter(deadline: .now() + testDelay, execute: work)
            return
        }
        #endif
        work()
    }
}

/// launchtails' before/after switch on one test binary: AIRC_LAUNCHTAILS_BASELINE=1 makes a Chromium profile's WebKit
/// side before its Chromium lists start compiling (0.1.63's order). Always off in public builds.
enum LaunchTailsBaseline {
    #if AIRC_TESTING
    static let enabled = ProcessInfo.processInfo.environment["AIRC_LAUNCHTAILS_BASELINE"] == "1"
    #else
    static let enabled = false
    #endif
}

/// littleaircfast's before/after switches on one test binary: AIRC_LITTLEAIRCFAST_BASELINE=1 turns every change off,
/// or a comma-separated list turns off only those (`lazywk`: a Chromium profile's WebKit side made at its first rule
/// install, as before; `window`: the Space texture tiles made in the first window's layout, as before). Always on in
/// public builds.
enum LittleAircFast {
    #if AIRC_TESTING
    private static let off: Set<String> = {
        let v = ProcessInfo.processInfo.environment["AIRC_LITTLEAIRCFAST_BASELINE"] ?? ""
        return v == "1" ? ["lazywk", "window"] : Set(v.split(separator: ",").map { String($0) })
    }()
    static var lazyWebKitSide: Bool { !off.contains("lazywk") }
    static var lightWindow: Bool { !off.contains("window") }
    #else
    static let lazyWebKitSide = true
    static let lightWindow = true
    #endif

    /// AIRC_LAF_SLOW_WEBKIT_RULES=<s> (test builds): a Chromium profile's first lazy WebKit-side rule preparation starts
    /// that much later, so launchtimeline's hybrid run (AIRC_LAF_HYBRID=1) makes the side while its rules still prepare.
    static func afterWebKitTestDelay(_ work: @escaping () -> Void) {
        #if AIRC_TESTING
        if let s = Double(ProcessInfo.processInfo.environment["AIRC_LAF_SLOW_WEBKIT_RULES"] ?? ""), s > 0, !delayedWebKit {
            delayedWebKit = true
            LaunchTimeline.mark("blocking webkit rules delayed \(s) s (test)")
            DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: work)
            return
        }
        #endif
        work()
    }
    #if AIRC_TESTING
    private static var delayedWebKit = false
    #endif
}

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

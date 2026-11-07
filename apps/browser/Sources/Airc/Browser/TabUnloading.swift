// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import ObjectiveC
#if canImport(AircCore)
import AircCore
#endif

/// MEM-3: a tab not seen for a while frees its page (Settings → General, default 30 minutes); never the visible
/// tab, one playing audio or video, one using the camera, microphone or screen, one still loading, or one with typed-in
/// form input. A memory-pressure warning frees the longest-hidden eligible tab. Chromium does this itself
/// (AircProfile.unloadTimeout; its discard keeps the tab's history and reloads on activation): the app only passes the
/// setting on. WebKit pages (the dev engine's, and the Chromium build's DRM pages, docs/user/protected-media.md) the app
/// frees by the same rule: their web view closes, the tab stays with its title and icon, and WebKit's session state
/// brings it back with its history and scroll position when shown. Every site follows the same rule on both engines,
/// but one: pinned tabs and Favorites of the sites people keep open for notifications and calls (AircKit's
/// KeepLoadedSites: Gmail, Slack, Discord…) never unload while Settings → General → "Keep chat and mail sites loaded"
/// is on (the default). Chromium receives a per-page autoDiscardable exemption for both timeout and pressure.
/// Older frameworks fall back to the app timer.
/// No repeating timers: one one-shot for the next deadline.
extension WindowController {
    private static var statesKey = 0

    /// Unloaded WebKit pages' session state (WebKitTab.unloadState), by tab, until they are shown again.
    private var unloadedStates: [String: Any] {
        get { objc_getAssociatedObject(self, &Self.statesKey) as? [String: Any] ?? [:] }
        set { objc_setAssociatedObject(self, &Self.statesKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var unloadAfter: TimeInterval? {
        guard let m = app?.settings.values.unloadAfterMinutes, m > 0 else { return nil }
        return TimeInterval(m * 60)
    }

    #if AIRC_TESTING
    /// For the scripted check: unload after `seconds` instead of the setting.
    static var unloadOverride: TimeInterval?
    var effectiveUnloadAfter: TimeInterval? { Self.unloadOverride ?? unloadAfter }
    #else
    var effectiveUnloadAfter: TimeInterval? { unloadAfter }
    #endif

    /// Settings → General → "Keep chat and mail sites loaded".
    var keepsChatSitesLoaded: Bool { app?.settings.values.keepChatSitesLoaded ?? true }

    #if AIRC_TESTING
    /// For the scripted check: more sites to keep (a loopback host).
    static var keepLoadedTestSites: [String] = []
    private var extraKeptSites: [String] { Self.keepLoadedTestSites }
    #else
    private var extraKeptSites: [String] { [] }
    #endif

    /// A pinned tab or Favorite showing a listed site, while the setting is on: never on the unload timer.
    func keepsLoaded(_ tabID: String) -> Bool {
        guard keepsChatSitesLoaded, let tab = store.tab(tabID), !tab.isToday else { return false }
        return KeepLoadedSites.keepsLoaded(engineTab(for: tabID)?.url ?? URL(string: tab.url), extra: extraKeptSites)
    }

    /// Compatibility with older frameworks that lack the per-tab exemption.
    var appUnloadsChromiumPages: Bool {
        #if canImport(AircCore)
        return app?.engine is ChromiumEngine && keepsChatSitesLoaded
            && !AircTab.instancesRespond(to: NSSelectorFromString("setAutoDiscardable:"))
        #else
        return false
        #endif
    }

    /// The timeout Chromium's own timer gets (0: off).
    private var engineUnloadTimeout: TimeInterval { appUnloadsChromiumPages ? 0 : (effectiveUnloadAfter ?? 0) }

    func setUpUnloading() {
        #if canImport(AircCore)
        // Once for the app (WIN-7: a second window replaced the first's hooks, and MediaLibrary's after them), with the
        // settings of the window used last.
        if let app, let chromium = app.engine as? ChromiumEngine, !app.windowSession.unloadHooksInstalled {
            app.windowSession.unloadHooksInstalled = true
            let apply: (EngineProfile) -> Void = { [weak app, weak self] p in
                guard let c = app?.controller ?? self else { return chromium.setUnloadTimeout(0, for: p) }
                chromium.setUnloadTimeout(c.engineUnloadTimeout, for: p)
                c.applyPictureInPictureSettings(to: p)
            }
            profiles.didLoad = apply
            profiles.loadedProfiles.forEach(apply)
            chromium.discardedStateDidChange = { [weak app] _ in app?.controllers.forEach { $0.scheduleReload() } }
            ChromiumRuntime.memoryPressureHandler = { level in
                NSLog("Airc: memory pressure \(level); the engine freed the longest-hidden eligible tab")
            }
        }
        #endif
        // The app's own pages (all of them on the dev engine; the WebKit pages of the Chromium build).
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.unloadDueTabs(pressure: true) }
        source.resume()
        memoryPressure = source
    }

    /// Settings changed: update per-page exemptions before rescheduling either engine.
    func applyKeepLoadedPolicy() {
        #if canImport(AircCore)
        let selector = NSSelectorFromString("setAutoDiscardable:")
        for (id, page) in pages {
            guard let core = (page as? ChromiumTab)?.core, core.responds(to: selector) else { continue }
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            let setter = unsafeBitCast(core.method(for: selector), to: Setter.self)
            setter(core, selector, !keepsLoaded(id))
        }
        #endif
    }

    func applyUnloadSetting() {
        applyKeepLoadedPolicy()
        #if canImport(AircCore)
        if let chromium = app?.engine as? ChromiumEngine {
            profiles.loadedProfiles.forEach { chromium.setUnloadTimeout(engineUnloadTimeout, for: $0) }
        }
        #endif
        // Pages the app no longer frees (Chromium's, back with the engine) or that are now kept leave the timer; hidden
        // ones that are no longer kept join it.
        for id in hiddenSince.keys where !appUnloads(engineTab(for: id)) || keepsLoaded(id) { hiddenSince[id] = nil }
        noteHiddenPages(chromiumOnly: false)
        queueUnloadCheck()
    }

    var appUnloads: Bool {
        #if canImport(AircCore)
        if app?.engine is ChromiumEngine { return false }
        #endif
        return true
    }

    /// The app frees this page itself: any page on the dev engine, a WebKit page in the Chromium build, and the
    /// Chromium build's Chromium pages while it runs their timer.
    func appUnloads(_ page: EngineTab?) -> Bool {
        page != nil && (appUnloads || ProtectedMedia.isWebKitPage(page) || appUnloadsChromiumPages)
    }

    func pageVisibilityChanged(hidden: String?, shown: String?) {
        applyKeepLoadedPolicy()
        if let shown { hiddenSince[shown] = nil }
        if let hidden, appUnloads(engineTab(for: hidden)), !keepsLoaded(hidden) { hiddenSince[hidden] = Date() }
        if appUnloads || appUnloadsChromiumPages || hidden != nil { queueUnloadCheck() }
    }

    /// Coalesced, off the Space-switch path.
    func queueUnloadCheck() {
        guard appUnloads || appUnloadsChromiumPages || !hiddenSince.isEmpty || unloadTimer != nil, !unloadQueued else { return }
        unloadQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.unloadQueued = false
            self?.scheduleUnload()
        }
    }

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        unloadTimer = nil
        noteHiddenPages(chromiumOnly: true)
        guard let after = effectiveUnloadAfter, let first = hiddenSince.values.min() else { return }
        let t = Timer(fire: max(first.addingTimeInterval(after), Date().addingTimeInterval(0.2)), interval: 0, repeats: false) { [weak self] _ in
            self?.unloadDueTabs(pressure: false)
        }
        t.tolerance = min(30, after / 10)
        RunLoop.main.add(t, forMode: .common)
        unloadTimer = t
    }

    /// Hidden pages the app frees that aren't on its timer join it. `chromiumOnly`: Chromium's timer ran from a page's
    /// creation, so a Chromium page opened in the background (and never shown) joins as soon as the app sees it; a
    /// settings change brings in the rest (a page no longer kept).
    private func noteHiddenPages(chromiumOnly: Bool) {
        guard effectiveUnloadAfter != nil, !chromiumOnly || appUnloadsChromiumPages else { return }
        let visible = visibleTabIDs, now = Date()
        for (id, page) in pages where hiddenSince[id] == nil && !visible.contains(id) && appUnloads(page) {
            guard !chromiumOnly || !ProtectedMedia.isWebKitPage(page), !isPageUnloaded(id), !keepsLoaded(id),
                  !MediaLibrary.shared.calls.holds(id) else { continue }
            hiddenSince[id] = now
        }
    }

    /// Frees every due tab (or, under memory pressure, the longest-hidden eligible one), after checking each for
    /// typed-in form input in the page. A tab kept for audio, loading or input is looked at again a timeout later.
    func unloadDueTabs(pressure: Bool) {
        let now = Date()
        if unloadedStates.keys.contains(where: { store.tab($0) == nil }) { unloadedStates = unloadedStates.filter { store.tab($0.key) != nil } }
        let after = effectiveUnloadAfter ?? .infinity
        let due = hiddenSince.filter { pressure || now.timeIntervalSince($0.value) >= after }.sorted { $0.value < $1.value }.map(\.key)
        var eligible: [String] = []
        for id in due {
            guard !visibleTabIDs.contains(id), let page = engineTab(for: id), appUnloads(page), !isPageUnloaded(id), !keepsLoaded(id) else {
                hiddenSince[id] = nil
                continue
            }
            // Memory pressure: Chromium frees its own pages (the engine's listener); the app, its WebKit pages.
            if pressure, isChromiumPage(page) { continue }
            if page.isAudible || page.isLoading || SiteControlsCenter.shared?.activity(of: page).isCapturing == true {
                if !pressure { hiddenSince[id] = now }
                continue
            }
            eligible.append(id)
        }
        if pressure { eligible = Array(eligible.prefix(1)) }
        for id in eligible {
            guard let page = engineTab(for: id) else { continue }
            let chromiumPage = isChromiumPage(page)
            keepsPage(page) { [weak self, weak page] keep in
                guard let self, let page, self.engineTab(for: id) === page, !self.visibleTabIDs.contains(id),
                      self.hiddenSince[id] != nil else { return }
                if keep {
                    self.hiddenSince[id] = Date()
                } else if chromiumPage {
                    // The engine keeps a page its checks protect (a call, an active media session): asked again later.
                    if page.discard() { self.hiddenSince[id] = nil; self.scheduleReload() } else { self.hiddenSince[id] = Date() }
                } else {
                    if let state = (page as? WebKitTab)?.unloadState { self.unloadedStates[id] = state }
                    self.unloadPage(id)
                    self.scheduleReload()
                }
                self.queueUnloadCheck()
            }
        }
        queueUnloadCheck()
    }

    /// A Chromium page of the Chromium build (the engine discards it; the app closes its WebKit pages).
    private func isChromiumPage(_ page: EngineTab) -> Bool { !appUnloads && !ProtectedMedia.isWebKitPage(page) }

    /// Typed-in form input, or (WebKit, whose sound report misses muted and silent media) a video or sound still
    /// playing, or one in picture in picture.
    private func keepsPage(_ page: EngineTab, _ answer: @escaping (Bool) -> Void) {
        page.hasUnsavedInput { dirty in
            guard !dirty, page is WebKitTab, !page.isClosed else { return answer(dirty) }
            page.evaluate("""
            !!document.pictureInPictureElement || Array.prototype.some.call(document.querySelectorAll('video,audio'),
              function (m) { return !m.paused && !m.ended && m.readyState > 2; })
            """) { playing in answer((playing as? Bool) != false) }
        }
    }

    /// The page for a tab unloaded here, opened again from its WebKit session state (nil: there is none, or its site
    /// no longer plays in WebKit; the caller opens the tab's URL).
    func reopenUnloadedPage(_ tabID: String, url: URL?, profile: EngineProfile) -> EngineTab? {
        guard let state = unloadedStates.removeValue(forKey: tabID), let url else { return nil }
        #if canImport(AircCore)
        if let w = engineWindow as? ChromiumWindow { return w.openWebKitTab(restoring: state, url: url, profile: profile) }
        #endif
        guard let w = engineWindow as? WebKitWindow, let p = profile as? WebKitProfile else { return nil }
        return w.openTab(restoring: state, profile: p, hostProfile: nil)
    }
}

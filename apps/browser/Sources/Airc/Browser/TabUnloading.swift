// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
#if canImport(AircCore)
import AircCore
#endif

/// MEM-3: a tab not seen for a while frees its page (Settings → General, default 30 minutes); never the visible
/// tab, one playing audio, one still loading, or one with typed-in form input. A memory-pressure warning frees the
/// longest-hidden eligible tab. Chromium does this itself (AircProfile.unloadTimeout; its discard keeps the tab's
/// history and reloads on activation): the app only passes the setting on. On the WebKit dev engine the app applies
/// the same rule and the tab reloads its URL when shown. No repeating timers: one one-shot for the next deadline.
extension WindowController {
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

    func setUpUnloading() {
        #if canImport(AircCore)
        if let chromium = app?.engine as? ChromiumEngine {
            let apply: (EngineProfile) -> Void = { [weak self] p in
                chromium.setUnloadTimeout(self?.effectiveUnloadAfter ?? 0, for: p)
                self?.applyPictureInPictureSettings(to: p)
            }
            profiles.didLoad = apply
            profiles.loadedProfiles.forEach(apply)
            chromium.discardedStateDidChange = { [weak self] _ in self?.scheduleReload() }
            ChromiumRuntime.memoryPressureHandler = { level in
                NSLog("Airc: memory pressure \(level); the engine freed the longest-hidden eligible tab")
            }
            return
        }
        #endif
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.unloadDueTabs(pressure: true) }
        source.resume()
        memoryPressure = source
    }

    /// Settings changed: Chromium takes the new timeout; the dev engine reschedules.
    func applyUnloadSetting() {
        #if canImport(AircCore)
        if let chromium = app?.engine as? ChromiumEngine {
            profiles.loadedProfiles.forEach { chromium.setUnloadTimeout(effectiveUnloadAfter ?? 0, for: $0) }
            return
        }
        #endif
        queueUnloadCheck()
    }

    var appUnloads: Bool {
        #if canImport(AircCore)
        if app?.engine is ChromiumEngine { return false }
        #endif
        return true
    }

    func pageVisibilityChanged(hidden: String?, shown: String?) {
        guard appUnloads else { return }
        if let shown { hiddenSince[shown] = nil }
        if let hidden, engineTab(for: hidden) != nil { hiddenSince[hidden] = Date() }
        queueUnloadCheck()
    }

    /// Coalesced, off the Space-switch path.
    func queueUnloadCheck() {
        guard appUnloads, !unloadQueued else { return }
        unloadQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.unloadQueued = false
            self?.scheduleUnload()
        }
    }

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        unloadTimer = nil
        guard let after = effectiveUnloadAfter, let first = hiddenSince.values.min() else { return }
        let t = Timer(fire: max(first.addingTimeInterval(after), Date().addingTimeInterval(0.2)), interval: 0, repeats: false) { [weak self] _ in
            self?.unloadDueTabs(pressure: false)
        }
        t.tolerance = min(30, after / 10)
        RunLoop.main.add(t, forMode: .common)
        unloadTimer = t
    }

    /// Frees every due tab (or, under memory pressure, the longest-hidden eligible one), after checking each for
    /// typed-in form input in the page. A tab kept for audio, loading or input is looked at again a timeout later.
    func unloadDueTabs(pressure: Bool) {
        let now = Date()
        let after = effectiveUnloadAfter ?? .infinity
        let due = hiddenSince.filter { pressure || now.timeIntervalSince($0.value) >= after }.sorted { $0.value < $1.value }.map(\.key)
        var eligible: [String] = []
        for id in due {
            guard !visibleTabIDs.contains(id), let page = engineTab(for: id) else { hiddenSince[id] = nil; continue }
            if page.isAudible || page.isLoading {
                if !pressure { hiddenSince[id] = now }
                continue
            }
            eligible.append(id)
        }
        if pressure { eligible = Array(eligible.prefix(1)) }
        for id in eligible {
            engineTab(for: id)?.hasUnsavedInput { [weak self] dirty in
                guard let self, !self.visibleTabIDs.contains(id), self.hiddenSince[id] != nil else { return }
                if dirty {
                    self.hiddenSince[id] = Date()
                } else {
                    self.unloadPage(id)
                    self.scheduleReload()
                }
                self.queueUnloadCheck()
            }
        }
        queueUnloadCheck()
    }
}

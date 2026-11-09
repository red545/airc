// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
import Darwin
#if canImport(AircCore)
import AircCore
#endif

extension SnapshotRunner {
    func parityP20cScenario() {
        step { [self] done in
            Task { @MainActor in
                await BlockingCheck(runner: self).run()
                done()
            }
        }
    }
}

/// Real network and page fixtures, no list hosts, external pages or media APIs.
@MainActor private final class BlockingCheck {
    let runner: SnapshotRunner
    var server: LocalPageServer?
    var port: UInt16 = 0
    var privateWindow: PrivateWindowController?
    var samples: [[String: Any]] = []
    init(runner: SnapshotRunner) { self.runner = runner }
    var c: WindowController { runner.c }
    var app: AppDelegate { runner.app! }
    var center: BlockingCenter { app.blocking }
    var memoryMode: Bool? {
        if app.options.script == "parityp20c-memory-off" { return false }
        if app.options.script == "parityp20c-memory-on" { return true }
        return nil
    }
    var profileID: String { c.store.profile(ofSpace: c.currentSpaceID).id }
    var url: URL { URL(string: "http://localhost:\(port)/")! }
    var pageURL: URL { memoryMode == nil ? url : url.appendingPathComponent("clean") }
    func check(_ ok: Bool, _ title: String) { runner.check(ok, "parityp20c: " + title) }
    func evaluate(_ tab: EngineTab, _ script: String) async -> Any? {
        await withCheckedContinuation { continuation in tab.evaluate(script) { continuation.resume(returning: $0) } }
    }
    func wait(_ condition: () async -> Bool, seconds: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
    func load(_ tab: EngineTab) async -> Bool {
        let token = UUID().uuidString
        var target = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        target.queryItems = [URLQueryItem(name: "check", value: token)]
        tab.load(target.url!)
        return await wait {
            await self.evaluate(tab, "location.search === '?check=\(token)' && document.documentElement.dataset.fixtureDone === 'yes'") as? Bool == true && !tab.isLoading
        }
    }
    func page() -> EngineTab? {
        guard let row = try? c.store.openTab(url: pageURL.absoluteString, inSpace: c.currentSpaceID) else { return nil }
        c.reloadAll(animated: false); c.show(row.id, focus: false)
        return c.engineTab(for: row.id)
    }
    func hits() async -> [String: Int] {
        guard let response = try? await URLSession.shared.data(from: url.appendingPathComponent("hits")),
              let result = try? JSONSerialization.jsonObject(with: response.0) as? [String: Int] else { return [:] }
        return result
    }
    func install(_ id: String, includeDefaults: Bool = false) async {
        await withCheckedContinuation { resume in center.installCheckRules(BlockingCheckFixtures.rules, profile: id, enabled: memoryMode ?? true, includeDefaults: includeDefaults || memoryMode != nil) { resume.resume() } }
    }
    func site(_ value: Bool, tab: EngineTab) async {
        // The center deliberately reloads the same URL. Invalidate the previous
        // document before changing policy so its completed fixture cannot pass.
        _ = await evaluate(tab, "document.documentElement.dataset.fixtureDone = ''")
        await withCheckedContinuation { resume in center.setSiteEnabled(value, tab: tab) { resume.resume() } }
    }
    func enabled(_ value: Bool, id: String) async {
        await withCheckedContinuation { resume in center.setCheckEnabled(value, profile: id) { resume.resume() } }
    }
    func state(_ tab: EngineTab) async -> [String: Any] {
        await evaluate(tab, #"({ad:!!window.adRan,allowed:!!window.allowedRan,tracker:window.trackerResult,frame:window.frameResult,redirect:!!window.redirectAdRan,image:document.querySelector('img').naturalWidth,hostHidden:getComputedStyle(document.querySelector('.sponsor')).display==='none',genericHidden:getComputedStyle(document.querySelector('.generic-ad')).display==='none',exceptionVisible:getComputedStyle(document.querySelector('.allowed-ad')).display!=='none'})"#) as? [String: Any] ?? [:]
    }
    func assertBlocked(_ tab: EngineTab, _ label: String, genericExpected: Bool = true) async {
        let ready = await wait { await self.evaluate(tab, "document.documentElement.dataset.fixtureDone === 'yes'") as? Bool == true }
        let frame = await wait { (await self.state(tab))["frame"] as? String != nil }
        let cosmetic = await wait { (await self.state(tab))["genericHidden"] as? Bool == genericExpected }
        let value = await state(tab)
        if !cosmetic || value["hostHidden"] as? Bool != true {
            let native = center.selectors(for: tab, url: tab.url?.absoluteString ?? "", tokens: #"{"classes":["generic-ad"],"ids":[]}"#, isMainFrame: true)
            let page = await evaluate(tab, "JSON.stringify({receive:typeof window.__aircPageReceive,sheets:[...document.adoptedStyleSheets].map(s=>({count:s.cssRules.length,fixture:[...s.cssRules].map(r=>r.cssText).filter(s=>s.includes('generic-ad')||s.includes('.sponsor'))})),state:document.readyState})")
            runner.note("parityp20c cosmetics diagnostic: native=\(native), messages=\(BlockingCosmetics.checkMessages), page=\(String(describing: page)), state=\(value)")
        }
        check(ready && value["ad"] as? Bool == false && value["tracker"] as? String == "blocked", label + ": script and tracker blocked")
        let expectedFrame = tab is WebKitTab ? "blocked" : "allowed"
        check(frame && value["frame"] as? String == expectedFrame, label + ": " + (tab is WebKitTab ? "WebKit top-document party semantics (documented conversion limit)" : "Chromium uses the iframe initiator for party matching"))
        check(value["redirect"] as? Bool == false, label + ": redirect target blocked")
        check(value["allowed"] as? Bool == true && (value["image"] as? Int ?? 0) > 0, label + ": exception and request type allowed")
        check(cosmetic && value["hostHidden"] as? Bool == true && value["exceptionVisible"] as? Bool == true, label + (genericExpected ? ": host/generic cosmetics and cosmetic exception" : ": EasyList loopback generichide exception keeps generic elements visible"))
        let counted = await wait { (self.center.count(for: tab) ?? -1) >= 3 }
        check(counted, label + ": confirmed network count (\(center.count(for: tab).map(String.init) ?? "unavailable"))")
    }
    func assertAllowed(_ tab: EngineTab, _ label: String) async {
        let ready = await wait { await self.evaluate(tab, "document.documentElement.dataset.fixtureDone === 'yes'") as? Bool == true && !tab.isLoading }
        let value = await state(tab)
        check(ready && value["ad"] as? Bool == true && value["tracker"] as? String == "loaded", label + ": network allowed")
        check(value["hostHidden"] as? Bool == false && value["genericHidden"] as? Bool == false, label + ": cosmetics absent after reload")
        let framesAllowed = await wait { (await self.state(tab))["frame"] as? String == "allowed" }
        check(framesAllowed, label + ": top-site exception covers iframe requests too")
        check(center.count(for: tab) == 0, label + ": count reset on reload")
    }
    func run() async {
        defer { privateWindow?.closeWindow(); server?.stop() }
        check(center.lists.checkNetworkIsDisabled, "list updater has no host transport in scripted runs")
        await center.refresh(force: true)
        check(center.lists.updating.isEmpty, "forced refresh also remains stubbed")
        var received: [String: Int] = [:] // only accessed by the fixture server queue
        server = LocalPageServer(pages: [:])
        guard let server else { check(false, "loopback server created"); return }
        port = await withCheckedContinuation { resume in server.start { resume.resume(returning: $0 ?? 0) } }
        guard port != 0 else { check(false, "loopback server listening"); return }
        let html = Self.html(port: port)
        let fixturePort = port
        server.handler = { path in
            if path == "/hits" {
                let data = try? JSONSerialization.data(withJSONObject: received, options: [.sortedKeys])
                return .init(headers: ["Content-Type": "application/json"], body: "", data: data)
            }
            received[path, default: 0] += 1
            switch path {
            case "/": return .init(body: html)
            case "/clean": return .init(body: Self.cleanHTML)
            case "/p20c-neutral-script.js": return .init(headers: ["Content-Type": "text/javascript"], body: "window.contentRuns=(window.contentRuns||0)+1;")
            case "/p20c-neutral-style.css": return .init(headers: ["Content-Type": "text/css"], body: "body{font:16px system-ui;margin:32px}article{padding:4px}")
            case "/ads.js": return .init(headers: ["Content-Type": "text/javascript"], body: "window.adRan=true;")
            case "/frame-allowed.js": return .init(headers: ["Content-Type": "text/javascript"], body: "parent.postMessage('same-party-allowed','http://localhost:\(fixturePort)');")
            case "/frame": return .init(body: "<!doctype html><script src='/frame-allowed.js' onerror=\"parent.postMessage('same-party-blocked','http://localhost:\(fixturePort)')\"></script>")
            case "/hop": return .init(status: "302 Found", headers: ["Location": "http://127.0.0.1:\(fixturePort)/ads-redirect.js"], body: "")
            case "/ads-redirect.js": return .init(headers: ["Content-Type": "text/javascript"], body: "window.redirectAdRan=true;")
            case "/allowed.js": return .init(headers: ["Content-Type": "text/javascript"], body: "window.allowedRan=true;")
            case "/tracker": return .init(headers: ["Access-Control-Allow-Origin": "*"], body: "tracker")
            case "/pixel": return .init(headers: ["Content-Type": "image/png"], body: "", data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aSTsAAAAASUVORK5CYII="))
            default: return .init(status: "404 Not Found", body: "")
            }
        }
        await install(profileID)
        guard let tab = page() else { check(false, "fixture tab created"); return }
        if let mode = memoryMode {
            _ = await wait { await self.evaluate(tab, "document.documentElement.dataset.fixtureDone === 'yes'") as? Bool == true }
            await measure(tab, onlyMode: mode)
            writeMeasurements()
            return
        }
        await assertBlocked(tab, "ordinary profile")
        if app.options.script == "parityp20c-probe" { return }
        // A single DOM mutation can carry more than the bridge's message cap.
        // The matching token at the end must still reach the filter engine.
        _ = await evaluate(tab, #"(()=>{const ad=document.createElement('div');ad.id='batch-fixture';ad.className=Array.from({length:300},(_,n)=>'界'.repeat(230)+n).join(' ')+' batch-ad';ad.textContent='Dynamic advertisement';document.body.append(ad)})()"#)
        let batchHidden = await wait { await self.evaluate(tab, "getComputedStyle(document.getElementById('batch-fixture')).display === 'none'") as? Bool == true }
        check(batchHidden, "large dynamic DOM token batch preserves cosmetic matching")
        let blockedHits = await hits()
        check(blockedHits["/ads.js", default: 0] == 0 && blockedHits["/tracker", default: 0] == 0 && blockedHits["/allowed.js", default: 0] > 0 && blockedHits["/hop", default: 0] > 0 && blockedHits["/ads-redirect.js", default: 0] == 0,
              "server confirms no blocked request reached loopback")
        let priorCount = center.count(for: tab)
        _ = await load(tab); await assertBlocked(tab, "reload")
        check(center.count(for: tab) == priorCount, "count is per document, not cumulative")
        await site(false, tab: tab); await assertAllowed(tab, "site exception")
        let disk = BlockingSettings(directory: AppPaths.dataDirectory, existingProfiles: [])
        check(disk.configuration(profileID).exceptions.contains("localhost"), "ordinary exception persisted")
        await site(true, tab: tab); await assertBlocked(tab, "site switched back on")
        let configBeforePrivate = center.settings.configuration(profileID)
        privateWindow = await withCheckedContinuation { resume in PrivateBrowsing.shared.open(app: app) { resume.resume(returning: $0) } }
        if let window = privateWindow {
            let privateTab = window.openPage(url)
            await assertBlocked(privateTab, "private window")
            await site(true, tab: privateTab) // remember an explicit private on
            await site(false, tab: tab)
            _ = await load(privateTab); await assertBlocked(privateTab, "private on overrides a later ordinary exception")
            await site(true, tab: tab)
            await site(false, tab: privateTab); await assertAllowed(privateTab, "private exception")
            check(center.settings.configuration(profileID) == configBeforePrivate, "private exception never changes persisted policy")
            _ = await load(tab); await assertBlocked(tab, "regular tab unaffected by private exception")
            window.closeWindow(); privateWindow = nil
            _ = await wait { PrivateBrowsing.shared.windows.isEmpty }
            privateWindow = await withCheckedContinuation { resume in PrivateBrowsing.shared.open(app: app) { resume.resume(returning: $0) } }
            if let fresh = privateWindow { await assertBlocked(fresh.openPage(url), "fresh private session forgets exception"); fresh.closeWindow(); privateWindow = nil }
            else { check(false, "fresh private session") }
        } else { check(false, "private window opened") }
        await separation()
        migrationPolicy()
        await coexistence(tab)
        await withCheckedContinuation { resume in
            center.installCheckRules("localhost##.sponsor\n", profile: profileID) { resume.resume() }
        }
        _ = await load(tab)
        let cosmeticOnly = await wait {
            let value = await self.state(tab)
            return value["ad"] as? Bool == true && value["tracker"] as? String == "loaded" &&
                value["hostHidden"] as? Bool == true && value["genericHidden"] as? Bool == false
        }
        check(cosmeticOnly && center.count(for: tab) == 0 && center.failures.isEmpty,
              "cosmetic-only selection installs with an empty WebKit network conversion")
        // EasyList deliberately exempts localhost from generic hiding. Test
        // that real policy separately from the synthetic cosmetic fixtures;
        // performance samples still load the complete default list selection.
        await install(profileID, includeDefaults: true)
        _ = await load(tab)
        await assertBlocked(tab, "default lists plus fixture", genericExpected: false)
        // Overhead uses dedicated fresh on/off processes, not this process
        // after switching profiles, rules and private windows repeatedly.
        c.showSiteControls()
        await withCheckedContinuation { resume in runner.captureNow("blocking-site-controls") { resume.resume() } }
        c.closeSiteControls(animated: false)
        check(center.failures.isEmpty, "all selected rules installed on the running engine")
    }
    func writeMeasurements() {
        if let json = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: runner.dir.appendingPathComponent("blocking-measurements.json"))
        }
    }
    func separation() async {
        guard let other = try? c.profiles.createProfile(name: "Blocking Check", emoji: "🧪", color: nil) else { check(false, "second profile created"); return }
        let profile: EngineProfile? = await withCheckedContinuation { resume in c.profiles.whenLoaded(other.id, { resume.resume(returning: $0) }, failed: { resume.resume(returning: nil) }) }
        guard let profile else { check(false, "second profile ready"); return }
        check(center.settings.configuration(other.id).enabled, "new profiles default on")
        await install(other.id)
        await enabled(false, id: other.id)
        let window = app.engine.makeWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        let otherTab = window.openTab(url: nil, profile: profile, foreground: true)
        _ = await load(otherTab); await assertAllowed(otherTab, "separate disabled profile")
        check(center.settings.configuration(profileID).enabled, "another profile’s switch does not change this profile")
        otherTab.close(); window.window.close()
    }
    func migrationPolicy() {
        let folder = runner.dir.appendingPathComponent("migration-fixture", isDirectory: true)
        let file = folder.appendingPathComponent("Blocking/settings.json")
        // Old policy: unchosen existing profiles were off, while offered=true
        // also recorded a user explicitly switching protection off.
        let legacy = #"{"schema":1,"profiles":{"unchosen":{"enabled":false,"offered":false},"explicit-off":{"enabled":false,"offered":true}},"coexistenceDismissed":[]}"#
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(legacy.utf8).write(to: file, options: .atomic)
        } catch { check(false, "migration fixture written"); return }
        let migrated = BlockingSettings(directory: folder, existingProfiles: ["unchosen", "explicit-off", "without-settings"])
        check(migrated.configuration("unchosen").enabled && migrated.configuration("without-settings").enabled,
              "existing profiles without an explicit choice become enabled")
        check(!migrated.configuration("explicit-off").enabled, "migration preserves a previous explicit off")
        check(migrated.configuration("unchosen").defaultMigrationVersion == 1,
              "existing-profile migration is recorded")
        check(!migrated.configuration("unchosen").blockThirdPartyCookies,
              "third-party cookie blocking stays off by default")
        let once = BlockingSettings(directory: folder, existingProfiles: ["unchosen", "explicit-off", "without-settings"])
        check(once.profiles == migrated.profiles, "migration result persists unchanged on relaunch")
        once.setEnabled(false, profile: "unchosen")
        let relaunched = BlockingSettings(directory: folder, existingProfiles: ["unchosen", "explicit-off"])
        check(!relaunched.configuration("unchosen").enabled && relaunched.configuration("unchosen").hasExplicitChoice,
              "explicit off after migration stays off on relaunch")
        check(!relaunched.configuration("explicit-off").enabled, "previous explicit off remains off on relaunch")
        BlockingNotices.dismissForCheck(in: c)
        BlockingNotices.show(in: c, forCheck: true)
        check(!BlockingNotices.isShown(in: c), "no existing-profile turn-on offer is shown")
    }
    func coexistence(_ tab: EngineTab) async {
        #if canImport(AircCore)
        if let profile = tab.profile as? ChromiumProfile {
            let folder = runner.dir.appendingPathComponent("fixture-adblock", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = #"{"manifest_version":3,"name":"Fixture Adblock","version":"1.0","description":"Synthetic coexistence fixture; no permissions, no network."}"#
            try? Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
            let id: String? = await withCheckedContinuation { resume in profile.core.loadUnpackedExtension(forTesting: folder.path) { id, _ in resume.resume(returning: id) } }
            guard let id else { check(false, "synthetic blocker extension loads under test gate"); return }
            let blockers = center.blockers(profile: profileID)
            check(blockers.contains { $0.id == id }, "enabled blocker still enabled before consent")
            check(center.settings.shouldOfferCoexistence(profile: profileID, extensionIDs: [id]), "coexistence notice offered")
            BlockingNotices.show(in: c, forCheck: true)
            check(BlockingNotices.isShown(in: c), "coexistence notice is rendered with the fixture extension")
            await withCheckedContinuation { resume in runner.captureNow("blocking-extension-coexistence") { resume.resume() } }
            center.settings.dismissCoexistence(profile: profileID, extensionIDs: [id])
            BlockingNotices.dismissForCheck(in: c)
            BlockingNotices.show(in: c, forCheck: true)
            check(!BlockingNotices.isShown(in: c), "Keep Both dismisses this coexistence offer")
            check(center.blockers(profile: profileID).contains { $0.id == id }, "Keep Both leaves extension enabled")
            check(center.disableOtherBlockers(profile: profileID, extensions: [id]), "explicit consent disables the listed blocker")
            check(!center.blockers(profile: profileID).contains { $0.id == id }, "consented extension is disabled")
            return
        }
        #endif
        let ids = ["synthetic-blocker"]
        check(center.settings.shouldOfferCoexistence(profile: profileID, extensionIDs: ids), "coexistence offer policy on WebKit")
        center.settings.dismissCoexistence(profile: profileID, extensionIDs: ids)
        check(!center.settings.shouldOfferCoexistence(profile: profileID, extensionIDs: ids), "Keep Both remembers consent choice; WebKit has no extension host")
    }
    var measurableWindow: Bool {
        c.window.isOnActiveSpace && c.window.isVisible && c.window.occlusionState.contains(.visible)
    }
    func noteMeasurementEnvironment() {
        runner.note("FAIL-ENV parityp20c: overhead requires an uncovered window on the active Space; pid=\(getpid()), activeSpace=\(c.window.isOnActiveSpace), visible=\(c.window.isVisible), occlusionVisible=\(c.window.occlusionState.contains(.visible))")
    }
    func measure(_ tab: EngineTab, onlyMode: Bool? = nil) async {
        guard measurableWindow else { noteMeasurementEnvironment(); return }
        for mode in onlyMode.map({ [$0] }) ?? [false, true] {
            await enabled(mode, id: profileID)
            for iteration in 0..<6 {
                guard measurableWindow else { noteMeasurementEnvironment(); return }
                let started = CACurrentMediaTime()
                let ready = await load(tab)
                let elapsed = (CACurrentMediaTime() - started) * 1000
                guard measurableWindow else { noteMeasurementEnvironment(); return }
                let navigation = await evaluate(tab, "performance.getEntriesByType('navigation')[0]?.loadEventEnd || 0") as? Double ?? 0
                check(ready && navigation > 0, "measurement completed a fresh document")
                check(center.count(for: tab) == 0, "neutral overhead fixture has no blocked requests")
                samples.append(["fixture": "allowed-resources", "enabled": mode, "iteration": iteration, "ready": ready, "wall_ms": elapsed,
                                "navigation_ms": navigation, "window_active_space": true, "window_occlusion_visible": true, "app_resident_bytes": Self.residentBytes(),
                                "app_physical_footprint_bytes": Self.physicalFootprintBytes()])
                await requestMemorySample(tab, enabled: mode, iteration: iteration)
            }
        }
    }
    func requestMemorySample(_ tab: EngineTab, enabled: Bool, iteration: Int) async {
        guard FileManager.default.fileExists(atPath: runner.dir.appendingPathComponent("blocking-memory-sampler.enabled").path) else { return }
        let token = UUID().uuidString
        var helpers: [Int32] = []
        if let wk = tab as? WebKitTab {
            for (object, name) in [(wk.webView as NSObject, "_webProcessIdentifier"),
                                   (wk.webView as NSObject, "_gpuProcessIdentifier"),
                                   (wk.webView.configuration.websiteDataStore as NSObject, "_networkProcessIdentifier")] {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { continue }
                typealias Identifier = @convention(c) (AnyObject, Selector) -> Int32
                let call = unsafeBitCast(object.method(for: selector), to: Identifier.self)
                let pid = call(object, selector)
                if pid > 0 { helpers.append(pid) }
            }
        }
        let request: [String: Any] = ["token": token, "enabled": enabled, "iteration": iteration,
                                      "app_pid": getpid(), "webkit_helpers": helpers]
        let file = runner.dir.appendingPathComponent("blocking-memory-request.json")
        if let data = try? JSONSerialization.data(withJSONObject: request) { try? data.write(to: file, options: .atomic) }
        let ack = runner.dir.appendingPathComponent("blocking-memory-ack.txt")
        let sampled = await wait({ (try? String(contentsOf: ack, encoding: .utf8)) == token }, seconds: 5)
        check(sampled, "external process-footprint sample completed")
    }
    static func physicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        } }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        } }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
    // Same resource work on/off: blocking must not appear faster merely
    // because it prevented the ad/tracker fixture from doing its work.
    nonisolated static var cleanHTML: String {
        let rows = (0..<200).map { "<article class='p20c-neutral-\($0)'>An ordinary page item.</article>" }.joined()
        let scripts = (0..<6).map { "<script src='/p20c-neutral-script.js?v=\($0)'></script>" }.joined()
        return "<!doctype html><meta charset='utf-8'><title>Neutral blocking overhead fixture</title><link rel='stylesheet' href='/p20c-neutral-style.css'><h1>Ordinary page content</h1>" + rows + scripts + "<img alt='' src='/pixel'><script>addEventListener('load',()=>document.documentElement.dataset.fixtureDone=window.contentRuns===6?'yes':'error')</script>"
    }
    static func html(port: UInt16) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>Blocking fixture</title>
        <style>body{font:18px system-ui;margin:40px}section{padding:24px;background:#f0f4ef}.sponsor,.generic-ad{background:#ffe5bd;padding:20px}</style>
        <h1>A quiet corner of the web</h1><section>Independent stories, without the distractions.</section>
        <p class="sponsor">Sponsored placement</p><p class="generic-ad">Advertisement</p><p class="allowed-ad">Allowed sponsor label</p>
        <script>addEventListener('message',e=>{if(e.origin==='http://127.0.0.1:\(port)' && ['same-party-allowed','same-party-blocked'].includes(e.data))window.frameResult=e.data==='same-party-allowed'?'allowed':'blocked';});</script>
        <iframe title="Party-context fixture" src="http://127.0.0.1:\(port)/frame"></iframe>
        <script src="/hop"></script>
        <img alt="Allowed image" src="http://127.0.0.1:\(port)/pixel">
        <script src="http://127.0.0.1:\(port)/ads.js"></script><script src="http://127.0.0.1:\(port)/allowed.js"></script>
        <script>fetch('http://127.0.0.1:\(port)/tracker').then(()=>window.trackerResult='loaded',()=>window.trackerResult='blocked').finally(()=>document.documentElement.dataset.fixtureDone='yes');</script>
        """
    }
}
/// Shared by initial profile setup and the check; no intermediate default-only
/// filter warms the isolated memory-on process.
enum BlockingCheckFixtures {
    static let rules = """
    ||127.0.0.1^$script,third-party
    @@/allowed.js$script
    /tracker$xmlhttprequest,third-party
    localhost##.sponsor
    ##.generic-ad
    ##.batch-ad
    ##.allowed-ad
    localhost#@#.allowed-ad
    """
}
#endif

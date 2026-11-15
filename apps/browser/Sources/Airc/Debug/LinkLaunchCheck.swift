// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// linklaunch: a link that launches Airc and opens in Little Airc shows only Little Airc, as Arc did. No browser window
/// is made or ordered in at launch, so macOS never switches from the sending app's full-screen Space to the desktop;
/// the session's windows come back when the person asks (the Dock). By hand, never in the suite (it needs another app
/// in native full screen): the runner in the linklaunch artifacts has a helper app enter native full screen and launch
/// a scratch copy with the link (NSWorkspace, as WhatsApp hands one over), and samples the window server from outside.
///   `--script linklaunch-seed` (a plain launch): windows-write's four windows (WindowsCheck.swift), plus a link rule:
///       links to localhost open in the Work Space. Leaves windows-session.json and linklaunch-tabs.json.
///   `--script linklaunch` (launched by the link; those two files copied into its folder):
///       AIRC_LINKLAUNCH_EXPECT=littlearc (default): no browser window made, shown or ordered in from the launch on; the
///         Space never changes; Little Airc on the full-screen app's Space. AIRC_LINKLAUNCH_REOPEN=dock (default): the
///         runner then opens the running copy (`open -b`: Launch Services' reopen event and activation, as a Dock click):
///         every saved window comes back, each with its Space and tab, and every tab is still there. =none: it quits
///         with Little Airc only (the runner's windows-read checks the session survived).
///       AIRC_LINKLAUNCH_EXPECT=space: the link matches the rule: the browser windows open at launch, as before.
///   `--script linklaunch-onboarding --onboarding` (first run, launched by the link): onboarding shows, the link waits
///       for it; once onboarding is done, the browser window opens and the link opens in Little Airc.
extension SnapshotRunner {
    private struct LinkLaunchExpected: Codable {
        struct W: Codable { var frame: [Double]; var spaceID: String; var tabID: String?; var elsewhere: Bool; var sidebarWidth: Double; var blank: Bool? }
        var windows: [W]
    }

    func linkLaunchScenario() {
        switch script {
        case "linklaunch-seed": linkLaunchSeed()
        case "linklaunch-onboarding": linkLaunchOnboarding()
        default:
            if ProcessInfo.processInfo.environment["AIRC_LINKLAUNCH_EXPECT"] == "space" { linkLaunchToSpace() } else { linkLaunchToLittleArc() }
        }
    }

    private var linkLaunchLabel: String { "linklaunch (\(app?.engine.name ?? "?"))" }

    private func linkLaunchSeed() {
        windowsSessionWrite()
        run { [self] in
            guard let app, let work = app.store.orderedSpaces.first(where: { $0.name == "Work" }) else {
                return check(false, "linklaunch-seed: the Work Space exists")
            }
            app.settings.values.linkRules = [LinkRule(match: .contains, pattern: "localhost", spaceID: work.id)]
            let tabs = app.store.state.tabs.keys.sorted()
            try? JSONEncoder().encode(tabs).write(to: dir.appendingPathComponent("linklaunch-tabs.json"))
            check(app.controllers.count == 4 && tabs.count >= 4,
                  "linklaunch-seed: \(app.controllers.count) windows and \(tabs.count) tabs saved; links to localhost go to Work by a rule")
        }
        wait(1.2)
    }

    private func linkLaunchExpected() -> LinkLaunchExpected? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("windows-session.json")) else { return nil }
        return try? JSONDecoder().decode(LinkLaunchExpected.self, from: data)
    }

    private func linkLaunchLogLines() {
        run { [self] in
            note("\(linkLaunchLabel): launch event \(LaunchEvent.shared.summary), link before did-finish-launching "
                 + "\(LinkLog.yesNo(LaunchEvent.shared.linkDuringLaunch))")
            for line in Self.linksLog(since: 0).split(separator: "\n") { note("\(linkLaunchLabel): Links.log: \(line)") }
            note("\(linkLaunchLabel): probe: \(LinkLaunchProbe.shared.history.joined(separator: "; "))")
        }
    }

    private func linkLaunchToLittleArc() {
        let probe = LinkLaunchProbe.shared
        let label = linkLaunchLabel
        var little: LittleArcController?
        step { [self] done in
            let ours = { self.app?.littleArcs.first { $0.page?.url?.query?.contains("from=linklaunch") == true } }
            waitUntil({ ours()?.page?.isLoading == false && ours()?.window.isVisible == true }, timeout: 60) {
                little = ours()
                // A late browser window or Space switch would show by now (the old launch switched at 0.4 s, routed at 4 s).
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: done)
            }
        }
        run { [self] in
            guard let app, let l = little else { return check(false, "\(label): the launch's link opens Little Airc") }
            let log = Self.linksLog(since: 0)
            let launchLine = log.split(separator: "\n").first { $0.contains("launch: launched by a link") }.map(String.init) ?? "none"
            check(launchedByLinkWithoutWindow && launchLine != "none",
                  "\(label): launched by its link, the app opens no browser window at launch (Links.log: \(launchLine.suffix(260)))")
            check(app.windowSession.openCount == 0 && app.controllers.isEmpty && probe.shownWindows.isEmpty,
                  "\(label): no browser window was made, shown or ordered in from the launch on (made \(app.windowSession.openCount), "
                  + "open \(app.controllers.count), seen visible \(probe.shownWindows))")
            // AIRC_LINKLAUNCH_EXPECT=desktop: the link came from an app that isn't in full screen (`open`): Little Airc
            // comes forward as an ordinary window, key, the app active.
            if ProcessInfo.processInfo.environment["AIRC_LINKLAUNCH_EXPECT"] == "desktop" {
                check(!l.overFullScreen && l.window.isVisible && l.window.isKeyWindow && NSApp.isActive && NSApp.activationPolicy() == .regular,
                      "\(label) from the desktop: Little Airc comes forward as an ordinary window, key, the app active and regular (panel "
                      + "\(l.overFullScreen), visible \(l.window.isVisible), key \(l.window.isKeyWindow), active \(NSApp.isActive), "
                      + "policy \(NSApp.activationPolicy().rawValue))")
                probe.windowsAllowed = true
                try? "shown\n".write(to: dir.appendingPathComponent("la-shown"), atomically: true, encoding: .utf8)
                return
            }
            let fsPID = probe.fsPID ?? LittleArcFullScreen.shared.lastSource
            let fsName = NSRunningApplication(processIdentifier: fsPID)?.bundleIdentifier ?? "pid \(fsPID)"
            let fsSpace = FullScreenSpaces.space(of: fsPID)
            let panelSpaces = FullScreenSpaces.spaces(ofWindow: l.window.windowNumber)
            check(l.overFullScreen && fsSpace?.current == true && panelSpaces.contains(fsSpace?.id ?? 0) && l.window.isVisible
                  && l.window.isOnActiveSpace && LinkLog.isFullScreen(fsPID),
                  "\(label): Little Airc shows on \(fsName)'s full-screen Space (Space \(fsSpace.map { String($0.id) } ?? "none"), on screen "
                  + "\(fsSpace?.current == true), the panel's Spaces \(panelSpaces), panel \(l.overFullScreen), visible \(l.window.isVisible), "
                  + "\(fsName) in full screen \(LinkLog.isFullScreen(fsPID)))")
            note("\(label): launch event \(LaunchEvent.shared.summary)")
            check(probe.spaceChanges.isEmpty && probe.fsLeftScreen.isEmpty && !log.contains("handing the activation back"),
                  "\(label): the Space never changes, no desktop flash (Space changes \(probe.spaceChanges), the full-screen Space off screen "
                  + "\(probe.fsLeftScreen), hand-back \(log.contains("handing the activation back")))")
            check(l.window.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == fsPID,
                  "\(label): Little Airc is key over \(fsName), which stays the front app (key \(l.window.isKeyWindow), front "
                  + "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"), activation policy \(NSApp.activationPolicy().rawValue))")
            probe.windowsAllowed = true
            try? "shown\n".write(to: dir.appendingPathComponent("la-shown"), atomically: true, encoding: .utf8)
        }
        if ProcessInfo.processInfo.environment["AIRC_LINKLAUNCH_REOPEN"] != "none" {
            // The runner opens the running copy now (`open -b`): the Dock's reopen event.
            step { [self] done in
                waitUntil({ (self.app?.controllers.count ?? 0) > 0 }, timeout: 60) { DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: done) }
            }
            run { [self] in
                guard let app else { return }
                let log = Self.linksLog(since: 0)
                check(log.contains("reopen (the Dock, or opening the running app): no browser window open since the link launch"),
                      "\(label): the Dock's reopen (Launch Services' reopen event) reaches applicationShouldHandleReopen")
                guard let expected = linkLaunchExpected() else { return check(false, "\(label): the seed run left windows-session.json") }
                check(app.controllers.count == expected.windows.count,
                      "\(label): the reopen brings back every saved window (\(app.controllers.count) of \(expected.windows.count))")
                for (i, (c, e)) in zip(app.controllers, expected.windows).enumerated() {
                    let f = c.window.frame
                    let close = zip([f.minX, f.minY, f.width, f.height], e.frame).allSatisfy { abs($0 - $1) <= 2 }
                    check(close && c.currentSpaceID == e.spaceID && c.shownTabID == e.tabID && (c.multiWindow.elsewhereTabID != nil) == e.elsewhere
                          && (e.blank == nil || c.isBlankWindow == e.blank) && c.window.isVisible,
                          "\(label): window \(i + 1) comes back as saved: frame \(close), Space \(c.store.space(c.currentSpaceID)?.name ?? "?"), "
                          + "tab \(c.shownTabID == e.tabID), \(e.elsewhere ? "its tab in another window" : "its page")\(e.blank == true ? ", blank" : ""), "
                          + "visible \(c.window.isVisible)")
                }
                let front = app.controllers.first?.window
                check(front?.isVisible == true && front?.isOnActiveSpace == true,
                      "\(label): the window used last is on screen in front (on the active Space \(front?.isOnActiveSpace == true), key "
                      + "\(front?.isKeyWindow == true), app active \(NSApp.isActive))")
                let saved = (try? Data(contentsOf: dir.appendingPathComponent("linklaunch-tabs.json"))).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                let missing = saved.filter { app.store.tab($0) == nil }
                check(!saved.isEmpty && missing.isEmpty, "\(label): every tab is still there (\(saved.count) saved, missing \(missing))")
            }
        } else {
            wait(1)
        }
        linkLaunchLogLines()
    }

    private func linkLaunchToSpace() {
        let label = linkLaunchLabel + " to a Space"
        step { [self] done in
            let shown = { self.app?.controllers.first?.shownTabID.flatMap { self.app?.store.tab($0) }?.url.contains("from=linklaunch-space") == true }
            waitUntil(shown, timeout: 60) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: done) }
        }
        run { [self] in
            guard let app else { return }
            let c = app.controllers.first
            let work = app.store.orderedSpaces.first { $0.name == "Work" }?.id
            let tab = c?.shownTabID.flatMap { app.store.tab($0) }
            let expected = linkLaunchExpected()?.windows.count ?? -1
            check(!launchedByLinkWithoutWindow && app.littleArcs.isEmpty && tab?.url.contains("from=linklaunch-space") == true
                  && c?.currentSpaceID == work && c?.window.isVisible == true,
                  "\(label): a link a rule sends to a Space opens there, in the browser window, at launch (tab \(tab != nil), Space Work "
                  + "\(c?.currentSpaceID == work), visible \(c?.window.isVisible == true), Little Aircs \(app.littleArcs.count))")
            check(app.controllers.count == expected && app.controllers.allSatisfy { $0.window.isVisible },
                  "\(label): the session's windows open with it (\(app.controllers.count) of \(expected))")
        }
        linkLaunchLogLines()
    }

    private func linkLaunchOnboarding() {
        let label = linkLaunchLabel + " first run"
        wait(3)
        run { [self] in
            guard let app else { return }
            let log = Self.linksLog(since: 0)
            check(onboarding?.window.isVisible == true && app.controllers.isEmpty && app.littleArcs.isEmpty && log.contains("waiting for the browser window"),
                  "\(label): launched by a link on the first run, onboarding shows and the link waits for it (onboarding visible "
                  + "\(onboarding?.window.isVisible == true), browser windows \(app.controllers.count), Little Aircs \(app.littleArcs.count))")
            if let o = onboarding { app.onboardingDidFinish(o) }
        }
        step { [self] done in
            waitUntil({ self.app?.littleArcs.contains { $0.page?.url?.query?.contains("from=linklaunch") == true } == true }, timeout: 20) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: done)
            }
        }
        run { [self] in
            guard let app else { return }
            check(app.controllers.count == 1 && app.littleArcs.contains { $0.page?.url?.query?.contains("from=linklaunch") == true },
                  "\(label): once onboarding is done, the browser window opens and the link opens in Little Airc (windows "
                  + "\(app.controllers.count), Little Aircs \(app.littleArcs.count))")
        }
        linkLaunchLogLines()
    }
}

/// From the launch on (SnapshotRunner.init, before the launch's window decision): every window of the app other than
/// Little Airc that becomes visible, every Space change, and whether the sending app's full-screen Space leaves the
/// screen, sampled every 20 ms until Little Airc is checked.
final class LinkLaunchProbe {
    static let shared = LinkLaunchProbe()
    private weak var app: AppDelegate?
    private let started = Date()
    private(set) var spaceChanges: [String] = []
    private(set) var shownWindows: [String] = []
    private(set) var fsLeftScreen: [String] = []
    private(set) var history: [String] = []
    /// The sending app (AIRC_LA_FS_SOURCE, its bundle ID).
    private(set) var fsPID: pid_t?
    /// After the Little Airc checks: the reopen's windows are expected.
    var windowsAllowed = false
    private var seen: Set<String> = []
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var fsWasCurrent: Bool?

    private func stamp() -> String { String(format: "+%.3f s", Date().timeIntervalSince(started)) }

    func start(app: AppDelegate?) {
        guard timer == nil else { return }
        self.app = app
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.windowsAllowed else { return }
            self.spaceChanges.append("\(self.stamp()) (\(LinkLog.frontApp()))")
        }
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        history.append("\(stamp()) started")
    }

    private func sample() {
        guard !windowsAllowed, let app else { return }
        if fsPID == nil, let id = ProcessInfo.processInfo.environment["AIRC_LA_FS_SOURCE"],
           let pid = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier { fsPID = pid }
        if let pid = fsPID {
            let current = FullScreenSpaces.space(of: pid)?.current
            if current != fsWasCurrent {
                history.append("\(stamp()) the full-screen Space on screen \(current.map(LinkLog.yesNo) ?? "none")")
                if fsWasCurrent == true, current != true { fsLeftScreen.append(stamp()) }
                fsWasCurrent = current
            }
        }
        // Little Airc's own windows (its panel, and the engine's child windows in it) aside.
        func inLittleArc(_ w: NSWindow) -> Bool {
            var x: NSWindow? = w
            while let c = x { if app.littleArc(for: c) != nil { return true }; x = c.parent }
            return false
        }
        for w in NSApp.windows where w.isVisible && !inLittleArc(w) && w.frame.width > 200 && w.frame.height > 150 {
            let name = "\(app.windowName(w)) \(Int(w.frame.width))×\(Int(w.frame.height))"
            if seen.insert(name).inserted { shownWindows.append("\(stamp()) \(name)") }
        }
        if !app.littleArcs.isEmpty, !history.contains(where: { $0.hasSuffix("Little Airc open") }) { history.append("\(stamp()) Little Airc open") }
    }
}
#endif

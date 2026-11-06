// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--snapshot <dir> --script <name>`: drives a scripted scenario through the real UI code, writes
/// window PNGs (no screen-recording permission needed: our views render themselves, and the page
/// comes from the engine's snapshot), then quits. Used to check the UI from the Linux box.
final class SnapshotRunner {
    weak var app: AppDelegate?
    /// The browser window. Set once it exists (after onboarding, in the onboarding scenario).
    var c: WindowController! { app?.controller }
    let dir: URL
    let script: String
    private var steps: [(@escaping () -> Void) -> Void] = []
    private var log: [String] = []
    var spaces: [String: String] = [:]   // name → ID
    var onboarding: OnboardingController?
    private var started = false

    init(app: AppDelegate, directory: URL, script: String) {
        self.app = app
        dir = directory
        self.script = script
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// The browser window opened (every scenario but onboarding starts here).
    func windowDidOpen(_ controller: WindowController) {
        guard script != "onboarding", script != "onboarding-e2e" else { return }
        if script == "perf" { PerfLaunch.windowOpened() }
        start()
    }

    /// The onboarding window is up (`--script onboarding`).
    func onboardingDidStart(_ o: OnboardingController) {
        guard script == "onboarding" || script == "onboarding-e2e", onboarding == nil else { return }
        onboarding = o
        start()
    }

    private func start() {
        guard !started else { return }
        started = true
        note("engine: \(app?.engine.name ?? "?")")
        switch script {
        case "showcase": showcase()
        case "onboarding": onboardingScenario()
        case "onboarding-e2e": onboardingE2EScenario()
        case "importux": importUXScenario()
        case "persist-write": persistWrite()
        case "persist-read": persistRead()
        case "split-write": splitPersistWrite()
        case "split-read": splitPersistRead()
        case "events": eventsScenario()
        case "littlearc": littleArcLinkScenario()
        case "littlearc-cold": littleArcColdStartScenario()
        case "drmsettings": protectedContentSettingsScenario()
        case "perf": perfScenario()
        case "callspace": callSpaceScenario()
        case "sitecontrols": siteControlsScenario()
        case "calendar": calendarScenario()
        case "updatebutton": updateButtonScenario()
        case "boosts": boostsScenario()
        case "medialib", "medialib-downloads", "medialib-media", "medialib-call": mediaLibScenario()
        case "pipcontrols": pipControlsScenario()
        case "cbperf": commandBarHistoryPerf()
        case "frames": framesScenario()
        case "extension": extensionScenario()
        case "fullscreen": fullScreenScenario()
        case "fullscreen-exit": fullscreenExitCheck()
        case "smoke": activateForRealInput(); smokeScenario()
        case "page-input": activateForRealInput(); waitForPage(); pageInput()
        case "dialogs":
            #if canImport(AircCore)
            dialogsScenario()
            #else
            note("dialogs: Chromium only")
            #endif
        case "password-bounds":
            #if canImport(AircCore)
            passwordBoundsScenario()
            #endif
        case "prompts":
            #if canImport(AircCore)
            promptsScenario()
            #else
            note("prompts: Chromium only")
            #endif
        case "telemetry": telemetryScenario()
        case "crashreports": crashReportsScenario()
        case "followups": followupsScenario()
        case "marketing": marketingScenario()   // product shots, not a check: scripts/marketing-shots.sh only
        default:
            note("unknown script \(script)")
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.next() }
        // Never hang the build: quit after four minutes whatever happens (the perf harness allows 660 s).
        let limit: Double = script == "perf" ? 660 : 240
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
            self.note("FAIL \(self.script): timed out after \(Int(limit)) s with \(self.steps.count) steps left")
            self.finish()
        }
    }

    private func next() {
        guard !steps.isEmpty else { return finish() }
        let s = steps.removeFirst()
        s { DispatchQueue.main.async { self.next() } }
    }

    func step(_ s: @escaping (@escaping () -> Void) -> Void) { steps.append(s) }
    func run(_ block: @escaping () -> Void) { step { done in block(); done() } }
    func wait(_ seconds: Double) { step { done in DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: done) } }

    /// AIRC_REAL_CLICKS=1 (the owner allows it briefly): the app takes focus, so the window is key and the checks that
    /// need an active window (a click's effect on a page, automatic PiP) run too; the run quits right after.
    func activateForRealInput() {
        guard ProcessInfo.processInfo.environment["AIRC_REAL_CLICKS"] == "1" else { return }
        step { [self] done in
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            waitUntil({ self.c.window.isKeyWindow }, timeout: 5) {
                self.note("\(self.script): real input, window key \(self.c.window.isKeyWindow), app active \(NSApp.isActive)")
                done()
            }
        }
    }

    func note(_ s: String) {
        log.append(s)
        print("[snapshot] " + s)
    }

    func finish() {
        let file = dir.appendingPathComponent("log.txt")
        let previous = (try? String(contentsOf: file, encoding: .utf8)).map { $0 + "\n" } ?? ""
        try? (previous + "[\(script)]\n" + log.joined(separator: "\n")).write(to: file, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    // MARK: The showcase scenario

    private func showcase() {
        let store = c.store
        run { [self] in
            do {
                // Profiles: the default one plus two of our own, each with its own engine data store.
                let personal = store.defaultProfile
                let work = try c.profiles.createProfile(name: "Work", emoji: "💼", color: RGBA(hex: "7EB6D5"))
                let studio = try c.profiles.createProfile(name: "Studio", emoji: "🎨", color: RGBA(hex: "E59EBA"))

                // Spaces in different themes and profiles, like the owner's sidebar.
                let first = store.selectedSpace
                try store.updateSpace(first.id) {
                    $0.name = "Home"
                    $0.icon = .emoji("🏠")
                    $0.theme = DesignTheme.preset("mint")!.model
                }
                let workSpace = try store.createSpace(name: "Work", icon: .emoji("💼"),
                    theme: DesignTheme.preset("sky")!.model, profileID: work.id, after: first.id)
                let studioSpace = try store.createSpace(name: "Studio", icon: .emoji("🎨"),
                    theme: DesignTheme.preset("grape")!.model,
                    profileID: studio.id, after: workSpace.id)
                let side = try store.createSpace(name: "Side project", icon: nil, theme: DesignTheme.preset("paper")!.model,
                                                 profileID: personal.id, after: studioSpace.id)
                let money = try store.createSpace(name: "Garden", icon: .emoji("🌱"), theme: DesignTheme.preset("lemon")!.model,
                                                  profileID: work.id, after: side.id)
                spaces = ["personal": first.id, "work": workSpace.id, "studio": studioSpace.id, "money": money.id]

                // Favorites belong to the profile.
                try favorite("https://mail.google.com/mail/u/0/#inbox", title: "Inbox (3) - Gmail",
                             icon: "https://ssl.gstatic.com/ui/v1/icons/mail/rfr/gmail.ico", profile: personal.id, space: first.id)
                try favorite("https://calendar.google.com/calendar/r", title: "Google Calendar", icon: nil,
                             profile: personal.id, space: first.id)
                try favorite("https://github.com/", title: "GitHub", icon: "https://github.githubassets.com/favicons/favicon.png",
                             profile: work.id, space: workSpace.id)
                try favorite("https://linear.app/", title: "Linear", icon: "https://linear.app/favicon.ico",
                             profile: work.id, space: workSpace.id)
                try favorite("https://www.notion.so/", title: "Notion", icon: "https://www.notion.so/images/favicon.ico",
                             profile: work.id, space: workSpace.id)
                try favorite("https://www.figma.com/", title: "Figma", icon: "https://static.figma.com/app/icon/1/favicon.png",
                             profile: studio.id, space: studioSpace.id)

                // Pinned: a few tabs and a folder; Today: real pages.
                try pin("https://docs.google.com/spreadsheets/", title: "Trip budget - Google Sheets",
                        icon: "https://ssl.gstatic.com/docs/spreadsheets/favicon3.ico", space: first.id)
                let trips = try store.createFolder(named: "Trips", inSpace: first.id)
                try pin("https://www.google.com/maps", title: "Google Maps", icon: "https://www.google.com/images/branding/product/ico/maps15_bnuw3a_32dp.ico",
                        space: first.id, parent: trips.id)
                try pin("https://en.wikipedia.org/wiki/Lisbon", title: "Lisbon - Wikipedia",
                        icon: "https://en.wikipedia.org/static/favicon/wikipedia.ico", space: first.id, parent: trips.id)
                try pin("https://github.com/apple/swift", title: "swiftlang/swift", icon: "https://github.githubassets.com/favicons/favicon.png", space: first.id)
                try pin("http://localhost:5173/app", title: "localhost:5173/app", icon: nil, space: first.id)

                for (url, title) in [("https://news.ycombinator.com/", "Hacker News"),
                                     ("https://www.youtube.com/", "YouTube"),
                                     ("https://developer.apple.com/documentation/appkit", "AppKit | Apple Developer Documentation")] {
                    _ = try store.openTab(url: url, inSpace: first.id, activate: false, title: title)
                }
                let shown = try store.openTab(url: "https://en.wikipedia.org/wiki/Arc_(web_browser)", inSpace: first.id,
                                              title: "Arc (web browser) - Wikipedia")

                try pin("https://developer.apple.com/documentation/webkit", title: "WebKit docs",
                        icon: "https://developer.apple.com/favicon.ico", space: workSpace.id)
                _ = try store.openTab(url: "https://developer.apple.com/documentation/swiftui", inSpace: workSpace.id, activate: false, title: "SwiftUI")
                _ = try store.openTab(url: "https://github.com/trending", inSpace: workSpace.id, title: "Trending repositories on GitHub")

                _ = try store.openTab(url: "https://en.wikipedia.org/wiki/Oklab_color_space", inSpace: studioSpace.id, activate: false, title: "Oklab")
                _ = try store.openTab(url: "https://en.wikipedia.org/wiki/Color_theory", inSpace: studioSpace.id, title: "Color theory - Wikipedia")
                _ = try store.openTab(url: "https://en.wikipedia.org/wiki/Budget", inSpace: money.id, title: "Budget - Wikipedia")

                c.reloadAll(animated: false)
                c.switchToSpace(first.id, animated: false)
                c.show(shown.id, focus: false)
                note("seeded: \(store.state.profiles.count) profiles, \(store.state.spaces.count) spaces, \(store.state.tabs.count) tabs")
            } catch {
                note("seed failed: \(error)")
            }
        }
        waitForPage()
        capture("01-space-personal")

        switchTo("work")
        waitForPage()
        capture("02-space-work")

        switchTo("studio")
        waitForPage()
        capture("03-space-studio")

        // SB-44 (owner, 2026-11-05): a row while its page loads: the ring in the favicon slot after 150 ms and a
        // long title that fades out before the trailing edge.
        run { [self] in
            guard let t = try? c.store.openTab(url: "https://techcrunch.com/", inSpace: c.currentSpaceID,
                                              title: "TechCrunch | Startup and Technology News") else { return }
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        wait(0.45)
        capture("03b-row-loading")

        // A real two-finger swipe from personal toward Work, captured mid-gesture.
        run { [self] in c.switchToSpace(spaces["personal"]!, animated: false) }
        waitForPage()
        run { [self] in
            swipe(phase: .began, dx: -4)
            for _ in 0..<10 { swipe(phase: .changed, dx: -10) }
        }
        wait(0.05)
        capture("04-swipe-mid")
        run { [self] in
            let t0 = CACurrentMediaTime()
            // A quick flick: the release speed carries it to Work.
            for _ in 0..<3 { swipe(phase: .changed, dx: -12); Thread.sleep(forTimeInterval: 0.008) }
            swipe(phase: .ended, dx: 0)
            note(String(format: "swipe release → page swap: %.1f ms", (CACurrentMediaTime() - t0) * 1000))
        }
        wait(0.45)
        capture("05-swipe-settled")

        // Space switch timing (§2.12): main-thread work from the click/key to the new Space's first frame being
        // committed, measured per switch with a run-loop observer after Core Animation's commit.
        measureSpaceSwitches()

        // Command Bar: history and open tabs ranked with inline completion, search suggestions, the "/" actions
        // mode, and ⌘L opening over the URL field.
        commandBarScenario()

        // Create a Space (SP-10): the card on the sidebar page, then New Profile… from the Profile pill (SP-11, one step).
        run { [self] in
            c.openNewSpacePanel()
            guard let m = c.newSpacePanel?.model else { return }
            m.name = "Clients"
            m.icon = "🧾"
            m.theme = DesignTheme.preset("ember")?.model
        }
        wait(0.6)
        capture("07-new-space-sheet")
        run { [self] in
            guard let m = c.newSpacePanel?.model else { return }
            c.showThemePickerForTests()
            note("theme row → picker: \(c.themePopover?.isShown == true ? "shown" : "not shown"); theme colours \(m.currentTheme.colors.count)")
        }
        wait(0.5)
        step { [self] done in
            guard let v = c.themePopover?.contentView, let w = v.window else { note("no theme picker window"); return done() }
            captureWindow(w, name: "07a-theme-picker", rounded: 0, done)
        }
        run { [self] in
            c.themePopover?.close()
            guard let m = c.newSpacePanel?.model else { return }
            c.openCreateProfile(forNewSpace: m)
            guard let pm = c.createProfilePanel?.model else { return note("no Create Profile card") }
            pm.name = "Clients"
            pm.emoji = "🤝"
            pm.colorIndex = 4
        }
        wait(0.5)
        capture("07b-create-profile-one-step")
        run { [self] in
            c.createProfilePanel?.model.onCreate?()
            note("one-step Create Profile → card's profile: \(c.newSpacePanel?.model.profile?.name ?? "-"); profiles: "
                 + c.store.orderedProfiles.map(\.name).joined(separator: ", "))
        }
        wait(0.4)
        capture("07c-new-space-new-profile")
        step { [self] done in
            Perf.reset()
            Perf.enabled = true
            FrameTiming.measure({ self.c.newSpacePanel?.model.onCreate?() }) { t in
                Perf.enabled = false
                self.note("new space with new profile, Enter → first frame: " + t.description)
                self.note("new space sections (ms): " + Perf.report())
                done()
            }
        }
        wait(0.6)
        capture("08-new-space-created")
        // Space menu → Set Profile › New Profile…: Arc's two steps, with this Space ticked.
        run { [self] in
            c.openCreateProfile(forSpace: spaces["studio"])
            guard let pm = c.createProfilePanel?.model else { return note("no Create Profile card") }
            pm.name = "Freelance"
            pm.colorIndex = 2
        }
        wait(0.5)
        capture("08b-create-profile-step1")
        run { [self] in
            guard let pm = c.createProfilePanel?.model else { return }
            pm.step = .spaces
            if let money = spaces["money"] { pm.chosen.insert(money) }
        }
        wait(0.5)
        capture("08c-create-profile-step2")
        run { [self] in c.createProfilePanel?.model.onCancel?() }
        wait(0.3)

        // Hidden sidebar (⌘S).
        run { [self] in c.switchToSpace(spaces["personal"]!, animated: false) }
        waitForPage()
        run { [self] in c.toggleSidebar() }
        wait(0.4)
        capture("09-sidebar-hidden")
        run { [self] in c.toggleSidebar() }
        wait(0.3)

        // Drag a Today tab into the pinned section with real mouse events through the window,
        // captured mid-drag (ghost + drop line), then after the drop.
        dragTodayTabIntoPinned()
        wait(0.5)
        capture("10-drag-dropped")
        libraryAndFolderPreview()
        run { [self] in
            note("op log entries: \((try? c.store.operations().count) ?? -1)")
            try? c.store.flush()
        }
        settingsScenario()
    }

    // MARK: Relaunch check: write state, quit; a second launch on the same data captures it.

    private func persistWrite() {
        run { [self] in
            do {
                let store = c.store
                let work = try c.profiles.createProfile(name: "Work", emoji: "💼", color: RGBA(hex: "7EB6D5"))
                let s = try store.createSpace(name: "Work", icon: .emoji("💼"), theme: DesignTheme.preset("ocean")!.model,
                                              profileID: work.id, after: store.selectedSpace.id)
                try favorite("https://github.com/", title: "GitHub", icon: "https://github.githubassets.com/favicons/favicon.png",
                             profile: work.id, space: s.id)
                try pin("https://developer.apple.com/documentation/appkit", title: "AppKit", icon: "https://developer.apple.com/favicon.ico", space: s.id)
                _ = try store.createFolder(named: "Reading", inSpace: s.id)
                _ = try store.openTab(url: "https://example.com/", inSpace: s.id, activate: false, title: "Example Domain")
                let t = try store.openTab(url: "https://en.wikipedia.org/wiki/Persistence_(computer_science)", inSpace: s.id,
                                          title: "Persistence")
                c.reloadAll(animated: false)
                c.switchToSpace(s.id, animated: false)
                c.show(t.id, focus: false)
            } catch { note("persist-write failed: \(error)") }
        }
        waitForPage()
        capture("12-persist-before-quit")
        // H6: a spare profile is prepared (as the profile menu does) and its folder is kept for the next launch.
        run { [self] in c.profiles.prepareSpare() }
        wait(1.5)
        run { [self] in
            note("spare: \(c.profiles.spareDirectory ?? "-"), engine profile folders \(engineFolders())")
            note("state: " + summary()); try? c.store.flush()
        }
    }

    private func persistRead() {
        waitForPage()
        capture("13-persist-after-relaunch")
        run { [self] in note("state: " + summary()) }
        // H6: the relaunch reuses the spare's folder, and New Profile adopts it: no new folder appears.
        var spare: String?
        var folders = 0
        run { [self] in
            spare = c.profiles.spareDirectory
            folders = engineFolders()
            c.profiles.prepareSpare()
        }
        wait(1.5)
        run { [self] in
            check(spare != nil && c.profiles.spareDirectory == spare && engineFolders() == folders,
                  "spare profile (H6): the relaunch reuses \(spare ?? "-") (now \(c.profiles.spareDirectory ?? "-")), engine profile folders \(folders) → \(engineFolders())")
            guard let p = try? c.profiles.createProfile(name: "Later", emoji: "", color: nil) else { return check(false, "spare profile: New Profile failed") }
            check(p.engineDirectory == spare && c.profiles.spareDirectory == nil,
                  "spare profile (H6): New Profile adopts the spare's folder (\(p.engineDirectory))")
        }
        wait(1)
        run { [self] in
            check(engineFolders() == folders, "spare profile (H6): no new engine folder after New Profile (\(folders) → \(engineFolders()))")
            try? c.store.flush()
        }
    }

    /// Chromium's profile folders on disk (-1 on WebKit, which keeps no folders per profile).
    private func engineFolders() -> Int {
        guard app?.engine.name.hasPrefix("Chromium") == true else { return -1 }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.chromium.path)) ?? []
        return names.filter { $0 == "Default" || $0.hasPrefix("Profile-") }.count
    }

    private func summary() -> String {
        let s = c.store
        let current = s.space(c.currentSpaceID)
        return "profiles=\(s.orderedProfiles.map(\.name)) spaces=\(s.orderedSpaces.map(\.name)) "
            + "current=\(current?.name ?? "-") shown=\(s.tab(c.shownTabID)?.title ?? "-") "
            + "pinned=\(s.pinnedRows(ofSpace: c.currentSpaceID).count) today=\(s.todayTabs(ofSpace: c.currentSpaceID).count) "
            + "favorites=\(s.favorites(ofProfile: s.profile(ofSpace: c.currentSpaceID).id).count)"
    }

    func favorite(_ url: String, title: String, icon: String?, profile: String, space: String) throws {
        let t = try c.store.openTab(url: url, inSpace: space, activate: false, title: title)
        try c.store.move(.tab(t.id), to: .favorites(profileID: profile, index: 99))
        if let item = c.store.tab(t.id)?.itemID {
            try c.store.replaceSavedURL(ofItem: item, with: url, title: title)
            if let icon { try setIcon(item, icon) }
        }
        try c.store.closeTab(t.id)
    }

    func pin(_ url: String, title: String, icon: String?, space: String, parent: String? = nil) throws {
        let t = try c.store.openTab(url: url, inSpace: space, activate: false, title: title)
        let index = c.store.children(of: .pinned(spaceID: space), parent: parent).count
        try c.store.move(.tab(t.id), to: .pinned(spaceID: space, parentID: parent, index: index))
        if let item = c.store.tab(t.id)?.itemID {
            try c.store.replaceSavedURL(ofItem: item, with: url, title: title)
            if let icon { try setIcon(item, icon) }
        }
        try c.store.closeTab(t.id)
    }

    private func setIcon(_ itemID: String, _ url: String) throws {
        guard var i = c.store.item(itemID) else { return }
        i.faviconURL = url
        try c.store.perform(nil) { c.store.put(i) }
    }

    func switchTo(_ name: String) {
        run { [self] in if let id = spaces[name] { c.switchToSpace(id, animated: false) } }
    }

    /// Waits until the shown page has loaded (or 12 s), then a moment for paint and favicons.
    func waitForPage() {
        step { [self] done in
            let deadline = Date().addingTimeInterval(12)
            func poll() {
                // Not loading is enough: Chromium resets a page's progress to 0 when its load finishes.
                let page = c.shownTabID.flatMap { c.engineTab(for: $0) }
                if let page, page.isLoading, Date() > deadline {
                    note(String(format: "page still loading after 12 s: %@ (progress %.2f)", page.url?.absoluteString ?? "-", page.progress))
                }
                if page == nil || page!.isLoading == false || Date() > deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: done)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
                }
            }
            poll()
        }
    }

    // MARK: Synthesized trackpad events

    private enum Phase: UInt32 { case began = 1, changed = 2, ended = 4 }

    private func swipe(phase: Phase, dx: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        guard let ns = NSEvent(cgEvent: e) else { return }
        c.sidebar.scrollWheel(with: ns)
    }

    // MARK: Capture

    private func dragTodayTabIntoPinned() {
        step { [self] done in
            guard let page = c.pageView(for: c.currentSpaceID),
                  let hn = c.store.todayTabs(ofSpace: c.currentSpaceID).first(where: { $0.url.contains("ycombinator") }),
                  let swift = c.store.pinnedRoots(ofSpace: c.currentSpaceID).first(where: { $0.savedURL?.contains("swift") == true })
            else { note("drag: rows not found"); return done() }
            page.layoutSubtreeIfNeeded()
            let rows = page.list.subviews
            guard let source = rows.first(where: { ($0 as? TabRowView)?.tabID == hn.id }),
                  let target = rows.first(where: { ($0 as? TabRowView)?.entry?.item?.id == swift.id })
            else { note("drag: views not found"); return done() }
            c.sidebar.setHovered(true)
            let start = source.convert(NSPoint(x: 90, y: source.bounds.midY), to: nil)
            let end = target.convert(NSPoint(x: 110, y: target.bounds.maxY - 6), to: nil)
            let window = c.window
            func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: type == .leftMouseUp ? 0 : 1)
            }
            var i = 0
            let steps = 24
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
                i += 1
                if i <= steps {
                    let f = CGFloat(i) / CGFloat(steps)
                    let p = NSPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f)
                    if let e = mouse(.leftMouseDragged, p) { NSApp.postEvent(e, atStart: false) }
                } else if i == steps + 4 {
                    self.captureNow("10-drag-mid") {}
                } else if i == steps + 30 {
                    t.invalidate()
                    if let e = mouse(.leftMouseUp, end) { NSApp.postEvent(e, atStart: false) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            if let down = mouse(.leftMouseDown, start) { window.sendEvent(down) }   // runs the drag loop until mouse-up
            let pinnedNow = c.store.pinnedRows(ofSpace: c.currentSpaceID).compactMap { $0.item?.savedURL }
            note("drag: Hacker News is now " + (c.store.tab(hn.id)?.itemID != nil ? "pinned" : "still in Today")
                 + "; pinned order: " + pinnedNow.map { URLRules.displayHost($0) }.joined(separator: ", "))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.c.sidebar.setHovered(false)
                done()
            }
        }
    }

    /// Renders the window: our views draw themselves; the page comes from the engine's snapshot;
    /// overlays (Command Bar, New Space, toasts) are drawn last.
    func capture(_ name: String) {
        step { [self] done in captureNow(name, done) }
    }

    func captureNow(_ name: String, _ done: @escaping () -> Void) {
        do {
            let root = c.root
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let overlays: [NSView] = [c.commandBar, c.newSpacePanel, c.createProfilePanel, c.folderPreview.panel, c.siteControls, c.boostEditor,
                                      CalendarCard.shared.panel, c.peek?.view, c.prompts.bubble, c.prompts.passwords.view,
                                      c.toast.isHidden ? nil : c.toast].compactMap { $0 }
            overlays.forEach { $0.isHidden = true }
            let frameView = root.superview ?? root
            let base = render(frameView)
            overlays.forEach { $0.isHidden = false }
            let overlayImages = overlays.map { ($0.frame, render($0)) }
            let cardFrame = c.card.frame
            // Peek's page goes into its card (window coordinates → root's flipped ones).
            let peekRect: NSRect? = c.peek.map { p in root.convert(p.view.pageHost.convert(p.view.pageHost.bounds, to: nil), from: nil) }
            var peekImage: NSImage?
            // SV-1: a split's panes, each page into its pane (root's flipped coordinates).
            let panes: [(id: String, rect: NSRect)] = c.shownSplitID == nil ? [] : c.splitContainer.panes.map {
                ($0.tabID, root.convert($0.convert($0.bounds, to: nil), from: nil))
            }
            var paneImages: [(NSRect, NSImage)] = []
            let finish: (NSImage?) -> Void = { page in
                let size = root.bounds.size
                let scale: CGFloat = 2
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                           pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                           bitsPerPixel: 0)!
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                base?.draw(in: NSRect(origin: .zero, size: size))
                for (pr, img) in paneImages {
                    let r = NSRect(x: pr.minX, y: size.height - pr.maxY, width: pr.width, height: pr.height)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: r, xRadius: AircMetrics.Window.cardRadius, yRadius: AircMetrics.Window.cardRadius).addClip()
                    img.draw(in: r)
                    NSGraphicsContext.restoreGraphicsState()
                }
                if let page, panes.isEmpty {
                    // Root is flipped; image space isn't.
                    let r = NSRect(x: cardFrame.minX, y: size.height - cardFrame.maxY, width: cardFrame.width, height: cardFrame.height)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: r, xRadius: AircMetrics.Window.cardRadius, yRadius: AircMetrics.Window.cardRadius).addClip()
                    page.draw(in: r)
                    NSGraphicsContext.restoreGraphicsState()
                }
                for (frame, img) in overlayImages {
                    let r = NSRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height)
                    img?.draw(in: r)
                }
                if let pr = peekRect, let peekImage {
                    peekImage.draw(in: NSRect(x: pr.minX, y: size.height - pr.maxY, width: pr.width, height: pr.height))
                }
                NSGraphicsContext.restoreGraphicsState()
                let url = self.dir.appendingPathComponent(name + ".png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                self.note("wrote \(name).png")
                done()
            }
            let single = { (done: @escaping (NSImage?) -> Void) in
                if let id = self.c.shownTabID, let page = self.c.engineTab(for: id) { page.snapshot(completion: done) } else { done(nil) }
            }
            let shown = { (done: @escaping (NSImage?) -> Void) in
                guard !panes.isEmpty else { return single(done) }
                // Each pane's page in turn, then the rest.
                func next(_ k: Int) {
                    guard k < panes.count else { return done(nil) }
                    guard let page = self.c.engineTab(for: panes[k].id) else { return next(k + 1) }
                    page.snapshot { img in
                        if let img { paneImages.append((panes[k].rect, img)) }
                        next(k + 1)
                    }
                }
                next(0)
            }
            if let p = c.peek?.page {
                p.snapshot { img in peekImage = img; shown(finish) }
            } else {
                shown(finish)
            }
        }
    }

    /// `view` as the screen shows it. AircSnapshot draws each label once: a plain `cacheDisplay` composites macOS 26's
    /// labels twice, so all ink came out too dark (docs/design.md, pass-4 decision 1).
    func render(_ view: NSView) -> NSImage? {
        MainActor.assumeIsolated { AircSnapshot.image(of: view) }
    }
}
#endif

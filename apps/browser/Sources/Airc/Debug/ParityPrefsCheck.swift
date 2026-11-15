// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
import Security

/// Records the taps haptic feedback on lets through (in place of the trackpad).
private final class PrefsHapticRecorder: NSObject, NSHapticFeedbackPerformer {
    private(set) var taps = 0
    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern, performanceTime: NSHapticFeedbackManager.PerformanceTime) { taps += 1 }
}

/// What a `prefs-<pass>-write` run leaves for its `-read` run, in the data folder.
private struct PrefsExpected: Codable {
    struct Window: Codable { var spaceID: String; var tabID: String? }
    var icon: String
    var windows: [Window]
    var tabs: [String]
}

/// `--script parityprefs` (prefs: docs/qa/parity-audit.md E12, Q03; E15's settings from P21b re-verified), both
/// engines, loopback pages, **real input** from the build Mac's UI driver (AIRC_REAL_KEYS=1, a dedicated UI session):
///   1. Haptic feedback when reordering tabs: a real drag of the first Today tab to below the third taps the trackpad
///      (a recording performer) once per place it passes; after a real click on the switch in Settings › General, the
///      same drag taps nothing; another click turns it back on.
///   2. Play Airc sound effects: a real click turns it off: the alert and an NSSound stay quiet, from the real call
///      site (Format › Bold with nothing editable) too, and no `-[NSSound play]` runs at all (probed); a click turns
///      it back on and the alert plays.
///   3. App Icon: real clicks on Outline, Sunset, Ocean and Graphite each put it up as the Dock's icon and in
///      settings.json, six different pictures; Midnight also becomes the bundle's Finder icon, with `codesign --verify
///      --deep` and SecStaticCodeCheckValidity (strict) still passing; Holographic gives the app's own icon back and
///      takes the Finder icon off (`--strict` passes again).
///   4. When Airc starts: “Open my windows and tabs from last time” by default, this launch restored; the section on
///      screen (parityprefs-general.png).
/// `--script prefs-<restore|fresh|crash>-<write|read>` (the same data folder, two launches each): the Outline icon set
/// in the write run is the Dock's at the read run's launch; "Open my windows and tabs from last time" (default) brings
/// both windows back with their tabs; "Open a new window" opens one window on the Space used last with no tab open,
/// every tab still in the sidebar; with "Open a new window" and a crash (the write run ends with `_exit`, no quit),
/// both windows come back.
extension SnapshotRunner {
    func parityPrefsScenario() {
        let tag = "parityprefs"
        var server: LocalPageServer?, base = ""
        let recorder = PrefsHapticRecorder()
        var beeps = 0, beepsBefore = 0, playsBefore = 0, silencedBefore = 0
        var tapsBefore = 0, stepsBefore = 0, skippedBefore = 0, orderBefore: [String] = []
        var launchedIcon: NSImage?
        let quiet = NSSound(named: "Tink")
        quiet?.volume = 0
        func settings() -> NSWindow? { app?.settingsWindow?.window }

        guard UIDriverClient.available else {
            note("SKIP \(tag): real input only (AIRC_REAL_KEYS=1, the UI driver, a dedicated UI session)")
            return finish()
        }
        step { [self] done in
            server = LocalPageServer(pages: Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d"].map {
                ("/\($0).html", "<!doctype html><title>Tab \($0.uppercased())</title><p style='font:18px -apple-system;padding:30px'>\($0)</p>")
            }))
            server?.start { port in
                guard let port else { self.check(false, "\(tag): the loopback pages"); return self.finish() }
                base = "http://127.0.0.1:\(port)"
                done()
            }
        }
        run { [self] in
            AppPersonalization.testBeep = { beeps += 1 }
            AppPersonalization.testHapticPerformer = recorder
            AppPersonalization.installSoundProbe()
            launchedIcon = NSImage(data: NSApp.applicationIconImage.tiffRepresentation ?? Data())
            let sid = c.currentSpaceID
            let ids = ["d", "c", "b", "a"].compactMap { try? c.store.openTab(url: base + "/\($0).html", inSpace: sid, activate: false, title: "Tab \($0.uppercased())").id }
            c.reloadAll(animated: false)
            if let first = ids.last { c.show(first, focus: false) }
            check(app?.settings.values.startupWindows == .lastSession && app?.windowSession.launchRestored == true,
                  "\(tag): When Airc starts is “\(app?.settings.values.startupWindows.title ?? "?")” by default, and this launch restored")
            check(AppPersonalization.preferences == PersonalizationPreferences() && AppPersonalization.availableIcons == PersonalizationPreferences.AppIcon.allCases,
                  "\(tag): Holographic, sounds and haptics on by default (as Arc's); icons \(AppPersonalization.availableIcons.map(\.title))")
        }
        waitForPage()

        // 1. Haptics on reorder steps, with real drags.
        for on in [true, false] {
            if !on { prefsClickSetting(.general, anchor: "prefs.haptics", tag: tag) }
            run { [self] in
                check(AppPersonalization.preferences.haptics == on, "\(tag): Haptic feedback when reordering tabs is \(on ? "on" : "off (a real click)")")
                tapsBefore = recorder.taps
                stepsBefore = AppPersonalization.reorderSteps
                skippedBefore = AppPersonalization.SilentHaptics.shared.skipped
                orderBefore = c.store.todayTabs(ofSpace: c.currentSpaceID).map(\.id)
            }
            prefsRealDrag(from: { orderBefore.first }, below: { orderBefore.count > 2 ? orderBefore[2] : nil }, tag: tag)
            run { [self] in
                let order = c.store.todayTabs(ofSpace: c.currentSpaceID).map(\.id)
                let steps = AppPersonalization.reorderSteps - stepsBefore, taps = recorder.taps - tapsBefore
                let skipped = AppPersonalization.SilentHaptics.shared.skipped - skippedBefore
                let moved = order != orderBefore && (order.firstIndex(of: orderBefore.first ?? "") ?? 0) >= 2
                if on {
                    check(moved && steps >= 2 && taps == steps,
                          "\(tag): haptic feedback on: a real drag reorders (\(moved)) and taps once per place (\(steps) places, \(taps) taps)")
                } else {
                    check(moved && steps >= 2 && taps == 0 && skipped == steps,
                          "\(tag): haptic feedback off: the same real drag taps nothing (\(steps) places, \(taps) taps, \(skipped) skipped)")
                }
            }
        }
        prefsClickSetting(.general, anchor: "prefs.haptics", tag: tag)
        run { [self] in
            check(AppPersonalization.preferences.haptics, "\(tag): a real click turns haptic feedback back on")
            AppPersonalization.testHapticPerformer = nil
        }

        // 2. Sounds.
        prefsClickSetting(.general, anchor: "prefs.sounds", tag: tag)
        run { [self] in
            let saved = AppSettings(directory: AppPaths.dataDirectory).values.personalization.playsSounds
            check(!AppPersonalization.preferences.playsSounds && !saved, "\(tag): a real click turns Play Airc sound effects off (settings.json: \(saved ? "on" : "off"))")
            beepsBefore = beeps
            playsBefore = AppPersonalization.soundPlays
            silencedBefore = AppPersonalization.silencedBeeps
            NSSound.beep()
            AppPersonalization.play(quiet)
            FormatRouter.shared.apply(.bold, in: c.window)
        }
        wait(0.6)
        run { [self] in
            check(beeps == beepsBefore && AppPersonalization.soundPlays == playsBefore && AppPersonalization.silencedBeeps >= silencedBefore + 2,
                  "\(tag): sound effects off: no alert and no NSSound plays (\(beeps - beepsBefore) alerts, \(AppPersonalization.soundPlays - playsBefore) NSSound plays, \(AppPersonalization.silencedBeeps - silencedBefore) kept quiet)")
        }
        prefsCaptureSettings("parityprefs-general.png")
        prefsClickSetting(.general, anchor: "prefs.sounds", tag: tag)
        run { [self] in
            beepsBefore = beeps
            playsBefore = AppPersonalization.soundPlays
            NSSound.beep()
            AppPersonalization.play(quiet)
            check(AppPersonalization.preferences.playsSounds && beeps == beepsBefore + 1 && AppPersonalization.soundPlays == playsBefore + 1,
                  "\(tag): a real click turns sound effects back on: the alert and a sound play (\(beeps - beepsBefore), \(AppPersonalization.soundPlays - playsBefore))")
        }

        // 3. App Icon.
        prefsClickSetting(.appearance, anchor: "prefs.icon.outline", tag: tag)
        run { [self] in
            let d = Self.prefsIconDifference(NSApp.applicationIconImage, AppPersonalization.image(for: .outline))
            let saved = AppSettings(directory: AppPaths.dataDirectory).values.personalization.appIcon
            check(AppPersonalization.preferences.appIcon == .outline && d < 4 && Self.prefsIconDifference(NSApp.applicationIconImage, launchedIcon) > 12 && saved == .outline,
                  "\(tag): a real click on Outline makes it the Dock's icon (difference \(Int(d))) and saves it (\(saved.rawValue))")
        }
        prefsCaptureSettings("parityprefs-appearance.png")
        run { [self] in
            let all = PersonalizationPreferences.AppIcon.allCases, images = all.map { AppPersonalization.image(for: $0) }
            var alike: [String] = []
            for i in all.indices { for j in all.indices where j > i && Self.prefsIconDifference(images[i], images[j]) < 8 { alike.append("\(all[i].title)/\(all[j].title)") } }
            check(alike.isEmpty, "\(tag): the six icons are six pictures\(alike.isEmpty ? "" : " (alike: \(alike))")")
        }
        for icon in [PersonalizationPreferences.AppIcon.sunset, .ocean, .graphite] {
            prefsClickSetting(.appearance, anchor: "prefs.icon." + icon.rawValue, tag: tag)
            run { [self] in
                let d = Self.prefsIconDifference(NSApp.applicationIconImage, AppPersonalization.image(for: icon))
                let saved = AppSettings(directory: AppPaths.dataDirectory).values.personalization.appIcon
                check(AppPersonalization.preferences.appIcon == icon && d < 4 && saved == icon,
                      "\(tag): a real click on \(icon.title) makes it the Dock's icon (difference \(Int(d))) and saves it (\(saved.rawValue))")
            }
        }
        // The Finder icon, on this test bundle only for the check (scripted runs never write it otherwise).
        run { AppPersonalization.writesBundleIcon = true }
        prefsClickSetting(.appearance, anchor: "prefs.icon.midnight", tag: tag)
        wait(1.0)
        run { [self] in
            let path = Bundle.main.bundlePath
            let d = Self.prefsIconDifference(NSApp.applicationIconImage, AppPersonalization.image(for: .midnight))
            let finder = Self.prefsIconDifference(NSWorkspace.shared.icon(forFile: path), AppPersonalization.image(for: .midnight))
            check(AppPersonalization.preferences.appIcon == .midnight && d < 4 && AppPersonalization.bundleHasCustomIcon
                  && !AppPersonalization.bundleIconFailed && finder < 12,
                  "\(tag): a real click on Midnight makes it the Dock's icon (difference \(Int(d))) and the Finder's (custom icon \(AppPersonalization.bundleHasCustomIcon), difference \(Int(finder)))")
            let deep = Self.prefsCodesign(["--verify", "--deep", path]), strict = Self.prefsStaticCheck(path)
            check(deep == 0 && strict == errSecSuccess,
                  "\(tag): with the Finder icon the signature is still valid (codesign --verify --deep \(deep), SecStaticCodeCheckValidity strict \(strict))")
            note("\(tag): codesign --verify --deep --strict with the Finder icon: \(Self.prefsCodesign(["--verify", "--deep", "--strict", path])) (its Finder info is outside the seal)")
        }
        prefsClickSetting(.appearance, anchor: "prefs.icon.holographic", tag: tag)
        wait(1.0)
        run { [self] in
            let strict = Self.prefsCodesign(["--verify", "--deep", "--strict", Bundle.main.bundlePath])
            check(!AppPersonalization.bundleHasCustomIcon && strict == 0,
                  "\(tag): Holographic takes the Finder icon off; codesign --verify --deep --strict passes again (\(strict))")
            AppPersonalization.writesBundleIcon = false
        }
        run { [self] in
            check(AppPersonalization.preferences.appIcon == .holographic && Self.prefsIconDifference(NSApp.applicationIconImage, launchedIcon) < 4,
                  "\(tag): a real click on Holographic gives the Dock the app's own icon back")
            settings()?.orderOut(nil)
            AppPersonalization.testBeep = nil
            server?.stop()
        }
    }

    /// `prefs-<pass>-write` and `-read`.
    func prefsRelaunchScenario() {
        let parts = script.split(separator: "-").map(String.init)
        guard parts.count == 3, ["restore", "fresh", "crash"].contains(parts[1]) else { check(false, "prefs: unknown script \(script)"); return finish() }
        let pass = parts[1]
        let file = AppPaths.dataDirectory.appendingPathComponent("prefs-expected.json")
        let icons: [String: PersonalizationPreferences.AppIcon] = ["restore": .sunset, "fresh": .graphite, "crash": .ocean]
        let icon = icons[pass] ?? .outline
        let choice: StartupWindows = pass == "restore" ? .lastSession : .newWindow
        if parts[2] == "write" {
            var server: LocalPageServer?, base = ""
            step { [self] done in
                server = LocalPageServer(pages: ["/a.html": "<!doctype html><title>Home</title><p>Home</p>", "/b.html": "<!doctype html><title>Work</title><p>Work</p>"])
                server?.start { port in base = port.map { "http://127.0.0.1:\($0)" } ?? ""; done() }
            }
            run { [self] in
                guard let app, !base.isEmpty, let a = try? c.store.openTab(url: base + "/a.html", inSpace: c.currentSpaceID, activate: false, title: "Home"),
                      let work = try? c.store.createSpace(name: "Work", icon: nil, theme: c.store.selectedSpace.theme,
                                                          profileID: c.store.profile(ofSpace: c.currentSpaceID).id, after: c.currentSpaceID),
                      let b = try? c.store.openTab(url: base + "/b.html", inSpace: work.id, activate: false, title: "Work") else {
                    return check(false, "prefs-\(pass)-write: two Spaces with a tab each")
                }
                c.reloadAll(animated: false)
                c.show(a.id, focus: false)
                let w2 = app.openNewWindow(from: c, spaceID: work.id, tab: .id(b.id), commandBar: false)
                w2?.show(b.id, focus: false)
                AppPersonalization.update { $0.appIcon = icon }
                app.settings.values.startupWindows = choice
                check(app.controllers.count == 2 && app.settings.values.startupWindows == choice,
                      "prefs-\(pass)-write: two windows; When Airc starts: “\(choice.title)”; icon \(icon.title)")
            }
            wait(1.5)
            run { [self] in
                guard let app else { return }
                app.saveSession()
                let expected = PrefsExpected(icon: icon.rawValue, windows: app.controllers.map { .init(spaceID: $0.currentSpaceID, tabID: $0.shownTabID) },
                                             tabs: app.controllers.compactMap(\.shownTabID))
                try? JSONEncoder().encode(expected).write(to: file)
                check(app.store.localValue(AppDelegate.exitMarkKey) == PreviousExit.running.rawValue,
                      "prefs-\(pass)-write: while Airc runs the exit mark says running")
                server?.stop()
            }
            if pass == "crash" {
                run { [self] in
                    try? app?.store.flush()
                    note("prefs-crash-write: ending without a quit (_exit, as a crash would: no willTerminate, no crash report)")
                    finishAsIfCrashed()
                }
            }
            return
        }
        // Read.
        wait(1.0)
        run { [self] in
            guard let app, let data = try? Data(contentsOf: file), let expected = try? JSONDecoder().decode(PrefsExpected.self, from: data) else {
                return check(false, "prefs-\(pass)-read: the write run left its expectations")
            }
            let want = PersonalizationPreferences.AppIcon(rawValue: expected.icon) ?? .holographic
            let d = Self.prefsIconDifference(NSApp.applicationIconImage, AppPersonalization.image(for: want))
            check(AppPersonalization.preferences.appIcon == want && d < 4,
                  "prefs-\(pass)-read: after the relaunch \(want.title) is still the Dock's icon (difference \(Int(d)))")
            let previous = app.windowSession.previousExit, restored = app.windowSession.launchRestored
            let wantPrevious: PreviousExit = pass == "crash" ? .running : .clean
            check(previous == wantPrevious && app.settings.values.startupWindows == choice,
                  "prefs-\(pass)-read: the last run ended \(previous?.rawValue ?? "?") (expected \(wantPrevious.rawValue)); the choice is “\(app.settings.values.startupWindows.title)”")
            if pass == "fresh" {
                let tabsKept = expected.tabs.allSatisfy { app.store.tab($0) != nil }
                check(restored == false && app.controllers.count == 1 && c.shownTabID == nil && c.currentSpaceID == expected.windows.first?.spaceID && tabsKept,
                      "prefs-fresh-read: “Open a new window”: one window (\(app.controllers.count)) on the Space used last, no tab open (\(c.shownTabID ?? "none")), every tab still in the sidebar (\(tabsKept))")
            } else {
                check(restored == true && app.controllers.count == expected.windows.count,
                      "prefs-\(pass)-read: \(pass == "crash" ? "after a crash, even with “Open a new window”, " : "")\(expected.windows.count) windows come back (\(app.controllers.count))")
                for (i, (w, e)) in zip(app.controllers, expected.windows).enumerated() {
                    check(w.currentSpaceID == e.spaceID && w.shownTabID == e.tabID,
                          "prefs-\(pass)-read: window \(i + 1) is back on its Space (\(w.store.space(w.currentSpaceID)?.name ?? "?")) with its tab")
                }
            }
            check(app.store.localValue(AppDelegate.exitMarkKey) == PreviousExit.running.rawValue, "prefs-\(pass)-read: the mark says running again")
            // Leave the data as a first launch would find it.
            AppPersonalization.update { $0.appIcon = .holographic }
            app.settings.values.startupWindows = .lastSession
        }
        capture("prefs-\(pass)-read")
    }

    /// The app key and in front for real input; FAIL-ENV when it can't be.
    private func prefsFront(_ w: NSWindow, tag: String, _ done: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        waitUntil({ NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace }, timeout: 3) {
            let ok = NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace
            if !ok { self.note("FAIL-ENV \(tag): window not key/active (active=\(NSApp.isActive), key=\(w.isKeyWindow), space=\(w.isOnActiveSpace))") }
            done(ok)
        }
    }

    /// A real drag (driver `--drag`) from `from`'s Today row to just below `below`'s.
    private func prefsRealDrag(from: @escaping () -> String?, below: @escaping () -> String?, tag: String) {
        step { [self] done in
            let w = c.window
            guard let page = c.pageView(for: c.currentSpaceID), let a = from(), let b = below() else { check(false, "\(tag): rows to drag"); return done() }
            page.layoutSubtreeIfNeeded()
            guard let ra = page.rows[a], let rb = page.rows[b] else { check(false, "\(tag): rows to drag"); return done() }
            prefsFront(w, tag: tag) { ok in
                guard ok else { return done() }
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let s = w.convertPoint(toScreen: ra.convert(NSPoint(x: min(90, ra.bounds.width / 2), y: ra.bounds.midY), to: nil))
                let e = w.convertPoint(toScreen: rb.convert(NSPoint(x: min(90, rb.bounds.width / 2), y: rb.bounds.midY), to: nil))
                let endY = e.y - rb.bounds.height * 0.4
                let f = { (v: CGFloat) in String(format: "%.1f", v) }
                UIDriverClient.run(["--drag", f(s.x), f(top - s.y), f(e.x), f(top - endY)]) { ok, out in
                    if !ok { self.note("FAIL-ENV \(tag): the driver refused the drag (\(out))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: done)
                }
            }
        }
    }

    /// Settings on `page`, on screen and tall; then a real click on the test anchor `anchor` (a toggle row, an icon
    /// tile), scrolled into view first.
    private func prefsClickSetting(_ page: SettingsPage, anchor: String, tag: String) {
        run { [self] in
            app?.showSettings(page: page)
            if let w = app?.settingsWindow?.window, let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
                w.setFrame(NSRect(x: screen.minX + 60, y: screen.minY + 20, width: w.frame.width, height: screen.height - 40), display: true)
            }
        }
        wait(0.8)
        step { [self] done in
            guard let w = app?.settingsWindow?.window, let v = w.contentView else { check(false, "\(tag): the Settings window"); return done() }
            guard let a = TestAnchors.view(anchor, in: v) else { check(false, "\(tag): \(anchor) in Settings"); return done() }
            a.scrollToVisible(a.bounds.insetBy(dx: 0, dy: -60))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                v.layoutSubtreeIfNeeded()
                let r = a.convert(a.bounds, to: nil)
                let p = NSPoint(x: r.minX + min(60, r.width / 2), y: r.midY)
                self.prefsFront(w, tag: tag) { ok in
                    guard ok else { return done() }
                    let g = w.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
                    UIDriverClient.run(["--click", String(Double(g.x)), String(Double(top - g.y))]) { ok, out in
                        if !ok { self.note("FAIL-ENV \(tag): the driver refused the click on \(anchor) (\(out))") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
                    }
                }
            }
        }
    }

    private func prefsCaptureSettings(_ name: String) {
        wait(0.3)
        run { [self] in
            guard let w = app?.settingsWindow?.window, let v = w.contentView else { return }
            v.layoutSubtreeIfNeeded()
            guard let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return note("parityprefs: could not render \(name)") }
            try? png.write(to: dir.appendingPathComponent(name))
            note("wrote \(name)")
        }
    }

    /// Mean channel difference (0–255) of two icons drawn at 128 px (at 32 px the bundle's .icns draws its small-size
    /// variant, while `applicationIconImage` hands back the picture AppKit made of it).
    static func prefsIconDifference(_ a: NSImage?, _ b: NSImage?) -> Double {
        let n = 128
        func pixels(_ i: NSImage?) -> [UInt8] {
            guard let i, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32)
            else { return [] }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            i.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
            NSGraphicsContext.restoreGraphicsState()
            return Array(UnsafeBufferPointer(start: rep.bitmapData, count: n * n * 4))
        }
        let x = pixels(a), y = pixels(b)
        guard x.count == y.count, !x.isEmpty else { return 255 }
        return Double(zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(x.count)
    }

    /// /usr/bin/codesign's exit status.
    static func prefsCodesign(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// SecStaticCodeCheckValidity with strict validation and every architecture (what an updater checks).
    static func prefsStaticCheck(_ path: String) -> OSStatus {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return -1 }
        // kSecCSStrictValidate | kSecCSCheckAllArchitectures
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 1 << 4 | 1 << 0), nil)
    }

    private static func prefsScrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(prefsScrollViews)
    }
}
#endif

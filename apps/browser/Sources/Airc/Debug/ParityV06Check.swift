// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import Carbon.HIToolbox

/// `--script v06` (both engines): V06, Little Arc's global actions end to end, through the app's real pieces
/// (Browser/LittleArcGlobalActions.swift, docs/user/little-arc.md). parityp06b checks the logic with stand-ins; this one
/// uses the real Carbon registrar and the real menus:
///   - off (the default): no hot key and no handler; a hot-key event for Airc's ID finds nobody (eventNotHandledErr);
///   - on: Settings' "Open Little Airc when I press ⌥⌘N" registers ⌥⌘N with the window server (exclusive, so it's
///     never taken from an app that holds it: that's reported, not overridden);
///   - a press: with `AIRC_REAL_KEYS=1` (dedicated session, under the UI lock), a real ⌥⌘N from the build Mac's stable
///     UI driver through the HID event stream (Debug/UIDriverClient.swift), and the link in the quick lookup field is
///     typed with real key presses and Return; else a real ⌥⌘N posted by this process when it may post events;
///     otherwise (a test app has no event-posting grant) the window server's hot-key event, made in-app and sent to
///     the app's event target, where the real Carbon handler takes it. The log says which. The app in front at the
///     press is logged (another app's in open -g runs, Airc's in a dedicated session);
///   - the first press comes with another app in front (Airc hands the front to the Finder first);
///   - the press opens an empty Little Airc window with its quick lookup field ("Search or enter URL…") ready; typing a
///     link there and Return opens it in that window;
///   - File › New Little Airc Window is ⌥⌘N, as in Arc's MainMenu.nib (key "n", ⌥⌘); with real keys, a driver ⌥⌘N posted
///     to Airc's PID, with Airc in front and the global hot key off, opens one through the menu (the hot key, when on,
///     takes ⌥⌘N first; through the HID stream another app's global ⌥⌘N would);
///   - Window › Show Little Airc Windows brings back hidden and minimized ones; the Command Bar's (⌘T) does too;
///   - Window › Close Little Airc Windows and the Command Bar's close them all, each page to its Space's Archive;
///   - off again: the hot key and handler are gone, and the same event finds nobody.
/// The hot key is held only while the feature is on in this run (a few seconds).
extension SnapshotRunner {
    /// The window server's hot-key event for Airc's Little Arc hot key, made here and sent to the app's event target (where
    /// CarbonHotKeyRegistrar's handler listens). Its status: noErr when a handler took it.
    static func sendCarbonHotKeyEvent() -> OSStatus {
        var event: EventRef?
        var status = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(),
                                 EventAttributes(kEventAttributeNone), &event)
        guard status == noErr, let event else { return status }
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: CarbonHotKeyRegistrar.signature, id: 1)
        status = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   MemoryLayout<EventHotKeyID>.size, &id)
        guard status == noErr else { return status }
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    /// A real key press with `flags` through the HID event stream (needs the event-posting grant). False: not allowed.
    static func postRealKey(_ keyCode: CGKeyCode, _ flags: CGEventFlags) -> Bool {
        guard CGPreflightPostEventAccess(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// A menu item by title, anywhere in the menu bar.
    static func menuItem(_ title: String, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == title { return item }
            if let hit = menuItem(title, in: item.submenu) { return hit }
        }
        return nil
    }

    /// Chooses a menu item as a click in its menu does.
    static func choose(_ item: NSMenuItem?) -> Bool {
        guard let item, let menu = item.menu, let i = menu.items.firstIndex(of: item) else { return false }
        menu.update()
        guard item.isEnabled else { return false }
        menu.performActionForItem(at: i)
        return true
    }

    func parityV06Scenario() {
        let actions = LittleArcGlobalActions.shared
        var server: LocalPageServer?
        var base = ""
        var realKeys = false
        let driverKeys = UIDriverClient.available
        var opened: LittleArcController?
        func settings(_ change: @escaping (inout LittleArcGlobalSettings) -> Void) {
            run { [self] in
                var v = app?.settings.values.littleArcGlobal ?? LittleArcGlobalSettings()
                change(&v)
                app?.settings.values.littleArcGlobal = v
            }
            wait(0.3)
        }
        func frontApp() -> String {
            guard let f = NSWorkspace.shared.frontmostApplication else { return "none" }
            return f.processIdentifier == getpid() ? "Airc" : (f.bundleIdentifier ?? "another app")
        }
        /// The shortcut pressed, from whatever app is in front: the Little Arc it opened.
        func press(_ label: String, fromAnotherApp: Bool = false, _ then: @escaping (LittleArcController?) -> Void) {
            if fromAnotherApp {
                // Another app in front, as a person in Mail or Finder presses it: Airc gives up the front (nothing of
                // ours floats or comes forward) and hands it to the Finder.
                step { [self] done in
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
                       let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                        // The Finder takes the front (it's always running; a dedicated session has hidden its windows).
                        NSApp.yieldActivation(to: finder)
                        finder.activate()
                    }
                    waitUntil({ NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() }, timeout: 3) {
                        let front = frontApp()
                        self.check(front != "Airc", "v06 \(label): another app is in front for the press (\(front))")
                        done()
                    }
                }
            }
            step { [self] done in
                let before = app?.littleArcs.count ?? 0
                let presses = actions.presses
                let front = frontApp()
                func observe(_ how: String) {
                    note("v06 \(label): pressed with \(front) in front, as \(how)")
                    waitUntil({ (self.app?.littleArcs.count ?? 0) > before && actions.presses > presses
                                && self.app?.littleArcs.last?.addressField.currentEditor() != nil }, timeout: 5) {
                        opened = (self.app?.littleArcs.count ?? 0) > before ? self.app?.littleArcs.last : nil
                        then(opened)
                        done()
                    }
                }
                if driverKeys {
                    UIDriverClient.run(["--key", "cmd+opt+n"]) { ok, out in
                        observe(ok ? "a real ⌥⌘N from the stable UI driver (HID event stream, no --pid)"
                                   : "a stable UI driver ⌥⌘N that FAILED (\(out))")
                    }
                } else if realKeys, Self.postRealKey(CGKeyCode(kVK_ANSI_N), [.maskCommand, .maskAlternate]) {
                    observe("a real ⌥⌘N through the HID event stream")
                } else {
                    observe("the hot-key event sent in-app (status \(Self.sendCarbonHotKeyEvent())); no key posting")
                }
            }
        }
        func waitForLittleArcs(_ n: Int, loaded: Bool = false, _ then: @escaping () -> Void) {
            step { [self] done in
                waitUntil({
                    let ls = self.app?.littleArcs.filter { !$0.isMiniPlayer } ?? []
                    return ls.count == n && (!loaded || ls.allSatisfy { $0.page?.url != nil && $0.page?.isLoading == false })
                }, timeout: 8) { then(); done() }
            }
        }

        step { [self] done in
            server = LocalPageServer(pages: ["/q": "<!doctype html><title>quick</title><p>Quick lookup</p>",
                                            "/p": "<!doctype html><title>little page</title><p>x</p>"])
            server?.start { port in
                base = port.map { "127.0.0.1:\($0)" } ?? ""
                if base.isEmpty { self.check(false, "v06: the loopback page server starts") }
                done()
            }
        }
        closeLittleArcs()
        run { [self] in
            app?.settingsWindow?.window.orderOut(nil)
            // The app's own pieces, whatever an earlier check left: the real Carbon registrar, no selection lookup.
            actions.registrar = CarbonHotKeyRegistrar()
            actions.makeProbe = { CarbonHotKeyRegistrar() }
            realKeys = CGPreflightPostEventAccess()
            if driverKeys, !LittleArcController.actsAsOwner {
                note("FAIL-ENV v06: real keys need AIRC_LA_AS_OWNER=1 too: a scripted run never activates Airc, so typed keys stay with the Finder")
            }
            note(driverKeys ? "v06: AIRC_REAL_KEYS=1: presses, typing and the menu shortcut are real keys from the stable UI driver "
                 + "(keyboard layout \(UIDriverClient.layoutName))"
                 : "v06: event posting \(realKeys ? "granted: presses are real keys" : "not granted to the test app: presses are in-app hot-key events")")
        }
        settings { $0 = LittleArcGlobalSettings() }

        // Off, the default: nothing installed, and the hot-key event finds nobody.
        step { [self] done in
            let s = app?.settings.values.littleArcGlobal ?? LittleArcGlobalSettings()
            let before = app?.littleArcs.count ?? 0
            let status = Self.sendCarbonHotKeyEvent()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let none = (self.app?.littleArcs.count ?? 0) == before
                self.check(!s.enabled && !actions.isInstalled && status == OSStatus(eventNotHandledErr) && none,
                           "v06: off by default; no hot key or handler, so Airc's hot-key event finds nobody and opens nothing "
                           + "(enabled \(s.enabled), installed \(actions.isInstalled), status \(status), opened \(!none))")
                done()
            }
        }

        // On: Arc's row, ⌥⌘N registered with the window server.
        settings { $0.enabled = true }
        run { [self] in
            let title = LittleArcGlobalSettingsSection.hotKeyTitle(actions.settings.shortcut)
            if actions.problem == .otherApp {
                note("FAIL-ENV v06: another app on this Mac holds ⌥⌘N, so Airc doesn't take it (\(actions.problem?.message ?? "-"))")
            }
            check(title == "Open Little Airc when I press ⌥⌘N" && actions.isInstalled && actions.problem == nil && actions.lastStatus == noErr,
                  "v06: \"\(title)\" on registers ⌥⌘N with the window server (installed \(actions.isInstalled), status \(actions.lastStatus), "
                  + "problem \(actions.problem?.message ?? "none"))")
        }

        // A press: an empty Little Airc with its quick lookup field ready.
        press("first press", fromAnotherApp: true) { [self] l in
            let editor = l?.addressField.currentEditor()
            let ready = l.map { $0.window.firstResponder === editor && editor != nil } ?? false
            let empty = l.map { $0.page?.url == nil || URLRules.isNewTab($0.page?.url?.absoluteString ?? "") } ?? false
            check(l != nil && empty && ready && l?.addressField.placeholderString == "Search or enter URL…",
                  "v06: the shortcut opens an empty Little Airc window with its quick lookup field ready (opened \(l != nil), empty \(empty), "
                  + "field first responder \(ready), placeholder \"\(l?.addressField.placeholderString ?? "-")\", visible \(l?.window.isVisible == true))")
        }
        step { [self] done in
            guard let l = opened, let editor = l.addressField.currentEditor() as? NSTextView, !base.isEmpty else {
                check(false, "v06: typing in the quick lookup field: no field editor")
                return done()
            }
            func typed() {
                waitUntil({ l.page?.title == "quick" && l.page?.isLoading == false }, timeout: 8) {
                    self.check(l.page?.title == "quick" && l.page?.url?.path == "/q" && self.app?.littleArcs.count == 1,
                               "v06: a link typed in the quick lookup field and Return opens in that Little Airc window "
                               + "(\(l.page?.url?.path ?? "-"), \"\(l.page?.title ?? "-")\", windows \(self.app?.littleArcs.count ?? 0))")
                    done()
                }
            }
            if driverKeys {
                // Real keys go to the key window of the app in front: that must be this Little Airc, its field editing.
                let ready = NSApp.isActive && l.window.isKeyWindow && l.window.firstResponder === editor
                guard ready, let keys = UIDriverClient.keys(typing: base + "/q") else {
                    check(false, "v06: real typing needs Airc in front with the Little Airc field editing (active \(NSApp.isActive), "
                          + "key \(l.window.isKeyWindow), front \(frontApp()))")
                    return done()
                }
                UIDriverClient.press(keys + ["return"]) { ok, out in
                    self.note("v06: typed \(base)/q and Return as \(keys.count + 1) real key presses from the stable UI driver"
                              + (ok ? "" : " — FAILED: \(out)"))
                    typed()
                }
            } else {
                editor.insertText(base + "/q", replacementRange: editor.selectedRange())
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                typed()
            }
        }
        press("second press") { [self] l in
            check(l != nil && app?.littleArcs.count == 2, "v06: a second press opens another Little Airc window (\(app?.littleArcs.count ?? 0))")
        }

        // File › New Little Airc Window, Arc's ⌥⌘N.
        if driverKeys {
            // The global hot key takes ⌥⌘N before any menu does, so the menu's own shortcut is pressed with it off, and
            // posted to this process (the driver's --pid): through the HID stream another app's global ⌥⌘N would take
            // it first (on the build Mac, Arc's own Little Arc hot key does).
            settings { $0.enabled = false }
            step { [self] done in
                let item = Self.menuItem("New Little Airc Window")
                let key = item.map { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .option] } ?? false
                let presses = actions.presses
                let front = frontApp()
                guard NSApp.isActive, NSApp.keyWindow != nil, !actions.isInstalled else {
                    check(false, "v06: a real ⌥⌘N for the menu needs Airc in front with a key window and the hot key off "
                          + "(front \(front), key window \(NSApp.keyWindow != nil), hot key installed \(actions.isInstalled))")
                    return done()
                }
                // What AppKit hands the app for the press (a layout's ⌥N can be a dead key), for the log.
                var seen: [String] = []
                let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
                    let chars = e.type == .keyDown ? (e.charactersIgnoringModifiers ?? "-") : "-"
                    seen.append("\(e.type == .keyDown ? "down" : "flags") code \(e.keyCode) ignoring \"\(chars)\" "
                                + "flags \(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue) key window \(e.window.map { "\(type(of: $0))" } ?? "none")")
                    return e
                }
                UIDriverClient.run(["--key", "cmd+opt+n", "--pid", String(getpid())]) { ok, out in
                    self.waitUntil({ (self.app?.littleArcs.count ?? 0) == 3 }, timeout: 5) {
                        if let monitor { NSEvent.removeMonitor(monitor) }
                        self.note("v06: the menu press as AppKit delivered it: " + (seen.isEmpty ? "no key events" : seen.joined(separator: "; ")))
                        self.check(item != nil && key && ok && self.app?.littleArcs.count == 3 && actions.presses == presses,
                                   "v06: File › New Little Airc Window is ⌥⌘N, as in Arc's menu (key \"\(item?.keyEquivalent ?? "-")\", "
                                   + "modifiers \(item?.keyEquivalentModifierMask.rawValue ?? 0)); a real ⌥⌘N from the stable UI driver "
                                   + "(posted to Airc's PID) with \(front) in front opens one through the menu, not the hot key (driver \(ok ? "ok" : out), "
                                   + "windows \(self.app?.littleArcs.count ?? 0), hot-key presses \(actions.presses - presses))")
                        done()
                    }
                }
            }
        } else {
            run { [self] in
                let item = Self.menuItem("New Little Airc Window")
                let key = item.map { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .option] } ?? false
                let chosen = Self.choose(item)
                check(item != nil && key && chosen, "v06: File › New Little Airc Window is ⌥⌘N, as in Arc's menu (key \"\(item?.keyEquivalent ?? "-")\", "
                      + "modifiers \(item?.keyEquivalentModifierMask.rawValue ?? 0)), and choosing it opens one")
            }
        }
        waitForLittleArcs(3) { [self] in
            check(app?.littleArcs.count == 3, "v06: three Little Airc windows now (\(app?.littleArcs.count ?? 0))")
        }

        // Window › Show Little Airc Windows: a hidden one and a minimized one come back.
        var minimized = false
        step { [self] done in
            let ls = app?.littleArcs ?? []
            guard ls.count == 3 else { return done() }
            ls[0].window.orderOut(nil)
            ls[1].window.miniaturize(nil)
            waitUntil({ ls[1].window.isMiniaturized }, timeout: 3) {
                minimized = ls[1].window.isMiniaturized
                if !minimized { self.note("v06: the window didn't minimize in 3 s; Show is checked with a hidden one only") }
                done()
            }
        }
        step { [self] done in
            let item = NSApp.windowsMenu?.items.first { $0.title == "Show Little Airc Windows" }
            let hidden = app?.littleArcs.filter { !$0.window.isVisible }.count ?? 0
            let chosen = Self.choose(item)
            waitUntil({ self.app?.littleArcs.allSatisfy { $0.window.isVisible && !$0.window.isMiniaturized } == true }, timeout: 4) {
                let all = self.app?.littleArcs.allSatisfy { $0.window.isVisible && !$0.window.isMiniaturized } == true
                self.check(chosen && hidden == (minimized ? 2 : 1) && all,
                           "v06: Window › Show Little Airc Windows brings back the hidden\(minimized ? " and the minimized" : "") one (\(hidden) not visible before, all back \(all))")
                done()
            }
        }
        run { [self] in
            app?.littleArcs.first?.window.orderOut(nil)
            let bar = c.commandActions().first { $0.title == "Show Little Airc Windows" }
            bar?.run()
        }
        wait(0.5)
        run { [self] in
            let all = app?.littleArcs.allSatisfy { $0.window.isVisible } == true
            check(all, "v06: the Command Bar's (⌘T) Show Little Airc Windows brings back a hidden one (all visible \(all))")
        }

        // Window › Close Little Airc Windows: each page to the Archive, the windows closed.
        step { [self] done in
            let before = Set(c.store.state.archive.keys)
            let pages = app?.littleArcs.compactMap { $0.page?.url?.absoluteString }.filter { !URLRules.isNewTab($0) } ?? []
            let chosen = Self.choose(NSApp.windowsMenu?.items.first { $0.title == "Close Little Airc Windows" })
            waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 6) {
                let added = self.c.store.state.archive.filter { !before.contains($0.key) }.values
                let archived = Set(added.map(\.url)).isSuperset(of: pages) && added.allSatisfy { $0.origin == ArchiveEntry.littleArcOrigin }
                self.check(chosen && self.app?.littleArcs.isEmpty == true && archived && !pages.isEmpty,
                           "v06: Window › Close Little Airc Windows closes them all, the page to its Space's Archive as Little Airc's "
                           + "(left \(self.app?.littleArcs.count ?? -1), archived \(added.count), pages \(pages.count))")
                done()
            }
        }
        step { [self] done in
            guard !base.isEmpty else { return done() }
            for i in 0..<2 { _ = app?.openLittleArc(url: URL(string: "http://\(base)/p?n=\(i)")) }
            done()
        }
        waitForLittleArcs(2, loaded: true) {}
        step { [self] done in
            let before = Set(c.store.state.archive.keys)
            let bar = c.commandActions().first { $0.title == "Close Little Airc Windows" }
            bar?.run()
            waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 6) {
                let added = self.c.store.state.archive.filter { !before.contains($0.key) }.count
                let gone = self.c.commandActions().contains { $0.title.hasSuffix("Little Airc Windows") }
                self.check(bar != nil && self.app?.littleArcs.isEmpty == true && added == 2 && !gone,
                           "v06: the Command Bar's (⌘T) Close Little Airc Windows closes both and archives them (\(added)); with none left, "
                           + "the Command Bar offers neither (\(!gone))")
                done()
            }
        }

        // Off again: the hot key and its handler are gone.
        settings { $0.enabled = false }
        step { [self] done in
            let status = Self.sendCarbonHotKeyEvent()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.check(!actions.isInstalled && status == OSStatus(eventNotHandledErr) && self.app?.littleArcs.isEmpty == true,
                           "v06: turned off, the hot key and handler are gone; the same event finds nobody (status \(status))")
                server?.stop()
                done()
            }
        }
    }
}
#endif

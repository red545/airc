// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import Carbon.HIToolbox

/// `--script parityp06b` (both engines): Little Arc from any app (P06b; LittleArcGlobalActions, docs/user/little-arc.md).
/// The global shortcut and the selection go through injected stand-ins, so the run never holds a key the owner types and
/// never asks macOS for Accessibility:
///   - off by default, with nothing installed (the real Carbon registrar at launch); on: the shortcut is registered,
///     ⌥⌘N by default; off again: nothing installed;
///   - the shortcut opens an empty Little Arc; over a full-screen app in front, the full-screen panel;
///   - "Look up the selected text": with access, the selection is searched in the profile's engine; without it, Little
///     Arc opens empty, says how to allow it, and no prompt is asked for; off, the selection isn't read at all; Settings'
///     "Allow…" asks nothing in a scripted run;
///   - conflicts: macOS's own shortcuts, another app's (the exclusive registration fails), Airc's commands; a rebind to a
///     free key takes effect; a key macOS uses isn't registered;
///   - the real Carbon plumbing: an unused key (⌃⌥⇧⌘F19) registers and lets go;
///   - Show Little Airc Windows brings hidden ones back; Close Little Airc Windows sends each page to the Archive (marked
///     as Little Arc's) and closes them; the Dock menu offers both while there are Little Arc windows;
///   - "Archive Little Aircs after": an hour, and Never (no timer).
extension SnapshotRunner {
    func parityP06bScenario() {
        let actions = LittleArcGlobalActions.shared
        let registrar = P06bRegistrar()
        let probe = P06bRegistrar()
        let selection = P06bSelection()
        var fullScreen: pid_t?
        var server: LocalPageServer?
        var base = ""
        var opened: LittleArcController?
        func settings(_ change: @escaping (inout LittleArcGlobalSettings) -> Void) {
            run { [self] in
                var v = app?.settings.values.littleArcGlobal ?? LittleArcGlobalSettings()
                change(&v)
                app?.settings.values.littleArcGlobal = v
            }
            wait(0.2)
        }
        /// The shortcut pressed: the Little Arc it opened.
        func press(_ then: @escaping (LittleArcController?) -> Void) {
            step { [self] done in
                let before = app?.littleArcs.count ?? 0
                registrar.press()
                waitUntil({ (self.app?.littleArcs.count ?? 0) > before }, timeout: 4) {
                    opened = self.app?.littleArcs.last
                    then((self.app?.littleArcs.count ?? 0) > before ? opened : nil)
                    done()
                }
            }
        }
        func closeOpened() {
            step { [self] done in
                opened?.closeWindow()
                waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 4) { done() }
            }
        }

        // Off by default: nothing installed (the app's own Carbon registrar, as launched).
        run { [self] in
            let s = app?.settings.values.littleArcGlobal ?? LittleArcGlobalSettings()
            check(!s.enabled && !actions.isInstalled && s.shortcut == .littleArcDefault && s.archiveAfter == .sixHours,
                  "P06b: off by default, and then no global shortcut or handler is installed (enabled \(s.enabled), installed \(actions.isInstalled), "
                  + "default \(s.shortcut.display), archive \(s.archiveAfter.title))")
            LittleArcController.startsHidden = true
            actions.registrar = registrar
            actions.makeProbe = { probe }
            actions.selection = selection
            actions.systemShortcuts = { Array(LittleArcGlobalActions.defaultSymbolicHotKeys.values) }
            actions.fullScreenSource = { let f = fullScreen; fullScreen = nil; return f }
        }
        step { done in
            server = LocalPageServer(pages: ["/p": "<!doctype html><title>Little page</title><p>x</p>"])
            server?.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                done()
            }
        }

        // On: ⌥⌘N registered; the shortcut opens an empty Little Arc with its address field.
        settings { $0.enabled = true }
        run { [self] in
            check(registrar.registered == .littleArcDefault && actions.isInstalled && actions.problem == nil,
                  "P06b: turned on, ⌥⌘N is registered as a global shortcut (\(registrar.registered?.display ?? "none"), problem \(String(describing: actions.problem)))")
        }
        press { [self] l in
            let empty = l.map { $0.page?.url == nil || URLRules.isNewTab($0.page?.url?.absoluteString ?? "") } ?? false
            check(l != nil && empty && l?.overFullScreen == false, "P06b: the shortcut opens an empty Little Airc for a new search (opened \(l != nil), empty \(empty))")
        }
        closeOpened()

        // Over a full-screen app in front: the full-screen panel.
        run { fullScreen = getpid() }
        press { [self] l in
            check(l?.openedOverFullScreen == true && l?.window is NSPanel,
                  "P06b: with a full-screen app in front, the shortcut opens the panel that shows over it (\(l.map { String(describing: type(of: $0.window)) } ?? "none"))")
        }
        closeOpened()

        // The selection: not allowed yet; allowed; turned off.
        settings { $0.searchesSelection = true }
        run { selection.trusted = false; selection.text = "pastel de nata" }
        press { [self] l in
            check(l != nil && actions.lastNeededAccess && selection.reads == 0 && selection.prompts == 0 && l?.toast.isHidden == false,
                  "P06b: without Accessibility, the shortcut opens Little Airc empty and says how to allow it; the selection isn't read and nothing "
                  + "asks macOS (reads \(selection.reads), prompts \(selection.prompts), note shown \(l?.toast.isHidden == false))")
        }
        closeOpened()
        run { [self] in
            check(!actions.requestAccess() && selection.prompts == 0, "P06b: Settings' Allow… asks macOS for nothing in a scripted run")
            selection.trusted = true
        }
        press { [self] l in
            let want = c.store.profile(ofSpace: c.currentSpaceID).searchEngine.searchURL(for: "pastel de nata").absoluteString
            check(selection.reads == 1 && actions.lastLookup == "pastel de nata" && l?.page?.url?.absoluteString == want,
                  "P06b: with access, the shortcut searches the selected text in the profile's engine (\(l?.page?.url?.absoluteString ?? "-"))")
        }
        closeOpened()
        settings { $0.searchesSelection = false }
        press { [self] l in
            check(l != nil && selection.reads == 1, "P06b: with the lookup off, the selection isn't read (reads \(selection.reads))")
        }
        closeOpened()

        // Conflicts and rebinding.
        run { [self] in
            let space = GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags.command.rawValue, key: " ")
            let newTab = GlobalShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: NSEvent.ModifierFlags.command.rawValue, key: "t")
            let held = GlobalShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, key: "k")
            let free = GlobalShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, key: "l")
            probe.refuse = [held.keyCode]
            let system = actions.conflict(for: space)
            let airc = actions.conflict(for: newTab)
            let other = actions.conflict(for: held)
            let none = actions.conflict(for: free)
            let aircOK: Bool = if case .airc(let t)? = airc { t == ShortcutCenter.title("file.newTab") } else { false }
            check(system == .system("Spotlight") && aircOK && other == .otherApp && none == nil && airc?.canUseAnyway == true && system?.canUseAnyway == false,
                  "P06b: a key macOS uses (⌘Space: Spotlight), an Airc command's (⌘T), another app's (it holds ⌃⌥⌘K) are named; a free one isn't "
                  + "(\(String(describing: system)), \(String(describing: airc)), \(String(describing: other)), \(String(describing: none)))")
        }
        settings { $0.shortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, key: "l") }
        run { [self] in
            check(registrar.registered?.keyCode == UInt32(kVK_ANSI_L) && actions.problem == nil,
                  "P06b: rebound to ⌃⌥⌘L, that key is registered (\(registrar.registered?.display ?? "none"))")
        }
        settings { $0.shortcut = GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags.command.rawValue, key: " ") }
        run { [self] in
            check(registrar.registered == nil && actions.problem == .system("Spotlight"),
                  "P06b: a key macOS uses isn't registered, and Settings says why (\(actions.problem?.message ?? "-"))")
            registrar.refuse = [UInt32(kVK_ANSI_K)]
        }
        settings { $0.shortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, key: "k") }
        run { [self] in
            check(registrar.registered == nil && actions.problem == .otherApp, "P06b: a key another app holds: \(actions.problem?.message ?? "-")")
            registrar.refuse = []
        }
        settings { $0.shortcut = .littleArcDefault }

        // The real Carbon plumbing, with a key nobody uses, held for an instant.
        run { [self] in
            // The real registration, on a combo nobody uses (⌃⌥⇧⌘F19), held for well under a second and logged.
            let real = CarbonHotKeyRegistrar()
            let f19 = GlobalShortcut(keyCode: UInt32(kVK_F19), modifiers: NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue, key: "f19")
            let start = ProcessInfo.processInfo.systemUptime
            let status = real.register(f19) {}
            let installed = real.isInstalled
            real.unregister()
            let held = ProcessInfo.processInfo.systemUptime - start
            note("P06b: real Carbon hot key ⌃⌥⇧⌘F19 registered (status \(status)) and released after \(String(format: "%.1f", held * 1000)) ms")
            check(status == noErr && installed && !real.isInstalled && held < 1,
                  "P06b: Carbon registers a global hot key (⌃⌥⇧⌘F19, status \(status)) and lets go of it within a second (\(String(format: "%.1f", held * 1000)) ms)")
        }

        // Show and close all; the Dock menu.
        var pages: [String] = []
        step { [self] done in
            guard !base.isEmpty else { return done() }
            for i in 0..<3 { _ = app?.openLittleArc(url: URL(string: "\(base)/p?n=\(i)")) }
            waitUntil({ self.app?.littleArcs.count == 3 && self.app?.littleArcs.allSatisfy { $0.page?.isLoading == false && $0.page?.url != nil } == true }, timeout: 8) {
                pages = self.app?.littleArcs.compactMap { $0.page?.url?.absoluteString } ?? []
                self.app?.littleArcs.first?.window.orderOut(nil)
                done()
            }
        }
        run { [self] in
            // Window › Show/Close Little Airc Windows (enabled now) and their Command Bar lines.
            let window = NSApp.windowsMenu?.items.filter { $0.title.hasSuffix("Little Airc Windows") } ?? []
            let enabled = window.allSatisfy { ($0 as? NSMenuItemValidation)?.validateMenuItem($0) == true }
            let bar = c.contextCommandActions().map(\.title).filter { $0.hasSuffix("Little Airc Windows") }
            check(window.map(\.title) == ["Show Little Airc Windows", "Close Little Airc Windows"] && enabled && bar == window.map(\.title),
                  "P06b: Window › Show and Close Little Airc Windows, enabled with Little Airc windows open, and the same two in the Command Bar "
                  + "(menu \(window.map(\.title)), enabled \(enabled), Command Bar \(bar))")
            let titles = app.flatMap { $0.applicationDockMenu(NSApp) }?.items.map(\.title) ?? []
            let hidden = app?.littleArcs.filter { !$0.window.isVisible }.count ?? 0
            actions.showAll()
            let visible = app?.littleArcs.allSatisfy { $0.window.isVisible } == true
            check(titles.suffix(2) == ["Show Little Airc Windows", "Close Little Airc Windows"] && hidden == 1 && visible,
                  "P06b: the Dock menu offers Show and Close Little Airc Windows; Show brings a hidden one back (\(titles), hidden \(hidden), all visible \(visible))")
        }
        run { [self] in
            let before = Set(c.store.state.archive.keys)
            actions.closeAll()
            let added = c.store.state.archive.filter { !before.contains($0.key) }.values
            let urls = Set(added.map(\.url))
            check(added.count == 3 && urls == Set(pages) && added.allSatisfy { $0.origin == ArchiveEntry.littleArcOrigin },
                  "P06b: Close Little Airc Windows sends each page to the Archive, marked as Little Airc's (archived \(added.count) of \(pages.count))")
        }
        step { [self] done in
            waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 4) {
                let titles = self.app.flatMap { $0.applicationDockMenu(NSApp) }?.items.map(\.title) ?? []
                let window = NSApp.windowsMenu?.items.filter { $0.title.hasSuffix("Little Airc Windows") } ?? []
                let disabled = !window.isEmpty && window.allSatisfy { ($0 as? NSMenuItemValidation)?.validateMenuItem($0) == false }
                let bar = self.c.contextCommandActions().map(\.title).filter { $0.hasSuffix("Little Airc Windows") }
                self.check(self.app?.littleArcs.isEmpty == true && !titles.contains { $0.contains("Little Airc") } && disabled && bar.isEmpty,
                           "P06b: and closes them; with none left, the Dock menu has no Little Airc entries (\(titles)), the Window menu's are off "
                           + "(\(disabled)) and the Command Bar has none (\(bar))")
                done()
            }
        }

        // "Archive Little Aircs after".
        settings { $0.archiveAfter = .oneHour }
        step { [self] done in
            let l = app?.openLittleArc(url: nil)
            let due = l?.archiveDue.map { $0.timeIntervalSinceNow } ?? 0
            let hour = LittleArcController.archiveAfter == 3600 && due > 3500 && due <= 3600
            app?.settings.values.littleArcGlobal.archiveAfter = .never
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let never = LittleArcController.archiveAfter == .infinity && l?.archiveDue == nil
                self.check(hour && never, "P06b: Archive Little Aircs after 1 hour sets the timer (\(Int(due)) s); Never stops it (\(never))")
                l?.closeWindow()
                done()
            }
        }

        // Off again: nothing installed.
        settings { $0.enabled = false; $0.archiveAfter = .sixHours }
        run { [self] in
            check(!actions.isInstalled && registrar.registered == nil, "P06b: turned off, the shortcut and its handler are gone")
            LittleArcController.startsHidden = false
            server?.stop()
        }
    }
}

/// Stands in for the Carbon registrar: records what's registered; refuses the keys another app "holds".
final class P06bRegistrar: GlobalHotKeyRegistrar {
    private(set) var registered: GlobalShortcut?
    private var handler: (() -> Void)?
    var refuse: Set<UInt32> = []
    var isInstalled: Bool { registered != nil }

    func register(_ shortcut: GlobalShortcut, handler: @escaping () -> Void) -> OSStatus {
        unregister()
        if refuse.contains(shortcut.keyCode) { return OSStatus(eventHotKeyExistsErr) }
        registered = shortcut
        self.handler = handler
        return noErr
    }

    func unregister() {
        registered = nil
        handler = nil
    }

    /// The person presses the shortcut.
    func press() { handler?() }
}

/// Stands in for the Accessibility reader: whether access is granted, the selection, and what was asked of it.
final class P06bSelection: SelectionReader {
    var trusted = false
    var text: String?
    private(set) var reads = 0
    private(set) var prompts = 0
    var isTrusted: Bool { trusted }

    func selectedText() -> String? {
        reads += 1
        return trusted ? text : nil
    }

    func requestTrust() { prompts += 1 }
}
#endif

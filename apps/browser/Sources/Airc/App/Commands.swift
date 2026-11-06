// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import QuartzCore

/// Every browser command with its Arc shortcut (CB-2). The main menu shows them; a key monitor
/// runs them before the page sees the key, so a web page can't swallow ⌘T or ⌃2.
struct BrowserCommand {
    let title: String
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let run: (WindowController) -> Void

    init(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [], _ run: @escaping (WindowController) -> Void) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.run = run
    }

    static func arrow(_ k: Int) -> String { String(Character(UnicodeScalar(k)!)) }
    static let left = arrow(NSLeftArrowFunctionKey)
    static let right = arrow(NSRightArrowFunctionKey)
    static let up = arrow(NSUpArrowFunctionKey)
    static let down = arrow(NSDownArrowFunctionKey)
}

enum CommandMenus {
    static func file() -> [BrowserCommand?] {
        [
            BrowserCommand("New Tab", "t", .command) { $0.openCommandBar(mode: .newTab) },
            BrowserCommand("Open Location…", "l", .command) { $0.openCommandBar(mode: .editURL) },
            BrowserCommand("New Window", "n", .command) { $0.showStub("New windows") },
            BrowserCommand("New Private Window", "n", [.command, .shift]) { $0.showStub("Private windows") },
            BrowserCommand("New Little Arc Window", "n", [.command, .option]) { $0.app?.openLittleArc(url: nil) },
            nil,
            // LA-1: these act in a Little Arc window (LittleArcController.handleKey); the main window has nothing to move.
            BrowserCommand("Open in Space", "o", .command) { c in if c.peek != nil { c.promotePeek() } else { NSSound.beep() } },
            BrowserCommand("Open in Space…", "o", [.command, .option]) { _ in NSSound.beep() },
            nil,
            BrowserCommand("Close Tab", "w", .command) { $0.closeCurrentTab() },
            BrowserCommand("Reopen Closed Tab", "t", [.command, .shift]) { $0.undo() },
            nil,
            BrowserCommand("Save Page As…", "s", [.command, .shift]) { $0.showStub("Save Page") },
            BrowserCommand("Print…", "p", .command) { $0.printPage() },
        ]
    }

    static func editExtras() -> [BrowserCommand?] {
        [
            BrowserCommand("Copy URL", "c", [.command, .shift]) { $0.copyURL() },
            BrowserCommand("Copy URL as Markdown", "c", [.command, .shift, .option]) { $0.copyURLMarkdown() },
            nil,
            BrowserCommand("Find…", "f", .command) { $0.showFind() },
            BrowserCommand("Find Next", "g", .command) { $0.findAgain(forward: true) },
            BrowserCommand("Find Previous", "g", [.command, .shift]) { $0.findAgain(forward: false) },
        ]
    }

    static func view() -> [BrowserCommand?] {
        [
            BrowserCommand("Toggle Sidebar", "s", .command) { $0.toggleSidebar() },
            BrowserCommand("Reload Page", "r", .command) { $0.reloadOrStop() },
            BrowserCommand("Reload Ignoring Cache", "r", [.command, .shift]) { $0.reloadIgnoringCache() },
            nil,
            BrowserCommand("Zoom In", "=", .command) { $0.zoom(step: 1); $0.siteControlsDidZoom() },
            BrowserCommand("Zoom Out", "-", .command) { $0.zoom(step: -1); $0.siteControlsDidZoom() },
            BrowserCommand("Actual Size", "0", .command) { $0.zoom(step: 0); $0.siteControlsDidZoom() },
            nil,
            BrowserCommand("Extensions", "e", .command) { $0.showExtensions() },
            BrowserCommand("Site Controls") { $0.toggleSiteControls() },
            // BST-1. Arc had no shortcut for its Boost editor, so neither does this.
            BrowserCommand("Boost This Site…") { $0.showBoostEditor() },
            BrowserCommand("History", "y", .command) { $0.showHistory() },
            nil,
            BrowserCommand("Developer Tools", "i", [.command, .option]) { $0.showDevTools(console: false) },
            BrowserCommand("JavaScript Console", "j", [.command, .option]) { $0.showDevTools(console: true) },
            BrowserCommand("View Source", "u", [.command, .option]) { $0.viewSource() },
        ]
    }

    static func spaces() -> [BrowserCommand?] {
        var c: [BrowserCommand?] = [
            BrowserCommand("New Space…") { $0.openNewSpacePanel() },
            BrowserCommand("Rename Space…") { $0.renameCurrentSpace() },
            BrowserCommand("Edit Theme Color…") { $0.editTheme($0.currentSpaceID) },
            BrowserCommand("New Profile…") { $0.openCreateProfile(forSpace: $0.currentSpaceID) },
            nil,
            BrowserCommand("Next Space", BrowserCommand.right, [.command, .option]) { $0.switchSpace(offset: 1) },
            BrowserCommand("Previous Space", BrowserCommand.left, [.command, .option]) { $0.switchSpace(offset: -1) },
            nil,
        ]
        for n in 1...9 {
            c.append(BrowserCommand("Space \(n)", "\(n)", .control) { $0.switchToSpace(number: n) })
        }
        c.append(nil)
        c.append(BrowserCommand("Delete Space…") { $0.deleteSpace($0.currentSpaceID) })
        return c
    }

    static func tabs() -> [BrowserCommand?] {
        var c: [BrowserCommand?] = [
            BrowserCommand("Pin / Unpin Tab", "d", .command) { $0.togglePin() },
            BrowserCommand("Add to Favorites") { $0.addCurrentToFavorites() },
            BrowserCommand("Clear Today", "k", [.command, .shift]) { $0.clearToday() },
            nil,
            BrowserCommand("Next Tab", BrowserCommand.down, [.command, .option]) { $0.selectAdjacentTab(1) },
            BrowserCommand("Previous Tab", BrowserCommand.up, [.command, .option]) { $0.selectAdjacentTab(-1) },
            BrowserCommand("Last Used Tab", "\t", .control) { $0.selectLastTab() },
            nil,
            // SV-1 (spec §2.16b): in a split, ⌘[ / ⌘] move between the panes; elsewhere they're Back and Forward.
            BrowserCommand("Back", "[", .command) { if !$0.focusAdjacentPane(-1) { $0.goBack() } },
            BrowserCommand("Forward", "]", .command) { if !$0.focusAdjacentPane(1) { $0.goForward() } },
            nil,
            // Arc's split keys: ⌃⇧+ adds a pane, ⌃⇧− closes the focused one, ⌃⇧1–4 focus a pane.
            BrowserCommand("New Split View", "=", [.control, .shift]) { $0.newSplitView() },
            BrowserCommand("Close Pane", "-", [.control, .shift]) { $0.closeFocusedPane() },
            BrowserCommand("Separate All Tabs") { $0.separateShownSplit() },
        ]
        for n in 1...4 {
            c.append(BrowserCommand("Focus Pane \(n)", "\(n)", [.control, .shift]) { $0.focusPane(number: n) })
        }
        c.append(nil)
        for n in 1...9 {
            c.append(BrowserCommand(n == 9 ? "Last Sidebar Tab" : "Sidebar Tab \(n)", "\(n)", .command) { $0.selectTab(number: n) })
        }
        c.append(nil)
        c.append(BrowserCommand("Library", "l", [.command, .shift]) { $0.showLibrary() })
        return c
    }

    static var all: [BrowserCommand] {
        (file() + editExtras() + view() + spaces() + tabs()).compactMap { $0 }
    }
}

final class CommandMenuItem: NSMenuItem {
    var command: BrowserCommand?
    weak var app: AppDelegate?
    @objc func fire() {
        guard let c = app?.controller, let command else { return }
        // A Little Arc window takes its own shortcuts; the main window's commands don't reach into it.
        if let little = app?.littleArc(for: NSApp.keyWindow) {
            if let e = NSApp.currentEvent, e.type == .keyDown, little.handleKey(e) { return }
            if command.title == "New Little Arc Window" { command.run(c) }
            return
        }
        KeyMonitor.menuFired(command, in: c)
    }
}

enum MainMenu {
    static func build(app: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Airc")
        appMenu.addItem(withTitle: "About Airc", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        #if canImport(Sparkle)
        let updates = appMenu.addItem(withTitle: "Check for Updates…", action: NSSelectorFromString("checkForUpdates:"), keyEquivalent: "")
        updates.target = app.updaterController
        #endif
        appMenu.addItem(.separator())
        appMenu.addItem(closure("Settings…", ",", .command, app) { $0.app?.showSettings() })
        appMenu.addItem(closure("Import from Arc…", "", [], app) { $0.app?.startOnboarding(mode: .rerun, atImport: true) })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Airc", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Airc", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, to: main)

        add(menu("File", CommandMenus.file(), app), to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        for c in CommandMenus.editExtras() { edit.addItem(item(c, app)) }
        add(edit, to: main)

        let view = menu("View", CommandMenus.view(), app)
        view.addItem(.separator())
        view.addItem(FullScreenMenu.item())
        view.delegate = FullScreenMenu.shared
        add(view, to: main)

        add(menu("Spaces", CommandMenus.spaces(), app), to: main)
        add(menu("Tabs", CommandMenus.tabs(), app), to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, to: main)
        NSApp.windowsMenu = window
        return main
    }

    private static func add(_ m: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
        item.submenu = m
        main.addItem(item)
    }

    private static func menu(_ title: String, _ commands: [BrowserCommand?], _ app: AppDelegate) -> NSMenu {
        let m = NSMenu(title: title)
        for c in commands { m.addItem(item(c, app)) }
        return m
    }

    private static func item(_ c: BrowserCommand?, _ app: AppDelegate) -> NSMenuItem {
        guard let c else { return .separator() }
        let i = CommandMenuItem(title: c.title, action: #selector(CommandMenuItem.fire), keyEquivalent: c.key)
        i.keyEquivalentModifierMask = c.modifiers
        i.command = c
        i.app = app
        i.target = i
        return i
    }

    private static func closure(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ app: AppDelegate,
                                _ run: @escaping (WindowController) -> Void) -> NSMenuItem {
        item(BrowserCommand(title, key, mods, run), app)
    }
}

/// Runs browser shortcuts before the focused view (often the web page) sees them, except where CB-3 lets a page
/// have its own shortcut first.
enum KeyMonitor {
    /// Arc's hold-to-quit: ⌘Q quits only when held; a tap shows "Hold ⌘Q to Quit".
    private static var quitHold: DispatchWorkItem?

    // MARK: CB-3, "prefer website"

    /// A shortcut handed to the page, waiting for the page to say whether it used it.
    private struct Pending {
        let command: BrowserCommand
        let fallback: DispatchWorkItem
    }
    private static var pending: [String: Pending] = [:]
    /// A shortcut was handed to the page and its answer hasn't come yet (the real-event checks wait for it).
    static var isWaitingForPage: Bool { !pending.isEmpty }
    /// How long the browser waits for the page's answer before running its own command anyway. Only a page that never
    /// answers waits this long; a busy renderer (heavy load) can take a few hundred ms, and a shorter wait then ran the
    /// browser's command on top of the page's own use of the key.
    static let pageAnswerTimeout: TimeInterval = 1.0
    /// Shortcuts the page used, and when: pressing one again within a second runs the browser's command.
    private static var pageUsed: [String: CFTimeInterval] = [:]
    static let secondPressWindow: CFTimeInterval = 1.0

    /// Chrome's reserved shortcuts (pages never get them) and ⌥/⌃ combinations stay browser-first.
    private static func pageMayUse(_ cmd: BrowserCommand) -> Bool {
        guard cmd.modifiers.contains(.command), !cmd.modifiers.contains(.option), !cmd.modifiers.contains(.control) else { return false }
        return !["t", "w", "n", "q"].contains(cmd.key.lowercased())
    }

    /// The same spelling the page script reports (WebKitEngine.keysScript).
    static func combo(_ cmd: BrowserCommand) -> String {
        "cmd+" + (cmd.modifiers.contains(.shift) ? "shift+" : "") + cmd.key.lowercased()
    }

    /// The page answered: run the browser's command if it didn't use the shortcut, otherwise wait for a second press.
    static func pageReported(_ combo: String, pageUsedIt: Bool, in c: WindowController) {
        // ⇧ shortcuts arrive from the page with an upper-case or shifted key; match on what we're waiting for.
        guard let key = pending.keys.first(where: { $0 == combo || $0.lowercased() == combo.lowercased() }),
              let p = pending.removeValue(forKey: key) else { return }
        p.fallback.cancel()
        if pageUsedIt { pageUsed[key] = CACurrentMediaTime() } else { p.command.run(c) }
    }

    /// The menu ran a command (a click, or the engine handing back a key the page didn't use): run it once.
    static func menuFired(_ cmd: BrowserCommand, in c: WindowController) {
        if let p = pending.removeValue(forKey: combo(cmd)) { p.fallback.cancel() }
        cmd.run(c)
    }

    /// Hands `cmd`'s key to the focused page first (true), or returns false when the browser's command runs now.
    private static func offerToPage(_ cmd: BrowserCommand, in c: WindowController) -> Bool {
        guard pageMayUse(cmd), c.app?.engine.reportsPageShortcuts == true, let page = c.focusedPage,
              let scheme = page.url?.scheme, ["http", "https", "file", "data"].contains(scheme) else { return false }
        let key = combo(cmd)
        if let t = pageUsed.removeValue(forKey: key), CACurrentMediaTime() - t < secondPressWindow { return false }
        pending[key]?.fallback.cancel()
        // No answer (a page the script couldn't reach, a hung renderer): the browser's command runs anyway.
        let fallback = DispatchWorkItem { [weak c] in
            guard let c, let p = pending.removeValue(forKey: key) else { return }
            p.command.run(c)
        }
        pending[key] = Pending(command: cmd, fallback: fallback)
        DispatchQueue.main.asyncAfter(deadline: .now() + pageAnswerTimeout, execute: fallback)
        return true
    }

    static func install(app: AppDelegate) -> Any? {
        let commands = CommandMenus.all
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak app] event in
            if event.charactersIgnoringModifiers?.lowercased() == "q" { quitHold?.cancel(); quitHold = nil }
            if event.keyCode == 53 { app?.controller?.fullScreen.escapeUp() }
            return event
        }
        return NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak app] event in
            guard let app else { return event }
            var mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "q" {
                guard !event.isARepeat, quitHold == nil, !app.options.isAutomated else { return nil }
                app.controller?.showToast("Hold ⌘Q to Quit")
                let work = DispatchWorkItem { NSApp.terminate(nil) }
                quitHold = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
                return nil
            }
            if let little = app.littleArc(for: event.window) { return little.handleKey(event) ? nil : event }
            guard let c = app.controller, event.window === c.window else { return event }
            // Full screen (Arc): Esc goes to the page; a second press, or holding it, leaves full screen.
            // Peek: Esc closes it. So does Site Controls (first: it's above the page).
            if event.keyCode == 53, mods.isEmpty, c.closeSiteControls() { return nil }
            // The Boost editor: Esc ends Zap, then closes it. ⌘S in its code view saves the code (not the sidebar).
            if event.keyCode == 53, mods.isEmpty, c.boostEditorHandlesEscape() { return nil }
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "s", c.boostEditorSavesCode() { return nil }
            if event.keyCode == 53, mods.isEmpty, c.peek != nil { c.closePeek(); return nil }
            if event.keyCode == 53, mods.isEmpty, c.fullScreen.escapeDown(event) { return nil }
            guard !mods.isEmpty, var chars = event.charactersIgnoringModifiers?.lowercased() else { return event }
            // ⌘+ is ⇧⌘= on most layouts: the same command as ⌘=.
            if chars == "+", mods.contains(.command) { chars = "="; mods.remove(.shift) }
            // ⌃⇧ with = − 1…4 (the split keys) arrive as + _ ! @ …: matched by the key itself.
            if mods == [.control, .shift], let k = [24: "=", 27: "-", 18: "1", 19: "2", 20: "3", 21: "4"][Int(event.keyCode)] { chars = k }
            let editingText = c.window.firstResponder is NSTextView
            // ⌘Z: text fields undo their own typing; elsewhere it restores closed tabs (SB-23, SB-40).
            if chars == "z", mods == .command, !editingText {
                c.undo()
                return nil
            }
            for cmd in commands where !cmd.key.isEmpty {
                guard cmd.key.lowercased() == chars, cmd.modifiers == mods else { continue }
                // Plain editing shortcuts belong to the field being edited.
                if editingText, mods == .command, ["a", "c", "v", "x"].contains(chars) { return event }
                if offerToPage(cmd, in: c) {
                    // Straight to the page, whatever AppKit's own order (the main menu could otherwise take it first).
                    if let r = c.window.firstResponder as? NSView, !r.performKeyEquivalent(with: event) { r.keyDown(with: event) }
                    return nil
                }
                cmd.run(c)
                return nil
            }
            return event
        }
    }
}
